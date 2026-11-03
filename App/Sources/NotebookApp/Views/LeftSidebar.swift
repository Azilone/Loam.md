import AppKit
import PluginKitUI
import ImageIO
import SwiftUI
import PluginKit
import UniformTypeIdentifiers

/// The left sidebar, Craft's with Notion's "Customize": "New" at its head, the navigation rows plugins add, then their
/// sections (Favorites, Folders, Tags...) that fold and hide, and the vault at its foot, whose menu holds Settings,
/// Recently Deleted and "Customize". Customize swaps the content for the two lists to arrange
/// (`SidebarCustomizeView`); the choices go to the vault's config (`SidebarLayout`).
struct LeftSidebar: View {
    let session: ShellSession
    let workspace: WorkspaceController
    /// The left column's panels the user turned on in Settings > Sidebars (Search), under the sections.
    let panels: [Panel]
    /// The status bar slot's panels (the sync's state), drawn on the vault's icon and in its menu, so the pages and
    /// the window's corners are never shared with them.
    let statusBar: [Panel]
    let openSettings: () -> Void
    @State private var isCustomizing: Bool
    @State private var listHovered = false
    /// The list's tallest height since the pointer came in (`listHovered`).
    @State private var heldHeight: CGFloat = 0

    init(
        session: ShellSession, workspace: WorkspaceController, panels: [Panel], statusBar: [Panel] = [],
        openSettings: @escaping () -> Void, isCustomizing: Bool = false
    ) {
        self.session = session
        self.workspace = workspace
        self.panels = panels
        self.statusBar = statusBar
        self.openSettings = openSettings
        _isCustomizing = State(initialValue: isCustomizing)
    }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.themeTokens) private var theme

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                if isCustomizing {
                    SidebarCustomizeView(session: session) { setCustomizing(false) }
                        .transition(.opacity)
                } else {
                    content.transition(.opacity)
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)
        }
    }

    private var content: some View {
        VStack(spacing: 0) {
            NewMenuButton(pageKind: workspace.activeResource?.notesViewType)
                .padding(.horizontal, SidebarStyle.columnPadding)
                .padding(.top, 22)
                .padding(.bottom, 16)
            ScrollView {
                VStack(spacing: 0) {
                    SidebarLinksView(links: session.sidebarLayout.arranged(session.panels.links), workspace: workspace)
                    ForEach(session.sidebarLayout.arranged(session.sidebarSections(workspace: workspace)).filter { $0.isEmpty?() != true }) { section in
                        SidebarSectionView(section: section, layout: session.sidebarLayout)
                    }
                }
                .padding(.horizontal, SidebarStyle.columnPadding)
                .padding(.bottom, 8)
                // While the pointer is in the list it never gets shorter: a folder closed at the bottom of a scrolled
                // list would otherwise pull the rows down, and the row above the one clicked would land under the
                // pointer. The room left below goes when the pointer leaves.
                .onGeometryChange(for: CGFloat.self, of: \.size.height) { height in
                    if listHovered { heldHeight = max(heldHeight, height) }
                }
                .frame(minHeight: listHovered ? heldHeight : 0, alignment: .top)
            }
            .softScrollEdges()
            .frame(maxHeight: .infinity)
            .onHover { inside in
                listHovered = inside
                if !inside { heldHeight = 0 }
            }
            if !panels.isEmpty {
                SlotView(panels: panels, selectedID: workspace.chrome.leadingPanel) {
                    workspace.selectPanel($0, in: .leading)
                }
                .frame(maxHeight: .infinity)
            }
            // The vault, pinned under the list, its foot level with the pages': its menu holds Settings, Recently
            // Deleted and Customize, its icon the sync's dot.
            if let host = session.host {
                VaultSwitcher(session: session, host: host, statusBar: statusBar, openSettings: openSettings) {
                    setCustomizing(true)
                }
                .padding(.horizontal, SidebarStyle.columnPadding)
                .padding(.top, 8)
                .padding(.bottom, Glass.gap)
            }
        }
    }

    private func setCustomizing(_ on: Bool) {
        withAnimation(Motion.resolved(Motion.Spring.smooth.animation, reduceMotion: reduceMotion)) { isCustomizing = on }
    }

}

extension View {
    /// One of the sidebar's two pills, "New" at its head and the vault at its foot: a little taller than a row, its
    /// icon in the rows' icon column, round as the rows are under the theme's corners.
    func sidebarPill(_ fill: Color) -> some View {
        sidebarPill { $0.fill(fill) }
    }

    /// The pill printed in `ink`: a soft light from the top, the paper's grain and a cloud of light dots in its top
    /// corner, as the selected row's pill. For "New", the sidebar's one call to action.
    func sidebarPill(ink: Color) -> some View {
        sidebarPill { shape in
            ZStack {
                InkFill(shape, color: ink, grain: 0.1)
                HalftoneCloud(corner: .topTrailing, step: 2, seed: 53, color: .white.opacity(0.16))
                    .clipShape(shape)
                shape.strokeBorder(
                    LinearGradient(colors: [.white.opacity(0.22), .clear], startPoint: .top, endPoint: .center),
                    lineWidth: 1
                )
            }
            .shadow(color: ink.opacity(0.22), radius: 5, y: 2)
        }
    }

    private func sidebarPill<Fill: View>(@ViewBuilder _ fill: (RoundedRectangle) -> Fill) -> some View {
        let height = SidebarStyle.rowHeight + 6
        let shape = RoundedRectangle(cornerRadius: Corners.pill ? height / 2 : Corners.r(height / 2), style: .continuous)
        return font(.ui(size: SidebarStyle.fontSize, weight: .semibold))
            .padding(.horizontal, SidebarStyle.rowPadding)
            .frame(maxWidth: .infinity, minHeight: height)
            .background(fill(shape))
            .contentShape(shape)
    }
}

/// A section of the sidebar: its grey title with a chevron that folds it, then the plugin's rows.
private struct SidebarSectionView: View {
    let section: SidebarSection
    let layout: SidebarLayout
    @State private var isHovered = false
    @Environment(\.themeTokens) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let isCollapsed = layout.isCollapsed(section)
        VStack(alignment: .leading, spacing: 0) {
            SidebarSectionHeader(title: section.title, isCollapsed: isCollapsed, isHovered: isHovered) {
                withAnimation(Motion.resolved(Motion.Spring.smooth.animation, reduceMotion: reduceMotion)) {
                    try? layout.setCollapsed(section, !isCollapsed)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if let add = section.add {
                    Button {
                        // The new row shows at once, so a folded section opens first.
                        if isCollapsed { try? layout.setCollapsed(section, false) }
                        add.action()
                    } label: {
                        Image(symbol: "plus")
                            .font(.ui(size: 11, weight: .semibold))
                            .foregroundStyle(theme.secondaryText)
                            .frame(width: 18, height: 18)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(add.title.uiLocalized)
                    .accessibilityLabel(add.title.uiLocalized)
                    // Left of the chevron, on the title's baseline row; shown while the title is hovered.
                    .padding(.trailing, SidebarStyle.rowPadding + 14)
                    .padding(.bottom, 4)
                    .opacity(isHovered ? 0.9 : 0)
                }
            }
            .onHover { isHovered = $0 }
            .animation(Motion.hover, value: isHovered)
            if !isCollapsed {
                section.makeView()
                    .transition(.opacity.combined(with: .offset(y: -6)))
            }
        }
        .clipped()
    }
}

/// The navigation group (Craft's "All Docs", "Tasks", "Calendar"): the five main links as rows, then a "Tools" section,
/// folded by default, holding the others. The row of the active resource is raised; a click opens it in the focused tab. The
/// order inside each group is the user's (Customize).
struct SidebarLinksView: View {
    let links: [SidebarLink]
    let workspace: WorkspaceController
    /// Whether the Tools group is open, read once from the defaults (not `@AppStorage`: the sidebar redraws with every
    /// note opened, and a defaults observer per redraw is not worth a toggle).
    @State private var toolsOpen = UserDefaults.standard.bool(forKey: SidebarLinksView.toolsOpenKey)
    @Environment(\.themeTokens) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let toolsOpenKey = "sidebar.toolsOpen"
    /// The links that are rows of their own; every other link is a tool.
    static let primaryIDs: Set<String> = [
        "explorer.all-notes", "tasks.link", "projects.link", "daily.calendar-link", "habits.link",
    ]

    var body: some View {
        let primary = links.filter { Self.primaryIDs.contains($0.id) }
        let tools = links.filter { !Self.primaryIDs.contains($0.id) }
        // The page on screen belongs to a tool: the group stays open, so the selected row is in sight.
        let isForcedOpen = tools.contains { workspace.activeResource == $0.resource }
        let isOpen = toolsOpen || isForcedOpen
        VStack(spacing: 0) {
            ForEach(primary) { row($0) }
            if !tools.isEmpty {
                ToolsRow(tools: tools, isOpen: isOpen) {
                    withAnimation(Motion.resolved(Motion.Spring.smooth.animation, reduceMotion: reduceMotion)) {
                        toolsOpen = !isOpen
                    }
                    UserDefaults.standard.set(toolsOpen, forKey: Self.toolsOpenKey)
                }
                if isOpen {
                    VStack(spacing: 0) { ForEach(tools) { row($0) } }
                        .transition(.opacity.combined(with: .offset(y: -6)))
                }
            }
        }
        .clipped()
    }

    private func row(_ link: SidebarLink) -> some View {
        SidebarRow(
            title: link.title.uiLocalized, symbol: link.symbol, count: link.count?(),
            isSelected: workspace.activeResource == link.resource
        ) {
            if let action = link.action { action() } else { workspace.open(link.resource, placement: .replace) }
        }
        .equatable()
    }
}

/// "Tools": a small dim label, the mini icons of the links it holds and a chevron, under the main rows.
/// "Tools": a section title like the others, with the mini icons of the links it holds while it is folded.
private struct ToolsRow: View {
    let tools: [SidebarLink]
    let isOpen: Bool
    let toggle: () -> Void
    @State private var isHovered = false

    var body: some View {
        SidebarSectionHeader(title: "Tools", isCollapsed: !isOpen, isHovered: isHovered, toggle: toggle) {
            if !isOpen {
                HStack(spacing: 7) {
                    ForEach(tools) { Image(symbol: $0.symbol).font(.ui(size: 12, weight: .medium)) }
                }
                .padding(.leading, 4)
                .transition(.opacity)
            }
        }
        .onHover { isHovered = $0 }
        .animation(Motion.hover, value: isHovered)
    }
}

/// The title of a sidebar section (Folders, Tags, Tools): small capitals in the theme's label face, dimmer than the
/// rows, with the chevron that folds it at its end; anything `accessory` adds sits after the title.
struct SidebarSectionHeader<Accessory: View>: View {
    let title: String
    let isCollapsed: Bool
    let isHovered: Bool
    let toggle: () -> Void
    @ViewBuilder var accessory: Accessory
    @Environment(\.themeTokens) private var theme

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 0) {
                Text(title.uiLocalized)
                    .themeLabel(size: SidebarStyle.sectionFontSize, weight: .semibold)
                accessory
                Spacer(minLength: 0)
                Image(symbol: "chevron.right")
                    .font(.ui(size: 9, weight: .semibold))
                    .rotationEffect(.degrees(isCollapsed ? 0 : 90))
                    .opacity(isHovered ? 0.9 : 0.45)
            }
            .foregroundStyle(theme.secondaryText.opacity(SidebarStyle.sectionTitleOpacity))
            .padding(.horizontal, SidebarStyle.rowPadding)
            .padding(.top, SidebarStyle.sectionGap)
            .padding(.bottom, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isCollapsed ? "Show \(title)" : "Hide \(title)")
    }
}

extension SidebarSectionHeader where Accessory == EmptyView {
    init(title: String, isCollapsed: Bool, isHovered: Bool, toggle: @escaping () -> Void) {
        self.init(title: title, isCollapsed: isCollapsed, isHovered: isHovered, toggle: toggle) { EmptyView() }
    }
}

/// A row of the shell's part of the sidebar, drawn as the plugins' sections draw theirs (`sidebarRow`). Equal when
/// it draws the same: opening a note redraws only the rows whose selection changed (the action is a new closure each
/// time, for the same link).
struct SidebarRow: View, Equatable {
    let title: String
    let symbol: String
    var count: Int?
    let isSelected: Bool
    let open: () -> Void
    @Environment(\.themeTokens) private var theme

    var body: some View {
        // A button, so VoiceOver and keyboard access press it too.
        Button { open() } label: {
            HStack(spacing: SidebarStyle.iconGap) {
                SidebarIcon(symbol, color: theme.sidebarAccessory(selected: isSelected), ground: theme.sidebarGround(selected: isSelected))
                    .frame(width: SidebarStyle.iconSize)
                Text(title.uiLocalized).lineLimit(1)
                Spacer(minLength: 0)
                // Only counts that ask for attention are given (overdue tasks, meetings processing): a small pill.
                if let count, count > 0 {
                    Text("\(count)")
                        .font(.ui(size: 11.5, weight: .semibold))
                        .foregroundStyle(isSelected ? Color.white : theme.accent)
                        .padding(.horizontal, 7)
                        .frame(minWidth: 20, minHeight: 20)
                        .background(Capsule().fill(isSelected ? Color.white.opacity(0.22) : theme.accent.opacity(0.16)))
                }
            }
            .sidebarRow(isSelected: isSelected)
        }
        .buttonStyle(.plain)
    }

    nonisolated static func == (lhs: SidebarRow, rhs: SidebarRow) -> Bool {
        lhs.title == rhs.title && lhs.symbol == rhs.symbol && lhs.count == rhs.count && lhs.isSelected == rhs.isSelected
    }
}

// MARK: - Customize

/// The sidebar's Customize mode (Notion's): the navigation rows and the sections as cards, each with a grip to drag
/// it into place and a switch to show or hide it, then "Done".
struct SidebarCustomizeView: View {
    let session: ShellSession
    let done: () -> Void
    @State private var notice: String?
    @Environment(\.themeTokens) private var theme

    var body: some View {
        let layout = session.sidebarLayout
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if let notice {
                        Text(notice).font(.ui(.label)).foregroundStyle(.orange).padding(.bottom, 6)
                    }
                    groupTitle("Navigation")
                    ReorderableCards(
                        items: layout.arranged(session.panels.links, all: true).map {
                            CardItem(id: $0.id, title: $0.title.uiLocalized, isOn: layout.isShown($0))
                        },
                        toggle: { id, on in
                            if let link = session.panels.links.first(where: { $0.id == id }) {
                                save { try layout.set(link, shown: on) }
                            }
                        },
                        reorder: { ids in save { try layout.reorderLinks(ids) } }
                    )
                    groupTitle("Sections")
                    let sections = session.sidebarSections(workspace: session.workspace)
                    ReorderableCards(
                        items: layout.arranged(sections, all: true).map { section in
                            CardItem(id: section.id, title: section.title.uiLocalized, isOn: layout.isShown(section),
                                     pin: layout.pinned.first { $0.sectionID == section.id })
                        },
                        toggle: { id, on in
                            if let section = sections.first(where: { $0.id == id }) {
                                save { try layout.set(section, shown: on) }
                            }
                        },
                        reorder: { ids in save { try layout.reorderSections(ids) } },
                        remove: { pin in save { try layout.remove(pin) } }
                    )
                    AddPinnedSectionMenu(session: session) { pin in save { try layout.add(pin) } }
                }
                .padding(.horizontal, SidebarStyle.columnPadding)
                .padding(.bottom, 12)
            }
            .softScrollEdges()
            Button(action: done) {
                Text("Done")
                    .font(.ui(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 38)
                    .background(RoundedRectangle(cornerRadius: Corners.r(10), style: .continuous).fill(theme.accent))
                    .contentShape(RoundedRectangle(cornerRadius: Corners.r(10), style: .continuous))
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.defaultAction)
            .padding(.horizontal, SidebarStyle.columnPadding)
            .padding(.top, 8)
            .padding(.bottom, 14)
        }
    }

    private func groupTitle(_ title: String) -> some View {
        Text(title.uiLocalized)
            .font(.ui(size: 13, weight: .medium))
            .foregroundStyle(theme.secondaryText)
            .padding(.horizontal, 8)
            .padding(.top, 12)
            .padding(.bottom, 6)
    }

    private func save(_ change: () throws -> Void) {
        do {
            notice = nil
            try change()
        } catch {
            notice = "Could not save: \(String(describing: error))"
        }
    }
}

struct CardItem: Identifiable, Equatable {
    let id: String
    let title: String
    let isOn: Bool
    /// The folder or tag of a section the user added, which its menu can remove.
    var pin: SidebarLayout.Pin?
}

/// "+ Section from a folder or tag": a menu of the vault's folders and tags; the one picked becomes a section.
private struct AddPinnedSectionMenu: View {
    let session: ShellSession
    let add: (SidebarLayout.Pin) -> Void
    @Environment(\.themeTokens) private var theme

    var body: some View {
        let notes = session.runtime.kernel.services.service(.noteQuery)?.run(NoteQuery()) ?? []
        let pinned = Set(session.sidebarLayout.pinned)
        let folders = Set(notes.map { VaultPath.directory(of: $0.path) }.filter { !$0.isEmpty })
            .map { SidebarLayout.Pin(kind: .folder, value: $0) }
            .filter { !pinned.contains($0) }
            .sorted { $0.value.localizedCaseInsensitiveCompare($1.value) == .orderedAscending }
        let tags = Dictionary(grouping: notes.flatMap(\.tags), by: { $0.lowercased() }).values.compactMap(\.first)
            .map { SidebarLayout.Pin(kind: .tag, value: $0) }
            .filter { !pinned.contains($0) }
            .sorted { $0.value.localizedCaseInsensitiveCompare($1.value) == .orderedAscending }
        Menu {
            Section("Folders") {
                ForEach(folders, id: \.self) { pin in
                    Button { add(pin) } label: { Label(pin.value, symbol: "folder") }
                }
            }
            Section("Tags") {
                ForEach(tags, id: \.self) { pin in
                    Button { add(pin) } label: { Label(pin.title, symbol: "number") }
                }
            }
        } label: {
            Text("+ Section from a folder or tag")
                .font(.ui(size: 13))
                .foregroundStyle(theme.accent)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .padding(.horizontal, 10)
        .padding(.top, 12)
        .disabled(folders.isEmpty && tags.isEmpty)
    }
}

/// The rows of a section the user added: the notes of its folder (and below) or of its tag, the last changed first.
struct PinnedSectionView: View {
    let pin: SidebarLayout.Pin
    let session: ShellSession
    let workspace: WorkspaceController
    @Environment(\.themeTokens) private var theme

    static let limit = 8

    var body: some View {
        let query = pin.kind == .folder
            ? NoteQuery(folder: pin.value, sort: [SortKey(key: "modified", descending: true)], limit: Self.limit)
            : NoteQuery(tags: [pin.value], sort: [SortKey(key: "modified", descending: true)], limit: Self.limit)
        let notes = session.runtime.kernel.services.service(.noteQuery)?.run(query) ?? []
        if notes.isEmpty {
            Text("No notes here yet")
                .font(.ui(size: 12))
                .foregroundStyle(theme.secondaryText)
                .padding(.horizontal, SidebarStyle.rowPadding)
                .padding(.vertical, 4)
        } else {
            VStack(spacing: 0) {
                ForEach(notes, id: \.path) { note in
                    SidebarRow(title: note.title, symbol: "doc.text", isSelected: workspace.activeResource == .file(note.path)) {
                        workspace.open(.file(note.path), placement: .replace)
                    }
                }
            }
        }
    }
}

extension ShellSession {
    /// The plugins' sections and the ones the user added from a folder or a tag.
    func sidebarSections(workspace: WorkspaceController) -> [SidebarSection] {
        let pinned = sidebarLayout.pinned.map { pin in
            SidebarSection(id: pin.sectionID, title: pin.title, order: 1000) { [self] in
                AnyView(PinnedSectionView(pin: pin, session: self, workspace: workspace))
            }
        }
        return panels.sections + pinned
    }
}

/// Cards stacked one under the other that a drag puts in another order: the dragged card takes the place of the
/// one under the pointer as it moves, and the order is saved on drop.
private struct ReorderableCards: View {
    let items: [CardItem]
    let toggle: (String, Bool) -> Void
    let reorder: ([String]) -> Void
    var remove: (SidebarLayout.Pin) -> Void = { _ in }
    @State private var order: [String]?
    @State private var dragging: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let byID = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let ids = (order ?? items.map(\.id)).filter { byID[$0] != nil }
        VStack(spacing: 6) {
            ForEach(ids, id: \.self) { id in
                if let item = byID[id] {
                    CustomizeCard(item: item, isDragged: dragging == id) { toggle(id, $0) }
                        .contextMenu {
                            if let pin = item.pin {
                                Button("Remove Section", role: .destructive) { remove(pin) }
                            }
                        }
                        .onDrag {
                            dragging = id
                            order = ids
                            return NSItemProvider(object: id as NSString)
                        }
                        .onDrop(of: [.text], delegate: CardDropDelegate(
                            target: id, dragging: $dragging, order: $order,
                            animation: Motion.resolved(Motion.Spring.standard.animation, reduceMotion: reduceMotion)
                        ) { reorder($0) })
                }
            }
        }
    }
}

private struct CardDropDelegate: DropDelegate {
    let target: String
    @Binding var dragging: String?
    @Binding var order: [String]?
    let animation: Animation
    let commit: ([String]) -> Void

    func dropEntered(info: DropInfo) {
        guard let dragging, dragging != target, var ids = order,
              let from = ids.firstIndex(of: dragging), let to = ids.firstIndex(of: target) else { return }
        ids.move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to)
        withAnimation(animation) { order = ids }
        Haptics.alignment()
    }

    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }

    func performDrop(info: DropInfo) -> Bool {
        if let order { commit(order) }
        dragging = nil
        order = nil
        return true
    }
}

/// A row of Customize: a grip, the title, a switch; greyed on a bare card while off.
private struct CustomizeCard: View {
    let item: CardItem
    let isDragged: Bool
    let set: (Bool) -> Void
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.themeTokens) private var theme

    var body: some View {
        HStack(spacing: 10) {
            // The grip: two columns of three dots.
            Grid(horizontalSpacing: 2.5, verticalSpacing: 2.5) {
                ForEach(0..<3, id: \.self) { _ in
                    GridRow { ForEach(0..<2, id: \.self) { _ in Circle().frame(width: 2.5, height: 2.5) } }
                }
            }
            .foregroundStyle(theme.text.opacity(0.28))
            .frame(width: 10)
            .accessibilityHidden(true)
            Text(item.title)
                .font(.ui(size: SidebarStyle.fontSize))
                .foregroundStyle(item.isOn ? theme.text.opacity(SidebarStyle.titleOpacity) : theme.secondaryText.opacity(0.6))
                .lineLimit(1)
            Spacer(minLength: 0)
            // The loam style draws its label beside the switch, so it gets none: the title is already on the left.
            Toggle(isOn: Binding(get: { item.isOn }, set: set)) { EmptyView() }
                .accessibilityLabel(item.title)
                .toggleStyle(.loam)
        }
        .padding(.horizontal, 12)
        .frame(height: 40)
        .background {
            let shape = RoundedRectangle(cornerRadius: Corners.r(10), style: .continuous)
            if item.isOn {
                shape.fill(colorScheme == .dark ? Color.white.opacity(0.08) : .white)
                    .shadow(color: .black.opacity(isDragged ? 0.12 : 0.04), radius: isDragged ? 6 : 1, y: isDragged ? 3 : 0.5)
            } else {
                shape.strokeBorder(theme.text.opacity(0.08))
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: Corners.r(10), style: .continuous))
        .opacity(isDragged ? 0.6 : 1)
    }
}

