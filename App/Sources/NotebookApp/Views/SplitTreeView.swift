import AppKit
import PluginKitUI
import SwiftUI
import WorkspaceModel

/// The workspace tree, laid out by AppKit: each pane in its own hosting view (`PaneHostView`), placed by the model's
/// fractions in `layout()`, with the dividers between them. The model decides the shape; this view draws it and
/// forwards the dividers' drags.
///
/// A window resize sets the frames once per pass and lays out what is in each pane; nothing of SwiftUI's is laid
/// out above the panes. The root is always a split here, as it was in SwiftUI: a pane that gets a neighbour keeps its
/// view (its scroll position, its editor) and only its width changes, as the neighbour comes in.
struct WorkspaceView: View {
    let workspace: WorkspaceController
    let views: ViewRegistryStore

    /// Reads the tree in its own body: a change of it runs only this one, not the window's.
    var body: some View {
        WorkspaceTree(workspace: workspace, views: views, root: workspace.layout.root)
    }
}

/// The AppKit view of the tree, updated in the transaction of the tree's change.
private struct WorkspaceTree: NSViewRepresentable {
    let workspace: WorkspaceController
    let views: ViewRegistryStore
    /// The tree to draw, read by the view that makes this one, so a change of it updates this view in the change's
    /// transaction: a pane added with an animation arrives with its motion.
    let root: LayoutNode

    func makeNSView(context: Context) -> SplitTreeView {
        let view = SplitTreeView(workspace: workspace, views: views, environment: context.environment)
        view.follow(edges: context.environment.sidebarEdges)
        view.apply(root, animated: false)
        return view
    }

    func updateNSView(_ view: SplitTreeView, context: Context) {
        view.follow(edges: context.environment.sidebarEdges)
        view.update(environment: context.environment)
        let transaction = context.transaction
        view.apply(root, animated: transaction.animation != nil && !transaction.disablesAnimations)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: SplitTreeView, context: Context) -> CGSize? {
        proposal.replacingUnspecifiedDimensions(by: .zero)
    }
}

/// The view of the workspace tree: the panes and the dividers, laid out by hand.
final class SplitTreeView: ShellView {
    private let workspace: WorkspaceController
    private let views: ViewRegistryStore
    private var environment: EnvironmentValues
    private(set) var root: LayoutNode?
    private(set) var panes: [PaneID: PaneHostView] = [:]
    private(set) var dividers: [DividerKey: SplitDividerView] = [:]

    /// The fractions shown instead of the model's: while a divider is dragged (written to the workspace once, when
    /// it is let go), and while the pages spring onto a position. Writing the layout on every pointer event
    /// invalidated every view that reads it and saved it, on every frame of the drag.
    private var shownFractions: [UUID: [Double]] = [:]
    /// Each split's length less its dividers, from the last layout pass: what a drag of its dividers is measured in.
    private var available: [UUID: CGFloat] = [:]

    /// The gap between two pages, which is also the divider's room.
    static let dividerThickness: CGFloat = Glass.gap
    /// How wide the grip under the pointer is: a little more than the gap, so it is easy to catch.
    static let gripThickness: CGFloat = 10
    /// A pane is never dragged smaller than this.
    static let minimumLength: CGFloat = 120

    struct DividerKey: Hashable {
        let split: UUID
        let index: Int
    }

    init(workspace: WorkspaceController, views: ViewRegistryStore, environment: EnvironmentValues) {
        self.workspace = workspace
        self.views = views
        self.environment = environment
        super.init(frame: .zero)
        wantsLayer = true
        followTree()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }

    // MARK: Model

    /// The tree comes from SwiftUI (`WorkspaceTree.updateNSView`), in the transaction of its change. A change made
    /// during a drop, inside AppKit's drag loop, sometimes never reached it: the note was open in the model, but its
    /// pane only showed at the next drag. The view also follows the model itself, one turn later, and draws a tree
    /// SwiftUI has not handed over; when SwiftUI did, `apply` has nothing left to do.
    private func followTree() {
        withObservationTracking {
            _ = workspace.layout.root
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                guard let self else { return }
                let root = self.workspace.layout.root
                if root != self.root { self.apply(root, animated: !Motion.reduceMotion) }
                self.followTree()
            }
        }
    }

    func update(environment: EnvironmentValues) {
        self.environment = environment
        for pane in panes.values { pane.update(environment: environment) }
        let accent = NSColor(environment.themeTokens.accent)
        for divider in dividers.values { divider.accent = accent }
    }

    /// Draws `root`: a pane that is new arrives from the side it opens on while the others take their room at once;
    /// a pane that goes fades quickly where it was (`Motion.exit`). Under Reduce Motion, only the fades.
    func apply(_ root: LayoutNode, animated: Bool) {
        // Out of a window, the panes wait for it: a hosting view made before it is in a window gives VoiceOver (and
        // `loam-ctl ax`) none of its SwiftUI elements.
        guard window != nil else {
            pending = root
            return
        }
        pending = nil
        guard root != self.root else { return }
        self.root = root
        let present = Set(root.allPanes.map(\.id))
        for (id, view) in panes where !present.contains(id) {
            panes[id] = nil
            leave(view, animated: animated)
        }
        var arrived: [PaneHostView] = []
        for pane in root.allPanes where panes[pane.id] == nil {
            let view = PaneHostView(pane: pane.id, workspace: workspace, views: views, environment: environment)
            panes[pane.id] = view
            // Under the dividers, which take the pointer over the gap and a point of each page beside it.
            addSubview(view, positioned: .below, relativeTo: firstDivider)
            arrived.append(view)
        }
        let first = root.allPanes.first?.id, last = root.allPanes.last?.id
        for (id, view) in panes {
            view.isFirst = id == first
            view.isLast = id == last
        }
        syncDividers(root)
        // Fractions shown ahead of the model (a drag let go) go once the model has them, unless the pages are still
        // moving there.
        shownFractions = shownFractions.filter { split, shown in
            guard let model = root.split(split)?.fractions, model.count == shown.count else { return false }
            return model != shown || drag?.key.split == split || settling?.split == split
        }
        needsLayout = true
        layoutSubtreeIfNeeded()
        guard animated else { return }
        for view in arrived {
            if let place = root.place(of: view.pane) { arrive(view, index: place.index, axis: place.axis) }
        }
    }

    /// The tree given before the view was in a window.
    private var pending: LayoutNode?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let pending, window != nil { apply(pending, animated: false) }
    }

    private var firstDivider: NSView? { subviews.first { $0 is SplitDividerView } }

    private func syncDividers(_ root: LayoutNode) {
        var wanted: [DividerKey: SplitAxis] = [:]
        root.forEachSplit { id, axis, children in
            for index in 0..<max(0, children.count - 1) { wanted[DividerKey(split: id, index: index)] = axis }
        }
        for (key, divider) in dividers where wanted[key] != divider.axis {
            divider.removeFromSuperview()
            dividers[key] = nil
        }
        let accent = NSColor(environment.themeTokens.accent)
        for (key, axis) in wanted where dividers[key] == nil {
            let divider = SplitDividerView(key: key, axis: axis, tree: self)
            divider.accent = accent
            dividers[key] = divider
            addSubview(divider)
        }
    }

    // MARK: Layout

    override func layout() {
        super.layout()
        guard let root else { return }
        place(root, in: bounds)
        if pendingClip != nil { clipSlide() }
    }

    private func place(_ node: LayoutNode, in rect: CGRect) {
        switch node {
        case .pane(let pane):
            setFrame(of: panes[pane.id], to: rect)
        case .split(let id, let axis, let children, let fractions):
            let shown = shownFractions[id] ?? fractions
            let horizontal = axis == .horizontal
            let total = horizontal ? rect.width : rect.height
            let length = max(0, total - Self.dividerThickness * CGFloat(children.count - 1))
            available[id] = length
            var offset: CGFloat = 0
            for (index, child) in children.enumerated() {
                let share = length * CGFloat(index < shown.count ? shown[index] : 0)
                let start = pixel(offset), end = pixel(offset + share)
                let childRect = horizontal
                    ? CGRect(x: rect.minX + start, y: rect.minY, width: end - start, height: rect.height)
                    : CGRect(x: rect.minX, y: rect.minY + start, width: rect.width, height: end - start)
                place(child, in: childRect)
                offset += share
                guard index < children.count - 1 else { continue }
                let middle = offset + Self.dividerThickness / 2
                let grip = Self.gripThickness
                let dividerRect = horizontal
                    ? CGRect(x: rect.minX + middle - grip / 2, y: rect.minY, width: grip, height: rect.height)
                    : CGRect(x: rect.minX, y: rect.minY + middle - grip / 2, width: rect.width, height: grip)
                setFrame(of: dividers[DividerKey(split: id, index: index)], to: dividerRect)
                offset += Self.dividerThickness
            }
        }
    }

    /// `value` on the screen's pixel grid, as SwiftUI's stacks place their children.
    private func pixel(_ value: CGFloat) -> CGFloat {
        let scale = window?.backingScaleFactor ?? 2
        return (value * scale).rounded() / scale
    }

    private func setFrame(of view: NSView?, to rect: CGRect) {
        guard let view, view.frame != rect else { return }
        view.frame = rect
    }

    // MARK: Panes coming and going

    /// A pane opening in the split arrives from the edge it opens on, where its drop zone was, as its neighbours make
    /// room (`Motion.Metrics.paneShift`, `Motion.Spring.smooth`: a page never overshoots); with Reduce Motion it only
    /// fades in.
    private func arrive(_ view: PaneHostView, index: Int, axis: SplitAxis) {
        guard let layer = view.layer else { return }
        let reduceMotion = Motion.reduceMotion
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let fade = reduceMotion ? CABasicAnimation(keyPath: "opacity") : Self.spring(.smooth, keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        if reduceMotion {
            fade.duration = 0.12
            fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
        }
        layer.add(fade, forKey: "arrive.fade")
        if !reduceMotion {
            let shift = (index == 0 ? -1 : 1) * Motion.Metrics.paneShift
            // In the layer's own space, which is not flipped: a shift down the screen is a negative y.
            let slide = Self.spring(.smooth, keyPath: axis == .horizontal ? "position.x" : "position.y")
            slide.isAdditive = true
            slide.fromValue = axis == .horizontal ? shift : -shift
            slide.toValue = 0
            layer.add(slide, forKey: "arrive.slide")
        }
        CATransaction.commit()
    }

    /// A pane closing fades quickly where it was (`Motion.exit`) while the others take its room at once.
    private func leave(_ view: PaneHostView, animated: Bool) {
        view.isLeaving = true
        guard animated, let layer = view.layer else {
            view.removeFromSuperview()
            return
        }
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak view] in view?.removeFromSuperview() }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = layer.presentation()?.opacity ?? 1
        fade.toValue = 0
        fade.duration = 0.12
        fade.timingFunction = CAMediaTimingFunction(name: .easeIn)
        layer.opacity = 0
        layer.add(fade, forKey: "leave")
        CATransaction.commit()
    }

    static func spring(_ spring: Motion.Spring, keyPath: String) -> CASpringAnimation {
        let animation = CASpringAnimation(perceptualDuration: spring.duration, bounce: spring.bounce)
        animation.keyPath = keyPath
        animation.duration = animation.settlingDuration
        return animation
    }

    // MARK: Sidebar slides

    /// Where the sidebars left the workspace last: its leading edge and the room right of the last page.
    private var edges: SidebarEdges?
    private var slideGeneration = 0

    /// Plays a sidebar's slide on the workspace, laid out once where the slide leaves it: it is first drawn where its
    /// leading edge was and follows the column's edge there (the left sidebar), and it is cut at the inspector's edge
    /// as that column comes or goes, so its pages and tabs never cover the column. All of it additive springs on the
    /// render server (`Motion.Spring.slide`), as the column's own slide (`SlidingColumnView`): nothing is laid out
    /// on the frames of the slide. The last page's edge (`PageChromeView.followSlide`) and the first tab bar's room
    /// for the traffic lights (`TabBarView.setLeadingInset`) follow on their own.
    func follow(edges new: SidebarEdges?) {
        let old = edges
        edges = new
        guard let old, let new, old != new, new.animation != nil, window != nil, let layer else { return }
        let shift = (old.leadingEdge - new.leadingEdge).rounded()
        let bleed = (new.trailingRoom - old.trailingRoom).rounded()
        slideGeneration += 1
        if shift != 0 { layer.add(Self.slide("position.x", from: shift), forKey: "slide") }
        // The cut needs the width the slide leaves: it comes with the layout that follows this update.
        pendingClip = (shift, bleed)
        needsLayout = true
        DispatchQueue.main.async { [weak self] in self?.clipSlide() }
    }

    private var pendingClip: (shift: CGFloat, bleed: CGFloat)?

    /// Cuts the workspace at its trailing edge for the slide: everything left of, above and below it, a plain
    /// rectangle the render server clips to. It stays at the edge's place while the workspace moves (the opposite of
    /// the shift), and its own edge follows the inspector's. Gone once the slide has settled.
    private func clipSlide() {
        guard let (shift, bleed) = pendingClip, let layer else { return }
        pendingClip = nil
        let generation = slideGeneration
        let far: CGFloat = 10_000
        let clip = CALayer()
        clip.backgroundColor = NSColor.black.cgColor
        clip.frame = CGRect(x: -far, y: -far, width: bounds.width + far, height: bounds.height + 2 * far)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        CATransaction.setCompletionBlock { [weak self] in
            guard let self, self.slideGeneration == generation else { return }
            self.layer?.mask = nil
        }
        layer.mask = clip
        // Its leading end stays far out: the clip grows from its centre, and moves back against the shift.
        if shift != 0 || bleed != 0 { clip.add(Self.slide("position.x", from: bleed / 2 - shift), forKey: "slide") }
        if bleed != 0 { clip.add(Self.slide("bounds.size.width", from: bleed), forKey: "slide.width") }
        // Held for the whole slide, whichever move is the last.
        let hold = Self.slide("opacity", from: 0)
        clip.add(hold, forKey: "hold")
        CATransaction.commit()
    }

    private static func slide(_ keyPath: String, from value: CGFloat) -> CASpringAnimation {
        let animation = spring(.slide, keyPath: keyPath)
        animation.isAdditive = true
        animation.fromValue = value
        animation.toValue = 0
        return animation
    }

    // MARK: Dividers

    /// The drag in progress: its divider, the fractions when it started, whether the boundary is held on a key
    /// position.
    private var drag: (key: DividerKey, start: [Double], snapped: Bool)?
    /// The fractions before a double click evened a divider out, to go back to on the next one.
    private var beforeEvening: [UUID: [Double]] = [:]
    private var settling: FractionSpring?

    private func fractions(of split: UUID) -> [Double]? {
        shownFractions[split] ?? root?.split(split)?.fractions
    }

    /// Moves the boundary between child `index` and the next one by `translation` points from where the drag started,
    /// keeping both at least `minimumLength`. Near a key position the boundary sticks to it, then lets go with a pull
    /// (`SplitSnap`); the pages follow the pointer 1:1 meanwhile.
    func dragDivider(_ key: DividerKey, by translation: CGFloat) {
        guard let current = fractions(of: key.split), let length = available[key.split], length > 0,
              key.index + 1 < current.count else { return }
        if drag?.key != key {
            settling = nil
            drag = (key, current, false)
            workspace.dividerDragChanged(true)
            dividers[key]?.isDragging = true
        }
        guard let start = drag?.start else { return }
        let pair = start[key.index] + start[key.index + 1]
        let minimum = min(Self.minimumLength / length, pair / 2)
        let raw = min(max(start[key.index] + translation / length, minimum), pair - minimum)
        let magnet = SplitSnap.resolve(first: raw, pair: pair, pairLength: pair * length, minimum: minimum)
        var updated = start
        updated[key.index] = magnet.first
        updated[key.index + 1] = pair - magnet.first
        if magnet.isSnapped != drag?.snapped {
            if magnet.isSnapped { Haptics.alignment() }
            drag?.snapped = magnet.isSnapped
            dividers[key]?.isSnapped = magnet.isSnapped
        }
        shownFractions[key.split] = updated
        needsLayout = true
    }

    /// Lets go of the divider: close enough to a key position, it falls onto it with `Motion.Spring.settle`. The
    /// workspace gets the fractions once, now.
    func endDividerDrag(_ key: DividerKey) {
        guard drag?.key == key, let current = fractions(of: key.split) else { return }
        drag = nil
        dividers[key]?.isDragging = false
        dividers[key]?.isSnapped = false
        workspace.dividerDragChanged(false)
        var updated = current
        if key.index + 1 < current.count, let length = available[key.split] {
            let pair = current[key.index] + current[key.index + 1]
            if let first = SplitSnap.landing(first: current[key.index], pair: pair, pairLength: pair * length) {
                updated[key.index] = first
                updated[key.index + 1] = pair - first
            }
        }
        move(key.split, from: current, to: updated)
    }

    /// Sizes the two pages around a divider the same; once they are, the next double click goes back to the sizes
    /// they had.
    func evenOut(_ key: DividerKey) {
        guard let current = fractions(of: key.split), key.index + 1 < current.count else { return }
        let pair = current[key.index] + current[key.index + 1]
        var updated = current
        if abs(current[key.index] - pair / 2) < 0.002, let before = beforeEvening[key.split], before.count == current.count {
            updated = before
            beforeEvening[key.split] = nil
        } else {
            beforeEvening[key.split] = current
            updated[key.index] = pair / 2
            updated[key.index + 1] = pair / 2
        }
        Haptics.alignment()
        move(key.split, from: current, to: updated)
    }

    /// Gives the workspace `target` and moves the pages there from `start` with `Motion.Spring.settle`, laid out on
    /// each frame of it; at once under Reduce Motion or when they are already there.
    private func move(_ split: UUID, from start: [Double], to target: [Double]) {
        settling = nil
        // Shown until the model comes back with them (`apply`), so no frame shows the pages where they were.
        shownFractions[split] = target
        workspace.setFractions(split: split, target)
        needsLayout = true
        guard start != target, !Motion.reduceMotion, window != nil else { return }
        shownFractions[split] = start
        settling = FractionSpring(view: self, split: split, from: start, to: target, spring: .settle) { [weak self] fractions in
            guard let self else { return }
            if let fractions {
                self.shownFractions[split] = fractions
            } else {
                self.settling = nil
                self.shownFractions[split] = self.root?.split(split)?.fractions == target ? nil : target
            }
            self.needsLayout = true
        }
    }
}

/// Fractions moving from one set to another on a spring, a value per display frame, for what Core Animation cannot
/// move by itself: the pages' widths, which lay their content out again.
@MainActor
final class FractionSpring: NSObject {
    let split: UUID
    private let from: [Double]
    private let to: [Double]
    private let spring: SwiftUI.Spring
    private let step: ([Double]?) -> Void
    private var link: CADisplayLink?
    private var start: CFTimeInterval?

    init(view: NSView, split: UUID, from: [Double], to: [Double], spring: Motion.Spring, step: @escaping ([Double]?) -> Void) {
        self.split = split
        self.from = from
        self.to = to
        self.spring = SwiftUI.Spring(duration: spring.duration, bounce: spring.bounce)
        self.step = step
        super.init()
        let link = view.displayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    @objc private func tick(_ link: CADisplayLink) {
        let now = link.targetTimestamp
        let begin = start ?? link.timestamp
        start = begin
        let time = now - begin
        guard time < spring.settlingDuration else {
            link.invalidate()
            self.link = nil
            step(nil)
            return
        }
        let progress = spring.value(target: 1.0, time: time)
        step(zip(from, to).map { $0 + ($1 - $0) * progress })
    }

    isolated deinit {
        link?.invalidate()
    }
}

/// The gap between two pages. At rest it is invisible, with the resize pointer; under the pointer a slim grip shows
/// in the middle of the gap; while dragged the grip stretches into a line along the whole divider, and lights up in
/// the accent when the boundary is held on a key position. A double click evens the two pages out.
final class SplitDividerView: ShellView {
    let key: SplitTreeView.DividerKey
    let axis: SplitAxis
    private weak var tree: SplitTreeView?
    private let bar = CALayer()
    /// Where the pointer went down, in the window, so that the divider moving under it does not skew the drag.
    private var downPoint: NSPoint?
    private var hasDragged = false

    var accent: NSColor = .controlAccentColor { didSet { updateBar(animated: false) } }
    private var isHovering = false { didSet { if isHovering != oldValue { updateBar(animated: true) } } }
    var isDragging = false { didSet { if isDragging != oldValue { updateBar(animated: true) } } }
    var isSnapped = false { didSet { if isSnapped != oldValue { updateBar(animated: true) } } }

    /// The visible bar's thickness at rest under the pointer, and while dragged or held.
    private static let barThickness: CGFloat = 4
    private static let activeThickness: CGFloat = 5

    init(key: SplitTreeView.DividerKey, axis: SplitAxis, tree: SplitTreeView) {
        self.key = key
        self.axis = axis
        self.tree = tree
        super.init(frame: .zero)
        wantsLayer = true
        bar.opacity = 0
        layer?.addSublayer(bar)
        setAccessibilityElement(true)
        setAccessibilityRole(.splitter)
        setAccessibilityLabel("Split divider")
        setAccessibilityOrientation(axis == .horizontal ? .vertical : .horizontal)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func layout() {
        super.layout()
        updateBar(animated: false)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(
            rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self
        ))
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: axis == .horizontal ? .columnResize : .rowResize)
    }

    /// Only for a pointer that is over the grip: AppKit also says the pointer entered when the area is laid again
    /// under where the pointer last was, in another window or none.
    override func mouseEntered(with event: NSEvent) {
        isHovering = event.window === window && bounds.contains(convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) { isHovering = false }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            downPoint = nil
            tree?.evenOut(key)
            return
        }
        downPoint = event.locationInWindow
        hasDragged = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let downPoint else { return }
        let point = event.locationInWindow
        // The window's space grows upwards; the split's downwards.
        let translation = axis == .horizontal ? point.x - downPoint.x : downPoint.y - point.y
        guard hasDragged || abs(translation) >= 1 else { return }
        hasDragged = true
        tree?.dragDivider(key, by: translation)
    }

    override func mouseUp(with event: NSEvent) {
        if hasDragged { tree?.endDividerDrag(key) }
        downPoint = nil
        hasDragged = false
    }

    /// The grip: a short pill under the pointer, a long line while dragged, the accent's glow while held.
    private func updateBar(animated: Bool) {
        let horizontal = axis == .horizontal
        let thickness = isDragging || isSnapped ? Self.activeThickness : Self.barThickness
        let along = horizontal ? bounds.height : bounds.width
        let length = isDragging ? max(along - 2 * Glass.pageRadius, 0) : min(44, along)
        let shown = isHovering || isDragging
        CATransaction.begin()
        if animated && !Motion.reduceMotion {
            // A hover fades (`Motion.hover`); a drag starting or holding a key position moves with `Motion.Spring.tap`.
            CATransaction.setAnimationDuration(isDragging || isSnapped ? Motion.Spring.tap.duration : 0.12)
            CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
        } else if animated {
            CATransaction.setAnimationDuration(0.12)
        } else {
            CATransaction.setDisableActions(true)
        }
        bar.bounds = CGRect(x: 0, y: 0, width: horizontal ? thickness : length, height: horizontal ? length : thickness)
        bar.position = CGPoint(x: bounds.midX, y: bounds.midY)
        bar.cornerRadius = thickness / 2
        bar.backgroundColor = accent.withAlphaComponent(isSnapped ? 1 : isDragging ? 0.55 : 0.35).cgColor
        bar.shadowColor = accent.cgColor
        bar.shadowRadius = 5
        bar.shadowOffset = .zero
        bar.shadowOpacity = isSnapped ? 0.6 : 0
        bar.opacity = shown ? 1 : 0
        CATransaction.commit()
    }
}

/// The key positions of a divider, and the magnet that pulls it onto them.
///
/// The boundary follows the pointer one for one, until it comes within `reach` points of a key position. There the
/// pointer moves it less and less, down to nothing within `grip` points: it sticks. Pulled farther, it lets go with
/// a little catch-up, ending back on the pointer at `reach`, so it never jumps.
enum SplitSnap {
    /// Where the first of two pages can take the pair's room: half, then thirds and quarters.
    static let ratios: [Double] = [1.0 / 2, 1.0 / 3, 2.0 / 3, 1.0 / 4, 3.0 / 4]
    /// Within this distance, in points, of a key position the boundary is held on it.
    static let grip: CGFloat = 4
    /// The distance at which the magnet starts to pull.
    static let reach: CGFloat = 24
    /// Letting go of the divider within this distance of a key position lands it on it.
    static let landing: CGFloat = 12

    /// The nearest key position to `first`, as a fraction and its distance in points, if one is usable.
    private static func nearest(first: Double, pair: Double, pairLength: CGFloat, minimum: Double) -> (fraction: Double, distance: Double)? {
        guard pair > 0, pairLength > 0 else { return nil }
        var best: (fraction: Double, distance: Double)?
        for ratio in ratios {
            let candidate = pair * ratio
            guard candidate >= minimum, pair - candidate >= minimum else { continue }
            let distance = abs(first - candidate) * Double(pairLength) / pair
            if distance < (best?.distance ?? .infinity) { best = (candidate, distance) }
        }
        return best
    }

    /// Where the boundary goes when the pointer puts the first page at `first`: the fraction, and whether the
    /// boundary is held on a key position.
    static func resolve(first: Double, pair: Double, pairLength: CGFloat, minimum: Double) -> (first: Double, isSnapped: Bool) {
        guard let near = nearest(first: first, pair: pair, pairLength: pairLength, minimum: minimum),
              near.distance < Double(reach) else { return (first, false) }
        if near.distance <= Double(grip) { return (near.fraction, true) }
        // From `grip` to `reach`: a cubic that starts flat, ends on the pointer with its slope.
        let r = Double(reach), u = near.distance - Double(grip), l = r - Double(grip)
        let c3 = (1 - 2 * r / l) / (l * l)
        let c2 = (3 * r - l) / (l * l)
        let pulled = c2 * u * u + c3 * u * u * u
        let sign: Double = first < near.fraction ? -1 : 1
        return (near.fraction + sign * pulled * pair / Double(pairLength), false)
    }

    /// The key position a divider let go at `first` falls onto, if it is close enough.
    static func landing(first: Double, pair: Double, pairLength: CGFloat) -> Double? {
        guard let near = nearest(first: first, pair: pair, pairLength: pairLength, minimum: 0),
              near.distance <= Double(landing), near.distance > 0.01 else { return nil }
        return near.fraction
    }
}

extension LayoutNode {
    /// The panes of this tree in reading order.
    var allPanes: [Pane] {
        switch self {
        case .pane(let pane): [pane]
        case .split(_, _, let children, _): children.flatMap(\.allPanes)
        }
    }

    /// The split with `id` in this tree.
    func split(_ id: UUID) -> (axis: SplitAxis, children: [LayoutNode], fractions: [Double])? {
        guard case .split(let splitID, let axis, let children, let fractions) = self else { return nil }
        if splitID == id { return (axis, children, fractions) }
        for child in children { if let found = child.split(id) { return found } }
        return nil
    }

    /// Calls `body` with every split of this tree, outermost first.
    func forEachSplit(_ body: (UUID, SplitAxis, [LayoutNode]) -> Void) {
        guard case .split(let id, let axis, let children, _) = self else { return }
        body(id, axis, children)
        for child in children { child.forEachSplit(body) }
    }

    /// Where pane `id` sits in its split: its index and the split's axis; nil for a lone pane.
    func place(of id: PaneID) -> (index: Int, axis: SplitAxis)? {
        guard case .split(_, let axis, let children, _) = self else { return nil }
        for (index, child) in children.enumerated() {
            if case .pane(let pane) = child, pane.id == id { return (index, axis) }
            if let found = child.place(of: id) { return found }
        }
        return nil
    }
}
