import AppKit
import PluginKitUI
import SwiftUI

/// The "Folders" section of the left sidebar, under the title the shell draws: the transient error line, then the
/// top-level folders (the first five, then "N more folders") and the contents of the open ones. The notes at the
/// vault's root are not here: "All Notes" shows them.
///
/// A flat list of the visible rows (indented by depth) rather than `OutlineGroup`, so the open folders live in the
/// model and survive the section being rebuilt.
struct FoldersSection: View {
    @Bindable var model: ExplorerModel
    @Environment(\.themeTokens) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        // The reader reaches the sidebar's scroll view, which holds this section.
        ScrollViewReader { proxy in
            rowsView
                .onChange(of: model.renaming) { _, path in
                    // A new folder may land below the fold: bring its name field into sight.
                    guard let path else { return }
                    DispatchQueue.main.async {
                        Motion.with(Motion.Spring.smooth.animation) { proxy.scrollTo(path, anchor: nil) }
                    }
                }
        }
    }

    private var rowsView: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let message = model.message {
                Text(message.uiLocalized)
                    .font(.ui(.body))
                    .foregroundStyle(theme.text)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(theme.spacing.medium)
                    .background(RoundedRectangle(cornerRadius: Corners.r(8)).fill(Color.orange.opacity(0.15)))
            }
            let rows = model.folderRows
            let cascade = model.cascadeIndex(in: rows)
            let selected = model.selected
            ForEach(rows) { row in
                // The selection is read here and handed down, so a note opened elsewhere redraws the two rows whose
                // state changed instead of every row that read `selected`.
                TreeRow(model: model, row: row, isSelected: selected == row.item.path)
                    .id(row.id)
                    .transition(reduceMotion ? .opacity : FolderUnfold.transition(index: cascade[row.id]))
            }
            if model.hiddenFolderCount > 0 {
                MoreFoldersRow(count: model.hiddenFolderCount) {
                    Motion.with(FolderUnfold.slide) { model.showsAllFolders = true }
                }
            }
        }
        // Folders open and close smoothly, every time, as in Craft.
        .animation(reduceMotion ? Motion.fade : FolderUnfold.slide, value: model.expanded)
        .contentShape(Rectangle())
        .onDrop(of: [DragPayload.type], isTargeted: nil) { providers in
            dropResource(providers, model: model, folder: "")
        }
        .contextMenu {
            Button("New Folder") { model.newFolder(in: "") }
            Button("Collapse All Folders") { model.collapseAll() }
            if model.showsAllFolders, model.topFolders.count > ExplorerModel.folderLimit {
                Button("Show Fewer Folders") { model.showsAllFolders = false }
            }
            Button("Refresh") { model.refresh() }
        }
        .alert(
            deleteTitle,
            isPresented: Binding(
                get: { model.pendingDelete != nil },
                set: { shown in if !shown { model.pendingDelete = nil } }
            )
        ) {
            Button("Move to Recently Deleted", role: .destructive) { model.confirmDelete() }
            Button("Cancel", role: .cancel) { model.pendingDelete = nil }
        } message: {
            Text(deleteMessage)
        }
    }

    private var deleteMessage: String {
        switch model.trashRetentionDays() {
        case .some(let days) where days > 0:
            return "You can get it back from Recently Deleted for \(days == 1 ? "1 day" : "\(days) days")."
        default:
            return "You can get it back from Recently Deleted."
        }
    }

    private var deleteTitle: String {
        let name = model.pendingDelete.map { ExplorerModel.lastComponent($0) } ?? ""
        return "Move “\(name)” to Recently Deleted?"
    }
}

/// "4 more folders", in grey under the first five: a click lists them all.
private struct MoreFoldersRow: View {
    let count: Int
    let action: () -> Void
    @Environment(\.themeTokens) private var theme

    var body: some View {
        HStack(spacing: SidebarStyle.iconGap) {
            SidebarIcon("ellipsis", color: theme.secondaryText.opacity(0.8), ground: theme.sidebarGround(selected: false))
                .frame(width: SidebarStyle.iconSize)
            Text(count == 1 ? "1 more folder" : "\(count) more folders")
                .foregroundStyle(theme.secondaryText)
            Spacer(minLength: 0)
        }
        .sidebarRow(isSelected: false)
        .tappableRow(action)
    }
}

/// The "Favorites" section: the starred notes and folders, a star before each; a row's menu unstars it.
struct FavoritesSection: View {
    let model: ExplorerModel
    @Environment(\.themeTokens) private var theme

    var body: some View {
        let items = model.favoriteItems
        // Nothing starred: the sidebar leaves the whole section out (`SidebarSection.isEmpty`).
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(items) { item in
                    HStack(spacing: SidebarStyle.iconGap) {
                        let onAccent = model.selected == item.path
                        ThemedEmoji(emoji: "⭐", size: 13, ink: onAccent ? .white : nil)
                            .frame(width: SidebarStyle.iconSize)
                        Text(model.title(of: item)).lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .sidebarRow(isSelected: model.selected == item.path)
                    .tappableRow { model.click(item, newTab: commandKeyDown()) }
                    .draggableResource(item.resource, row: item.kind == .folder ? "folder" : model.symbol(forNote: item.path))
                    .contextMenu {
                        Button("Remove from Favorites") { model.toggleFavorite(item.path) }
                    }
                }
            }
        }
    }
}

/// The "Recent" section: the notes changed last.
struct RecentSection: View {
    let model: ExplorerModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(model.recent) { note in
                RecentRow(model: model, note: note)
            }
        }
    }
}

/// A note of the "Recent" section.
private struct RecentRow: View {
    let model: ExplorerModel
    let note: ExplorerModel.Recent
    @Environment(\.themeTokens) private var theme

    var body: some View {
        HStack(spacing: SidebarStyle.iconGap) {
            SidebarIcon("clock", color: theme.secondaryText, ground: theme.sidebarGround(selected: false)).frame(width: SidebarStyle.iconSize)
            Text(note.title).lineLimit(1)
            if !note.folder.isEmpty {
                Text(note.folder).lineLimit(1).font(.ui(.caption)).foregroundStyle(theme.secondaryText)
            }
            Spacer(minLength: 0)
        }
        .sidebarRow(isSelected: false)
        .tappableRow { model.open(note.path, newTab: commandKeyDown()) }
        .draggableResource(.file(note.path), row: model.symbol(forNote: note.path))
    }
}

/// A row of the tree: a folder (with its chevron), a note or an attachment.
private struct TreeRow: View {
    @Bindable var model: ExplorerModel
    let row: ExplorerModel.Row
    let isSelected: Bool
    @Environment(\.themeTokens) private var theme
    @State private var targeted = false
    @State private var hovered = false
    @FocusState private var nameFocused: Bool

    private var item: ExplorerModel.Item { row.item }
    private var isFolder: Bool { item.kind == .folder }
    /// Where a drop on this row goes: the folder itself, or the folder a file is in.
    private var dropFolder: String { isFolder ? item.path : VaultPath.directory(of: item.path) }

    var body: some View {
        // The icon where the navigation rows have theirs and the title after the same gap, so the sidebar has one
        // column of icons; a folder's chevron is at the end, as the sections' titles have theirs.
        HStack(spacing: SidebarStyle.iconGap) {
            Group {
                if isFolder, let pose = folderPose {
                    // The default folder opens like Arc's.
                    AnimatedFolderIcon(pose: pose, color: folderInk, ground: folderGround)
                } else if isFolder, let drawn = drawnFolderSymbol {
                    // A plugin's folder (the attachments, the daily notes) in the sidebar's drawn icons, open with it.
                    SidebarIcon(drawn, color: folderInk, ground: folderGround, active: model.expanded.contains(item.path) || isSelected)
                } else if isFolder {
                    FolderIconView(
                        model.icon(forFolder: item.path, open: model.expanded.contains(item.path)),
                        color: FolderTint.color(for: item.path),
                        onAccent: isSelected
                    )
                } else {
                    SidebarIcon(symbol, color: theme.sidebarAccessory(selected: isSelected), ground: theme.sidebarGround(selected: isSelected))
                }
            }
            .frame(width: SidebarStyle.iconSize)
            .popover(isPresented: stylingBinding, arrowEdge: .trailing) {
                FolderStylePicker(model: model, path: item.path)
            }
            if model.renaming == item.path {
                TextField("Name", text: $model.renameText)
                    .textFieldStyle(.roundedBorder)
                    .focused($nameFocused)
                    .onSubmit { model.commitRename() }
                    .onExitCommand { model.cancelRename() }
                    .onAppear { nameFocused = true }
                    // Leaving the field (a click in the page, another window) keeps the name, as Finder does.
                    .onChange(of: nameFocused) { if !nameFocused, model.renaming == item.path { model.commitRename() } }
            } else {
                Text(model.title(of: item)).lineLimit(1)
            }
            Spacer(minLength: 0)
            if isFolder {
                // Every folder the same, whatever its icon: the chevron shows under the pointer and while the folder
                // is open, so a closed list stays calm and an open one says how to close it.
                let open = model.expanded.contains(item.path)
                Image(symbol: "chevron.right")
                    .font(.ui(size: 11, weight: .semibold))
                    .foregroundStyle(theme.sidebarAccessory(selected: isSelected).opacity(0.6))
                    .rotationEffect(.degrees(open ? 90 : 0))
                    .motion(.tap, value: open)
                    .frame(width: 10)
                    .opacity(hovered || open ? 1 : 0)
                    .motion(Motion.fade, value: hovered)
            }
        }
        // A child's icon under its parent's title.
        .padding(.leading, CGFloat(row.depth) * (SidebarStyle.iconSize + SidebarStyle.iconGap))
        .sidebarRow(isSelected: isSelected, isTargeted: targeted && isFolder)
        .onHover { hovered = $0 }
        .tappableRow { model.click(item, newTab: commandKeyDown()) }
        .draggableResource(item.resource, row: isFolder ? "folder" : symbol)
        .onDrop(of: [DragPayload.type], isTargeted: $targeted) { providers in
            dropResource(providers, model: model, folder: dropFolder)
        }
        .onChange(of: targeted) {
            guard targeted, isFolder else { return }
            Haptics.alignment()
            // A closed folder held under a drag opens after a moment, as in Finder, so a note can go deeper.
            let path = item.path
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(700))
                guard targeted, !model.expanded.contains(path) else { return }
                model.toggle(path)
            }
        }
        .contextMenu {
            Button("New Note") { model.newNote(in: dropFolder) }
            ForEach(model.newItems()) { item in
                Button { item.create(ExplorerModel.newNoteFolder(dropFolder)) } label: {
                    Label(item.title, symbol: item.symbol)
                }
            }
            Button("New Folder") { model.newFolder(in: dropFolder) }
            Divider()
            if isFolder {
                Button("Icon & Color…") { model.stylingFolder = item.path }
            }
            Button(model.isFavorite(item.path) ? "Remove from Favorites" : "Add to Favorites") {
                model.toggleFavorite(item.path)
            }
            let actions = model.actions(item.resource)
            if !actions.isEmpty {
                Divider()
                ForEach(actions) { action in
                    Button { action.perform(item.resource) } label: { Label(action.title, symbol: action.symbol) }
                }
            }
            Divider()
            Button("Rename") { model.beginRename(item.path) }
            Button("Move to…") { model.askMove(item.path) }
            Button("Reveal in Finder") { model.revealInFinder(item.path) }
            Divider()
            Button("Delete…", role: .destructive) { model.requestDelete(item.path) }
        }
    }

    /// How the opening folder stands: open with its children shown, half open under the pointer or a drag. Nil when
    /// the folder has an icon of its own (the user's, a plugin's), drawn as it is.
    private var folderPose: AnimatedFolderIcon.Pose? {
        let open = model.expanded.contains(item.path)
        guard case .symbol(let name) = model.icon(forFolder: item.path, open: open), name.hasPrefix("folder") else {
            return nil
        }
        if open { return .open }
        return hovered || targeted ? .peek : .closed
    }

    /// The symbol a plugin gives this folder, when the sidebar draws it (`SidebarGlyph`).
    private var drawnFolderSymbol: String? {
        guard case .symbol(let name) = model.icon(forFolder: item.path, open: false), !name.hasPrefix("folder"),
              SidebarGlyph.named(for: name) != nil else { return nil }
        return name
    }

    /// The folder's colour: the one the user gave it, else the grey of the sidebar's other icons; white when selected.
    private var folderInk: Color {
        if isSelected { return .white.opacity(0.9) }
        return FolderTint.custom(for: item.path) ?? theme.sidebarAccessory(selected: false)
    }

    /// What the folder sits on: the accent when selected, else the sidebar.
    private var folderGround: Color {
        if isSelected { return theme.accent }
        return theme.palette.sidebar.map(Color.init) ?? Color(nsColor: .windowBackgroundColor)
    }

    /// A note's or a file's icon.
    private var symbol: String {
        item.kind == .note ? model.symbol(forNote: item.path) : model.symbol(forFile: item.path)
    }

    private var stylingBinding: Binding<Bool> {
        Binding(
            get: { model.stylingFolder == item.path },
            set: { shown in if !shown, model.stylingFolder == item.path { model.stylingFolder = nil } }
        )
    }
}

/// How a folder's children come and go: they slide down a few points from under the folder and fade in, one after
/// the other, and leave together in a quick fade while the rows below slide up. No scale and no overshoot: text rows
/// that grow or bounce shimmer, and a disclosure in a Mac sidebar never does.
enum FolderUnfold {
    /// The rows below an opening or closing folder.
    static let slide = Motion.Spring.smooth.animation

    static func transition(index: Int?) -> AnyTransition {
        let insertion = AnyTransition.opacity
            .combined(with: .offset(y: -4))
            .animation(Motion.Spring.smooth.animation.delay(Motion.stagger(index: index ?? 0)))
        let removal = AnyTransition.opacity.animation(Motion.exit)
        return .asymmetric(insertion: insertion, removal: removal)
    }
}

private func commandKeyDown() -> Bool {
    NSEvent.modifierFlags.contains(.command)
}

/// Reads the dragged resource and moves it into `folder`. Returns whether the drop is taken.
@MainActor
private func dropResource(_ providers: [NSItemProvider], model: ExplorerModel, folder: String) -> Bool {
    guard let provider = providers.first else { return false }
    DragPayload.load(from: provider) { payload in
        if let payload { model.drop(payload, into: folder) }
    }
    return true
}
