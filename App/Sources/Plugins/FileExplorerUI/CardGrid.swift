import AppKit
import PluginKit
import PluginKitUI
import SwiftUI

/// The cards of a folder page in AppKit: a scroll view whose document places them itself, as a masonry of columns
/// (`FolderGridView.deal`). Each card is an AppKit view (`NoteCardCell`, with its hover, cascade, drag, menu and
/// open-from-card origin), and only the cards on screen, and a screenful around them, live. A card's height is
/// worked out once per width and kept, so a scroll moves frames and never lays a card out again, and a window resize
/// lays out only the cards on screen.
///
/// SwiftUI's lazy stacks re-measured the visible cards on every frame of a scroll and every step of a resize; one
/// hosting view per card then cost a page 250-450 ms to open (docs/APPKIT.md).
final class CardGridView: NSScrollView, NativeHostedView {
    /// What the grid shows.
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
    /// The page's folder, its cards followed in the model, and what the shell last said.
    private var resource: Resource?
    private var cards: Follow<[ExplorerModel.Item]>?
    /// What the shell last said; nil until it first does, and nothing is shown before (it would be laid out twice).
    private var environment: NativeViewEnvironment?
    /// Whether the first cards have cascaded in: later cards (a new note, a re-sort) appear at once.
    private var isSettled = false

    /// A folder page as the shell shows it (`ViewType.makeNSView`): the folder's cards, followed in the model.
    static func page(model: ExplorerModel, resource: Resource) -> CardGridView {
        let view = CardGridView(model: model)
        view.resource = resource
        view.cards = Follow({ [weak model] in model?.cardItems(for: resource) ?? [] }) { [weak view] _ in view?.refresh() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak view] in
            view?.isSettled = true
            view?.refresh()
        }
        return view
    }

    func hostEnvironmentChanged(_ environment: NativeViewEnvironment) {
        guard environment != self.environment else { return }
        self.environment = environment
        refresh()
    }

    /// Shows the model's cards for the page's folder, with the shell's theme and toolbar room.
    private func refresh() {
        guard let resource, let environment else { return }
        update(State(resource: resource, items: model.cardItems(for: resource), isSettled: isSettled,
                     theme: environment.theme, chromeInset: environment.topInset))
    }

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
    private(set) var live: [String: NoteCardCell] = [:]
    /// Cards ready for the next note that comes into view.
    private var pool: [NoteCardCell] = []
    /// Cards made once and set aside, hidden, by path: one coming back into view is shown as it was, never made
    /// again.
    private var parked: [String: NoteCardCell] = [:]
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
    /// The heights cards are placed with at a width they are being measured at off the main thread: their texts as
    /// tall as at the width they were at (`NoteCardCell.provisionalHeight`).
    private var provisional: [HeightKey: CGFloat] = [:]
    /// The cards being measured off the main thread.
    private(set) var measuring: Set<HeightKey> = []
    private var settleScheduled = false
    /// How many times a card was measured, for the tests: a scroll must not add to it.
    private(set) var measureCount = 0
    /// Where each card goes, for the tests.
    var placedFrames: [String: CGRect] { Dictionary(placed.map { ($0.item.path, $0.frame) }, uniquingKeysWith: { a, _ in a }) }

    /// A number for each note's path, given when the cards are dealt: a height is found without hashing the path.
    private var ids: [String: Int] = [:]

    struct HeightKey: Hashable {
        let id: Int
        let width: Int
        let modified: Double
    }

    struct Placed {
        let item: ExplorerModel.Item
        let index: Int
        let id: Int
        let modified: Double
        var frame: CGRect
    }

    /// How far past the visible rect cards are kept alive, so a scroll finds them ready.
    static let margin: CGFloat = 600
    /// Room around a card's own frame inside its view: none, its lift and shadow are drawn outside its bounds.
    static let outset: CGFloat = 0

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    func update(_ new: CardGridView.State) {
        let old = state
        state = new
        itemsVersion += 1
        if old?.theme != new.theme {
            heights = [:]
            provisional = [:]
            for host in Array(live.values) + pool + Array(parked.values) {
                host.theme = new.theme
                host.themeChanged()
            }
        }
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

    /// The cards dealt to the columns, with the stamp of each note, kept until the cards or the columns change: a
    /// card measured again only stacks its column again.
    private var dealt: (key: DealKey, columns: [[DealtCard]])?
    /// Grows at each update of the cards: what was dealt before is dealt again.
    private var itemsVersion = 0

    struct DealtCard {
        let item: ExplorerModel.Item
        let index: Int
        let id: Int
        let modified: Double
        let estimated: CGFloat
    }

    struct DealKey: Equatable {
        let version: Int
        let count: Int
        let columnWidth: CGFloat
    }

    /// Places every card: deals them to the columns by their estimated heights, as SwiftUI's grid did, then stacks
    /// each column with the heights measured so far (estimated for a card not measured yet).
    func relayout() {
        guard let state, let model, width > 0 else { return }
        let contentWidth = self.contentWidth
        let count = FolderGridView.columnCount(for: contentWidth)
        let spacing = FolderGridView.spacing
        let columnWidth = max(0, (contentWidth - spacing * CGFloat(count - 1)) / CGFloat(count))
        let dealKey = DealKey(version: itemsVersion, count: count, columnWidth: columnWidth)
        if dealt?.key != dealKey {
            let columns = FolderGridView.deal(state.items, into: count) { model.estimatedHeight(of: $0, width: columnWidth) }
            let stamps = model.noteStamps
            dealt = (dealKey, columns.map { column in
                column.map { entry in
                    let id = ids[entry.item.path] ?? {
                        let new = ids.count
                        ids[entry.item.path] = new
                        return new
                    }()
                    return DealtCard(item: entry.item, index: entry.index, id: id, modified: stamps[entry.item.path]?.modified ?? 0,
                                     estimated: model.estimatedHeight(of: entry.item, width: columnWidth))
                }
            })
            // Cards no longer on the page (another folder, a note gone) give their hosts back.
            let present = Set(state.items.map(\.path))
            for (path, host) in parked where !present.contains(path) {
                parked[path] = nil
                pool.append(host)
            }
        }

        let headerKey = (contentWidth, state.items.count, ExplorerModel.title(of: state.resource), state.items.isEmpty, state.theme)
        if lastHeaderKey.map({ $0.width != headerKey.0 || $0.count != headerKey.1 || $0.title != headerKey.2 || $0.empty != headerKey.3 || $0.theme != headerKey.4 }) ?? true {
            lastHeaderKey = headerKey
            lastHeaderHeight = headerHeight()
        }
        let top = PageMetrics.top
        header?.frame = CGRect(x: contentX, y: top, width: contentWidth, height: lastHeaderHeight)
        // Stacked again while cards near the screen take other heights (measured, or placed for a measure), which
        // can bring others near it: a few rounds at most.
        var rounds = 0
        while stack(columnWidth: columnWidth), rounds < 8 { rounds += 1 }
    }

    /// Stacks each column with the heights known, then makes the cards in view live: true when one of them took
    /// another height, and the columns must be stacked again.
    private func stack(columnWidth: CGFloat) -> Bool {
        guard let state, let columns = dealt?.columns else { return false }
        let spacing = FolderGridView.spacing
        let cardsTop = PageMetrics.top + lastHeaderHeight + (state.items.isEmpty ? 0 : PageMetrics.headerGap)
        var placed: [Placed] = []
        placed.reserveCapacity(state.items.count)
        var bottom = cardsTop
        for (column, dealt) in columns.enumerated() {
            var y = cardsTop
            let x = contentX + CGFloat(column) * (columnWidth + spacing)
            // On the pixel grid, as a stack places its children; the heights stay exact so nothing adds up. The
            // cards are measured at this width, which the heights are kept under.
            let left = pixel(x), cardWidth = pixel(x + columnWidth) - left
            let keyWidth = Int((cardWidth * 2).rounded())
            for entry in dealt {
                let heightKey = HeightKey(id: entry.id, width: keyWidth, modified: entry.modified)
                let height = heights[heightKey] ?? provisional[heightKey] ?? entry.estimated
                let top = pixel(y), end = pixel(y + height)
                placed.append(Placed(item: entry.item, index: entry.index, id: entry.id, modified: entry.modified,
                                     frame: CGRect(x: left, y: top, width: cardWidth, height: end - top)))
                y += height + spacing
            }
            bottom = max(bottom, y - (dealt.isEmpty ? 0 : spacing))
        }
        self.placed = placed
        let height = max(bottom + 32, (grid?.contentView.bounds.height ?? 0) - (grid?.contentInsets.top ?? 0))
        let size = NSSize(width: width, height: height)
        if frame.size != size { setFrameSize(size) }
        return placeVisibleCards()
    }

    private func pixel(_ value: CGFloat) -> CGFloat {
        let scale = window?.backingScaleFactor ?? 2
        return (value * scale).rounded() / scale
    }

    private func key(for placed: Placed) -> HeightKey {
        HeightKey(id: placed.id, width: Int((placed.frame.width * 2).rounded()), modified: placed.modified)
    }

    /// Makes the cards in view (and a margin around) live, measures the ones not measured at this width, and lets
    /// the others go back to the pool. When a measured height differs from what was used to place a card, the
    /// columns are stacked again.
    func showVisibleCards() {
        if placeVisibleCards() { relayout() }
    }

    /// `showVisibleCards`, true when a card took another height than it was placed with.
    private func placeVisibleCards() -> Bool {
        guard let grid, let state else { return false }
        // While the window is resized only the cards on screen are laid out at each step; the ones around them catch
        // up once the resize ends (`viewDidEndLiveResize`).
        let visible = grid.contentView.bounds.insetBy(dx: 0, dy: inLiveResize ? 0 : -Self.margin)
        var wanted = Set<String>()
        var remeasured = false
        for (number, entry) in placed.enumerated() where entry.frame.intersects(visible) {
            wanted.insert(entry.item.path)
            let host = live[entry.item.path] ?? parked.removeValue(forKey: entry.item.path).map { host in
                host.isScrolling = isScrolling
                host.show(entry.item)
                host.isHidden = false
                return host
            } ?? take(entry.item, index: entry.index, state: state)
            live[entry.item.path] = host
            let heightKey = key(for: entry)
            if heights[heightKey] == nil, !measuring.contains(heightKey) {
                // A card already laid out at another width (a sidebar sliding in, a window resized) is placed with
                // its texts as tall as there and measured off the main thread; one never laid out is measured now.
                let measured: CGFloat
                if let guess = host.provisionalHeight(for: entry.frame.width) {
                    measured = guess
                    provisional[heightKey] = guess
                    measuring.insert(heightKey)
                    host.measure(width: entry.frame.width) { [weak self] height in self?.measured(heightKey, height) }
                } else {
                    measured = host.height(for: entry.frame.width)
                    heights[heightKey] = measured
                }
                measureCount += 1
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
        // Stacked again with the real heights by the caller; the cards keep their hosts.
        return remeasured
    }

    /// A card measured off the main thread: kept, and the cards are placed again once this pass's measures are in.
    private func measured(_ key: HeightKey, _ height: CGFloat?) {
        measuring.remove(key)
        provisional[key] = nil
        if let height { heights[key] = height }
        guard !settleScheduled else { return }
        settleScheduled = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.settle() }
        }
    }

    /// Places the cards with their measured heights: the ones that move glide to their place (Core Animation, the
    /// views are at their place at once), unless the window is being resized or motion is reduced.
    private func settle() {
        settleScheduled = false
        let before = live.compactMapValues { host in host.layer.map { $0.presentation()?.position ?? $0.position } }
        relayout()
        guard !inLiveResize, !Motion.reduceMotion else { return }
        for (path, host) in live {
            guard let layer = host.layer, let from = before[path] else { continue }
            let delta = CGPoint(x: from.x - layer.position.x, y: from.y - layer.position.y)
            guard abs(delta.x) > 0.5 || abs(delta.y) > 0.5 else { continue }
            let glide = CASpringAnimation(perceptualDuration: Motion.Spring.standard.duration, bounce: 0)
            glide.keyPath = "position"
            glide.isAdditive = true
            glide.fromValue = NSValue(point: delta)
            glide.toValue = NSValue(point: .zero)
            layer.add(glide, forKey: "settle")
        }
    }

    /// A card for `item`: one from the pool, or a new one. Before the page has settled, the first cards cascade in.
    private func take(_ item: ExplorerModel.Item, index: Int, state: CardGridView.State) -> NoteCardCell {
        let host = pool.popLast() ?? {
            let made = NoteCardCell(model: model!, theme: state.theme)
            addSubview(made)
            return made
        }()
        host.isScrolling = false
        host.mayBeHovered = false
        host.setHovered(false, animated: false)
        host.show(item)
        host.isHidden = false
        if !state.isSettled, let delay = CardMotion.cascadeDelay(index: index, reduceMotion: Motion.reduceMotion) {
            host.cascadeIn(delay: delay)
        }
        return host
    }
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
