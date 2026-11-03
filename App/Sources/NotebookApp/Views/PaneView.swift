import PluginKitUI
import SwiftUI
import WorkspaceModel

/// A pane's page: its toolbar over the selected tab's view. The page's look (its rounded edge, background and
/// shadow) is drawn around it by AppKit (`PageChromeView`). A click anywhere in it focuses the pane; a tab or a note
/// dropped on it opens in it, or beside it on an edge (`PaneHostView`'s drop target).
struct PanePage: View {
    let pane: Pane
    let workspace: WorkspaceController
    let views: ViewRegistryStore
    @Environment(\.pageActions) private var actions
    @Environment(\.sidebarSliding) private var sliding
    @Environment(\.themeTokens) private var theme

    private var home: (() -> Void)? {
        guard let resource = actions.home else { return nil }
        return { workspace.open(resource, placement: .replace) }
    }

    private var selected: WorkspaceModel.Tab? { pane.tabs.first { $0.id == pane.selected } }

    /// A page of the selected tab: the one it shows, or the one Back returns to, kept under it.
    private struct TabPage {
        let tab: WorkspaceModel.Tab
        let context: ViewContext
        let identity: TabContentView.Identity
        let isKept: Bool
    }

    /// The kept page first, under the page shown.
    private func pages(of tab: WorkspaceModel.Tab) -> [TabPage] {
        let shown = TabPage(
            tab: tab, context: workspace.context(for: tab),
            identity: TabContentView.Identity(tab: tab, views: views, workspace: workspace), isKept: false
        )
        guard let kept = workspace.keptPage(of: tab, in: views) else { return [shown] }
        let identity = TabContentView.Identity(tab: kept.tab, views: views, workspace: workspace)
        guard identity != shown.identity else { return [shown] }
        return [TabPage(tab: kept.tab, context: kept.context, identity: identity, isKept: true), shown]
    }

    /// The arriving page takes the pose of the change that brought it; the leaving one fades quickly (`Motion.exit`)
    /// in the pose of the same change. Both read the change when they move, not when the view was built: a page that
    /// leaves was built before the change was known.
    private var pageTransition: AnyTransition {
        let transition = PageTransition(workspace: workspace, pane: pane.id)
        return .asymmetric(insertion: AnyTransition(transition), removal: AnyTransition(transition).animation(Motion.exit))
    }

    var body: some View {
        Group {
            if let tab = selected {
                // The view is rebuilt for each tab, resource and view type (`.id`), and the page that goes and
                // the one that comes move as the change says: from the clicked card, from the side of the new
                // tab, back to where it came from (`PageChange`). A view that follows its resource is kept while
                // links and sidebar rows replace the page, which then changes in one frame with no animation.
                // The page Back returns to stays under it, hidden, and comes back as it was (`keptPage`).
                ZStack {
                    ForEach(pages(of: tab), id: \.identity) { page in
                        TabContentView(tab: page.tab, context: page.context, views: views)
                            // The toolbar's room is given inside the page, under its motion: a safe area does
                            // not reach through a scale, so a page arriving from a card had its text laid out
                            // below the toolbar, then raised to under it once the scale came to rest.
                            .safeAreaPadding(.top, PageToolbar.height)
                            // Each page is opaque, so nothing of the page under it shows through its gaps (the
                            // board kept for Back between the cards of All Notes).
                            .background(theme.background)
                            .id(page.identity)
                            .modifier(KeptPage(isKept: page.isKept))
                            .motionTransition(pageTransition)
                            .transaction(value: selected.map(PageKey.init)) { transaction in
                                if workspace.pageChange(for: pane.id, showing: PageKey(tab)) == .replaced {
                                    transaction.animation = nil
                                }
                            }
                    }
                }
                // Up under the toolbar: each page keeps the toolbar's room itself (above).
                .ignoresSafeArea(.container, edges: .top)
            } else if let home {
                // A pane is never left empty: the last tab closed, it shows the home page.
                Color.clear.onAppear { home() }
            } else {
                EmptyPaneView()
            }
        }
        .motion(workspace.pageChange(for: pane.id, showing: selected.map(PageKey.init)).animation, value: selected.map(PageKey.init))
        // Nothing on the page reacts to the pointer while a sidebar slides: otherwise every frame of the slide
        // hit-tests each hover area of the page again (a card grid has dozens).
        .allowsHitTesting(!sliding)
        // Both bounds, so the page takes the pane's size whatever its view asks for: a view wider than a
        // narrow pane is cut by the page rather than pushing the page over its neighbours.
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
        .environment(\.pageChromeInset, PageToolbar.height)
        // Over the page rather than above it, so the text scrolls under the toolbar's glass, as in Craft.
        .safeAreaInset(edge: .top, spacing: 0) {
            PageToolbar(
                tab: selected?.id,
                resource: selected?.resource,
                workspace: workspace,
                viewSwitch: selected.flatMap { ViewSwitch(tab: $0, views: views) },
                title: selected.flatMap { workspace.context(for: $0).toolbarTitle },
                showsNavigation: workspace.layout.panes.first?.id != pane.id
            )
        }
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
        .environment(\.scrollEdgeBackdrop, theme.background)
        .background(theme.background)
        .background(PaneClickDetector { workspace.focus(pane.id) })
    }
}

/// The selected tab's view: the view type the registry picks for its resource, or a placeholder when no installed
/// plugin can open it (its plugin was disabled: the tab stays, and comes back to life when the plugin does).
struct TabContentView: View {
    let tab: WorkspaceModel.Tab
    let context: ViewContext
    let views: ViewRegistryStore

    /// A new view when the tab, its resource or its view type changes, so no state leaks from one to the next. A view
    /// type that follows its resource (`ViewType.followsResource`) keeps its view while the page is replaced in place:
    /// the page generation stands for the resource.
    struct Identity: Hashable {
        let tab: TabID
        let resource: Resource?
        let generation: Int
        let viewType: String?

        @MainActor init(tab: WorkspaceModel.Tab, views: ViewRegistryStore, workspace: WorkspaceController) {
            self.tab = tab.id
            let type = WorkspaceController.viewType(for: tab, in: views)
            let follows = type?.followsResource ?? false
            resource = follows ? nil : tab.resource
            generation = follows ? workspace.pageGeneration(of: tab.id) : 0
            viewType = type?.id
        }
    }

    var body: some View {
        if let type = WorkspaceController.viewType(for: tab, in: views) {
            type.makeView(context)
        } else {
            ContentUnavailableView {
                Label("No installed plugin can open this", symbol: "puzzlepiece.extension")
            } description: {
                Text(tab.resource.name)
            }
        }
    }
}

/// How a page arrives or leaves: scaled from a point, shifted from a side, always faded; under Reduce Motion only
/// the fade (`motionTransition`). The pose comes from the pane's last change, read when the transition runs.
private struct PageTransition: Transition {
    let workspace: WorkspaceController
    let pane: PaneID

    func body(content: Content, phase: TransitionPhase) -> some View {
        let effect = phase.isIdentity ? PageEffect.identity : workspace.pageEffect(for: pane, leaving: phase == .didDisappear)
        content
            .scaleEffect(effect.scale, anchor: effect.anchor)
            .offset(effect.offset)
            .opacity(phase.isIdentity ? 1 : 0)
            .transaction { if effect.isInstant { $0.animation = nil } }
    }
}

/// A page kept under the tab's page for Back: not under the pointer, not read by VoiceOver. It stays still and drawn
/// while the page opened from it arrives over it, then is hidden; when Back shows it again it is there at once, under
/// the page going back. It never moves itself: a grid of cards fading and scaling under the page arriving made most
/// frames of that motion late.
private struct KeptPage: ViewModifier {
    let isKept: Bool
    /// A page made to be kept (the one Back now returns to, after Back or a sidebar row) was not on screen: it starts
    /// hidden. Drawn, it showed through the page over it for a moment, a board behind the gaps of All Notes.
    @State private var isHidden: Bool

    /// The page's size when it was last shown: kept at it, a page is not laid out again when the pane's size changes
    /// under it (a window resize had the home page kept under a note lay out and draw its cards on every step).
    @State private var shownSize = Measured<CGSize?>(nil)

    init(isKept: Bool) {
        self.isKept = isKept
        _isHidden = State(initialValue: isKept)
    }

    func body(content: Content) -> some View {
        // Read with `isKept`, so a page Back shows again is drawn in that same frame, not a turn later.
        let hidden = isKept && isHidden
        KeptLayout(isKept: isKept, shownSize: shownSize) { content }
            .opacity(hidden ? 0 : 1)
            .animation(nil, value: hidden)
            .allowsHitTesting(!isKept)
            .accessibilityHidden(isKept)
            .task(id: isKept) {
                guard isKept else {
                    isHidden = false
                    return
                }
                try? await Task.sleep(for: .milliseconds(600))
                if !Task.isCancelled { isHidden = true }
            }
    }
}

/// Lays a page out at the pane's size while it is shown, and at the size it was last shown at once it is kept. The
/// size is read when the pane is laid out, not when the page's view was last built, and a kept page is proposed the
/// same size on every pass, so SwiftUI leaves it as it is. Its own size is always the pane's: a kept page wider than
/// a pane that narrowed under it never widens the pages' stack (the page shown over it would be laid out at that
/// width and centred), it reaches past the page's edge, which cuts it.
private struct KeptLayout: Layout {
    let isKept: Bool
    let shownSize: Measured<CGSize?>

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        // A page kept before it was ever shown (Back's page after a sidebar row) holds the size it first had.
        if !isKept || shownSize.value == nil { shownSize.value = bounds.size }
        let size = isKept ? shownSize.value ?? bounds.size : bounds.size
        subviews.first?.place(at: bounds.origin, anchor: .topLeading, proposal: ProposedViewSize(size))
    }
}

/// A pane with no tab: only the last pane of the workspace can be empty.
struct EmptyPaneView: View {
    var body: some View {
        ContentUnavailableView("Nothing open", symbol: "square.dashed")
            .foregroundStyle(.tertiary)
    }
}
