import AppKit
import PluginKitUI
import SwiftUI
import WorkspaceModel

/// A pane's tab bar in AppKit, on the canvas above its page, in the title bar row for the top panes (Craft's). The
/// tabs themselves are SwiftUI (`TabStrip`: the selected capsule sliding, hover, close, drag, right-click), in a
/// hosting view as wide as the tabs and no wider, inside a scroll view: a window resize only moves the scroll view's
/// edge, and nothing of SwiftUI is laid out again.
///
/// The first pane starts with Home and keeps clear of the traffic lights and the sidebar button while the left
/// sidebar is hidden, following its slide; the last one keeps clear of the right sidebar button. The empty area
/// drags the window. A tab or a note dropped on the bar goes in the gap under the pointer, marked by a thin accent
/// bar; on the empty area it goes at the end.
final class TabBarView: ShellView {
    let pane: PaneID
    let strip: PageHostingView<PaneRoot>
    let home: PageHostingView<PaneRoot>
    /// Each tab's frame in the strip, as SwiftUI last laid them out: only a drop reads them.
    let frames: Measured<[TabID: CGRect]>
    private weak var workspace: WorkspaceController?
    private let content = ShellView()
    private let scroll = TabScrollView()
    private let marker = CALayer()
    private let fade = CAGradientLayer()

    static let height: CGFloat = 40
    /// How far the tabs fade at an end of the bar with more tabs past it.
    private static let fadeLength: CGFloat = 24

    /// Whether the bar starts with Home (the first pane, when there is a home page).
    var showsHome = false { didSet { if showsHome != oldValue { home.isHidden = !showsHome; needsLayout = true } } }
    /// The room left for the right sidebar button (the last pane).
    var trailingInset: CGFloat = 0 { didSet { if trailingInset != oldValue { needsLayout = true } } }
    /// The room left for the traffic lights and the sidebar button (the first pane, its sidebar hidden).
    private(set) var leadingInset: CGFloat = 0
    var accent: NSColor = .controlAccentColor { didSet { marker.backgroundColor = accent.cgColor } }

    init(pane: PaneID, workspace: WorkspaceController, views: ViewRegistryStore, environment: PaneEnvironment) {
        self.pane = pane
        self.workspace = workspace
        let frames = Measured([TabID: CGRect]())
        self.frames = frames
        strip = PageHostingView(rootView: PaneRoot(
            part: .tabs(frames), pane: pane, workspace: workspace, views: views, environment: environment
        ))
        home = PageHostingView(rootView: PaneRoot(
            part: .home, pane: pane, workspace: workspace, views: views, environment: environment
        ))
        super.init(frame: .zero)
        for host in [strip, home] { host.safeAreaRegions = [] }
        home.sizingOptions = []
        // The strip says its own width, read when the tabs change (`stripWidth`); the bar sets its frame.
        strip.sizingOptions = [.intrinsicContentSize]
        home.isHidden = true
        // In the title bar row: AppKit would push the tabs down out of it, by the title bar's height.
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsetsZero
        scroll.drawsBackground = false
        scroll.hasHorizontalScroller = false
        scroll.hasVerticalScroller = false
        scroll.horizontalScrollElasticity = .automatic
        scroll.verticalScrollElasticity = .none
        scroll.contentView.drawsBackground = false
        scroll.contentView.postsBoundsChangedNotifications = true
        scroll.documentView = strip
        scroll.wantsLayer = true
        content.wantsLayer = true
        content.addSubview(home)
        content.addSubview(scroll)
        addSubview(content)
        wantsLayer = true
        marker.cornerRadius = 1
        marker.isHidden = true
        marker.backgroundColor = accent.cgColor
        layer?.addSublayer(marker)
        fade.startPoint = CGPoint(x: 0, y: 0.5)
        fade.endPoint = CGPoint(x: 1, y: 0.5)
        NotificationCenter.default.addObserver(
            self, selector: #selector(scrolled), name: NSView.boundsDidChangeNotification, object: scroll.contentView
        )
        registerForDraggedTypes([Self.dragType])
        strip.rootView.onTabsChange = { [weak self] in self?.tabsChanged() }
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }

    func update(environment: PaneEnvironment) {
        strip.rootView.environment = environment
        home.rootView.environment = environment
        accent = NSColor(environment.themeTokens.accent)
    }

    // MARK: Layout

    override func layout() {
        super.layout()
        if content.frame != bounds { content.frame = bounds }
        var x = leadingInset
        if showsHome {
            let homeFrame = NSRect(x: x, y: (Self.height - 30) / 2, width: 30, height: 30)
            if home.frame != homeFrame { home.frame = homeFrame }
            x += 30 + 4
        }
        let scrollFrame = NSRect(x: x, y: 0, width: max(0, bounds.width - x - trailingInset), height: Self.height)
        if scroll.frame != scrollFrame { scroll.frame = scrollFrame }
        // Measured only when the tabs change: asking SwiftUI for the strip's size on every step of a resize would lay
        // it out each time.
        if needsStripSize {
            needsStripSize = false
            sizeStrip()
        }
        // A wider bar shows more of the tabs from the right rather than leaving room after them.
        let clip = scroll.contentView
        let maxX = max(0, strip.frame.width - clip.bounds.width)
        if clip.bounds.minX > maxX { clip.setBoundsOrigin(NSPoint(x: maxX, y: 0)) }
        updateFade()
    }

    /// The strip as wide as its tabs. When it narrows (a tab closing) it waits for the closing tab's fade
    /// (`Motion.exit`), so the tab is not cut while it goes.
    private func sizeStrip() {
        let width = stripWidth
        let size = NSSize(width: width, height: Self.height)
        guard strip.frame.size != size else { return }
        if width < strip.frame.width {
            shrinkGeneration += 1
            let generation = shrinkGeneration
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                guard let self, self.shrinkGeneration == generation else { return }
                self.strip.setFrameSize(NSSize(width: self.stripWidth, height: Self.height))
                self.updateFade()
            }
        } else {
            shrinkGeneration += 1
            strip.setFrameSize(size)
        }
    }

    private var shrinkGeneration = 0

    /// The tabs' own width, as SwiftUI lays them out.
    private var stripWidth: CGFloat {
        ceil(strip.intrinsicContentSize.width)
    }
    private var needsStripSize = true

    /// The tabs changed (one opened, closed, renamed or selected): the strip takes its new width, and the selected tab
    /// scrolls into view (`Motion.Spring.standard`).
    private func tabsChanged() {
        needsStripSize = true
        needsLayout = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.layoutSubtreeIfNeeded()
            self.scrollToSelected()
        }
    }

    private func scrollToSelected() {
        guard let workspace, let selected = workspace.layout.panes.first(where: { $0.id == pane })?.selected,
              let frame = frames.value[selected] else { return }
        let clip = scroll.contentView
        let visible = clip.bounds
        guard visible.width > 0 else { return }
        var x = visible.minX
        if frame.minX < visible.minX { x = frame.minX }
        if frame.maxX > visible.maxX { x = frame.maxX - visible.width }
        x = min(max(0, x), max(0, strip.frame.width - visible.width))
        guard x != visible.minX else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Motion.appKitDuration(Motion.Spring.standard.duration)
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            clip.animator().setBoundsOrigin(NSPoint(x: x, y: 0))
        }
    }

    @objc private func scrolled() { updateFade() }

    /// The tabs fade at an end with more tabs past it, as `softScrollEdges` did; no mask at all when they all show.
    private func updateFade() {
        let visible = scroll.contentView.bounds
        let start = visible.minX > 1
        let end = visible.maxX < strip.frame.width - 1
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        guard start || end, scroll.bounds.width > 2 * Self.fadeLength else {
            scroll.layer?.mask = nil
            CATransaction.commit()
            return
        }
        let edge = Double(Self.fadeLength / scroll.bounds.width)
        fade.frame = scroll.bounds
        let clear = NSColor.clear.cgColor, black = NSColor.black.cgColor
        fade.colors = [start ? clear : black, black, black, end ? clear : black]
        fade.locations = [0, NSNumber(value: edge), NSNumber(value: 1 - edge), 1]
        scroll.layer?.mask = fade
        CATransaction.commit()
    }

    // MARK: Traffic lights

    /// Sets the room left for the traffic lights. With `from`, the tabs are first drawn where that room was and move
    /// to their place with the sidebar's slide: the room follows the column's edge, but stops at the lights, so the
    /// move is sampled from the slide's spring rather than played as one spring.
    func setLeadingInset(_ inset: CGFloat, slidingFrom edges: (from: CGFloat, to: CGFloat)?, reduceMotion: Bool) {
        guard inset != leadingInset || edges != nil else { return }
        leadingInset = inset
        needsLayout = true
        layoutSubtreeIfNeeded()
        guard let edges, edges.from != edges.to, !reduceMotion, let layer = content.layer else { return }
        let spring = SwiftUI.Spring(duration: Motion.Spring.slide.duration, bounce: Motion.Spring.slide.bounce)
        let duration = spring.settlingDuration
        let steps = 60
        var values: [CGFloat] = []
        for step in 0...steps {
            let progress = spring.value(target: 1.0, time: duration * Double(step) / Double(steps))
            let edge = edges.from + (edges.to - edges.from) * progress
            values.append((SidebarEdges.tabBarInset(leadingEdge: edge) - inset).rounded())
        }
        guard values.contains(where: { $0 != 0 }) else { return }
        let move = CAKeyframeAnimation(keyPath: "position.x")
        move.values = values
        move.isAdditive = true
        move.duration = duration
        move.calculationMode = .linear
        layer.add(move, forKey: "clearance")
    }

    // MARK: Window

    /// The empty area drags the window; a double click there does what a double click on a title bar does. A press
    /// on a tab or on Home that SwiftUI leaves to its superviews ends here too: it must not move the window, or a
    /// tab dragged out of the bar moves the window instead.
    override func mouseDown(with event: NSEvent) {
        guard let window, !isOverControl(event) else { return }
        if event.clickCount == 2 {
            let action = UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") ?? "Maximize"
            if action == "Minimize" { window.performMiniaturize(nil) } else if action != "None" { window.performZoom(nil) }
            return
        }
        window.performDrag(with: event)
    }

    /// The window server, not the app, moves the window on a press in the title bar row, and the views it is told
    /// to leave alone there never include the tab bars (AppKit does not look inside the workspace's views): the
    /// window is held still while the pointer is over a tab or Home (`TrafficLightsPositioner`), so a press there
    /// reaches the tab. The empty area and the gaps between the tabs still move it.
    private var pointerTracking: NSTrackingArea?
    private var isPointerOverTabs = false {
        didSet { if isPointerOverTabs != oldValue { workspace?.pointerOverTabsChanged(isPointerOverTabs, in: pane) } }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let pointerTracking { removeTrackingArea(pointerTracking) }
        let area = NSTrackingArea(
            rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
            owner: self, userInfo: nil
        )
        addTrackingArea(area)
        pointerTracking = area
    }

    override func mouseEntered(with event: NSEvent) { isPointerOverTabs = isOverControl(event) }
    override func mouseMoved(with event: NSEvent) { isPointerOverTabs = isOverControl(event) }
    override func mouseExited(with event: NSEvent) { isPointerOverTabs = false }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { isPointerOverTabs = false }
    }

    /// Whether `event` is over a tab or the Home button rather than the bar's empty area.
    func isOverControl(_ event: NSEvent) -> Bool {
        if !home.isHidden, home.bounds.contains(home.convert(event.locationInWindow, from: nil)) { return true }
        let point = strip.convert(event.locationInWindow, from: nil)
        return frames.value.values.contains { $0.contains(point) }
    }

    // MARK: Drops

    static let dragType = NSPasteboard.PasteboardType(DragPayload.type.identifier)

    private var insertion: Int? {
        didSet {
            guard insertion != oldValue else { return }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            if let insertion {
                marker.isHidden = false
                marker.frame = NSRect(x: max(0, markerX(insertion) - 1), y: 7, width: 2, height: 26)
            } else {
                marker.isHidden = true
            }
            CATransaction.commit()
        }
    }

    private var tabs: [WorkspaceModel.Tab] { workspace?.layout.panes.first { $0.id == pane }?.tabs ?? [] }

    /// The middle of each tab in order, in the strip.
    private var midpoints: [CGFloat] { tabs.compactMap { frames.value[$0.id]?.midX } }

    private func index(for sender: NSDraggingInfo) -> Int {
        let x = strip.convert(sender.draggingLocation, from: nil).x
        return tabInsertionIndex(at: x, midpoints: midpoints)
    }

    /// The gap before tab `index` (after the last one past the end), in this view.
    private func markerX(_ index: Int) -> CGFloat {
        let tabs = self.tabs
        let x: CGFloat
        if index < tabs.count, let frame = frames.value[tabs[index].id] {
            x = frame.minX
        } else {
            x = tabs.last.flatMap { frames.value[$0.id]?.maxX } ?? 0
        }
        return convert(NSPoint(x: x, y: 0), from: strip).x
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard sender.draggingPasteboard.availableType(from: [Self.dragType]) != nil else { return [] }
        insertion = index(for: sender)
        return .move
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard sender.draggingPasteboard.availableType(from: [Self.dragType]) != nil else { return [] }
        let new = index(for: sender)
        if new != insertion { Haptics.alignment() }
        insertion = new
        return .move
    }

    override func draggingExited(_ sender: NSDraggingInfo?) { insertion = nil }

    override func draggingEnded(_ sender: NSDraggingInfo) { insertion = nil }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let index = index(for: sender)
        insertion = nil
        guard let payload = Self.payload(from: sender.draggingPasteboard) else { return false }
        DragSession.shared.end()
        workspace?.perform(payload, inTabBarOf: pane, at: index)
        return true
    }

    /// The tab or note a drag carries (`DragPayload`), nil for anything else.
    static func payload(from pasteboard: NSPasteboard) -> DragPayload? {
        guard let data = pasteboard.data(forType: dragType), let string = String(data: data, encoding: .utf8) else {
            return nil
        }
        return DragPayload(string: string)
    }
}

/// The tabs' scroll view, which never moves the window (`ShellView`): neither does its clip view.
private final class TabScrollView: NSScrollView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        contentView = TabClipView()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var mouseDownCanMoveWindow: Bool { false }
}

private final class TabClipView: NSClipView {
    override var mouseDownCanMoveWindow: Bool { false }
}
