import AppKit
import PluginKitUI
import SwiftUI
import WorkspaceModel

/// The window of an open vault: the leading slot as the sidebar, the workspace in the middle, the trailing slot as
/// the inspector (`InspectorColumn`) and the status bar slot along the bottom. Slots without panels take no room. The side columns sit
/// on the window's translucent material (`WindowCanvas`); the panes are opaque pages detached from the edges.
///
/// The columns are laid out by hand rather than with `NavigationSplitView`: its split view feeds the content's
/// minimum size back into the window's constraints, which looped (and crashed) while resizing a grid.
///
/// A sidebar shows and hides as Craft's does: its column slides in from the window's edge (`SlidingColumn`, on the
/// render server). For the left sidebar, as in Craft, the workspace is laid out once at its new width and moved to
/// follow the column's edge (`SplitTreeView.follow`): nothing is laid out again on the frames of the slide, which on
/// "All Notes" measured every card on each frame. The inspector's slide does the same from the other side: only the
/// last page's trailing edge follows the column (`PageChromeView.followSlide`).
struct ShellWindow: View {
    let session: ShellSession

    var body: some View {
        ShellWindowContent(session: session)
            .themed(by: session.themes)
            // A text that changes while something moves (a tab's title as it opens, a count) changes at once instead
            // of morphing: SwiftUI draws a morphing text on the CPU on every frame. Views that want a numeric roll
            // say so themselves.
            .contentTransition(.identity)
    }
}

private struct ShellWindowContent: View {
    let session: ShellSession
    /// The columns' widths, read once and written back when dragged. Not `@AppStorage`: it runs the body again on
    /// any change of the app's defaults, and AppKit saves the window's frame there on every step of a resize, so the
    /// whole window and both columns were updated on each frame of it.
    @State private var leadingWidth = Self.storedWidth(Self.leadingWidthKey)
    @State private var trailingWidth = Self.storedWidth(Self.trailingWidthKey)
    private static let leadingWidthKey = "shell.leadingWidth"
    private static let trailingWidthKey = "shell.trailingWidth"

    private static func storedWidth(_ key: String) -> Double {
        UserDefaults.standard.object(forKey: key) as? Double ?? 280
    }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @AppStorage(WindowCanvas.transparencyKey) private var transparency = WindowCanvas.defaultTransparency

    /// The opaque colour behind the sidebars' scroll views; none while the desktop shows through.
    private var sidebarBackdrop: Color? {
        WindowCanvas.isTranslucent(transparency, reduceTransparency) ? nil : WindowCanvas.color(canvas, colorScheme)
    }
    @Environment(\.themeTokens) private var theme
    @Environment(\.openSettings) private var openSettings
    @Environment(\.windowCanvas) private var canvas
    @Environment(\.colorScheme) private var colorScheme

    static let leadingRange: ClosedRange<Double> = 180...420
    /// Where the tab bars start under the window's top edge: centred in the 52 point title bar.
    static let tabBarTop: CGFloat = 6
    static let trailingRange: ClosedRange<Double> = 200...460
    /// The right sidebar button's width and the gap to the window's edge, which the last tab bar keeps clear of.
    static let trailingButtonInset: CGFloat = 44

    var body: some View {
        let workspace = session.workspace
        let visibility = session.panelVisibility
        let leading = visibility.shown(session.panels.panels(in: .leading))
        let trailing = visibility.shown(session.panels.panels(in: .trailing))
        let statusBar = visibility.shown(session.panels.panels(in: .statusBar))
        let hasLeading = !leading.isEmpty || !session.panels.links.isEmpty || !session.panels.sections.isEmpty
        let showsLeading = workspace.chrome.showsLeading && hasLeading
        // The column is kept, and slides out while the focused page has nothing to show in it (the home page).
        let hasTrailing = true
        let showsTrailing = workspace.chrome.showsTrailing && hasTrailing
            && !InspectorColumn(session: session, workspace: workspace, panels: trailing).isEmpty

        HStack(spacing: 0) {
            if hasLeading { SideColumnRoom(width: leadingWidth + ColumnResizeHandle.width, isShown: showsLeading) }
            VStack(spacing: 0) {
                WorkspaceView(workspace: workspace, views: session.views)
                    // The top panes' tabs go up into the title bar row, clear of the traffic lights and the
                    // sidebar button when the sidebar is hidden.
                    .padding(.top, Self.tabBarTop)
                    .ignoresSafeArea(.container, edges: .top)
                    .environment(\.tabBarTrailingInset, hasTrailing ? Self.trailingButtonInset : 0)
                    .padding(.leading, showsLeading ? 0 : Glass.gap)
                    .padding(.trailing, showsTrailing ? 0 : Glass.gap)
                    .padding(.bottom, Glass.gap)
            }
            // Laid out at once at the new width; only the move to it is animated, by the workspace's AppKit view
            // (`SplitTreeView.follow`), from where the columns end up, written once per slide: the tab bar and the last
            // page follow it with their own animation (`SidebarEdges`), so nothing is laid out on the frames of a
            // slide.
            .transaction(value: showsLeading) { $0.animation = nil }
            .transaction(value: showsTrailing) { $0.animation = nil }
            .environment(\.sidebarEdges, SidebarEdges(
                leadingEdge: leadingEdge(showsLeading), trailingRoom: trailingRoom(showsTrailing),
                animation: SidebarMotion.animation(reduceMotion: reduceMotion)
            ))
            .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
            if hasTrailing { SideColumnRoom(width: trailingWidth + ColumnResizeHandle.width, isShown: showsTrailing) }
        }
        // The columns themselves, in the room the workspace leaves them.
        .background(alignment: .topLeading) {
            if hasLeading {
                SlidingColumn(isShown: showsLeading, edge: .leading, reduceMotion: reduceMotion) {
                    HStack(spacing: 0) {
                        LeftSidebar(session: session, workspace: workspace, panels: leading, statusBar: statusBar, openSettings: { openSettings() })
                        // Under the title bar row, which holds the traffic lights and the sidebar button.
                        .padding(.top, Self.tabBarTop + TabBar.height)
                        .frame(maxWidth: .infinity)
                        ColumnResizeHandle(width: $leadingWidth, range: Self.leadingRange, growsRightward: true) {
                            UserDefaults.standard.set(leadingWidth, forKey: Self.leadingWidthKey)
                        }
                    }
                    // Fills the column's hosting view whatever its width, never a width of its own: the view takes
                    // the new width before its content does, and a fixed width was centred in it for that frame,
                    // half the change away, so the column shook while it was resized.
                    .frame(maxWidth: .infinity)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .ignoresSafeArea()
                    .environment(\.pageActions, pageActions())
                    .onCanvas(theme)
                    .environment(\.scrollEdgeBackdrop, sidebarBackdrop)
                    .tint(theme.accent)
                    .contentTransition(.identity)
                }
                .frame(width: leadingWidth + ColumnResizeHandle.width)
                .frame(maxHeight: .infinity, alignment: .top)
                .ignoresSafeArea(.container, edges: .top)
            }
        }
        .background(alignment: .topTrailing) {
            if hasTrailing {
                SlidingColumn(isShown: showsTrailing, edge: .trailing, reduceMotion: reduceMotion) {
                    HStack(spacing: 0) {
                        ColumnResizeHandle(width: $trailingWidth, range: Self.trailingRange, growsRightward: false) {
                            UserDefaults.standard.set(trailingWidth, forKey: Self.trailingWidthKey)
                        }
                        InspectorColumn(session: session, workspace: workspace, panels: trailing)
                        .padding(.top, Self.tabBarTop + TabBar.height + 4)
                        .frame(maxWidth: .infinity)
                    }
                    // Fills the column whatever its width, as the left one.
                    .frame(maxWidth: .infinity)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .ignoresSafeArea()
                    .onCanvas(theme)
                    .environment(\.scrollEdgeBackdrop, sidebarBackdrop)
                    .tint(theme.accent)
                    .contentTransition(.identity)
                }
                .frame(width: trailingWidth + ColumnResizeHandle.width)
                .frame(maxHeight: .infinity, alignment: .top)
                .ignoresSafeArea(.container, edges: .top)
            }
        }
        .environment(\.pageActions, pageActions())
        .environment(\.sidebarSliding, workspace.isSidebarSliding && !reduceMotion)
        .background {
            ZStack(alignment: .topTrailing) {
                WindowCanvas(translucent: true)
                // A grain in the window's top right corner, on the canvas around the right sidebar's button. The
                // pages cover the rest of it.
                HalftoneCloud(corner: .topTrailing, step: 2, seed: 71, color: theme.accent.opacity(0.3))
                    .frame(width: 240, height: 80)
            }
            .ignoresSafeArea()
        }
        .containerBackground(.clear, for: .window)
        // No window toolbar: it would take the clicks of the tabs under it. The sidebar button is ours.
        // Right of the traffic lights, where they stay whether the sidebar shows or not: its button, then Back and
        // Forward of the first pane (the panes beside it have theirs in their page toolbar).
        .overlay(alignment: .topLeading) {
            TitleBarNavigation(workspace: workspace, hasSidebar: hasLeading)
                .padding(.leading, TitleBar.navigationX)
                .padding(.top, Self.tabBarTop + 5)
                .onCanvas(theme)
                .ignoresSafeArea(.container, edges: .top)
        }
        // The right sidebar button closes the same row, at the window's right end, as in Craft.
        .overlay(alignment: .topTrailing) {
            if hasTrailing {
                WindowButton(title: "Toggle Right Sidebar", symbol: "sidebar.trailing") { workspace.toggleSidebar(.trailing) }
                    .padding(.trailing, 14)
                    .padding(.top, Self.tabBarTop + 5)
                    .onCanvas(theme)
                    .ignoresSafeArea(.container, edges: .top)
            }
        }
        // Plugins' overlays (the Assistant's bubble), inside the window, under the palette and the toasts.
        .overlay(alignment: .bottomTrailing) {
            ZStack(alignment: .bottomTrailing) {
                ForEach(session.windowOverlays.overlays(in: .bottomTrailing)) { $0.makeView() }
            }
        }
        // A development build's worktree or branch, so side-by-side builds are told apart (nothing in a release).
        .overlay(alignment: .bottomLeading) {
            BuildBadge()
                // Over the pages' bottom left, clear of the sidebar's footer.
                .padding(.leading, leadingEdge(showsLeading) + 12)
                .padding(.bottom, Glass.gap + 8)
        }
        .background(WindowHold(workspace: workspace, centerY: Self.tabBarTop + TabBar.height / 2))
        .navigationTitle(workspace.activeResource?.name ?? session.name)
        .paletteChrome(session)
    }

    /// Where the workspace starts from the window's left edge: past the sidebar while it shows, a gap from the edge
    /// once it is hidden.
    private func leadingEdge(_ showsLeading: Bool) -> CGFloat {
        showsLeading ? leadingWidth + ColumnResizeHandle.width : Glass.gap
    }

    /// The room right of the last page: the inspector while it shows, a gap from the window's edge once it is hidden.
    private func trailingRoom(_ showsTrailing: Bool) -> CGFloat {
        showsTrailing ? trailingWidth + ColumnResizeHandle.width : Glass.gap
    }

    private func pageActions() -> PageActions {
        let session = session
        var actions = PageActions()
        if session.runtime.kernel.commands.command(id: Self.newNoteCommand) != nil {
            actions.newNote = { session.commandRunner.run(Self.newNoteCommand) }
        }
        actions.newItems = session.panels.newItems
        actions.home = session.homeResource
        actions.resourceActions = { [resourceActions = session.resourceActions] in resourceActions.actions(for: $0) }
        return actions
    }

    /// The file explorer's command, run by the page toolbar's "+".
    static let newNoteCommand = "explorer.new-note"
}

/// How the sidebars show and hide: Craft's slide (`Motion.Spring.slide`, a quick start easing out into a long settle
/// with no bounce), or with Reduce Motion a short cross-fade of the column in place, the pages jumping to their width.
enum SidebarMotion {
    static let duration: Double = Motion.Spring.slide.duration

    static func animation(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : Motion.Spring.slide.animation
    }
}

/// Moves the status bar, already laid out where the left sidebar's change leaves it, from where its leading edge was
/// to where it is now, with the workspace above it (`SplitTreeView.follow`): `edge` is animated, `settledEdge` is not,
/// and the bar is drawn `edge - settledEdge` away from its place.
private struct LeadingSlide: ViewModifier, Animatable {
    var edge: CGFloat
    let settledEdge: CGFloat

    nonisolated var animatableData: CGFloat {
        get { edge }
        set { edge = newValue }
    }

    func body(content: Content) -> some View {
        content.offset(x: (edge - settledEdge).rounded())
    }
}

/// Where the sidebars leave the workspace once they have slid: its leading edge from the window's left, and the room
/// right of the last page. The few views that follow a slide (the first tab bar keeping clear of the traffic lights,
/// the last page's trailing edge) animate from the old value to this one on their own, with `animation`. Writing the
/// moving values into the environment on every frame instead had SwiftUI go over every view of the pages on each
/// frame of a slide: the left sidebar slid at 20-40 frames a second on a real vault.
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

/// The room a side column takes beside the workspace: as wide as the column while it shows, nothing once hidden.
/// The column itself is drawn behind (`SlidingColumn`), so that its width is the only thing laid out again on each
/// frame of the slide.
struct SideColumnRoom: View {
    let width: Double
    let isShown: Bool

    var body: some View {
        Color.clear
            .frame(width: isShown ? width : 0)
            .allowsHitTesting(false)
    }
}

/// The invisible grip between a side column and the workspace: drag it to resize the column. The width moves by whole
/// points, with no animation, and is saved once the drag ends: a write to the defaults runs again every `@AppStorage`
/// body in the app, so each frame of the drag updated all of them.
struct ColumnResizeHandle: View {
    static let width: CGFloat = 6
    @Binding var width: Double
    let range: ClosedRange<Double>
    /// True for the leading column (dragging right widens it), false for the trailing one.
    let growsRightward: Bool
    /// Saves the width the drag left.
    let ended: () -> Void
    /// The width and the pointer's place in the window when the drag started.
    @State private var start: (width: Double, x: Double)?

    var body: some View {
        Color.clear
            .frame(width: Self.width)
            .contentShape(Rectangle())
            .pointerCursor(.columnResize)
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { drag in
                        // The pointer in the window, not the drag's translation: the grip lives in the column's own
                        // hosting view, which the new width lays out again, so the translation moved under the pointer
                        // and the column shook while it was dragged.
                        let x = NSApp.currentEvent.map { Double($0.locationInWindow.x) }
                            ?? Double(drag.location.x)
                        let origin = start ?? (width, x - Double(drag.translation.width))
                        if start == nil { start = origin }
                        let delta = (x - origin.x) * (growsRightward ? 1 : -1)
                        let next = min(max(origin.width + delta, range.lowerBound), range.upperBound).rounded()
                        guard next != width else { return }
                        var transaction = Transaction(animation: nil)
                        transaction.disablesAnimations = true
                        withTransaction(transaction) { width = next }
                    }
                    .onEnded { _ in
                        start = nil
                        ended()
                    }
            )
    }
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

/// A button of the title bar row: a symbol on a faint disc, round as the tabs beside it are under the theme's corners
/// (`ThemeCapsule`), darker under the pointer, its symbol greyed while there is nothing to do.
struct WindowButton: View {
    let title: String
    let symbol: String
    var isEnabled = true
    let action: () -> Void
    @State private var isHovered = false
    @Environment(\.themeTokens) private var theme

    var body: some View {
        Button(action: action) {
            Image(symbol: symbol)
                .font(.ui(size: 14, weight: .medium))
                .foregroundStyle(theme.secondaryText.opacity(isEnabled ? 1 : 0.55))
                .frame(width: TitleBar.buttonSide, height: TitleBar.buttonSide)
                .background(ThemeCapsule().fill(theme.text.opacity(isHovered && isEnabled ? 0.1 : 0.05)))
                .contentShape(ThemeCapsule())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .onHover { isHovered = $0 }
        .animation(Motion.hover, value: isHovered)
        .help(title)
        .accessibilityLabel(title)
    }
}

/// The left of the title bar row: the sidebar button, then Back and Forward of the first pane's tab. Forward is
/// always there, dimmed until Back has been used, so nothing shifts.
struct TitleBarNavigation: View {
    let workspace: WorkspaceController
    let hasSidebar: Bool

    private var tab: TabID? { workspace.layout.panes.first?.selected }

    var body: some View {
        HStack(spacing: TitleBar.buttonSpacing) {
            if hasSidebar {
                WindowButton(title: "Toggle Left Sidebar", symbol: "sidebar.leading") { workspace.toggleSidebar(.leading) }
            }
            WindowButton(title: "Back", symbol: "chevron.left", isEnabled: tab.map { workspace.canGoBack(in: $0) } ?? false) {
                if let tab { workspace.goBack(in: tab) }
            }
            WindowButton(title: "Forward", symbol: "chevron.right", isEnabled: tab.map { workspace.canGoForward(in: $0) } ?? false) {
                if let tab { workspace.goForward(in: tab) }
            }
        }
    }
}

/// The traffic lights' positioner, told when the window holds still: while a sidebar slides, a divider is dragged
/// or a note or tab is dragged over the pages (which step back under the title bar). Read in its own body, so a
/// slide or a drag starting and ending runs only this, not the window's.
private struct WindowHold: View {
    let workspace: WorkspaceController
    let centerY: CGFloat

    var body: some View {
        TrafficLightsPositioner(
            centerY: centerY,
            holdsStill: workspace.isSidebarSliding || workspace.isDividerDragging || DragSession.shared.isActive,
            workspace: workspace
        )
    }
}

/// Moves the window's traffic lights down so they line up with the tabs, as `trafficLightPosition` does in other
/// apps: the title bar is taller than AppKit's own without a toolbar. Kept in place on resize and full screen.
struct TrafficLightsPositioner: NSViewRepresentable {
    let centerY: CGFloat
    /// While a sidebar slides, the window cannot be dragged by its title bar row. A movable window has AppKit work out
    /// on every frame where the views under the title bar leave it draggable, which asks SwiftUI to walk its whole
    /// focus tree and the window server for a fence: about a third of each frame of the inspector's slide.
    var holdsStill = false
    /// Tells when pages, tabs or panes move, and when the pointer is over a tab, which hold the window still the same
    /// way.
    var workspace: WorkspaceController?

    func makeNSView(context: Context) -> PositionerView {
        let view = PositionerView()
        view.centerY = centerY
        workspace?.onPagesMoving = { [weak view] moving in
            view?.pagesMoving = moving
        }
        workspace?.onPointerOverTabs = { [weak view] over in
            view?.pointerOverTabs = over
        }
        return view
    }

    func updateNSView(_ view: PositionerView, context: Context) {
        view.centerY = centerY
        view.place()
        view.sidebarSliding = holdsStill
    }

    final class PositionerView: NSView {
        var centerY: CGFloat = 26
        var sidebarSliding = false { didSet { holdWindow() } }
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
            DispatchQueue.main.async { [weak self] in self?.place() }
        }

        override func layout() {
            super.layout()
            place()
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
}
