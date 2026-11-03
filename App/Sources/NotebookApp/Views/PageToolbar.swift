import PluginKit
import PluginKitUI
import SwiftUI
import WorkspaceModel

/// What the page toolbars can do beyond the pane itself, given by the window.
struct PageActions {
    /// Creates a note and opens it; nil when no plugin offers it.
    var newNote: (@MainActor () -> Void)?
    /// What plugins can create besides a note: the "+" of a page of one kind (the drawings) creates that kind.
    var newItems: [NewItem] = []
    /// What Home opens: the first navigation link ("All Notes"); nil hides it.
    var home: Resource?
    /// What plugins add to the menu of a file or folder ("Rename…"), for the tab's and the page's right-click menus.
    var resourceActions: @MainActor (Resource) -> [ResourceAction] = { _ in [] }
}

extension PageActions {
    /// The plugins' items for `resource` in a right-click menu: none for a page that is no file or folder.
    @MainActor func menuItems(for resource: Resource?) -> [RightClickItem] {
        guard let resource, resource.kind != .virtual else { return [] }
        return resourceActions(resource).map { action in
            RightClickItem(title: action.title, symbol: action.symbol) { action.perform(resource) }
        }
    }
}

extension EnvironmentValues {
    @Entry var pageActions = PageActions()
}

/// The toolbar at the top of a page, as in Craft: Back (and Forward after a Back) and New on the left, the view switch on the right, as light grey rounded squares (40 by 36, radius 12) with a hairline edge.
struct PageToolbar: View {
    let tab: TabID?
    /// What the tab shows, for the trail of folders it lives in.
    var resource: Resource?
    let workspace: WorkspaceController
    /// The views the tab's resource can be shown with, when there are several (a mindmap and its Markdown).
    var viewSwitch: ViewSwitch?
    /// The page's title once its own has scrolled under the toolbar (`ViewContext.toolbarTitle`).
    var title: ToolbarTitle?
    /// False for the first pane, whose Back and Forward are in the title bar row.
    var showsNavigation = true
    @Environment(\.pageActions) private var actions
    @Environment(\.themeTokens) private var theme

    static let height: CGFloat = 56

    private var trail: Breadcrumb { resource.map(Breadcrumb.init(resource:)) ?? Breadcrumb(folderNames: []) }

    /// A folder of the trail opens in this tab; Back returns to the page.
    private func openFolder(_ folder: String) {
        workspace.open(.folder(folder), placement: .replace)
    }

    var body: some View {
        HStack(spacing: 10) {
            // The first pane's Back and Forward are in the title bar row (`TitleBarNavigation`); the panes beside it keep theirs.
            if showsNavigation {
                PageToolbarButton(title: "Back", symbol: "chevron.left", size: 15, weight: .regular) {
                    if let tab { workspace.goBack(in: tab) }
                }
                .disabled(tab.map { !workspace.canGoBack(in: $0) } ?? true)
                // Forward only once Back has been used, so the toolbar stays Craft's until there is somewhere to go.
                if let tab, workspace.canGoForward(in: tab) {
                    PageToolbarButton(title: "Forward", symbol: "chevron.right", size: 15, weight: .regular) {
                        workspace.goForward(in: tab)
                    }
                }
            }
            // The folders the page lives in are always there, in small secondary text; the page's own title joins
            // them above once it has scrolled under the toolbar.
            VStack(alignment: .leading, spacing: 0) {
                if let title {
                    Text(title.title.uiLocalized)
                        .font(.ui(size: 13, weight: .semibold))
                        .foregroundStyle(theme.text)
                        .lineLimit(1)
                        .transition(.opacity.combined(with: .offset(y: 6)))
                }
                HStack(spacing: 6) {
                    // Gone when the page lives nowhere (root, All Notes, nothing open): a `ViewThatFits` left with no
                    // child keeps drawing the last trail it had. A new view per trail for the same reason.
                    if !trail.isEmpty {
                        BreadcrumbView(trail: trail, open: openFolder).id(trail.folders.map(\.title))
                    }
                    if let subtitle = title?.subtitle {
                        Label(subtitle, symbol: title?.symbol ?? "doc")
                            .font(.ui(size: 11))
                            .foregroundStyle(theme.secondaryText)
                            .labelStyle(TightLabelStyle())
                            .lineLimit(1)
                            .fixedSize()
                    }
                }
            }
            .padding(.leading, 4)
            // Back and New keep their place; the trail gives way to the view switch when the pane is narrow.
            .frame(maxWidth: .infinity, alignment: .leading)
            // A right-click on the page's title or its folders: the page's menu ("Rename…").
            .rightClickMenu { [actions, resource] in actions.menuItems(for: resource) }
            .motion(Motion.crossfade, value: resource)
            if let viewSwitch, let tab {
                ViewSwitcher(choices: viewSwitch.choices, selected: viewSwitch.current) { id in
                    workspace.setViewType(id == viewSwitch.choices.first?.id ? nil : id, for: tab)
                }
            }
        }
        .padding(.horizontal, PageMetrics.edge)
        // In a pane too narrow for all of it, Back and New stay in view and the right end is cut.
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        .frame(height: Self.height)
        .background { ToolbarGlass(isScrolled: title != nil) }
        .motion(Motion.Spring.smooth, value: title)
    }
}

/// Behind the page's toolbar: the same glass as the other scroll edges (`EdgeGlassBand`), a progressive blur of what
/// scrolls under it, strongest at the top and gone by its bottom edge, so text passing under the buttons softens
/// instead of colliding with them (Craft's glassy top). Over the bare page it is invisible: its wash is the page's own
/// colour and the blur stays out. A page whose text has gone under the toolbar (its title shows there) brings the
/// blur in; a page that does not say keeps the wash, since what scrolls under it cannot be known from here.
private struct ToolbarGlass: View {
    /// The page's title has gone under the toolbar.
    let isScrolled: Bool
    @Environment(\.themeTokens) private var theme

    var body: some View {
        ZStack {
            EdgeGlassBand(edge: .top, progress: 1, blur: isScrolled ? 1 : 0, length: PageToolbar.height, tint: theme.background)
            // With the title in it, the toolbar is the page's own colour down to under the title, as Craft's: the
            // title and its folders never sit over the text or a block scrolling under them.
            LinearGradient(
                stops: [.init(color: theme.background, location: 0), .init(color: theme.background, location: 0.82),
                        .init(color: theme.background.opacity(0), location: 1)],
                startPoint: .top, endPoint: .bottom
            )
            .opacity(isScrolled ? 1 : 0)
            .allowsHitTesting(false)
        }
        .frame(height: PageToolbar.height)
        .animation(Motion.ambient, value: isScrolled)
    }
}

/// The folders a page lives in as one line of small secondary text, "Areas › nested folder": each folder opens when
/// clicked. When the pane is too narrow for all of them the middle goes first ("Areas › … › nested folder"), then
/// the start, and at last only the folder the page is in, cut at its end if it must (`Breadcrumb.candidates`).
private struct BreadcrumbView: View {
    let trail: Breadcrumb
    let open: (String) -> Void
    @Environment(\.themeTokens) private var theme

    var body: some View {
        let candidates = trail.candidates
        ViewThatFits(in: .horizontal) {
            ForEach(Array(candidates.enumerated()), id: \.offset) { index, segments in
                row(segments).fixedSize(horizontal: index < candidates.count - 1, vertical: true)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Folder path")
    }

    private func row(_ segments: [Breadcrumb.Segment]) -> some View {
        HStack(spacing: 4) {
            ForEach(Array(segments.enumerated()), id: \.offset) { index, segment in
                if index > 0 {
                    Image(symbol: "chevron.right")
                        .font(.ui(size: 8, weight: .semibold))
                        .foregroundStyle(theme.secondaryText.opacity(0.6))
                }
                if let folder = segment.folder {
                    BreadcrumbButton(title: segment.title) { open(folder) }
                } else {
                    Text(segment.title.uiLocalized).foregroundStyle(theme.secondaryText)
                }
            }
        }
        .font(.ui(size: 11))
        .lineLimit(1)
    }
}

/// One folder of the trail: secondary text that darkens under the pointer.
private struct BreadcrumbButton: View {
    let title: String
    let action: () -> Void
    @State private var isHovered = false
    @Environment(\.themeTokens) private var theme

    var body: some View {
        Button(action: action) {
            Text(title.uiLocalized)
                .foregroundStyle(isHovered ? theme.text : theme.secondaryText)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Open \(title)")
        .onHover { isHovered = $0 }
        .animation(Motion.hover, value: isHovered)
    }
}

/// An icon and a title with little room between them.
private struct TightLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 3) {
            configuration.icon.imageScale(.small)
            configuration.title
        }
    }
}

/// Craft's toolbar control: a #F7F7F7 rounded square on the white page, a hairline edge and a faint shadow under it.
struct PageToolbarBackground: ViewModifier {
    var isHovered = false
    @Environment(\.themeTokens) private var theme

    static let height: CGFloat = 36
    static let cornerRadius: CGFloat = 12

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: Corners.r(Self.cornerRadius), style: .continuous)
        content
            .frame(height: Self.height)
            .background(shape.fill(theme.text.opacity(isHovered ? 0.08 : 0.045)))
            .overlay(shape.strokeBorder(theme.text.opacity(0.05)))
            .shadow(color: .black.opacity(0.04), radius: 1, y: 1)
            .contentShape(shape)
            .animation(Motion.hover, value: isHovered)
    }
}

/// One button of the page toolbar: an icon on Craft's light grey rounded square, a shade darker while hovered.
struct PageToolbarButton: View {
    let title: String
    let symbol: String
    var size: CGFloat = 14
    var weight: Font.Weight = .medium
    /// The symbol's colour; the text's when nil.
    var tint: Color?
    let action: () -> Void
    @State private var isHovered = false
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.themeTokens) private var theme

    var body: some View {
        Button { action() } label: {
            Image(symbol: symbol)
                .font(.ui(size: size, weight: weight))
                .foregroundStyle(isEnabled ? tint ?? theme.text.opacity(0.8) : theme.secondaryText.opacity(0.5))
                .frame(width: 40)
                .modifier(PageToolbarBackground(isHovered: isHovered && isEnabled))
        }
        .buttonStyle(.plain)
        .pointerStyle(.link)
        .help(title)
        .accessibilityLabel(title)
        .onHover { isHovered = $0 }
    }
}

/// The view types a tab can switch between: each one that can open its resource and has an icon, the default
/// first. Nil when there is only one.
struct ViewSwitch {
    struct Choice: Identifiable {
        let id: String
        let title: String
        let symbol: String
    }

    let choices: [Choice]
    let current: String

    @MainActor
    init?(tab: WorkspaceModel.Tab, views: ViewRegistryStore) {
        // A collection (a folder, a `.base`) switches between its own views in its tabs (Kanban, Table, Gallery), not
        // between the collection and the plain folder grid.
        guard tab.resource.kind != .folder, !tab.resource.path.hasSuffix(".base") else { return nil }
        // A catch-all viewer (Quick Look, negative priority) stays in "Open with" but is no view of the page.
        let choices = views.viewTypes(for: tab.resource).filter { $0.priority >= 0 }.compactMap { type in
            type.symbol.map { Choice(id: type.id, title: type.title, symbol: $0) }
        }
        guard choices.count > 1, let current = WorkspaceController.viewType(for: tab, in: views)?.id else { return nil }
        self.choices = choices
        self.current = current
    }
}

/// Icons grouped on one toolbar square, as Craft groups its page controls, one per view of the page, the current one
/// shaded: Mindmap and Markdown for a mindmap note.
struct ViewSwitcher: View {
    let choices: [ViewSwitch.Choice]
    let selected: String
    let choose: (String) -> Void
    @Environment(\.themeTokens) private var theme

    var body: some View {
        HStack(spacing: 2) {
            ForEach(choices) { choice in
                let isSelected = choice.id == selected
                Button { choose(choice.id) } label: {
                    Image(symbol: choice.symbol)
                        .font(.ui(size: 14, weight: .medium))
                        .foregroundStyle(isSelected ? theme.text.opacity(0.8) : theme.secondaryText)
                        .frame(width: 32, height: 28)
                        .background(
                            RoundedRectangle(cornerRadius: Corners.r(8), style: .continuous)
                                .fill(isSelected ? theme.text.opacity(0.07) : .clear)
                        )
                        .contentShape(RoundedRectangle(cornerRadius: Corners.r(8), style: .continuous))
                }
                .buttonStyle(.plain)
                .pointerStyle(.link)
                .help("Show as \(choice.title)")
                .accessibilityLabel("Show as \(choice.title)")
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        .padding(.horizontal, 4)
        .modifier(PageToolbarBackground())
        .motion(.tap, value: selected)
    }
}
