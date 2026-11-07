import AppKit
import PluginKitUI
import SwiftUI

/// What the board needs from the rest of the app to delete a card and take the deletion back.
struct BoardServices {
    /// Moves the note into the vault's trash; returns its path there.
    var trash: (String) throws -> String
    /// Brings a trashed note back; returns its path.
    var restore: (String) throws -> String
    /// Says why something failed.
    var report: (String) -> Void
    /// The note's checklist, done / total task lines, nil without any: shown on its card.
    var checklist: @MainActor (NoteRecord) -> BoardChecklist? = { _ in nil }
}

enum BoardError: Error, CustomStringConvertible {
    case unavailable(String)

    var description: String {
        switch self {
        case .unavailable(let reason): reason
        }
    }
}

/// The board view of collections (`type: kanban`) in AppKit, as Craft draws it: one tinted column per option of the
/// field it groups by (a pill and a count on top), white cards with the shown fields, "+" under each column to add
/// an entry there, "+" on the right to add a column. The same view in a page and in a note (a `base` block), where
/// it is as tall as its columns (`fittingSize`). One SwiftUI view per card cost the board 250-400 ms to open
/// (docs/APPKIT.md); the cards are reused views here, alive only near the screen.
///
/// A card is taken with the pointer and follows it above the board while the others part to open a gap at the
/// insertion index; letting go drops it into the gap, and the order the cards are left in is kept in the view
/// (`CollectionViewModel.moveEntry`). Dropping on another column writes that field in the note. Every movement is a
/// Core Animation spring (`Motion`), a fade under Reduce Motion.
final class BoardScrollView: NSScrollView, NativeHostedView {
    /// What the board shows of its model, followed as it changes.
    struct Shown: Equatable {
        var groups: [CollectionGroup]?
        var groupBy: PropertyRef?
        var fields: [PropertyRef]
        var properties: [CollectionProperty]
        var kinds: [String: PropertyKind]
    }

    let document: BoardDocumentView
    private let model: CollectionViewModel
    private var shown: Follow<Shown?>?
    /// The host's theme; nil until it is first given, and nothing is shown before (it would be laid out twice).
    private(set) var theme: ThemeTokens?
    private var emptyState: NSHostingView<AnyView>?
    private var undoBar: NSHostingView<AnyView>?
    private var undoTimer: Timer?
    private var isEmpty = false

    init(model: CollectionViewModel, services: BoardServices) {
        self.model = model
        document = BoardDocumentView(model: model, services: services)
        super.init(frame: .zero)
        drawsBackground = false
        contentView.drawsBackground = false
        hasVerticalScroller = true
        hasHorizontalScroller = true
        autohidesScrollers = true
        scrollerStyle = .overlay
        automaticallyAdjustsContentInsets = false
        documentView = document
        contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(scrolled), name: NSView.boundsDidChangeNotification, object: contentView)
        document.owner = self
        shown = Follow({ [weak model] in
            // A board the page is replacing by another view is not drawn again for that view's settings.
            guard let model, model.view.map({ $0.type == "kanban" }) ?? true else { return nil }
            return Self.shown(model)
        }) { [weak self] shown in
            guard let shown, self?.theme != nil else { return }
            self?.show(shown)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var mouseDownCanMoveWindow: Bool { false }

    static func shown(_ model: CollectionViewModel) -> Shown {
        Shown(groups: model.groups, groupBy: model.view?.groupBy?.property, fields: model.fields,
              properties: model.definition?.properties ?? [], kinds: model.result?.kinds ?? [:])
    }

    func hostEnvironmentChanged(_ environment: NativeViewEnvironment) {
        guard environment.theme != theme else { return }
        theme = environment.theme
        refresh()
    }

    /// In a note: as tall as the columns, up to the block's limit, then it scrolls.
    func fittingSize(width: CGFloat, maxHeight: CGFloat?) -> CGSize? {
        guard model.isEmbedded else { return nil }
        let content = isEmpty ? emptyHeight(width: width) : document.contentHeight
        return CGSize(width: width, height: min(content, maxHeight ?? .greatestFiniteMagnitude))
    }

    /// Shows the model as it is now, at once (after a drop, so the card lands where it was let go).
    func refresh() {
        show(Self.shown(model))
    }

    private func show(_ shown: Shown) {
        guard let theme else { return }
        isEmpty = shown.groupBy == nil || shown.groups == nil
        document.isHidden = isEmpty
        if isEmpty {
            let root = AnyView(EmptyState("Choose a field to group by", symbol: "rectangle.split.3x1",
                                          message: "A board shows one column per value of a field: pick it under View settings.")
                .environment(\.themeTokens, theme).tint(theme.accent))
            if let emptyState {
                emptyState.rootView = root
            } else {
                let host = NSHostingView(rootView: root)
                host.safeAreaRegions = []
                host.sizingOptions = []
                addSubview(host)
                emptyState = host
            }
            emptyState?.isHidden = false
            needsLayout = true
        } else {
            emptyState?.isHidden = true
            document.update(groups: shown.groups ?? [], field: shown.groupBy ?? .title, theme: theme)
        }
        invalidateIntrinsicContentSize()
    }

    private func emptyHeight(width: CGFloat) -> CGFloat {
        guard let emptyState else { return 0 }
        return ceil(NSHostingController(rootView: emptyState.rootView)
            .sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude)).height)
    }

    override func layout() {
        super.layout()
        if let emptyState, !emptyState.isHidden {
            emptyState.frame = CGRect(x: 0, y: 0, width: bounds.width, height: min(bounds.height, max(emptyHeight(width: bounds.width), 160)))
        }
        if let undoBar {
            let size = undoBar.fittingSize
            undoBar.frame = CGRect(x: (bounds.width - size.width) / 2, y: bounds.height - size.height, width: size.width, height: size.height)
        }
    }

    override func tile() {
        super.tile()
        document.viewportChanged()
    }

    /// The board scrolls sideways; a vertical wheel over columns that fit goes to what holds them (the note
    /// around a board block, the page).
    override func scrollWheel(with event: NSEvent) {
        let vertical = abs(event.scrollingDeltaY) > abs(event.scrollingDeltaX)
        if isEmpty || (vertical && document.frame.height <= contentView.bounds.height + 0.5) {
            nextResponder?.scrollWheel(with: event)
        } else {
            super.scrollWheel(with: event)
        }
    }

    @objc private func scrolled() { document.showVisibleCards(animated: false) }

    /// Scrolls the board sideways to `x`, at once (a card held near an edge) or with a spring (a new column).
    func scroll(toX x: CGFloat, animated: Bool) {
        let maxX = max(0, document.frame.width - contentView.bounds.width)
        let origin = CGPoint(x: min(max(x, 0), maxX), y: contentView.bounds.origin.y)
        if animated, !Motion.reduceMotion {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = Motion.Spring.smooth.duration
                context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1)
                contentView.animator().setBoundsOrigin(origin)
            }
        } else {
            contentView.scroll(to: origin)
        }
        reflectScrolledClipView(contentView)
    }

    // MARK: Undo

    /// "“Title” deleted · Undo" for six seconds.
    func showUndo(title: String, undo: @escaping () -> Void) {
        undoTimer?.invalidate()
        undoBar?.removeFromSuperview()
        let host = NSHostingView(rootView: AnyView(BoardUndoBar(title: title) { [weak self] in
            self?.hideUndo()
            undo()
        }.environment(\.themeTokens, theme ?? .standard)))
        host.safeAreaRegions = []
        addSubview(host)
        undoBar = host
        needsLayout = true
        layoutSubtreeIfNeeded()
        if let layer = host.layer, !Motion.reduceMotion {
            let rise = CASpringAnimation(perceptualDuration: Motion.Spring.pop.duration, bounce: Motion.Spring.pop.bounce)
            rise.keyPath = "transform.translation.y"
            rise.fromValue = -24
            rise.toValue = 0
            rise.duration = rise.settlingDuration
            layer.add(rise, forKey: "rise")
        }
        host.layer?.add(Self.fade(from: 0, to: 1, duration: 0.2), forKey: "fade")
        undoTimer = Timer.scheduledTimer(withTimeInterval: 6, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.hideUndo() }
        }
    }

    private func hideUndo() {
        undoTimer?.invalidate()
        undoTimer = nil
        guard let bar = undoBar else { return }
        undoBar = nil
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            bar.animator().alphaValue = 0
        } completionHandler: {
            bar.removeFromSuperview()
        }
    }

    static func fade(from: Float, to: Float, duration: Double) -> CABasicAnimation {
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = from
        fade.toValue = to
        fade.duration = duration
        return fade
    }
}

/// The board's content: the columns' backgrounds and headers, the cards near the screen, "+" buttons, and the card
/// in the hand. It takes the clicks and drags of the cards.
final class BoardDocumentView: NSView {
    struct Column: Equatable {
        var name: String
        var value: PropertyValue?
        var swatch: OptionPalette.Swatch
        /// The field's options, for the header's pill; none for the column without a value.
        var options: [String]
    }

    weak var owner: BoardScrollView?
    private let model: CollectionViewModel
    private let services: BoardServices
    private var theme = ThemeTokens.standard
    private var field = PropertyRef.title
    private(set) var columns: [Column] = []
    /// The cards of each column, top to bottom, as the model orders them.
    private(set) var lists: [[String]] = []
    private var records: [String: NoteRecord] = [:]
    private var contents: [String: BoardCardContent] = [:]
    /// What every card's content depends on besides its note.
    private struct Schema: Equatable {
        var fields: [PropertyRef]
        var properties: [CollectionProperty]
        var kinds: [String: PropertyKind]
        var today: String
    }
    private var schema: Schema?
    /// What `update` was last given.
    private struct Input: Equatable {
        var groups: [CollectionGroup]
        var field: PropertyRef
        var theme: ThemeTokens
        var fields: [PropertyRef]
        var properties: [CollectionProperty]
        var kinds: [String: PropertyKind]
    }
    private var lastInput: Input?
    /// Heights by card, measured once per content.
    private var heights: [String: (content: BoardCardContent, height: CGFloat)] = [:]
    private(set) var placement = BoardPlacement(columns: [], addColumn: .zero, size: .zero)
    private(set) var live: [String: BoardCardView] = [:]
    private var pool: [BoardCardView] = []
    private var columnLayers: [BoardColumnLayer] = []
    private var headers: [BoardHeaderView] = []
    private var pluses: [BoardPlusButton] = []
    private let addColumnButton = BoardPlusButton()
    private var addField: BoardAddField?
    /// The column whose inline field is open.
    private var adding: Int?
    private var hasShown = false

    // The drag.
    /// `movingColumn`: a column held by its header (`columnDrag`).
    private enum Phase { case idle, holding, settling, movingColumn }
    private var phase = Phase.idle
    private(set) var heldPath: String?
    /// Where the held card would land: its column and its index among that column's other cards.
    private(set) var gap: (column: Int, index: Int)?
    /// A card let go whose move is being written: it stays at its gap until the model has it there.
    private var landing: (path: String, column: Int, index: Int)?
    private var held: BoardCardView?
    private var grab = CGSize.zero
    /// The pointer, in the viewport (it does not scroll with the board).
    private var pointer = CGPoint.zero
    private var velocity = CGSize.zero
    private var lastEvent: (point: CGPoint, time: TimeInterval)?
    private var lastMove: CFTimeInterval = 0
    private var tilt = 0.0
    private var press: (path: String?, point: CGPoint)?
    private var link: CADisplayLink?
    private var lastTick: CFTimeInterval = 0
    private var cursorPushed = false
    /// A column held by its header: where it is now among the others, where the hand holds it (from its left
    /// edge), and its left edge under the hand. The others part for it as it passes them.
    private var columnDrag: (index: Int, grab: CGFloat, x: CGFloat)?
    /// The header pressed, until the hand moves enough to pick its column up.
    private var columnPress: (column: Int, point: CGPoint)?

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    /// A card answers the click that also brings the window forward, as the canvas board does.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    init(model: CollectionViewModel, services: BoardServices) {
        self.model = model
        self.services = services
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = false
        addColumnButton.isColumn = false
        addColumnButton.action = { [weak self] in self?.askNewColumn() }
        addSubview(addColumnButton)
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    var contentHeight: CGFloat { placement.size.height }

    // MARK: Showing the model

    func update(groups: [CollectionGroup], field: PropertyRef, theme: ThemeTokens) {
        // The model as shown already (the drop showed it, then the model's own change says it again).
        let input = Input(groups: groups, field: field, theme: theme, fields: model.fields,
                          properties: model.definition?.properties ?? [], kinds: model.result?.kinds ?? [:])
        guard input != lastInput || !hasShown else { return }
        lastInput = input
        // The model changed under a held column: it is let go where the model puts it.
        if columnDrag != nil || columnPress != nil {
            columnPress = nil
            finishColumnDrag()
        }
        let themeChanged = theme != self.theme
        self.theme = theme
        self.field = field
        let options = model.property(field).options
        columns = groups.map { group in
            let name = group.value.map(CollectionViewModel.text) ?? "No \(model.title(of: field))"
            return Column(name: name, value: group.value,
                          swatch: group.value == nil ? OptionPalette.grey : OptionPalette.swatch(for: name, in: options),
                          options: group.value == nil ? [] : options)
        }
        lists = groups.map { $0.entries.map(\.path) }
        let fields = model.fields
        // A card's content is made again only when its note or what the cards show changed.
        let schema = Schema(fields: fields, properties: model.definition?.properties ?? [], kinds: model.result?.kinds ?? [:], today: DateValuePill.today())
        let known = schema == self.schema ? records : [:]
        self.schema = schema
        var records: [String: NoteRecord] = [:]
        var contents: [String: BoardCardContent] = [:]
        for entry in groups.flatMap(\.entries) {
            records[entry.path] = entry
            if known[entry.path] == entry, let content = self.contents[entry.path] {
                contents[entry.path] = content
                continue
            }
            let lines = fields.compactMap { ref in
                BoardLine.make(model.value(ref, of: entry), kind: model.kind(ref), options: model.property(ref).options)
            }
            contents[entry.path] = BoardCardContent(title: entry.title, lines: lines, checklist: services.checklist(entry))
        }
        self.records = records
        self.contents = contents
        if themeChanged {
            for card in Array(live.values) + pool { card.theme = theme }
        }
        // The card in the hand went away under it (the note was deleted or moved elsewhere).
        if let path = heldPath, records[path] == nil { finishDrag() }
        if let adding, adding >= columns.count { closeField() }
        relayout(animated: hasShown && !themeChanged)
        hasShown = true
    }

    private func height(of path: String) -> CGFloat {
        guard let content = contents[path] else { return 60 }
        if let known = heights[path], known.content == content { return known.height }
        let height = content.height(width: BoardMetrics.cardWidth)
        heights[path] = (content, height)
        return height
    }

    /// The columns' cards with the one in the hand taken out of its column and put at the gap: the board lays out
    /// this, so the ghost is where the card would land and the others have parted for it.
    private var arranged: [[String]] {
        guard let (path, gap) = heldPath.flatMap({ path in gap.map { (path, $0) } })
                ?? landing.map({ ($0.path, (column: $0.column, index: $0.index)) }),
              gap.column < lists.count
        else { return lists }
        var lists = lists.map { $0.filter { $0 != path } }
        lists[gap.column].insert(path, at: min(gap.index, lists[gap.column].count))
        return lists
    }

    func viewportChanged() {
        resize()
        showVisibleCards(animated: false)
    }

    private func resize() {
        let clip = enclosingScrollView?.contentView.bounds.size ?? .zero
        let size = CGSize(width: max(placement.size.width, clip.width), height: max(placement.size.height, clip.height))
        if frame.size != size { setFrameSize(size) }
    }

    private func relayout(animated: Bool) {
        let previous = placement
        placement = BoardPlacement.place(lists: arranged, height: height(of:), fieldColumn: adding)
        if let columnDrag, columnDrag.index < placement.columns.count {
            let slot = placement.columns[columnDrag.index]
            placement.columns[columnDrag.index] = slot.shifted(by: columnDrag.x - slot.background.minX)
        }
        resize()
        let appearance = effectiveAppearance
        let animate = animated && !Motion.reduceMotion
        CATransaction.begin()
        if animate {
            CATransaction.setAnimationDuration(Motion.Spring.standard.duration)
            CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1))
        } else {
            CATransaction.setDisableActions(true)
        }
        for (index, column) in columns.enumerated() {
            let slot = placement.columns[index]
            let isNew = index >= columnLayers.count
            // The held column follows the hand; the others glide to their places.
            let lifted = columnDrag?.index == index
            let glides = animate && !isNew && !lifted
            if isNew {
                let made = BoardColumnLayer()
                layer?.insertSublayer(made, at: 0)
                columnLayers.append(made)
                let header = BoardHeaderView()
                addSubview(header)
                headers.append(header)
                let plus = BoardPlusButton()
                addSubview(plus)
                pluses.append(plus)
            }
            pluses[index].action = { [weak self] in self?.openField(index) }
            let background = columnLayers[index]
            let from = background.presentation()?.position ?? background.position
            background.show(column.swatch, frame: slot.background, appearance: appearance)
            if glides { Self.glide(background, from: from) }
            background.setTargeted(gap?.column == index, appearance: appearance)
            background.zPosition = lifted ? 50 : 0
            background.shadowOpacity = lifted ? 0.28 : 0
            background.shadowRadius = 18
            background.shadowOffset = CGSize(width: 0, height: -8)
            headers[index].layer?.zPosition = lifted ? 51 : 0
            pluses[index].layer?.zPosition = lifted ? 51 : 0
            move(headers[index], to: slot.header, animated: glides)
            headers[index].show(BoardHeaderView.Content(name: column.name, options: column.options,
                                                        count: lists[index].count, theme: theme))
            move(pluses[index], to: slot.plus, animated: glides)
            pluses[index].show(theme: theme, swatch: column.swatch, help: String(localized: "Add an entry in \(column.name)"))
            if isNew, animate, previous.columns.count > 0 { enterColumn(index) }
        }
        while columnLayers.count > columns.count {
            columnLayers.removeLast().removeFromSuperlayer()
            headers.removeLast().removeFromSuperview()
            pluses.removeLast().removeFromSuperview()
        }
        CATransaction.commit()
        move(addColumnButton, to: placement.addColumn, animated: animate)
        addColumnButton.show(theme: theme, swatch: OptionPalette.grey,
                             help: String(localized: "Add a column: a new option of \(model.title(of: field))"))
        if let adding, let frame = placement.columns[adding].field { addField?.frame = frame }
        showVisibleCards(animated: animate, previous: previous)
    }

    /// A new column comes in from the right, fading in.
    private func enterColumn(_ index: Int) {
        let slide = CASpringAnimation(perceptualDuration: Motion.Spring.standard.duration, bounce: Motion.Spring.standard.bounce)
        slide.keyPath = "position.x"
        slide.isAdditive = true
        slide.fromValue = 24
        slide.toValue = 0
        slide.duration = slide.settlingDuration
        for target in [columnLayers[index], headers[index].layer, pluses[index].layer].compactMap({ $0 }) {
            target.add(slide, forKey: "enter")
            target.add(BoardScrollView.fade(from: 0, to: 1, duration: Motion.Spring.standard.duration * 0.6), forKey: "enterFade")
        }
    }

    /// Puts `view` at `frame`; with `animated`, it glides there from where it shows now (an additive spring on
    /// its layer, the view at its place at once).
    private func move(_ view: NSView, to frame: CGRect, animated: Bool) {
        guard view.frame != frame else { return }
        let from = view.layer.map { $0.presentation()?.position ?? $0.position }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        view.frame = frame
        CATransaction.commit()
        guard animated, let layer = view.layer, let from else { return }
        Self.glide(layer, from: from)
    }

    /// A layer already at its place glides there from `from` (where it showed): an additive spring.
    private static func glide(_ layer: CALayer, from: CGPoint) {
        let delta = CGPoint(x: from.x - layer.position.x, y: from.y - layer.position.y)
        guard abs(delta.x) > 0.5 || abs(delta.y) > 0.5 else { return }
        let glide = CASpringAnimation(perceptualDuration: Motion.Spring.standard.duration, bounce: Motion.Spring.standard.bounce)
        glide.keyPath = "position"
        glide.isAdditive = true
        glide.fromValue = NSValue(point: delta)
        glide.toValue = NSValue(point: .zero)
        glide.duration = glide.settlingDuration
        layer.add(glide, forKey: "move")
    }

    /// Makes the cards near the screen and lets the others go back to the pool. `previous` is the placement before
    /// a change: a card new to the board comes in, one that left goes out.
    func showVisibleCards(animated: Bool, previous: BoardPlacement? = nil) {
        let visible = visibleRect.insetBy(dx: -300, dy: -300)
        var wanted = Set<String>()
        for (index, column) in placement.columns.enumerated() {
            let lifted = columnDrag?.index == index
            for (path, frame) in column.cards where frame.intersects(visible) {
                wanted.insert(path)
                if let card = live[path] {
                    move(card, to: frame, animated: animated && !lifted)
                    if let content = contents[path] { card.show(path: path, content: content, theme: theme) }
                } else {
                    let card = take()
                    card.show(path: path, content: contents[path]!, theme: theme)
                    // From where it was, when it was laid out but not alive (it scrolled in during a change).
                    let before = previous?.frame(of: path)
                    card.frame = before ?? frame
                    card.isHidden = false
                    live[path] = card
                    if let before, animated { move(card, to: frame, animated: true) } else { card.frame = frame }
                    if animated, previous != nil, before == nil { enter(card) }
                }
                live[path]?.setGhost(path == heldPath, tint: NSColor(columns[min(index, columns.count - 1)].swatch.text))
                live[path]?.layer?.zPosition = lifted ? 51 : 0
            }
        }
        for (path, card) in live where !wanted.contains(path) {
            live[path] = nil
            if animated, records[path] == nil {
                leave(card)
            } else {
                card.isHidden = true
                card.recycle()
                pool.append(card)
            }
        }
    }

    private func take() -> BoardCardView {
        if let card = pool.popLast() { return card }
        let card = BoardCardView()
        card.canHover = { [weak self] in self?.phase == .idle }
        card.theme = theme
        addSubview(card, positioned: .below, relativeTo: addColumnButton)
        return card
    }

    /// A new card: fades in, growing from its top edge.
    private func enter(_ card: BoardCardView) {
        guard let layer = card.layer else { return }
        layer.add(BoardScrollView.fade(from: 0, to: 1, duration: Motion.Spring.standard.duration * 0.6), forKey: "enterFade")
        let grow = CASpringAnimation(perceptualDuration: Motion.Spring.standard.duration, bounce: Motion.Spring.standard.bounce)
        grow.keyPath = "transform"
        grow.fromValue = NSValue(caTransform3D: Self.scaled(Motion.Metrics.enterScale, width: card.bounds.width))
        grow.toValue = NSValue(caTransform3D: CATransform3DIdentity)
        grow.duration = grow.settlingDuration
        layer.add(grow, forKey: "enter")
    }

    /// A card that left the board: fades out, shrinking a little, then goes back to the pool.
    private func leave(_ card: BoardCardView) {
        guard let layer = card.layer else { return }
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self, weak card] in
            MainActor.assumeIsolated {
                guard let self, let card, !self.live.values.contains(card) else { return }
                card.isHidden = true
                card.recycle()
                self.pool.append(card)
            }
        }
        let fade = BoardScrollView.fade(from: 1, to: 0, duration: 0.12)
        fade.fillMode = .forwards
        fade.isRemovedOnCompletion = false
        let shrink = CABasicAnimation(keyPath: "transform")
        shrink.toValue = NSValue(caTransform3D: Self.scaled(Motion.Metrics.enterScale, width: card.bounds.width))
        shrink.duration = 0.12
        shrink.fillMode = .forwards
        shrink.isRemovedOnCompletion = false
        shrink.timingFunction = CAMediaTimingFunction(name: .easeIn)
        layer.add(fade, forKey: "leaveFade")
        layer.add(shrink, forKey: "leave")
        CATransaction.commit()
    }

    /// `scale` about the middle of a card's top edge (a view's layer is anchored at its corner).
    private static func scaled(_ scale: CGFloat, width: CGFloat) -> CATransform3D {
        var transform = CATransform3DMakeTranslation(-width / 2, 0, 0)
        transform = CATransform3DConcat(transform, CATransform3DMakeScale(scale, scale, 1))
        return CATransform3DConcat(transform, CATransform3DMakeTranslation(width / 2, 0, 0))
    }

    // MARK: Clicks and the menu

    private func card(at point: CGPoint) -> String? {
        for column in placement.columns {
            for (path, frame) in column.cards where frame.contains(point) { return path }
        }
        return nil
    }

    override func mouseDown(with event: NSEvent) {
        if phase == .settling { land() }
        let point = convert(event.locationInWindow, from: nil)
        let path = card(at: point)
        press = (path, point)
        columnPress = path == nil ? movableColumn(headerAt: point).map { ($0, point) } : nil
        lastEvent = (point, event.timestamp)
        velocity = .zero
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let last = lastEvent, event.timestamp > last.time {
            let dt = event.timestamp - last.time
            let now = CGSize(width: (point.x - last.point.x) / dt, height: (point.y - last.point.y) / dt)
            // Smoothed: the events come unevenly.
            velocity = CGSize(width: velocity.width * 0.5 + now.width * 0.5, height: velocity.height * 0.5 + now.height * 0.5)
        }
        lastEvent = (point, event.timestamp)
        lastMove = CACurrentMediaTime()
        pointer = CGPoint(x: point.x - visibleRect.minX, y: point.y - visibleRect.minY)
        switch phase {
        case .movingColumn:
            followColumn(point)
        case .idle:
            if let columnPress, hypot(point.x - columnPress.point.x, point.y - columnPress.point.y) > 4 {
                pickUpColumn(columnPress.column, at: columnPress.point)
                followColumn(point)
                return
            }
            guard let press, let path = press.path, hypot(point.x - press.point.x, point.y - press.point.y) > 4 else { return }
            pickUp(path, at: press.point)
            follow()
        case .holding:
            follow()
        case .settling:
            break
        }
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            press = nil
            columnPress = nil
        }
        if phase == .movingColumn { return dropColumn() }
        if phase == .holding {
            release()
            return
        }
        let point = convert(event.locationInWindow, from: nil)
        guard phase == .idle, let press, let path = press.path, card(at: point) == path else { return }
        model.open(path, placement: event.modifierFlags.contains(.command) ? .newTab : .beside)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard phase == .idle, let path = card(at: convert(event.locationInWindow, from: nil)), let record = records[path]
        else { return nil }
        let menu = NSMenu()
        menu.addItem(ActionMenuItem(String(localized: "Open")) { [weak model] in model?.open(path, placement: .beside) })
        menu.addItem(ActionMenuItem(String(localized: "Open in New Tab")) { [weak model] in model?.open(path, placement: .newTab) })
        let current = lists.firstIndex { $0.contains(path) }
        let moves = columns.enumerated().filter { $0.offset != current }
        if !moves.isEmpty {
            let item = NSMenuItem(title: String(localized: "Move to"), action: nil, keyEquivalent: "")
            let submenu = NSMenu()
            for (_, column) in moves {
                submenu.addItem(ActionMenuItem(column.name) { [weak self] in self?.moveByMenu(path, to: column.value) })
            }
            item.submenu = submenu
            menu.addItem(item)
        }
        menu.addItem(.separator())
        menu.addItem(ActionMenuItem(String(localized: "Delete")) { [weak self] in self?.delete(record) })
        return menu
    }

    // MARK: The drag

    private func pickUp(_ path: String, at start: CGPoint) {
        guard let frame = placement.frame(of: path),
              let column = lists.firstIndex(where: { $0.contains(path) }),
              let index = lists[column].firstIndex(of: path),
              let content = contents[path]
        else { return }
        for card in live.values { card.setHovered(false, animated: true) }
        phase = .holding
        heldPath = path
        gap = (column, index)
        grab = CGSize(width: start.x - frame.minX, height: start.y - frame.minY)
        tilt = 0
        let copy = BoardCardView()
        copy.canHover = { false }
        copy.show(path: path, content: content, theme: theme)
        copy.frame = frame
        copy.layer?.zPosition = 100
        addSubview(copy)
        copy.layoutSubtreeIfNeeded()
        copy.setHeld(true, animated: true)
        held = copy
        live[path]?.setGhost(true, tint: NSColor(columns[column].swatch.text))
        columnLayers[column].setTargeted(true, appearance: effectiveAppearance)
        Haptics.levelChange()
        Sounds.play(.pickedUp)
        if !cursorPushed {
            NSCursor.closedHand.push()
            cursorPushed = true
        }
        startTicking()
    }

    /// The card goes where the pointer is (no animation: it is in the hand), and the gap goes where the card is.
    private func follow() {
        guard let held else { return }
        let point = CGPoint(x: pointer.x + visibleRect.minX, y: pointer.y + visibleRect.minY)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        held.setFrameOrigin(CGPoint(x: point.x - grab.width, y: point.y - grab.height))
        CATransaction.commit()
        retarget()
    }

    private func retarget() {
        guard let held, let path = heldPath, !lists.isEmpty else { return }
        let center = CGPoint(x: held.frame.midX, y: held.frame.midY)
        let column = BoardDragMath.column(at: center.x, count: lists.count)
        let heights = lists[column].filter { $0 != path }.map { height(of: $0) }
        let top = BoardMetrics.padding + BoardMetrics.headerHeight + BoardMetrics.itemSpacing
        let index = BoardDragMath.insertionIndex(y: center.y, top: top, heights: heights)
        guard gap.map({ $0.column != column || $0.index != index }) ?? true else { return }
        gap = (column, index)
        // Interruptible: a new target while the neighbours still move glides them on from where they are.
        relayout(animated: true)
        Haptics.alignment()
    }

    private func startTicking() {
        guard link == nil else { return }
        let link = displayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common)
        lastTick = 0
        self.link = link
    }

    private func stopTicking() {
        link?.invalidate()
        link = nil
    }

    /// Each frame while a card is held: the board scrolls near its edges, the card leans with the hand.
    @objc private func tick(_ link: CADisplayLink) {
        let now = link.timestamp
        let dt = lastTick == 0 ? 1.0 / 120 : min(now - lastTick, 1.0 / 20)
        lastTick = now
        guard phase == .holding, let owner else { return }
        let speed = BoardDragMath.autoScrollSpeed(pointerX: pointer.x, viewport: visibleRect.width)
        if speed != 0 {
            let x = visibleRect.minX + speed * dt
            let before = visibleRect.minX
            owner.scroll(toX: x, animated: false)
            if visibleRect.minX != before { follow() }
        }
        // The lean follows the hand's speed, and relaxes by itself when the hand stops.
        let idle = CACurrentMediaTime() - lastMove > 0.06
        let target = Motion.reduceMotion ? 0 : BoardDragMath.tilt(velocity: idle ? 0 : velocity.width)
        let next = tilt + (target - tilt) * min(1, dt * 14)
        if abs(next - tilt) > 0.01 {
            tilt = next
            held?.setTilt(tilt)
        }
    }

    /// Let go: the card falls onto its ghost (a spring on its layer, from where it is), then the move is written.
    private func release() {
        guard let held, let path = heldPath, let target = placement.frame(of: path) else { return land() }
        stopTicking()
        guard !Motion.reduceMotion else { return land() }
        phase = .settling
        tilt = 0
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.phase == .settling, self.heldPath == path else { return }
                self.land()
            }
        }
        let from = held.layer.map { $0.presentation()?.position ?? $0.position }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        held.frame = target
        CATransaction.commit()
        if let layer = held.layer, let from {
            let fall = CASpringAnimation(perceptualDuration: Motion.Spring.settle.duration, bounce: Motion.Spring.settle.bounce)
            fall.keyPath = "position"
            fall.isAdditive = true
            let delta = CGPoint(x: from.x - layer.position.x, y: from.y - layer.position.y)
            fall.fromValue = NSValue(point: delta)
            fall.toValue = NSValue(point: .zero)
            // The hand's speed at the release starts the spring (in distances per second, toward the slot).
            let distance = delta.x * delta.x + delta.y * delta.y
            if distance > 1 {
                fall.initialVelocity = -(velocity.width * delta.x + velocity.height * delta.y) / distance
            }
            fall.duration = fall.settlingDuration
            layer.add(fall, forKey: "fall")
        }
        held.setHeld(false, animated: true)
        CATransaction.commit()
    }

    /// The card is on its ghost: write the move, drop the ghost and the copy. The board then shows the model, whose
    /// order is the one on screen: nothing moves, only the counts change.
    /// The card is on its ghost: the copy and the ghost go, the card stays where it was let go, and the move is
    /// written on the next turn of the main thread, so the frame that lands the card only draws. The board then
    /// shows the model, whose order is the one on screen: nothing moves, only the counts change.
    private func land() {
        guard let path = heldPath, let gap, gap.column < columns.count else { return finishDrag() }
        let value = columns[gap.column].value
        let field = field
        finishDrag()
        landing = (path, gap.column, gap.index)
        Sounds.play(.dropped)
        if !Motion.reduceMotion { Haptics.alignment() }
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let landing = self.landing, landing.path == path else { return }
                self.model.moveEntry(path, to: value, in: field, at: landing.index)
                self.landing = nil
                self.owner?.refresh()
            }
        }
    }

    private func finishDrag() {
        stopTicking()
        let path = heldPath
        phase = .idle
        heldPath = nil
        gap = nil
        held?.removeFromSuperview()
        held = nil
        tilt = 0
        if let path { live[path]?.setGhost(false, tint: nil) }
        for layer in columnLayers { layer.setTargeted(false, appearance: effectiveAppearance) }
        if cursorPushed {
            NSCursor.pop()
            cursorPushed = false
        }
    }

    // MARK: Moving a column

    /// The column whose header is at `point`, if it can move: the column without a value stays last.
    private func movableColumn(headerAt point: CGPoint) -> Int? {
        guard phase == .idle else { return nil }
        return placement.columns.indices.first { index in
            index < columns.count && columns[index].value != nil
                && placement.columns[index].header.insetBy(dx: -BoardMetrics.padding, dy: -BoardMetrics.padding).contains(point)
        }
    }

    private func pickUpColumn(_ index: Int, at start: CGPoint) {
        guard index < placement.columns.count else { return }
        if adding != nil { closeField() }
        for card in live.values { card.setHovered(false, animated: true) }
        let left = placement.columns[index].background.minX
        phase = .movingColumn
        columnDrag = (index, start.x - left, left)
        Haptics.levelChange()
        Sounds.play(.pickedUp)
        if !cursorPushed {
            NSCursor.closedHand.push()
            cursorPushed = true
        }
        relayout(animated: true)
    }

    /// The held column goes with the hand, sideways only; past the middle of a neighbour, they swap places.
    private func followColumn(_ point: CGPoint) {
        guard var drag = columnDrag else { return }
        let movable = columns.filter { $0.value != nil }.count
        guard movable > 0 else { return }
        drag.x = min(max(point.x - drag.grab, -BoardMetrics.spacing),
                     BoardMetrics.columnX(movable - 1) + BoardMetrics.spacing)
        let target = min(BoardDragMath.column(at: drag.x + BoardMetrics.column / 2, count: columns.count), movable - 1)
        let moved = target != drag.index
        if moved {
            func shift<T>(_ items: inout [T]) { items.insert(items.remove(at: drag.index), at: target) }
            shift(&columns)
            shift(&lists)
            shift(&columnLayers)
            shift(&headers)
            shift(&pluses)
            drag.index = target
            Haptics.alignment()
        }
        columnDrag = drag
        relayout(animated: moved)
    }

    /// Let go: the column glides into its place, and the field's options take the columns' new order.
    private func dropColumn() {
        guard columnDrag != nil else { return }
        let before = (lastInput?.groups ?? []).compactMap { $0.value.map(CollectionViewModel.text) }
        finishColumnDrag()
        Sounds.play(.dropped)
        relayout(animated: true)
        let order = columns.compactMap { $0.value.map(CollectionViewModel.text) }
        guard order != before else { return }
        let field = field
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.model.reorderColumns(order, of: field)
                self.owner?.refresh()
            }
        }
    }

    private func finishColumnDrag() {
        columnDrag = nil
        if phase == .movingColumn { phase = .idle }
        if cursorPushed {
            NSCursor.pop()
            cursorPushed = false
        }
    }

    // MARK: Acting

    private func moveByMenu(_ path: String, to value: PropertyValue?) {
        model.moveEntry(path, to: value, in: field, at: .max)
        owner?.refresh()
    }

    private func openField(_ column: Int) {
        guard column < columns.count else { return }
        addField?.removeFromSuperview()
        let field = BoardAddField(theme: theme)
        field.commit = { [weak self] title in self?.commitAdd(title, column: column) }
        field.cancel = { [weak self] in self?.closeField() }
        addField = field
        adding = column
        addSubview(field)
        relayout(animated: true)
        if let frame = placement.columns[column].field { field.frame = frame }
        field.layer?.add(BoardScrollView.fade(from: 0, to: 1, duration: 0.15), forKey: "enter")
        window?.makeFirstResponder(field.field)
    }

    private func closeField() {
        guard let field = addField else { return }
        addField = nil
        adding = nil
        field.removeFromSuperview()
        relayout(animated: true)
    }

    private func commitAdd(_ title: String, column: Int) {
        guard column < columns.count else { return closeField() }
        let value = columns[column].value
        var values: [String: PropertyValue] = [:]
        if let value, field.namespace == .note { values[field.name] = value }
        let field = field
        addField?.removeFromSuperview()
        addField = nil
        adding = nil
        // A new card goes under the others, wherever its name would sort.
        if let path = model.newEntry(title: title, values: values) {
            model.moveEntry(path, to: value, in: field, at: .max)
        }
        owner?.refresh()
    }

    private func askNewColumn() {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = String(localized: "New column")
        let input = NSTextField(frame: CGRect(x: 0, y: 0, width: 220, height: 24))
        input.placeholderString = String(localized: "Name")
        alert.accessoryView = input
        alert.addButton(withTitle: String(localized: "Add"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.window.initialFirstResponder = input
        let field = field
        alert.beginSheetModal(for: window) { [weak self] response in
            MainActor.assumeIsolated {
                guard response == .alertFirstButtonReturn, let self else { return }
                self.model.addOption(input.stringValue, to: field)
                self.owner?.refresh()
                self.owner?.scroll(toX: .greatestFiniteMagnitude, animated: true)
            }
        }
    }

    private func delete(_ record: NoteRecord) {
        do {
            let trashed = try services.trash(record.path)
            model.reload()
            owner?.refresh()
            owner?.showUndo(title: record.title) { [weak self] in self?.restore(trashed, title: record.title) }
        } catch {
            services.report("Could not delete “\(record.title)”: \(error)")
        }
    }

    private func restore(_ trashPath: String, title: String) {
        do {
            // The card comes back to the index it left, the gap opening for it.
            _ = try services.restore(trashPath)
            model.reload()
            owner?.refresh()
        } catch {
            services.report("Could not restore “\(title)”: \(error)")
        }
    }
}
