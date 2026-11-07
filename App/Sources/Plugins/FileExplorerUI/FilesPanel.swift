import AppKit
import PluginKitUI
import SwiftUI

/// The "Folders" section of the left sidebar, under the title the shell draws: the transient error line, then the
/// top-level folders (the first five, then "N more folders") and the contents of the open ones. The notes at the
/// vault's root are not here: "All Notes" shows them.
///
/// The rows are `FolderTree` (AppKit), so a folder opening or the sidebar scrolling costs SwiftUI nothing but the
/// tree's height; the open folders live in the model and survive the section being rebuilt.
struct FoldersSection: View {
    @Bindable var model: ExplorerModel
    @Environment(\.themeTokens) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        rowsView
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
            let folderRows = model.folderRows
            FolderTree(model: model, state: FolderTreeView.State(
                rows: FolderTreeRow.rows(folderRows, model: model), selected: model.selected, renaming: model.renaming,
                stylingFolder: model.stylingFolder, cascade: model.cascadeIndex(in: folderRows), theme: theme))
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
                        ThemedEmoji(emoji: "⭐", size: 13, ink: onAccent ? theme.onAccent : nil)
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

/// How a folder's children come and go: they slide down a few points from under the folder and fade in, one after
/// the other, and leave together in a quick fade while the rows below slide up. No scale and no overshoot: text rows
/// that grow or bounce shimmer, and a disclosure in a Mac sidebar never does.
enum FolderUnfold {
    /// The rows below an opening or closing folder.
    static let slide = Motion.Spring.smooth.animation
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
