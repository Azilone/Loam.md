import AppKit
import PluginKitUI
import SwiftUI
import WorkspaceModel

/// A pane in AppKit: its tab bar on the canvas, and under it its page (`PageChromeView`), each with its SwiftUI in a
/// hosting view of its own. A window resize sets the pane's frames and lays out what is in them; nothing of the other
/// panes, the sidebars or the window's chrome is evaluated again, and the page's rounded edge and shadow are layers.
///
/// The pane reads its tabs from the workspace itself (`PaneRoot`), so a change made in an animation (a tab opening, a
/// page arriving) animates inside it as it did in the window's graph. The window's values for its pages are handed
/// over (`PaneEnvironment`): a hosting view starts from SwiftUI's defaults.
///
/// It is also the page's drop target: as soon as a drag starts anywhere in the window the page steps back and its
/// drop zones come over it (`PaneDropZones`); a drop on a zone opens the tab or note beside the pane, in the middle
/// as a tab of it.
final class PaneHostView: ShellView {
    let pane: PaneID
    /// The tab bar, in the title bar row for the top panes.
    let tabs: TabBarView
    /// The page's toolbar and the selected tab's pages, inside `page`.
    let pageContent: PageStackView
    let page: PageChromeView
    private weak var workspace: WorkspaceController?
    /// Set while the pane fades out after it closed: it takes no clicks and no longer says where its page is.
    var isLeaving = false
    /// The last pane's page follows a sidebar's slide with its trailing edge (`PageChromeView.followSlide`), and its
    /// tab bar keeps clear of the right sidebar button. Set by the split (`SplitTreeView`).
    var isLast = false { didSet { if isLast != oldValue { updateTabBar(from: nil) } } }
    /// The first pane's tab bar starts with Home and keeps clear of the traffic lights.
    var isFirst = false { didSet { if isFirst != oldValue { updateTabBar(from: nil) } } }

    init(pane: PaneID, workspace: WorkspaceController, views: ViewRegistryStore, environment: PaneEnvironment) {
        self.pane = pane
        self.workspace = workspace
        given = environment
        tabs = TabBarView(pane: pane, workspace: workspace, views: views, environment: given)
        pageContent = PageStackView(pane: pane, workspace: workspace, views: views, environment: given)
        page = PageChromeView(content: pageContent)
        super.init(frame: .zero)
        page.theme = given.themeTokens
        addSubview(page)
        // Over the page: the selected tab's capsule casts its shadow down onto it.
        addSubview(tabs)
        // A tab or a note dropped on the page opens in it, or beside it on an edge; the tab bar takes its own.
        registerForDraggedTypes([TabBarView.dragType])
        followDrags()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// What the pane was last given of the window's environment.
    private var given: PaneEnvironment

    /// Hands the window's environment to the pane: only when it changed, since a new root view diffs the pane. The
    /// last page's edge follows a sidebar's slide from here.
    func update(environment new: PaneEnvironment) {
        guard new != given else { return }
        let old = given
        given = new
        tabs.update(environment: new)
        pageContent.environment = new
        page.theme = new.themeTokens
        updateTabBar(from: old)
        if isLast, let before = old.sidebarEdges, let after = new.sidebarEdges, before != after {
            // Where the edge starts from: past its place by what the workspace moved left (the left sidebar opening)
            // and by the room the inspector takes; short of it by the room the inspector gives back.
            let bleed = max(0, after.leadingEdge - before.leadingEdge) + after.trailingRoom - before.trailingRoom
            page.followSlide(bleed: bleed, reduceMotion: after.animation == nil)
        }
    }

    /// The tab bar's room at its ends: Home and the traffic lights' room on the first pane, following a left
    /// sidebar's slide from `old`'s edge; the right sidebar button's room on the last.
    private func updateTabBar(from old: PaneEnvironment?) {
        tabs.showsHome = isFirst && given.pageActions.home != nil
        tabs.trailingInset = isLast ? given.tabBarTrailingInset : 0
        let edge = isFirst ? given.sidebarEdges?.leadingEdge : nil
        let inset = edge.map { SidebarEdges.tabBarInset(leadingEdge: $0) } ?? 0
        var slide: (from: CGFloat, to: CGFloat)?
        if let edge, let before = old?.sidebarEdges?.leadingEdge, before != edge { slide = (before, edge) }
        tabs.setLeadingInset(inset, slidingFrom: slide, reduceMotion: given.sidebarEdges?.animation == nil)
    }

    override func layout() {
        super.layout()
        let tabsFrame = NSRect(x: 0, y: 0, width: bounds.width, height: TabBar.height)
        let pageFrame = NSRect(x: 0, y: TabBar.height, width: bounds.width, height: max(0, bounds.height - TabBar.height))
        if tabs.frame != tabsFrame { tabs.frame = tabsFrame }
        if page.frame != pageFrame { page.frame = pageFrame }
        if let zones, zones.frame != pageFrame { zones.frame = pageFrame }
        publishPageFrame()
    }

    override func setFrameOrigin(_ newOrigin: NSPoint) {
        super.setFrameOrigin(newOrigin)
        publishPageFrame()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        isLeaving ? nil : super.hitTest(point)
    }

    /// The page's frame in the window, top left origin (SwiftUI's global space, as `OpenOrigin` measures a card):
    /// where a page opened from a card grows from, and what a dragged tab pictures. Measured here: inside the pane's
    /// own hosting view, SwiftUI's global space is the pane's.
    private func publishPageFrame() {
        guard !isLeaving, let workspace, let content = window?.contentView else { return }
        let page = NSRect(x: 0, y: TabBar.height, width: bounds.width, height: max(0, bounds.height - TabBar.height))
        let rect = convert(page, to: content)
        let top = content.isFlipped ? rect.minY : content.bounds.height - rect.maxY
        workspace.paneFrames[pane] = CGRect(x: rect.minX, y: top, width: rect.width, height: rect.height)
    }

    // MARK: Drags

    /// The zones over the page while a drag is under way, and what they show.
    private var zones: PageHostingView<PaneDropZones>?
    private let dropState = PaneDropState()
    private var zonesGeneration = 0

    /// A drag starting anywhere in the window (`DragSession`) steps the page back and brings its drop zones; one
    /// ending, with or without a drop, takes them away.
    private func followDrags() {
        withObservationTracking {
            _ = DragSession.shared.isActive
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                guard let self else { return }
                self.dragChanged(DragSession.shared.isActive)
                self.followDrags()
            }
        }
    }

    private func dragChanged(_ active: Bool) {
        page.setReceded(active, reduceMotion: Motion.reduceMotion)
        zonesGeneration += 1
        if active {
            if zones == nil {
                let host = PageHostingView(rootView: PaneDropZones(state: dropState))
                host.safeAreaRegions = []
                host.sizingOptions = []
                host.frame = page.frame
                addSubview(host, positioned: .above, relativeTo: page)
                zones = host
            }
            dropState.isDragging = true
        } else {
            // Out with the zones' own motion, then gone.
            withAnimation(SplitZones.settle) {
                dropState.isDragging = false
                dropState.edge = nil
                dropState.pointer = nil
            }
            let generation = zonesGeneration
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                guard let self, self.zonesGeneration == generation else { return }
                self.zones?.removeFromSuperview()
                self.zones = nil
            }
        }
    }

    /// The drag's point in the page, top left origin.
    private func pagePoint(_ sender: NSDraggingInfo) -> CGPoint {
        let point = convert(sender.draggingLocation, from: nil)
        return CGPoint(x: point.x - page.frame.minX, y: point.y - page.frame.minY)
    }

    private func accepts(_ sender: NSDraggingInfo) -> Bool {
        sender.draggingPasteboard.availableType(from: [TabBarView.dragType]) != nil
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard accepts(sender) else { return [] }
        let point = pagePoint(sender)
        withAnimation(SplitZones.settle) {
            dropState.edge = SplitZoneLayout.edge(at: point, in: page.frame.size, current: nil)
            dropState.pointer = point
        }
        DragGhost.shared.isOverSplitZone = dropState.edge.map { $0 != .center } ?? false
        return .move
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard accepts(sender) else { return [] }
        let point = pagePoint(sender)
        let new = SplitZoneLayout.edge(at: point, in: page.frame.size, current: dropState.edge)
        if new != dropState.edge { Haptics.alignment() }
        // The zone follows the pointer through a spring, so each position is its own small animation.
        withAnimation(SplitZones.settle) {
            if new != dropState.edge { dropState.edge = new }
            dropState.pointer = point
        }
        // Over a split zone the picture under the pointer grows: what is about to take half the window.
        DragGhost.shared.isOverSplitZone = new != .center
        return .move
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        DragGhost.shared.isOverSplitZone = false
        withAnimation(SplitZones.settle) {
            dropState.edge = nil
            dropState.pointer = nil
        }
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let target = SplitZoneLayout.edge(at: pagePoint(sender), in: page.frame.size, current: dropState.edge)
        dropState.edge = nil
        dropState.pointer = nil
        guard let payload = TabBarView.payload(from: sender.draggingPasteboard) else { return false }
        DragSession.shared.end()
        // The new pane makes room for itself: the controller animates a change of panes (`WorkspaceController.update`).
        workspace?.perform(payload, on: pane, edge: target)
        return true
    }

    override var isFlipped: Bool { true }
}

/// The hosting view of a page. Kept apart from the column's (`ColumnHostingView`): a page takes the keyboard as a
/// whole (a board's shortcuts, a canvas's arrows), so it answers first-responder questions as SwiftUI does.
final class PageHostingView<Content: View>: NSHostingView<Content> {
    override var mouseDownCanMoveWindow: Bool { false }
}

/// A view of the shell's that never moves the window. AppKit's default does for a view that is not opaque, and in
/// the title bar row the window server then takes a press there to move the window, before the app sees it: a
/// tab dragged in the top tab bar moved the window instead. Only the tab bar's empty area moves it, on purpose
/// (`TabBarView.mouseDown`).
class ShellView: NSView {
    override var mouseDownCanMoveWindow: Bool { false }
}

/// What the window gives its pages through the environment, handed to each page's hosting view explicitly: a hosting
/// view starts from SwiftUI's defaults. Handing the whole environment over (`\.self`) also froze values SwiftUI keeps
/// there for itself, such as whether an accessibility client is connected, and the panes showed VoiceOver nothing.
/// What the system gives every hosting view (the appearance, Reduce Motion, the locale) comes to the pane's on its own.
/// `PaneHostTests` checks that a plugin's page reads each value.
struct PaneEnvironment: Equatable {
    var themeTokens: ThemeTokens
    var windowCanvas: Color?
    var pageActions: PageActions
    var sidebarSliding: Bool
    var sidebarEdges: SidebarEdges?
    var tabBarTrailingInset: CGFloat

    /// What a pane gets outside a window's shell (a test's tree): the standard theme, no sidebars.
    static let standard = PaneEnvironment(
        themeTokens: .standard, windowCanvas: nil, pageActions: PageActions(), sidebarSliding: false,
        sidebarEdges: nil, tabBarTrailingInset: 0
    )

    /// Compared before a new environment is handed over, so a pane is updated only when one of them changed; the page
    /// actions' closures by what they offer.
    static func == (lhs: PaneEnvironment, rhs: PaneEnvironment) -> Bool {
        lhs.themeTokens == rhs.themeTokens
            && lhs.windowCanvas == rhs.windowCanvas
            && lhs.sidebarSliding == rhs.sidebarSliding
            && lhs.sidebarEdges == rhs.sidebarEdges
            && lhs.sidebarEdges?.animation == rhs.sidebarEdges?.animation
            && lhs.tabBarTrailingInset == rhs.tabBarTrailingInset
            && lhs.pageActions.home == rhs.pageActions.home
            && (lhs.pageActions.newNote == nil) == (rhs.pageActions.newNote == nil)
            && lhs.pageActions.newItems.map(\.id) == rhs.pageActions.newItems.map(\.id)
    }
}

extension View {
    /// The window's values for its pages (`PaneEnvironment`), as the window's own graph sets them.
    func paneEnvironment(_ values: PaneEnvironment) -> some View {
        environment(\.themeTokens, values.themeTokens)
            .environment(\.windowCanvas, values.windowCanvas)
            .environment(\.pageActions, values.pageActions)
            .environment(\.sidebarSliding, values.sidebarSliding)
            .environment(\.sidebarEdges, values.sidebarEdges)
            .environment(\.tabBarTrailingInset, values.tabBarTrailingInset)
            .tint(values.themeTokens.accent)
            // As the window: a text that changes while something moves changes at once (`ShellWindow`).
            .contentTransition(.identity)
    }
}
