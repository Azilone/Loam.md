import AppKit
import Observation
import PluginKitUI
import SwiftUI
import WorkspaceModel

/// A pane's tabs in AppKit, each as wide as its title (up to a limit), as in Craft: click to select, the cross to close,
/// drag to move (onto another tab bar, or a pane's edge to split), a right-click for the note's actions. The selected
/// tab sits on a bead of glass that slides from tab to tab; a tab opening grows from its left edge while the others
/// slide over, one closing fades while the others close the gap. Every motion is a Core Animation one: as SwiftUI
/// (`TabStrip`), each frame of a new tab's arrival laid the strip out on the main thread, late under a page being built.
final class TabStripView: NSView {
    private let pane: PaneID
    private weak var workspace: WorkspaceController?
    private let views: ViewRegistryStore
    /// Each tab's frame here, for the bar's drops and its window drag.
    let frames: Measured<[TabID: CGRect]>
    /// Called when the tabs or the selection change: the bar sizes the strip and scrolls the selected tab into view.
    var onChange: (() -> Void)?
    var environment: PaneEnvironment { didSet { if environment != oldValue { themeChanged() } } }

    private var items: [TabID: TabItemView] = [:]
    private var order: [TabID] = []
    private var selected: TabID?
    private let glass = CALayer()
    /// The width the tabs take, with the room after the last one.
    private(set) var contentWidth: CGFloat = 0

    static let spacing: CGFloat = 4
    static let trailingRoom: CGFloat = 24
    static let verticalPadding: CGFloat = 5

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    init(pane: PaneID, workspace: WorkspaceController, views: ViewRegistryStore, environment: PaneEnvironment, frames: Measured<[TabID: CGRect]>) {
        self.pane = pane
        self.workspace = workspace
        self.views = views
        self.environment = environment
        self.frames = frames
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = false
        glass.contentsGravity = .resize
        glass.zPosition = -1
        layer?.addSublayer(glass)
        themeChanged()
        sync(animated: false)
        observe()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// The tokens the tabs are drawn with: the canvas's, light on a dark sidebar colour.
    var theme: ThemeTokens {
        let tokens = environment.themeTokens
        return tokens.hasDarkCanvas ? tokens.onCanvas : tokens
    }

    private var isDark: Bool {
        environment.themeTokens.hasDarkCanvas || effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        themeChanged()
    }

    private func themeChanged() {
        updateGlassImage()
        for item in items.values { item.theme = theme }
        relayout(animated: false)
    }

    private func updateGlassImage() {
        let image = TabGlassImage.image(isDark: isDark)
        // The ends (margin and corner) keep their size; the middle of the capsule stretches. The corner is the
        // theme's radius, not half the height: with smaller corners the slice came out empty and the glass stayed
        // at the image's own width, a narrow pill at the tab's start.
        let cap = TabGlassImage.margin + TabGlassImage.radius
        glass.contents = image
        glass.contentsScale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        glass.contentsCenter = CGRect(x: cap / image.size.width, y: 0, width: max(0, 1 - 2 * cap / image.size.width), height: 1)
    }

    // MARK: Model

    private struct Snapshot: Equatable {
        var tabs: [Entry]
        var selected: TabID?
        var isFocused: Bool
    }

    private struct Entry: Equatable {
        var id: TabID
        var title: String
        var resource: Resource
    }

    private func snapshot() -> Snapshot? {
        guard let workspace, let pane = workspace.layout.panes.first(where: { $0.id == pane }) else { return nil }
        let tabs = pane.tabs.map { tab in
            Entry(id: tab.id, title: workspace.isNewTab(tab.id) ? "New Tab" : views.title(for: tab.resource), resource: tab.resource)
        }
        return Snapshot(tabs: tabs, selected: pane.selected, isFocused: workspace.layout.focusedPane == pane.id)
    }

    private func observe() {
        withObservationTracking {
            _ = snapshot()
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                guard let self else { return }
                self.sync(animated: true)
                self.observe()
            }
        }
    }

    private var last: Snapshot?

    private func sync(animated: Bool) {
        guard let snapshot = snapshot(), snapshot != last else { return }
        let animate = animated && !Motion.reduceMotion && last != nil
        last = snapshot
        let ids = snapshot.tabs.map(\.id)
        // Tabs gone: fade faster than they came (`Motion.exit`), then go.
        for (id, item) in items where !ids.contains(id) {
            items[id] = nil
            frames.value[id] = nil
            if animate {
                item.isLeaving = true
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = Motion.appKitDuration(PageStackView.exit)
                    item.animator().alphaValue = 0
                } completionHandler: { [weak item] in
                    MainActor.assumeIsolated { item?.removeFromSuperview() }
                }
            } else {
                item.removeFromSuperview()
            }
        }
        var arriving: [TabItemView] = []
        for entry in snapshot.tabs {
            let item = items[entry.id] ?? {
                let made = TabItemView(id: entry.id, strip: self)
                made.theme = theme
                addSubview(made)
                items[entry.id] = made
                arriving.append(made)
                return made
            }()
            item.show(
                title: entry.title, resource: entry.resource, isSelected: entry.id == snapshot.selected,
                isFocusedPane: snapshot.isFocused
            )
        }
        order = ids
        selected = snapshot.selected
        relayout(animated: animate, arriving: Set(arriving.map(\.id)))
        if animate {
            for item in arriving { item.growIn() }
        }
        onChange?()
    }

    // MARK: Layout

    private func relayout(animated: Bool, arriving: Set<TabID> = []) {
        var x: CGFloat = 0
        var placed: [TabID: CGRect] = [:]
        for id in order {
            guard let item = items[id] else { continue }
            let width = item.preferredWidth
            let frame = CGRect(x: x, y: Self.verticalPadding, width: width, height: TabBar.height - 2 * Self.verticalPadding)
            placed[id] = frame
            if item.frame != frame {
                if animated, !arriving.contains(id), !item.frame.isEmpty {
                    NSAnimationContext.runAnimationGroup { context in
                        context.duration = Motion.appKitDuration(Motion.Spring.standard.duration)
                        context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1)
                        item.animator().frame = frame
                    }
                } else {
                    item.frame = frame
                }
            }
            x += width + Self.spacing
        }
        contentWidth = max(0, x - Self.spacing) + Self.trailingRoom
        frames.value = placed
        moveGlass(to: selected.flatMap { placed[$0] }, animated: animated)
    }

    /// The glass under the selected tab: slides to it on a spring, in the render server.
    private func moveGlass(to frame: CGRect?, animated: Bool) {
        guard let frame else {
            glass.isHidden = true
            return
        }
        let margin = TabGlassImage.margin
        let target = frame.insetBy(dx: -margin, dy: -margin)
        let wasHidden = glass.isHidden
        glass.isHidden = false
        let from = glass.presentation()?.frame ?? glass.frame
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        glass.frame = target
        CATransaction.commit()
        guard animated, !wasHidden, from != target, !from.isEmpty else { return }
        for (key, fromValue, toValue) in [
            ("position", NSValue(point: CGPoint(x: from.midX, y: from.midY)), NSValue(point: CGPoint(x: target.midX, y: target.midY))),
            ("bounds.size", NSValue(size: from.size), NSValue(size: target.size)),
        ] {
            let spring = CASpringAnimation(perceptualDuration: Motion.Spring.standard.duration, bounce: Motion.Spring.standard.bounce)
            spring.keyPath = key
            spring.fromValue = fromValue
            spring.toValue = toValue
            spring.duration = spring.settlingDuration
            glass.add(spring, forKey: key)
        }
    }

    // MARK: Actions

    func select(_ id: TabID) { workspace?.select(id) }
    func close(_ id: TabID) { workspace?.close(id) }

    func beginDrag(_ id: TabID, title: String) {
        DragSession.shared.begin(.tab(id.raw), snapshot: workspace?.snapshot(of: pane), title: title)
    }

    func menuItems(for id: TabID) -> [RightClickItem] {
        guard let workspace else { return [] }
        let resource = workspace.layout.tab(id)?.resource
        return environment.pageActions.menuItems(for: workspace.isNewTab(id) ? nil : resource)
            + [.separator, RightClickItem(title: "Close Tab") { [weak workspace] in workspace?.close(id) }]
    }

    func focusPane() { workspace?.focus(pane) }
}

/// One tab: plain text, or on the glass when selected (Craft's), with the accent dot in the focused pane; the cross
/// shows on the selected tab and under the pointer.
final class TabItemView: NSView, NSDraggingSource {
    let id: TabID
    private weak var strip: TabStripView?
    var theme: ThemeTokens = .standard { didSet { if theme != oldValue { refresh() } } }
    var isLeaving = false
    private var title = ""
    private var isSelected = false
    private var isFocusedPane = false
    private var isHovered = false
    private let label = CardTextView()
    private let dot = CALayer()
    private let cross = CALayer()
    private let hover = CALayer()
    private var tracking: NSTrackingArea?
    private var downEvent: NSEvent?
    private var downOnCross = false
    private let menuWatcher = RightClickMenu.MenuView()

    static let maxTitle: CGFloat = 180
    static let minWidth: CGFloat = 80

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    init(id: TabID, strip: TabStripView) {
        self.id = id
        self.strip = strip
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = false
        hover.opacity = 0
        hover.cornerCurve = .continuous
        layer?.addSublayer(hover)
        dot.contentsGravity = .center
        layer?.addSublayer(dot)
        cross.contentsGravity = .center
        layer?.addSublayer(cross)
        addSubview(label)
        label.maxLines = 1
        menuWatcher.items = { [weak self] in
            guard let self, let strip = self.strip else { return [] }
            return strip.menuItems(for: self.id)
        }
        addSubview(menuWatcher)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func show(title: String, resource: Resource, isSelected: Bool, isFocusedPane: Bool) {
        guard title != self.title || isSelected != self.isSelected || isFocusedPane != self.isFocusedPane else { return }
        self.title = title
        self.isSelected = isSelected
        self.isFocusedPane = isFocusedPane
        refresh()
    }

    private var font: NSFont { NSFont.ui(size: UIType.label.size, weight: isSelected ? .medium : .regular) }
    private var shownTitle: String { title.isEmpty ? String(localized: "Untitled") : title }
    private var showsDot: Bool { isSelected && isFocusedPane }

    /// Its width: the title up to `maxTitle`, the dot, the cross, the paddings; `minWidth` at least.
    var preferredWidth: CGFloat {
        let titleWidth = min(Self.maxTitle, ceil((shownTitle as NSString).size(withAttributes: [.font: font]).width))
        let width = 12 + (showsDot ? 7 + 6 : 0) + titleWidth + 6 + 16 + 6
        return max(Self.minWidth, width)
    }

    private func refresh() {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        label.attributed = NSAttributedString(string: shownTitle, attributes: [
            .font: font, .foregroundColor: NSColor(isSelected ? theme.text : theme.secondaryText), .paragraphStyle: style,
        ])
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // An image's points are its pixels over the layer's scale: at 1 a Retina image showed twice its size.
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        dot.contentsScale = scale
        cross.contentsScale = scale
        dot.contents = showsDot ? Self.dotImage(NSColor(theme.accent)) : nil
        cross.contents = tintedSymbol("xmark", size: 9, weight: .semibold, color: NSColor(theme.secondaryText))
        hover.backgroundColor = NSColor(theme.text).withAlphaComponent(0.05).cgColor
        CATransaction.commit()
        updateHover(animated: false)
        setAccessibilityLabel(shownTitle)
        setAccessibilitySelected(isSelected)
        toolTip = nil
        needsLayout = true
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        hover.frame = bounds
        hover.cornerRadius = min(Corners.cap ?? bounds.height / 2, bounds.height / 2)
        var x: CGFloat = 12
        if showsDot {
            dot.frame = CGRect(x: x - 2.5, y: bounds.midY - 6, width: 12, height: 12)
            x += 7 + 6
        }
        dot.isHidden = !showsDot
        cross.frame = crossRect
        CATransaction.commit()
        let titleWidth = max(0, crossRect.minX - 6 - x)
        let height = label.height(for: titleWidth)
        label.frame = CGRect(x: x, y: (bounds.height - height) / 2, width: titleWidth, height: height)
        menuWatcher.frame = bounds
    }

    private var crossRect: CGRect { CGRect(x: bounds.width - 6 - 16, y: (bounds.height - 16) / 2, width: 16, height: 16) }

    /// The focused tab's dot: a lit bead of the accent in a soft halo of it.
    private static var dots: [NSColor: NSImage] = [:]
    private static func dotImage(_ color: NSColor) -> NSImage {
        if let known = dots[color] { return known }
        let image = NSImage(size: NSSize(width: 12, height: 12), flipped: true) { _ in
            color.withAlphaComponent(0.12).setFill()
            NSBezierPath(ovalIn: NSRect(x: 0, y: 0, width: 12, height: 12)).fill()
            let bead = NSRect(x: 2.5, y: 2.5, width: 7, height: 7)
            let light = color.blended(withFraction: 0.35, of: .white) ?? color
            NSGradient(colors: [light, color])?.draw(in: NSBezierPath(ovalIn: bead), relativeCenterPosition: NSPoint(x: -0.3, y: -0.4))
            NSColor.white.withAlphaComponent(0.4).setStroke()
            let ring = NSBezierPath(ovalIn: bead.insetBy(dx: 0.25, dy: 0.25))
            ring.lineWidth = 0.5
            ring.stroke()
            return true
        }
        dots[color] = image
        return image
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        refresh()
    }

    // MARK: Motion

    /// A tab opening grows from its left edge, fading in (`TabBar.tabTransition`).
    func growIn() {
        guard let layer else { return }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        fade.duration = Motion.Spring.standard.duration
        layer.add(fade, forKey: "grow.fade")
        let grow = CASpringAnimation(perceptualDuration: Motion.Spring.standard.duration, bounce: Motion.Spring.standard.bounce)
        grow.keyPath = "sublayerTransform"
        // Scaled about the tab's leading edge, at its middle.
        var start = CATransform3DMakeTranslation(0, bounds.midY, 0)
        start = CATransform3DScale(start, 0.6, 0.6, 1)
        start = CATransform3DTranslate(start, 0, -bounds.midY, 0)
        grow.fromValue = start
        grow.toValue = CATransform3DIdentity
        grow.duration = grow.settlingDuration
        layer.add(grow, forKey: "grow.scale")
    }

    // MARK: Pointer

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        // Its own bounds: `.inVisibleRect` reaches past a view that does not clip (see `NativeCardView`).
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        updateHover(animated: true)
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        updateHover(animated: true)
    }

    private func updateHover(animated: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(!animated)
        CATransaction.setAnimationDuration(0.12)
        hover.opacity = isHovered && !isSelected ? 1 : 0
        cross.opacity = isSelected || isHovered ? 1 : 0
        CATransaction.commit()
    }

    override func mouseDown(with event: NSEvent) {
        downEvent = event
        downOnCross = (isSelected || isHovered) && crossRect.insetBy(dx: -2, dy: -2).contains(convert(event.locationInWindow, from: nil))
        strip?.focusPane()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let down = downEvent, !downOnCross, let strip else { return }
        let a = down.locationInWindow, b = event.locationInWindow
        guard hypot(b.x - a.x, b.y - a.y) > 4 else { return }
        downEvent = nil
        let item = NSPasteboardItem()
        item.setData(Data(DragPayload.tab(id.raw).string.utf8), forType: TabBarView.dragType)
        let dragging = NSDraggingItem(pasteboardWriter: item)
        let point = convert(a, from: nil)
        // What follows the pointer is the shell's ghost (`DragGhost`); AppKit's own image is a single clear pixel.
        dragging.setDraggingFrame(NSRect(x: point.x, y: point.y, width: 1, height: 1), contents: NSImage(size: NSSize(width: 1, height: 1)))
        strip.beginDrag(id, title: shownTitle)
        beginDraggingSession(with: [dragging], event: down, source: self)
    }

    override func mouseUp(with event: NSEvent) {
        defer { downEvent = nil }
        guard downEvent != nil, bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        if downOnCross { strip?.close(id) } else { strip?.select(id) }
    }

    override func accessibilityPerformPress() -> Bool {
        strip?.select(id)
        return true
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .withinApplication ? [.move, .generic] : []
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        DragSession.shared.end()
    }
}
