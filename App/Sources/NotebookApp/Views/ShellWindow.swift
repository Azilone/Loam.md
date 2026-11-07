import AppKit
import PluginKit
import PluginKitUI
import SwiftUI
import WorkspaceModel

/// The window of an open vault: the leading slot as the sidebar, the workspace in the middle, the trailing slot as
/// the inspector (`InspectorColumn`) and the status bar slot along the bottom. Slots without panels take no room. The side columns sit
/// on the window's translucent material (`WindowCanvas`); the panes are opaque pages detached from the edges.
///
/// The window is AppKit (`ShellRootView`): SwiftUI only gives it the theme (`themed(by:)`), so the body here runs on
/// a change of theme alone. A sidebar shown, a note opened or a tab closed changes the frames and the layers of the
/// views that show it, and never evaluates a whole-window SwiftUI body. What plugins give the window (the sidebars'
/// panels, the inspector, the overlays) stays SwiftUI, each in a hosting view of its own.
struct ShellWindow: View {
    let session: ShellSession

    var body: some View {
        ShellRoot(session: session)
            // Under the title bar too: the tabs go up into its row.
            .ignoresSafeArea(.container, edges: .top)
            .themed(by: session.themes)
            // A text that changes while something moves (a tab's title as it opens, a count) changes at once instead
            // of morphing: SwiftUI draws a morphing text on the CPU on every frame. Views that want a numeric roll
            // say so themselves.
            .contentTransition(.identity)
            .containerBackground(.clear, for: .window)
    }
}

/// What the window's SwiftUI gives its AppKit: the theme's tokens and the canvas colour.
struct ShellLook: Equatable {
    var theme: ThemeTokens
    var canvas: Color?

    init(theme: ThemeTokens, canvas: Color?) {
        self.theme = theme
        self.canvas = canvas
    }

    init(_ environment: EnvironmentValues) {
        self.init(theme: environment.themeTokens, canvas: environment.windowCanvas)
    }

    /// The theme on the canvas around the pages, made light on a dark canvas (`ThemeTokens.hasDarkCanvas`).
    var canvasTheme: ThemeTokens { theme.hasDarkCanvas ? theme.onCanvas : theme }
}

private struct ShellRoot: NSViewRepresentable {
    let session: ShellSession

    func makeNSView(context: Context) -> ShellRootView {
        let view = ShellRootView(session: session, look: ShellLook(context.environment))
        view.openSettings = context.environment.openSettings
        return view
    }

    func updateNSView(_ view: ShellRootView, context: Context) {
        view.openSettings = context.environment.openSettings
        view.look = ShellLook(context.environment)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: ShellRootView, context: Context) -> CGSize? {
        proposal.replacingUnspecifiedDimensions(by: .zero)
    }
}

/// The window in AppKit: the canvas, the side columns, the workspace (`SplitTreeView`), the title bar row's buttons,
/// the plugins' overlays, the palette and the toasts, laid out by hand.
///
/// Each part follows what it shows itself (`Follow`): the sidebars' state, the first pane's history, the window's
/// title. A sidebar shows and hides as Craft's does: its column slides in from the window's edge (`SlidingColumnView`,
/// on the render server). For the left sidebar, as in Craft, the workspace is laid out once at its new width and moved
/// to follow the column's edge (`SplitTreeView.follow`): nothing is laid out again on the frames of the slide, which
/// on "All Notes" measured every card on each frame. The inspector's slide does the same from the other side: only
/// the last page's trailing edge follows the column (`PageChromeView.followSlide`).
///
/// The columns are laid out by hand rather than with a split view: `NavigationSplitView` fed the content's minimum
/// size back into the window's constraints, which looped (and crashed) while resizing a grid.
final class ShellRootView: NSView {
    /// Where the tab bars start under the window's top edge: centred in the 52 point title bar.
    static let tabBarTop: CGFloat = 6
    static let leadingRange: ClosedRange<Double> = 180...420
    static let trailingRange: ClosedRange<Double> = 200...460
    /// The right sidebar button's width and the gap to the window's edge, which the last tab bar keeps clear of.
    static let trailingButtonInset: CGFloat = 44
    /// The file explorer's command, run by the page toolbar's "+".
    static let newNoteCommand = "explorer.new-note"

    /// The columns' widths, read once and written back when dragged.
    private static let leadingWidthKey = "shell.leadingWidth"
    private static let trailingWidthKey = "shell.trailingWidth"

    private static func storedWidth(_ key: String) -> Double {
        UserDefaults.standard.object(forKey: key) as? Double ?? 280
    }

    /// The window's state that moves its parts: which sidebars show, and whether one is sliding.
    struct Chrome: Equatable {
        /// The left sidebar has something to show: panels, navigation links or sections.
        var hasLeading = false
        var showsLeading = false
        var showsTrailing = false
        var isSliding = false
    }

    private let session: ShellSession
    private var workspace: WorkspaceController { session.workspace }
    var look: ShellLook { didSet { if look != oldValue { lookChanged() } } }
    var openSettings: OpenSettingsAction?

    private let canvas: PassiveHostingView<CanvasRoot>
    private let split: SplitTreeView
    private let leading: SlidingColumnView<LeadingColumnRoot>
    private let trailing: SlidingColumnView<TrailingColumnRoot>
    private let leadingHandle: ColumnResizeHandle
    private let trailingHandle: ColumnResizeHandle
    private let leftSidebarButton = ChromeButton(look: .window, title: "Toggle Left Sidebar", symbol: "sidebar.leading")
    private let backButton = ChromeButton(look: .window, title: "Back", symbol: "chevron.left")
    private let forwardButton = ChromeButton(look: .window, title: "Forward", symbol: "chevron.right")
    private let rightSidebarButton = ChromeButton(look: .window, title: "Toggle Right Sidebar", symbol: "sidebar.trailing")
    private let overlays: OverlayHostingView<WindowOverlaysRoot>
    private let badge = BuildBadgeView()
    private let palette: PaletteLayerView
    private let toasts: OverlayHostingView<ToastRoot>
    private let lights = TrafficLightsView()
    private let keys = KeyMonitor()
    private let focus = PickerFocus()
    private var follows: [AnyObject] = []

    private var chrome: Chrome
    private var pageActions: PageActions
    private var leadingWidth: Double
    private var trailingWidth: Double

    init(session: ShellSession, look: ShellLook) {
        self.session = session
        self.look = look
        let chrome = Self.chrome(of: session)
        self.chrome = chrome
        let actions = Self.pageActions(of: session)
        pageActions = actions
        leadingWidth = Self.storedWidth(Self.leadingWidthKey)
        trailingWidth = Self.storedWidth(Self.trailingWidthKey)
        canvas = PassiveHostingView(rootView: CanvasRoot(look: look))
        split = SplitTreeView(workspace: session.workspace, views: session.views, environment: Self.paneEnvironment(
            look: look, actions: actions, chrome: chrome, leadingEdge: 0, trailingRoom: 0
        ))
        leading = SlidingColumnView(
            rootView: LeadingColumnRoot(session: session, look: look, actions: actions, openSettings: {}),
            edge: .leading, isShown: chrome.showsLeading
        )
        trailing = SlidingColumnView(rootView: TrailingColumnRoot(session: session, look: look), edge: .trailing, isShown: chrome.showsTrailing)
        leadingHandle = ColumnResizeHandle(range: Self.leadingRange, growsRightward: true)
        trailingHandle = ColumnResizeHandle(range: Self.trailingRange, growsRightward: false)
        overlays = OverlayHostingView(rootView: WindowOverlaysRoot(overlays: session.windowOverlays, look: look))
        palette = PaletteLayerView(controller: session.quickPick, theme: look.theme)
        toasts = OverlayHostingView(rootView: ToastRoot(runner: session.commandRunner, look: look))
        super.init(frame: .zero)
        wantsLayer = true
        canvas.safeAreaRegions = []
        canvas.sizingOptions = []
        overlays.safeAreaRegions = []
        overlays.sizingOptions = []
        toasts.safeAreaRegions = []
        toasts.sizingOptions = []
        addSubview(canvas)
        // The columns behind the workspace: a column that slides out passes under the pages' edge.
        addSubview(leading)
        addSubview(trailing)
        addSubview(split)
        addSubview(leadingHandle)
        addSubview(trailingHandle)
        // No window toolbar: it would take the clicks of the tabs under it. The sidebar buttons are ours. Right of
        // the traffic lights, where they stay whether the sidebar shows or not: the sidebar's button, then Back and
        // Forward of the first pane (the panes beside it have theirs in their page toolbar). The right sidebar
        // button closes the same row, at the window's right end, as in Craft.
        for button in [leftSidebarButton, backButton, forwardButton, rightSidebarButton] { addSubview(button) }
        // Plugins' overlays (the Assistant's bubble), inside the window, under the palette and the toasts.
        addSubview(overlays)
        // A development build's worktree or branch, so side-by-side builds are told apart (nothing in a release).
        addSubview(badge)
        addSubview(palette)
        addSubview(toasts)
        addSubview(lights)
        wire()
        lookChanged()
        split.apply(session.workspace.layout.root, animated: false)
        follow()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }

    private func wire() {
        let workspace = workspace
        leftSidebarButton.onPress = { workspace.toggleSidebar(.leading) }
        rightSidebarButton.onPress = { workspace.toggleSidebar(.trailing) }
        backButton.onPress = {
            if let tab = workspace.layout.panes.first?.selected { workspace.goBack(in: tab) }
        }
        forwardButton.onPress = {
            if let tab = workspace.layout.panes.first?.selected { workspace.goForward(in: tab) }
        }
        leadingHandle.width = { [weak self] in self?.leadingWidth ?? 0 }
        leadingHandle.resize = { [weak self] width in
            self?.leadingWidth = width
            self?.widthsChanged()
        }
        leadingHandle.ended = { [weak self] in
            guard let self else { return }
            UserDefaults.standard.set(self.leadingWidth, forKey: Self.leadingWidthKey)
        }
        trailingHandle.width = { [weak self] in self?.trailingWidth ?? 0 }
        trailingHandle.resize = { [weak self] width in
            self?.trailingWidth = width
            self?.widthsChanged()
        }
        trailingHandle.ended = { [weak self] in
            guard let self else { return }
            UserDefaults.standard.set(self.trailingWidth, forKey: Self.trailingWidthKey)
        }
        lights.centerY = Self.tabBarTop + TabBar.height / 2
        workspace.onPagesMoving = { [weak lights] moving in lights?.pagesMoving = moving }
        workspace.onPointerOverTabs = { [weak lights] over in lights?.pointerOverTabs = over }
    }

    /// What each part follows in the session.
    private func follow() {
        let session = session
        let workspace = workspace
        follows = [
            Follow { Self.chrome(of: session) } apply: { [weak self] chrome in self?.chromeChanged(chrome) },
            Follow { () -> [Bool] in
                guard let tab = workspace.layout.panes.first?.selected else { return [false, false] }
                return [workspace.canGoBack(in: tab), workspace.canGoForward(in: tab)]
            } apply: { [weak self] history in
                // Forward is always there, dimmed until Back has been used, so nothing shifts.
                self?.backButton.isEnabled = history[0]
                self?.forwardButton.isEnabled = history[1]
            },
            Follow { ActionsKey(session) } apply: { [weak self] _ in self?.actionsChanged() },
            // The window holds still while a sidebar slides, a divider is dragged or a note or tab is dragged over
            // the pages (which step back under the title bar).
            Follow { workspace.isSidebarSliding || workspace.isDividerDragging || DragSession.shared.isActive } apply: {
                [weak self] holds in self?.lights.sidebarSliding = holds
            },
            Follow { workspace.activeResource?.name ?? session.name } apply: { [weak self] title in
                self?.window?.title = title
            },
            Follow { session.quickPick.isPresented } apply: { [weak self] presented in
                guard let self, let window = self.window else { return }
                if presented { self.focus.shown(in: window) } else { self.focus.hidden(in: window) }
            },
        ]
    }

    // MARK: Changes

    private static func chrome(of session: ShellSession) -> Chrome {
        let workspace = session.workspace
        let leading = session.panelVisibility.shown(session.panels.panels(in: .leading))
        let hasLeading = !leading.isEmpty || !session.panels.links.isEmpty || !session.panels.sections.isEmpty
        // The right column stays where the user put it, whatever the page: a page with nothing to show in it (the
        // home page, All Notes) gets its empty state. Sliding it out and in with the page changed the page's width
        // on every navigation from the grid to a note and back, and both laid themselves out again.
        return Chrome(
            hasLeading: hasLeading,
            showsLeading: workspace.chrome.showsLeading && hasLeading,
            showsTrailing: workspace.chrome.showsTrailing,
            isSliding: workspace.isSidebarSliding
        )
    }

    /// The window's state changed: the columns slide (or jump, the change not being the user's), the workspace is
    /// laid out once at its new width and follows their edges.
    private func chromeChanged(_ new: Chrome) {
        let old = chrome
        chrome = new
        let reduceMotion = Motion.reduceMotion
        if new.showsLeading != old.showsLeading { leading.setShown(new.showsLeading, reduceMotion: reduceMotion, animated: true) }
        // False when the change is not the user's (the page they went to has nothing for this column): it then
        // jumps, in the same frame as the pages, instead of sliding out of step with them.
        if new.showsTrailing != old.showsTrailing {
            trailing.setShown(new.showsTrailing, reduceMotion: reduceMotion, animated: new.isSliding)
        }
        if new.hasLeading != old.hasLeading || new.showsLeading != old.showsLeading || new.showsTrailing != old.showsTrailing {
            place()
        }
        updatePanes()
    }

    private func widthsChanged() {
        place()
        updatePanes()
    }

    /// The page actions offered: a command or a home page that came or went.
    private func actionsChanged() {
        pageActions = Self.pageActions(of: session)
        leading.host.rootView = leadingRoot()
        updatePanes()
    }

    private func lookChanged() {
        canvas.rootView = CanvasRoot(look: look)
        leading.host.rootView = leadingRoot()
        trailing.host.rootView = TrailingColumnRoot(session: session, look: look)
        overlays.rootView = WindowOverlaysRoot(overlays: session.windowOverlays, look: look)
        toasts.rootView = ToastRoot(runner: session.commandRunner, look: look)
        palette.theme = look.theme
        let onCanvas = look.canvasTheme
        let appearance = look.theme.hasDarkCanvas ? NSAppearance(named: .darkAqua) : nil
        for button in [leftSidebarButton, backButton, forwardButton, rightSidebarButton] {
            button.theme = onCanvas
            button.appearance = appearance
        }
        updatePanes()
    }

    private func leadingRoot() -> LeadingColumnRoot {
        LeadingColumnRoot(session: session, look: look, actions: pageActions) { [weak self] in self?.openSettings?() }
    }

    /// Hands the window's values to the panes, and plays a sidebar's slide on the workspace.
    private func updatePanes() {
        let environment = Self.paneEnvironment(
            look: look, actions: pageActions, chrome: chrome, leadingEdge: leadingEdge, trailingRoom: trailingRoom
        )
        split.follow(edges: environment.sidebarEdges)
        split.update(environment: environment)
    }

    private static func paneEnvironment(
        look: ShellLook, actions: PageActions, chrome: Chrome, leadingEdge: CGFloat, trailingRoom: CGFloat
    ) -> PaneEnvironment {
        let reduceMotion = Motion.reduceMotion
        return PaneEnvironment(
            themeTokens: look.theme,
            windowCanvas: look.canvas,
            pageActions: actions,
            sidebarSliding: chrome.isSliding && !reduceMotion,
            // Only the move to the new width is animated, from where the columns end up, written once per slide:
            // the tab bar and the last page follow it with their own animation, so nothing is laid out on the
            // frames of a slide.
            sidebarEdges: SidebarEdges(
                leadingEdge: leadingEdge, trailingRoom: trailingRoom,
                animation: SidebarMotion.animation(reduceMotion: reduceMotion || !chrome.isSliding)
            ),
            tabBarTrailingInset: trailingButtonInset
        )
    }

    private static func pageActions(of session: ShellSession) -> PageActions {
        var actions = PageActions()
        if session.runtime.kernel.commands.command(id: newNoteCommand) != nil {
            actions.newNote = { session.commandRunner.run(newNoteCommand) }
        }
        actions.newItems = session.panels.newItems
        actions.home = session.homeResource
        actions.resourceActions = { [resourceActions = session.resourceActions] in resourceActions.actions(for: $0) }
        return actions
    }

    /// What the page actions are made of, to know when to make them again.
    private struct ActionsKey: Equatable {
        var home: Resource?
        var newItems: [String]

        @MainActor init(_ session: ShellSession) {
            home = session.homeResource
            newItems = session.panels.newItems.map(\.id)
        }
    }

    // MARK: Layout

    /// Where the workspace starts from the window's left edge: past the sidebar while it shows, a gap from the edge
    /// once it is hidden.
    private var leadingEdge: CGFloat {
        chrome.showsLeading ? leadingWidth + ColumnResizeHandle.width : Glass.gap
    }

    /// The room right of the last page: the inspector while it shows, a gap from the window's edge once it is hidden.
    private var trailingRoom: CGFloat {
        chrome.showsTrailing ? trailingWidth + ColumnResizeHandle.width : Glass.gap
    }

    /// The window's title bar, which the palette and the overlays keep clear of.
    private var titleBarHeight: CGFloat {
        guard let window else { return 0 }
        let content = convert(window.contentLayoutRect, from: nil)
        return max(0, content.minY)
    }

    override func layout() {
        super.layout()
        place()
    }

    private func place() {
        let size = bounds.size
        set(canvas, NSRect(origin: .zero, size: size))
        // Each column fills its room whatever its width, never a width of its own; hidden, it has slid out of the
        // window (`SlidingColumnView`).
        let leadingColumn = leadingWidth + ColumnResizeHandle.width
        let trailingColumn = trailingWidth + ColumnResizeHandle.width
        leading.isHidden = !chrome.hasLeading
        set(leading, NSRect(x: 0, y: 0, width: leadingColumn, height: size.height))
        set(trailing, NSRect(x: size.width - trailingColumn, y: 0, width: trailingColumn, height: size.height))
        leadingHandle.isHidden = !chrome.showsLeading
        set(leadingHandle, NSRect(x: leadingWidth, y: 0, width: ColumnResizeHandle.width, height: size.height))
        trailingHandle.isHidden = !chrome.showsTrailing
        set(trailingHandle, NSRect(x: size.width - trailingColumn, y: 0, width: ColumnResizeHandle.width, height: size.height))
        // The top panes' tabs go up into the title bar row, clear of the traffic lights and the sidebar button when
        // the sidebar is hidden.
        let left = leadingEdge, right = size.width - trailingRoom
        set(split, NSRect(x: left, y: Self.tabBarTop, width: max(0, right - left),
                          height: max(0, size.height - Self.tabBarTop - Glass.gap)))
        let side = TitleBar.buttonSide
        let y = Self.tabBarTop + 5
        var x = TitleBar.navigationX
        leftSidebarButton.isHidden = !chrome.hasLeading
        if chrome.hasLeading {
            set(leftSidebarButton, NSRect(x: x, y: y, width: side, height: side))
            x += side + TitleBar.buttonSpacing
        }
        set(backButton, NSRect(x: x, y: y, width: side, height: side))
        set(forwardButton, NSRect(x: x + side + TitleBar.buttonSpacing, y: y, width: side, height: side))
        set(rightSidebarButton, NSRect(x: size.width - 14 - side, y: y, width: side, height: side))
        let top = titleBarHeight
        let content = NSRect(x: 0, y: top, width: size.width, height: max(0, size.height - top))
        set(overlays, content)
        set(palette, content)
        set(toasts, content)
        // Over the pages' bottom left, clear of the sidebar's footer.
        let badgeSize = badge.intrinsicContentSize
        set(badge, NSRect(x: leadingEdge + 12, y: size.height - Glass.gap - 8 - badgeSize.height,
                          width: badgeSize.width, height: badgeSize.height))
        set(lights, .zero)
    }

    private func set(_ view: NSView, _ frame: NSRect) {
        if view.frame != frame { view.frame = frame }
    }

    // MARK: Window

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else {
            keys.stop()
            return
        }
        window.title = workspace.activeResource?.name ?? session.name
        keys.window = window
        let session = session
        keys.start { shortcut in session.handleKey(shortcut) }
        needsLayout = true
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        lookChanged()
    }
}

// MARK: - SwiftUI parts

/// The window's background: the translucent canvas, and a grain in its top right corner, around the right sidebar's
/// button. The pages cover the rest of it.
struct CanvasRoot: View {
    let look: ShellLook

    var body: some View {
        ZStack(alignment: .topTrailing) {
            WindowCanvas(translucent: true)
            HalftoneCloud(corner: .topTrailing, step: 2, seed: 71, color: look.theme.accent.opacity(0.3))
                .frame(width: 240, height: 80)
        }
        .ignoresSafeArea()
        .environment(\.themeTokens, look.theme)
        .environment(\.windowCanvas, look.canvas)
    }
}

/// The left column: the sidebar under the title bar row, which holds the traffic lights and the sidebar button. It
/// reads the panels and the workspace itself, so a change of them runs only this column.
struct LeadingColumnRoot: View {
    let session: ShellSession
    let look: ShellLook
    let actions: PageActions
    let openSettings: () -> Void

    var body: some View {
        let visibility = session.panelVisibility
        LeftSidebar(
            session: session, workspace: session.workspace,
            panels: visibility.shown(session.panels.panels(in: .leading)),
            statusBar: visibility.shown(session.panels.panels(in: .statusBar)),
            openSettings: openSettings
        )
        .padding(.top, ShellRootView.tabBarTop + TabBar.height)
        // Fills the column's hosting view whatever its width, never a width of its own: the view takes the new width
        // before its content does, and a fixed width was centred in it for that frame, half the change away, so the
        // column shook while it was resized. The resize handle's room is at its right end.
        .padding(.trailing, ColumnResizeHandle.width)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .ignoresSafeArea()
        .environment(\.pageActions, actions)
        .modifier(ColumnLook(look: look))
    }
}

/// The right column: the inspector of the focused tab.
struct TrailingColumnRoot: View {
    let session: ShellSession
    let look: ShellLook

    var body: some View {
        InspectorColumn(session: session, workspace: session.workspace,
                        panels: session.panelVisibility.shown(session.panels.panels(in: .trailing)))
            .padding(.top, ShellRootView.tabBarTop + TabBar.height + 4)
            .padding(.leading, ColumnResizeHandle.width)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .ignoresSafeArea()
            .modifier(ColumnLook(look: look))
    }
}

/// A column's values from the window: the theme on the canvas, and the opaque colour behind its scroll views (none
/// while the desktop shows through).
private struct ColumnLook: ViewModifier {
    let look: ShellLook
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(WindowCanvas.transparencyKey) private var transparency = WindowCanvas.defaultTransparency

    func body(content: Content) -> some View {
        content
            .environment(\.windowCanvas, look.canvas)
            .onCanvas(look.theme)
            .environment(\.scrollEdgeBackdrop,
                         WindowCanvas.isTranslucent(transparency, reduceTransparency) ? nil : WindowCanvas.color(look.canvas, colorScheme))
            .tint(look.theme.accent)
            .contentTransition(.identity)
    }
}

/// The plugins' window overlays (the Assistant's bubble), in the window's bottom right corner, by `order`.
struct WindowOverlaysRoot: View {
    let overlays: WindowOverlayStore
    let look: ShellLook

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            ForEach(overlays.overlays(in: .bottomTrailing)) { $0.makeView() }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        .environment(\.themeTokens, look.theme)
        .environment(\.windowCanvas, look.canvas)
        .tint(look.theme.accent)
        .contentTransition(.identity)
    }
}

/// The hosting view of SwiftUI over the window that takes only the clicks on what it draws: the plugins' overlays
/// and the toasts, over the whole window, let every other click through to the pages under them. A hosting view
/// answers every point of its bounds itself, drawn or not; what SwiftUI drew there is a layer of its own.
final class OverlayHostingView<Content: View>: NSHostingView<Content> {
    override var mouseDownCanMoveWindow: Bool { false }
    override var acceptsFirstResponder: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point) else { return nil }
        // An AppKit view of the content (a text field) is drawn there.
        guard hit === self, let layer else { return hit }
        return Self.draws(layer, at: convert(point, from: superview)) ? self : nil
    }

    /// Whether a layer under `layer`, shown, covers `point` (in `layer`'s space).
    private static func draws(_ layer: CALayer, at point: CGPoint) -> Bool {
        for sublayer in layer.sublayers ?? [] where !sublayer.isHidden && sublayer.opacity > 0 {
            let inner = sublayer.convert(point, from: layer)
            if sublayer.contains(inner) || draws(sublayer, at: inner) { return true }
        }
        return false
    }
}

/// A hosting view that is only drawn: the canvas behind everything.
final class PassiveHostingView<Content: View>: NSHostingView<Content> {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var acceptsFirstResponder: Bool { false }
}

// MARK: - AppKit parts

/// The invisible grip between a side column and the workspace: drag it to resize the column. The width moves by whole
/// points, with no animation, and is saved once the drag ends.
final class ColumnResizeHandle: ShellView {
    static let width: CGFloat = 6
    let range: ClosedRange<Double>
    /// True for the leading column (dragging right widens it), false for the trailing one.
    let growsRightward: Bool
    var width: () -> Double = { 0 }
    var resize: (Double) -> Void = { _ in }
    /// Saves the width the drag left.
    var ended: () -> Void = {}
    /// The width and the pointer's place in the window when the drag started.
    private var start: (width: Double, x: Double)?

    init(range: ClosedRange<Double>, growsRightward: Bool) {
        self.range = range
        self.growsRightward = growsRightward
        super.init(frame: .zero)
        addPointerCursor(.columnResize)
        setAccessibilityElement(true)
        setAccessibilityRole(.splitter)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func mouseDown(with event: NSEvent) {
        start = (width(), Double(event.locationInWindow.x))
    }

    override func mouseDragged(with event: NSEvent) {
        // The pointer in the window, which the new width does not move.
        guard let start else { return }
        let delta = (Double(event.locationInWindow.x) - start.x) * (growsRightward ? 1 : -1)
        let next = min(max(start.width + delta, range.lowerBound), range.upperBound).rounded()
        if next != width() { resize(next) }
    }

    override func mouseUp(with event: NSEvent) {
        guard start != nil else { return }
        start = nil
        ended()
    }
}

/// Which development build this window belongs to, as a small coloured capsule: the worktree or branch it was built
/// from (`LoamBuildLabel` in Info.plist, written by scripts/build-app.sh for a debug build and scripts/agent-run.sh for
/// an instance). Several builds run side by side while developing; the label and its colour tell them apart. A
/// release build has no label and shows nothing.
final class BuildBadgeView: NSView {
    static let label = Bundle.main.object(forInfoDictionaryKey: "LoamBuildLabel") as? String

    private let text = NSAttributedString(string: label ?? "", attributes: [
        .font: NSFont.ui(size: 11, weight: .semibold), .foregroundColor: NSColor.white,
    ])

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        isHidden = (Self.label ?? "").isEmpty
        layer?.backgroundColor = Self.color(for: Self.label ?? "").cgColor
        layer?.cornerCurve = .continuous
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override var intrinsicContentSize: NSSize {
        guard !isHidden else { return .zero }
        let size = text.size()
        return NSSize(width: ceil(size.width) + 16, height: ceil(size.height) + 6)
    }

    override func layout() {
        super.layout()
        layer?.cornerRadius = min(Corners.cap ?? bounds.height / 2, bounds.height / 2)
    }

    override func draw(_ dirtyRect: NSRect) {
        text.draw(at: NSPoint(x: 8, y: 3))
    }

    /// The same label gets the same colour on every build: a hue from a stable hash of its text.
    private static func color(for label: String) -> NSColor {
        let hash = label.unicodeScalars.reduce(UInt32(5381)) { ($0 &* 33) &+ $1.value }
        return NSColor(hue: CGFloat(hash % 360) / 360, saturation: 0.65, brightness: 0.75, alpha: 1)
    }
}

/// How the sidebars show and hide: Craft's slide (`Motion.Spring.slide`, a quick start easing out into a long settle
/// with no bounce), or with Reduce Motion a short cross-fade of the column in place, the pages jumping to their width.
enum SidebarMotion {
    static let duration: Double = Motion.Spring.slide.duration

    static func animation(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : Motion.Spring.slide.animation
    }
}

extension View {
    /// The theme's tokens, made light on a dark canvas (`ThemeTokens.hasDarkCanvas`) along with dark mode.
    @ViewBuilder func onCanvas(_ theme: ThemeTokens) -> some View {
        if theme.hasDarkCanvas {
            environment(\.themeTokens, theme.onCanvas).environment(\.colorScheme, .dark)
        } else {
            environment(\.themeTokens, theme)
        }
    }
}

/// Where the sidebars leave the workspace once they have slid: its leading edge from the window's left, and the room
/// right of the last page. The few views that follow a slide (the first tab bar keeping clear of the traffic lights,
/// the last page's trailing edge) animate from the old value to this one on their own, with `animation`, nil under
/// Reduce Motion and outside a slide.
struct SidebarEdges: Equatable {
    var leadingEdge: CGFloat
    var trailingRoom: CGFloat
    var animation: Animation?

    static func == (lhs: SidebarEdges, rhs: SidebarEdges) -> Bool {
        lhs.leadingEdge == rhs.leadingEdge && lhs.trailingRoom == rhs.trailingRoom
    }

    /// The room the first tab bar leaves for the traffic lights and the buttons beside them while the workspace's leading
    /// edge is at `edge`.
    static func tabBarInset(leadingEdge edge: CGFloat) -> CGFloat {
        max(0, TitleBar.navigationX + TitleBar.navigationWidth + Glass.gap - edge)
    }
}

extension EnvironmentValues {
    /// Set by the window; nil outside it (a page drawn elsewhere has no sidebars).
    @Entry var sidebarEdges: SidebarEdges?
}

enum VaultBadge {
    /// Up to two initials of the vault's name: "TestVault" gives "TV", "my notes" gives "MN".
    static func initials(_ name: String) -> String {
        let words = name.split { !$0.isLetter && !$0.isNumber }
        if words.count >= 2 { return String(words.prefix(2).compactMap(\.first)).uppercased() }
        let capitals = name.filter(\.isUppercase)
        if capitals.count >= 2 { return String(capitals.prefix(2)) }
        return String(name.prefix(2)).uppercased()
    }
}

/// One sidebar: a single panel fills it; several get a row of icons at the top, the current one raised.
struct SlotView: View {
    let panels: [Panel]
    let selectedID: String?
    let select: @MainActor @Sendable (String) -> Void

    private var current: Panel? { panels.first { $0.id == selectedID } ?? panels.first }

    var body: some View {
        VStack(spacing: 0) {
            if panels.count > 1, let current {
                PanelPicker(panels: panels, selectedID: current.id, select: select)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
            }
            if let current {
                current.makeView()
                    .id(current.id)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

/// The panels of a sidebar as icons in a rounded track, the current one on a white raised segment (Craft's).
private struct PanelPicker: View {
    let panels: [Panel]
    let selectedID: String
    let select: @MainActor @Sendable (String) -> Void
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.themeTokens) private var theme

    var body: some View {
        HStack(spacing: 2) {
            ForEach(panels) { panel in
                let isSelected = panel.id == selectedID
                Button { select(panel.id) } label: {
                    Image(symbol: panel.symbol)
                        .font(.ui(size: 13))
                        .foregroundStyle(isSelected ? theme.text : theme.secondaryText)
                        .frame(maxWidth: .infinity)
                        .frame(height: 26)
                        .background {
                            if isSelected {
                                ThemeCapsule()
                                    .fill(colorScheme == .dark ? Color.white.opacity(0.12) : .white)
                                    .shadow(color: .black.opacity(0.08), radius: 1.5, y: 1)
                            }
                        }
                        .contentShape(ThemeCapsule())
                }
                .buttonStyle(.plain)
                .help(panel.title)
                .accessibilityLabel(panel.title)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        .padding(2)
        .background(ThemeCapsule().fill(Color.primary.opacity(0.05)))
    }
}

/// The measurements of the title bar row's buttons, the same for each so the row reads as one set.
enum TitleBar {
    static let buttonSide: CGFloat = 30
    static let buttonSpacing: CGFloat = 4
    /// Where the buttons right of the traffic lights start.
    static let navigationX: CGFloat = 84
    /// The sidebar button, Back and Forward.
    static let navigationWidth: CGFloat = 3 * buttonSide + 2 * buttonSpacing
}

/// Moves the window's traffic lights down so they line up with the tabs, as `trafficLightPosition` does in other
/// apps: the title bar is taller than AppKit's own without a toolbar. Kept in place on resize and full screen.
final class TrafficLightsView: NSView {
    var centerY: CGFloat = 26 { didSet { if centerY != oldValue { place() } } }
    /// While a sidebar slides (or a divider, a note or a tab is dragged), the window cannot be dragged by its title
    /// bar row. A movable window has AppKit work out on every frame where the views under the title bar leave it
    /// draggable, which asks every hosting view for its focus and the window server for a fence: about a third of
    /// each frame of the inspector's slide.
    var sidebarSliding = false { didSet { holdWindow() } }
    /// Pages, tabs or panes move (`WorkspaceController.onPagesMoving`).
    var pagesMoving = false { didSet { holdWindow() } }
    /// The window is being resized by its edge: nothing can drag it meanwhile, and every frame of the resize
    /// otherwise worked out again which parts of the title bar row drag it.
    var liveResizing = false { didSet { holdWindow() } }
    /// The pointer is over a tab or Home in the title bar row. There the window server moves a movable window on
    /// a press, before the app sees it, wherever AppKit finds no opaque view, and it finds none in the tab bars:
    /// the top of a tab dragged the window instead of the tab.
    var pointerOverTabs = false { didSet { holdWindow() } }

    private func holdWindow() {
        let held = sidebarSliding || pagesMoving || liveResizing || pointerOverTabs
        if let window, window.isMovable == held { window.isMovable = !held }
    }
    private var observers: [NSObjectProtocol] = []

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        guard let window else { return }
        WindowRootResponder.answerAtOnce(in: window)
        for name in [NSWindow.didResizeNotification, NSWindow.didEndLiveResizeNotification,
                     NSWindow.didExitFullScreenNotification, NSWindow.didBecomeKeyNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) {
                [weak self] _ in MainActor.assumeIsolated { self?.place() }
            })
        }
        observers.append(NotificationCenter.default.addObserver(
            forName: NSWindow.willStartLiveResizeNotification, object: window, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.liveResizing = true } })
        observers.append(NotificationCenter.default.addObserver(
            forName: NSWindow.didEndLiveResizeNotification, object: window, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.liveResizing = false } })
        // Hovering the lights makes AppKit lay the zoom button out again at its own place, without a frame
        // change notification. `didUpdate` follows every event the window handles, on the main thread: put the
        // button back right away, before the frame is drawn.
        observers.append(NotificationCenter.default.addObserver(
            forName: NSWindow.didUpdateNotification, object: window, queue: nil
        ) { [weak self] _ in MainActor.assumeIsolated { self?.place() } })
        // AppKit lays the title bar out again on its own (on key changes, full screen, tab drags) and puts the
        // lights back at the top: follow their frames and the title bar's, and move them back each time.
        if let close = window.standardWindowButton(.closeButton) {
            let watched = [close, close.superview, close.superview?.superview].compactMap { $0 }
                + [NSWindow.ButtonType.miniaturizeButton, .zoomButton].compactMap { window.standardWindowButton($0) }
                + [window.standardWindowButton(.zoomButton)?.superview].compactMap { $0 }
            for view in watched {
                view.postsFrameChangedNotifications = true
                observers.append(NotificationCenter.default.addObserver(
                    forName: NSView.frameDidChangeNotification, object: view, queue: .main
                ) { [weak self] _ in MainActor.assumeIsolated { self?.place() } })
            }
        }
        place()
        holdWindow()
        DispatchQueue.main.async { [weak self] in self?.place() }
    }

    func place() {
        guard let window, let close = window.standardWindowButton(.closeButton),
              let titlebar = close.superview?.superview else { return }
        // The title bar container grows to twice the lights' centre; the lights are centred in it.
        let height = centerY * 2
        var frame = titlebar.frame
        if frame.height != height {
            frame.size.height = height
            frame.origin.y = window.frame.height - height
            titlebar.frame = frame
        }
        var x: CGFloat = 20
        for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            guard let button = window.standardWindowButton(kind), let parent = button.superview else { continue }
            let size = button.frame.size
            // Centred on `centerY` from the window's top, in window coordinates: the lights' parent may not sit
            // at the window's top, nor have its new height yet, while AppKit lays the title bar out again.
            // The zoom button can sit in a container of its own (its tiling menu), offset from the others':
            // x is in window coordinates too.
            let inWindow = NSRect(x: x, y: window.frame.height - centerY - size.height / 2,
                                  width: size.width, height: size.height)
            let origin = parent.convert(inWindow, from: nil).origin
            if button.frame.origin != origin { button.setFrameOrigin(origin) }
            x += size.width + 6
        }
    }
}
