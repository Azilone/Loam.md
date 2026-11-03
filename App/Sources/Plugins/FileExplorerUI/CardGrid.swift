import AppKit
import PluginKit
import PluginKitUI
import SwiftUI

/// The cards of a folder page in AppKit: a scroll view whose document places them itself, as a masonry of columns
/// (`FolderGridView.deal`). Each card is its SwiftUI view (`NoteCardView`, with its hover, cascade, drag, menu and
/// open-from-card origin) in a hosting view of its own, and only the cards on screen, and a screenful around them,
/// live. A card's height is measured once per width and kept, so a scroll moves frames and never lays a card out
/// again, and a window resize lays out only the cards on screen.
///
/// SwiftUI's lazy stacks re-measured the visible cards on every frame of a scroll and every step of a resize, and
/// hit-tested all of them on every event: All Notes scrolled and resized well under 120 frames a second.
struct CardGrid: NSViewRepresentable {
    let model: ExplorerModel
    let resource: Resource
    let items: [ExplorerModel.Item]
    /// Whether the first cards have cascaded in: later cards appear at once.
    let isSettled: Bool
    @Environment(\.themeTokens) private var theme
    @Environment(\.pageChromeInset) private var chromeInset

    func makeNSView(context: Context) -> CardGridView {
        let view = CardGridView(model: model)
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ view: CardGridView, context: Context) {
        view.update(CardGridView.State(
            resource: resource, items: items, isSettled: isSettled, theme: theme, chromeInset: chromeInset
        ))
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: CardGridView, context: Context) -> CGSize? {
        proposal.replacingUnspecifiedDimensions(by: .zero)
    }
}

final class CardGridView: NSScrollView {
    /// What the grid shows, given by SwiftUI on each of its updates.
    struct State {
        var resource: Resource
        var items: [ExplorerModel.Item]
        var isSettled: Bool
        var theme: ThemeTokens
        var chromeInset: CGFloat
    }

    let model: ExplorerModel
    let document = CardDocumentView()
    private let bottomFade = CAGradientLayer()
    private var isScrolling = false

    init(model: ExplorerModel) {
        self.model = model
        super.init(frame: .zero)
        document.grid = self
        drawsBackground = false
        contentView.drawsBackground = false
        hasVerticalScroller = true
        autohidesScrollers = true
        scrollerStyle = .overlay
        hasHorizontalScroller = false
        horizontalScrollElasticity = .none
        // The toolbar's room is the page's, given here (`pageChromeInset`); the window's title bar is not ours.
        automaticallyAdjustsContentInsets = false
        documentView = document
        contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(scrolled), name: NSView.boundsDidChangeNotification, object: contentView
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(liveScroll(_:)), name: NSScrollView.willStartLiveScrollNotification, object: self
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(liveScroll(_:)), name: NSScrollView.didEndLiveScrollNotification, object: self
        )
        wantsLayer = true
        bottomFade.zPosition = 10
        layer?.addSublayer(bottomFade)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var mouseDownCanMoveWindow: Bool { false }

    func update(_ state: State) {
        if contentInsets.top != state.chromeInset {
            contentInsets = NSEdgeInsets(top: state.chromeInset, left: 0, bottom: 0, right: 0)
            scrollerInsets = NSEdgeInsets(top: state.chromeInset, left: 0, bottom: 0, right: 0)
        }
        document.update(state)
        updateFade()
    }

    override func tile() {
        super.tile()
        document.widthChanged(contentView.bounds.width)
        updateFade()
    }

    @objc private func scrolled() {
        document.scrolled()
        updateFade()
    }

    /// The cards wait for a scroll to stop before drawing their diagrams (`isScrollingCards`).
    @objc private func liveScroll(_ note: Notification) {
        let scrolling = note.name == NSScrollView.willStartLiveScrollNotification
        guard scrolling != isScrolling else { return }
        isScrolling = scrolling
        document.setScrolling(scrolling)
    }

    /// The bottom of the page fades into the page's colour while more cards lie below, as `softScrollEdges`.
    private func updateFade() {
        guard let color = document.state.map({ NSColor($0.theme.background) }) else { return }
        let visible = contentView.bounds
        let distance = document.frame.height - visible.maxY
        let strength = Motion.EdgeGlass.steppedProgress(distance: distance)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let length = Motion.EdgeGlass.length
        bottomFade.frame = CGRect(x: 0, y: isFlipped ? bounds.height - length : 0, width: bounds.width, height: length)
        let steps = 8
        effectiveAppearance.performAsCurrentDrawingAppearance {
            bottomFade.colors = (0...steps).map { step in
                let fraction = Double(step) / Double(steps)
                return color.withAlphaComponent(0.9 * strength * Motion.EdgeGlass.rampOpacity(at: fraction)).cgColor
            }
        }
        bottomFade.locations = (0...steps).map { NSNumber(value: Double($0) / Double(steps)) }
        // From the edge (the bottom) towards the cards.
        bottomFade.startPoint = CGPoint(x: 0.5, y: isFlipped ? 1 : 0)
        bottomFade.endPoint = CGPoint(x: 0.5, y: isFlipped ? 0 : 1)
        bottomFade.isHidden = strength <= 0
        CATransaction.commit()
    }
}

/// The scroll view's document: the page's title and the cards, placed by hand.
final class CardDocumentView: NSView {
    weak var grid: CardGridView?
    private(set) var state: CardGridView.State?

    /// The page's title (and the item count of a print theme), over the cards.
    private var header: NSHostingView<CardGridHeader>?
    /// The cards on screen and around it, by path.
    private(set) var live: [String: CardHost] = [:]
    /// Hosts ready for the next card that comes into view.
    private var pool: [CardHost] = []
    /// Cards made once and set aside, hidden, by path: one coming back into view is shown as it was, never made
    /// again.
    private var parked: [String: CardHost] = [:]
    /// The most cards kept made; past it, a parked card's host goes back to the pool.
    static let parkedLimit = 400
    /// Whether the page is scrolling, for the cards brought back from `parked`.
    private var isScrolling = false

    /// Where each card goes, worked out when the cards, the width or a card's height change.
    private var placed: [Placed] = []
    private var width: CGFloat = 0

    /// Each card's height at a column width, measured once: while its note and the width stay the same, a card is
    /// never laid out again to be placed.
    private var heights: [HeightKey: CGFloat] = [:]
    /// How many times a card was measured, for the tests: a scroll must not add to it.
    private(set) var measureCount = 0
    /// Where each card goes, for the tests.
    var placedFrames: [String: CGRect] { Dictionary(placed.map { ($0.item.path, $0.frame) }, uniquingKeysWith: { a, _ in a }) }

    struct HeightKey: Hashable {
        let path: String
        let width: Int
        let modified: Double
    }

    struct Placed {
        let item: ExplorerModel.Item
        let index: Int
        var frame: CGRect
    }

    /// How far past the visible rect cards are kept alive, so a scroll finds them ready.
    static let margin: CGFloat = 600
    /// Room around a card's own frame inside its hosting view, for its lift and shadow on hover.
    static let outset: CGFloat = 16

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    func update(_ new: CardGridView.State) {
        let old = state
        state = new
        if old?.theme != new.theme {
            heights = [:]
            for host in live.values { host.theme = new.theme }
            for host in pool { host.theme = new.theme }
            for host in parked.values { host.theme = new.theme }
        }
        if old?.isSettled != new.isSettled { for host in live.values { host.isSettled = new.isSettled } }
        if old?.resource != new.resource { grid?.contentView.scroll(to: NSPoint(x: 0, y: -(grid?.contentInsets.top ?? 0))) }
        updateHeader()
        // A note that changed (its stamp) is measured again.
        relayout()
    }

    func widthChanged(_ newWidth: CGFloat) {
        guard newWidth != width else { return }
        width = newWidth
        relayout()
    }

    override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        showVisibleCards()
        settleHover()
    }

    /// Where the pointer is, in this view; nil when it is not over the window. Settable for the tests.
    var pointerLocation: () -> NSPoint? = { nil }

    private func pointer() -> NSPoint? {
        if let point = pointerLocation() { return point }
        guard let window else { return nil }
        return convert(window.mouseLocationOutsideOfEventStream, from: nil)
    }

    /// Notes the cards the pointer is over now, which may take their hover pose.
    private func notePointer() {
        guard let point = pointer() else { return }
        for host in live.values where host.cardFrame.contains(point) { host.mayBeHovered = true }
    }

    /// Once cards have stopped moving (a resize or a scroll has ended), the ones the pointer went over and has left
    /// are taken out of their hover pose.
    func settleHover() {
        let point = pointer()
        for host in live.values where host.mayBeHovered {
            if let point, host.cardFrame.contains(point) { continue }
            host.dropHover()
        }
    }

    private var scrollGeneration = 0

    /// A scroll has moved the cards: their hover is settled once it has stopped for a moment.
    func scrolled() {
        showVisibleCards()
        scrollGeneration += 1
        let generation = scrollGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self, self.scrollGeneration == generation else { return }
            self.settleHover()
        }
    }

    func setScrolling(_ scrolling: Bool) {
        isScrolling = scrolling
        for host in live.values { host.isScrolling = scrolling }
    }

    // MARK: Layout

    private var contentWidth: CGFloat {
        max(0, min(width - 2 * FolderGridView.horizontalPadding, FolderGridView.maxWidth))
    }

    /// The page's column of content (`pageColumn(.wide)`): as wide as the page up to `maxWidth`, centred.
    private var contentX: CGFloat {
        max(0, (width - contentWidth) / 2)
    }

    private func updateHeader() {
        guard let state else { return }
        let root = CardGridHeader(
            count: state.items.count, title: ExplorerModel.title(of: state.resource), theme: state.theme,
            newItem: model?.newItem(for: state.resource), isEmpty: state.items.isEmpty,
            newNote: { [weak self] in
                guard let model = self?.model, let resource = self?.state?.resource else { return }
                model.newNote(in: model.newNoteFolder(for: resource))
            }
        )
        if let header {
            header.rootView = root
        } else {
            let host = NSHostingView(rootView: root)
            host.safeAreaRegions = []
            host.sizingOptions = []
            addSubview(host)
            header = host
        }
    }

    private var model: ExplorerModel? { grid?.model }

    /// The header's height at the content's width.
    private func headerHeight() -> CGFloat {
        guard let header else { return 0 }
        let controller = NSHostingController(rootView: header.rootView)
        return ceil(controller.sizeThatFits(in: CGSize(width: contentWidth, height: .greatestFiniteMagnitude)).height)
    }

    private var lastHeaderKey: (width: CGFloat, count: Int, title: String, empty: Bool, theme: ThemeTokens?)?
    private var lastHeaderHeight: CGFloat = 0

    /// Places every card: deals them to the columns by their estimated heights, as SwiftUI's grid did, then stacks
    /// each column with the heights measured so far (estimated for a card not measured yet).
    func relayout() {
        guard let state, let model, width > 0 else { return }
        let contentWidth = self.contentWidth
        let count = FolderGridView.columnCount(for: contentWidth)
        let spacing = FolderGridView.spacing
        let columnWidth = max(0, (contentWidth - spacing * CGFloat(count - 1)) / CGFloat(count))
        let columns = FolderGridView.deal(state.items, into: count) { model.estimatedHeight(of: $0, width: columnWidth) }

        let headerKey = (contentWidth, state.items.count, ExplorerModel.title(of: state.resource), state.items.isEmpty, state.theme)
        if lastHeaderKey.map({ $0.width != headerKey.0 || $0.count != headerKey.1 || $0.title != headerKey.2 || $0.empty != headerKey.3 || $0.theme != headerKey.4 }) ?? true {
            lastHeaderKey = headerKey
            lastHeaderHeight = headerHeight()
        }
        let top = PageMetrics.top
        header?.frame = CGRect(x: contentX, y: top, width: contentWidth, height: lastHeaderHeight)
        let cardsTop = top + lastHeaderHeight + (state.items.isEmpty ? 0 : PageMetrics.headerGap)

        var placed: [Placed] = []
        var bottom = cardsTop
        for (column, dealt) in columns.enumerated() {
            var y = cardsTop
            let x = contentX + CGFloat(column) * (columnWidth + spacing)
            // On the pixel grid, as a stack places its children; the heights stay exact so nothing adds up. The
            // cards are measured at this width, which the heights are kept under.
            let left = pixel(x), cardWidth = pixel(x + columnWidth) - left
            for entry in dealt {
                let height = heights[key(for: entry.item, width: cardWidth)]
                    ?? model.estimatedHeight(of: entry.item, width: columnWidth)
                let top = pixel(y), end = pixel(y + height)
                placed.append(Placed(item: entry.item, index: entry.index, frame: CGRect(x: left, y: top, width: cardWidth, height: end - top)))
                y += height + spacing
            }
            bottom = max(bottom, y - (dealt.isEmpty ? 0 : spacing))
        }
        self.placed = placed
        // Cards no longer on the page (another folder, a note gone) give their hosts back.
        let present = Set(placed.map(\.item.path))
        for (path, host) in parked where !present.contains(path) {
            parked[path] = nil
            pool.append(host)
        }
        let height = max(bottom + 32, (grid?.contentView.bounds.height ?? 0) - (grid?.contentInsets.top ?? 0))
        let size = NSSize(width: width, height: height)
        if frame.size != size { setFrameSize(size) }
        showVisibleCards()
    }

    private func pixel(_ value: CGFloat) -> CGFloat {
        let scale = window?.backingScaleFactor ?? 2
        return (value * scale).rounded() / scale
    }

    private func key(for item: ExplorerModel.Item, width: CGFloat) -> HeightKey {
        HeightKey(path: item.path, width: Int((width * 2).rounded()), modified: model?.noteStamps[item.path]?.modified ?? 0)
    }

    /// Makes the cards in view (and a margin around) live, measures the ones not measured at this width, and lets
    /// the others go back to the pool. When a measured height differs from what was used to place a card, the
    /// columns are stacked again.
    func showVisibleCards() {
        guard let grid, let state else { return }
        // While the window is resized only the cards on screen are laid out at each step; the ones around them catch
        // up once the resize ends (`viewDidEndLiveResize`).
        let visible = grid.contentView.bounds.insetBy(dx: 0, dy: inLiveResize ? 0 : -Self.margin)
        var wanted = Set<String>()
        var remeasured = false
        for (number, entry) in placed.enumerated() where entry.frame.intersects(visible) {
            wanted.insert(entry.item.path)
            let host = live[entry.item.path] ?? parked.removeValue(forKey: entry.item.path).map { host in
                host.isScrolling = isScrolling
                host.isSettled = state.isSettled
                host.isHidden = false
                return host
            } ?? take(entry.item, index: entry.index, state: state)
            live[entry.item.path] = host
            let heightKey = key(for: entry.item, width: entry.frame.width)
            if heights[heightKey] == nil {
                // At its new width first, so that the measure and the layout that follows ask SwiftUI the same
                // question, and the card is laid out once.
                host.frame = entry.frame.insetBy(dx: -Self.outset, dy: -Self.outset)
                let measured = host.measuredHeight()
                measureCount += 1
                heights[heightKey] = measured
                if abs(measured - entry.frame.height) > 0.5 { remeasured = true }
                placed[number].frame.size.height = measured
            }
            host.frame = entry.frame.insetBy(dx: -Self.outset, dy: -Self.outset)
        }
        notePointer()
        for (path, host) in live where !wanted.contains(path) {
            live[path] = nil
            host.isHidden = true
            parked[path] = host
        }
        // Past the limit, the cards set aside give their hosts back for others.
        while parked.count > Self.parkedLimit, let (path, host) = parked.first {
            parked[path] = nil
            pool.append(host)
        }
        if remeasured {
            // Stacked again with the real heights; the cards keep their hosts.
            relayout()
        }
    }

    /// A card on screen is now `height` tall (its note changed, its picture came): placed again when that is not the
    /// height it was placed with.
    private func cardHeightChanged(_ path: String, _ height: CGFloat) {
        guard let number = placed.firstIndex(where: { $0.item.path == path }) else { return }
        let entry = placed[number]
        guard height > 0, abs(height - entry.frame.height) > 0.5 else { return }
        heights[key(for: entry.item, width: entry.frame.width)] = height
        // After this pass: a change of a card's size comes in the middle of its own layout.
        DispatchQueue.main.async { [weak self] in self?.relayout() }
    }

    /// A host for `item`: one from the pool, or a new one.
    private func take(_ item: ExplorerModel.Item, index: Int, state: CardGridView.State) -> CardHost {
        let host = pool.popLast() ?? {
            let made = CardHost(model: model!, theme: state.theme) { [weak self] path, height in
                self?.cardHeightChanged(path, height)
            }
            addSubview(made)
            return made
        }()
        host.isSettled = state.isSettled
        host.isScrolling = false
        host.mayBeHovered = false
        host.show(item, index: index)
        host.isHidden = false
        return host
    }
}

/// One card's hosting view, reused from card to card as the grid scrolls.
final class CardHost: NSView {
    let controller: NSHostingController<CardRoot>
    private(set) var path: String?

    var theme: ThemeTokens { didSet { if theme != oldValue { controller.rootView.theme = theme } } }
    var isScrolling = false { didSet { if isScrolling != oldValue { controller.rootView.isScrolling = isScrolling } } }
    var isSettled = true { didSet { if isSettled != oldValue { controller.rootView.isSettled = isSettled } } }

    init(model: ExplorerModel, theme: ThemeTokens, onHeight: @escaping (String, CGFloat) -> Void) {
        self.theme = theme
        controller = NSHostingController(rootView: CardRoot(model: model, item: nil, index: 0, theme: theme, onHeight: onHeight))
        controller.sizingOptions = []
        super.init(frame: .zero)
        controller.view.autoresizingMask = [.width, .height]
        if let host = controller.view as? NSHostingView<CardRoot> { host.safeAreaRegions = [] }
        addSubview(controller.view)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    /// Whether the pointer has been over the card since it was last checked: it may be in its hover pose.
    var mayBeHovered = false

    /// The card's own rect, its outset left out.
    var cardFrame: CGRect { frame.insetBy(dx: CardDocumentView.outset, dy: CardDocumentView.outset) }

    /// Takes the card out of its hover pose. Each card is a hosting view of its own, and one that moves away from
    /// under a still pointer (a resize, a scroll) is never told the pointer left: it stayed lifted. The window's
    /// single hosting view used to work hover out again on every layout.
    func dropHover() {
        mayBeHovered = false
        controller.rootView.hoverGeneration += 1
    }

    func show(_ item: ExplorerModel.Item, index: Int) {
        guard item.path != path || controller.rootView.item?.path != item.path else { return }
        path = item.path
        controller.rootView.item = item
        controller.rootView.index = index
    }

    override func layout() {
        super.layout()
        if controller.view.frame != bounds { controller.view.frame = bounds }
    }

    /// The card's own height at the host's width, its outset left out: asked with the host's own size, as its layout
    /// asks, so the answer is the layout's (the card takes its own height whatever it is offered).
    func measuredHeight() -> CGFloat {
        let size = controller.sizeThatFits(in: bounds.size)
        return size.height - 2 * CardDocumentView.outset
    }
}

/// A card as the grid shows it, with the room for its hover pose around it.
struct CardRoot: View {
    let model: ExplorerModel
    var item: ExplorerModel.Item?
    var index: Int
    var theme: ThemeTokens
    var isScrolling = false
    var isSettled = true
    /// Told the card's own height whenever it changes (its note changed, its picture came): the grid places it again.
    var onHeight: ((String, CGFloat) -> Void)?
    /// A new value makes the card anew, out of its hover pose (`CardHost.dropHover`).
    var hoverGeneration = 0

    var body: some View {
        Group {
            if let item {
                // Read here, when the card comes into view: a card off screen never reads its note.
                let card = model.card(for: item)
                NoteCardView(card: card, embed: model.cardEmbed(for: card)) { origin in
                    model.open(card, newTab: NSEvent.modifierFlags.contains(.command), from: origin)
                }
                .contextMenu { NoteCardMenu(model: model, card: card) }
                .cascadeIn(index: isSettled ? nil : index)
                // As tall as the card wants, as a stack lays it out, whatever room the host gives.
                .fixedSize(horizontal: false, vertical: true)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { onHeight?(item.path, $0) }
                .id(CardIdentity(path: item.path, hoverGeneration: hoverGeneration))
            }
        }
        // Both bounds: the card takes its column's width, and one that wants more (a footer's pills) runs over to the
        // right from the column's leading edge, as in a stack, rather than growing its host, which centred it.
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .topLeading)
        .padding(CardDocumentView.outset)
        .environment(\.themeTokens, theme)
        .environment(\.isScrollingCards, isScrolling)
        .tint(theme.accent)
    }
}

struct CardIdentity: Hashable {
    let path: String
    let hoverGeneration: Int
}

/// The page's title over its cards, and what an empty page shows.
struct CardGridHeader: View {
    let count: Int
    let title: String
    let theme: ThemeTokens
    let newItem: NewItem?
    let isEmpty: Bool
    let newNote: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageHeader(title, subtitle: count == 1 ? "1 item" : "\(count) items")
            if isEmpty {
                FolderEmptyState(newItem: newItem) { newNote() }
                    .padding(.top, Space.xxl)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .environment(\.themeTokens, theme)
        .tint(theme.accent)
    }
}
