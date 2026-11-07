import AppKit
import PluginKitUI
import SwiftUI

/// The Markdown editor: the view for `.md` files and the `editor` service (slash items, insert at caret, live
/// text of open notes, reveal a line), and `DocumentTextChanged` while typing.
/// An essential plugin; another editor can replace it by providing `editor` and a view type for `.md`.
public final class MarkdownEditorPlugin: UIPlugin {
    public static let manifest = PluginManifest(
        id: "markdown-editor",
        name: "Markdown editor",
        version: "1.0",
        description: "Markdown that looks right as you type, with the / menu.",
        icon: "text.cursor",
        provides: ["editor"],
        optionalRequires: ["note-graph", "daily-notes"],
        permissions: ["ui", "vault.read", "vault.write", "clipboard"]
    )

    public static let viewTypeID = "markdown.editor"

    private var service: MarkdownEditorService?

    public init() {}

    @MainActor public func activateUI(context: PluginContext) throws {
        let documents = DocumentStore(vault: context.vault)
        documents.textChanged = { [weak context] path in context?.emit(DocumentTextChanged(path: path)) }
        let service = MarkdownEditorService(documents: documents, workspace: { [weak context] in context?.workspace })
        service.selectionChanged = { [weak context] path, text in context?.emit(EditorSelectionChanged(path: path, text: text)) }
        service.noteHeaders = context.service(.noteHeaders)
        service.dailyNotes = { [weak context] in context?.service(.dailyNotes) }
        service.views = { [weak context] in context?.service(.views) }
        service.noteGraph = { [weak context] in context?.service(.noteGraph) }
        service.moveNote = { [weak context] from, to in
            guard let context else { return }
            if documents.isDraft(from) {
                // Nothing on disk to move: the open note follows, and so do the tabs showing it.
                guard !context.vault.exists(to), !documents.isDraft(to) else { throw VaultError.alreadyExists(path: to) }
                context.emit(NotesWillMove(moves: [from: to]))
                documents.didMove([from: to])
                context.emit(NotesMoved(moves: [from: to]))
                return
            }
            if let graph = context.service(.noteGraph) {
                _ = try graph.move([from: to])
            } else {
                context.emit(NotesWillMove(moves: [from: to]))
                try context.vault.move(from, to: to)
                context.emit(NotesMoved(moves: [from: to]))
            }
        }
        self.service = service
        try context.provide(.editor, service as any EditorService)

        try context.registerCommand(Command(
            id: "editor.toggle-source",
            title: "Markdown: view source",
            summary: "Shows the active note's Markdown as written (syntax visible), or the page again. The file is the "
                + "same either way; only how the editor shows it changes.",
            shortcut: KeyShortcut("u", [.command, .shift])
        ) { _ in
            try await MainActor.run {
                guard let source = service.toggleSource() else { throw MarkdownEditorError.noActiveEditor }
                return source ? "source" : "page"
            }
        })

        var markdown = ViewType(
            id: Self.viewTypeID,
            title: "Markdown",
            priority: 0,
            symbol: "doc.text",
            canOpen: { resource in Self.canOpen(resource) },
            makeView: { viewContext in AnyView(MarkdownTabView(viewContext: viewContext, service: service)) }
        )
        // A link or a sidebar row swaps the text in the same editor instead of making a new one (a TextKit stack, its
        // panels, a page of SwiftUI): the note is on screen sooner.
        markdown.followsResource = true
        try context.registerView(markdown)
        // The `/` menu's blocks as tiles, the last tab of a note's right sidebar.
        try context.addInspectorSection(InspectorSection(
            id: "markdown.insert", placement: .tab(InspectorPage(id: "markdown.insert", title: "Insert", order: 40)),
            viewTypes: [Self.viewTypeID], appliesTo: { _ in true }
        ) { _ in
            AnyView(InsertInspector(items: service.menuItems) { service.insert($0) })
        })

        context.on(VaultChanged.self) { [weak documents, weak service] event in
            let changes = event.changes
            // Worked out on the main thread: a closure written here is the main actor's, and a command's write
            // announces its changes from the thread it ran on.
            MainThread.run {
                documents?.vaultChanged(changes)
                service?.forgetEmbedKeys()
                if changes.contains(where: { $0.kind != .modified }) { service?.forgetFileStamps() }
            }
        }
        // Writes by other plugins (a task toggled, a property set, a line appended) never lose unsaved typing, nor
        // get overwritten by it: a reader gets the user's latest text, and a writer's change shows at once. The
        // editor's own reads and saves come back with its id and are ignored. Reads may come from any thread (a
        // command), hence `@Sendable`; only a note that is open is worth a hop to the main thread.
        let ownID = Self.manifest.id
        let openPaths = documents.openPathSet
        context.on(NoteWillRead.self) { @Sendable [weak documents] event in
            guard event.pluginID != ownID, openPaths.contains(event.path) else { return }
            let path = event.path
            MainThread.run { documents?.willRead(path) }
        }
        context.on(NoteDidChange.self) { @Sendable [weak documents] event in
            guard event.pluginID != ownID, openPaths.contains(event.path) else { return }
            let path = event.path
            MainThread.run { documents?.didChange(path) }
        }
        context.on(NotesWillMove.self) { [weak documents] event in
            let moves = event.moves
            MainThread.run { documents?.willMove(moves) }
        }
        context.on(NotesMoved.self) { [weak documents] event in
            let moves = event.moves
            MainThread.run { documents?.didMove(moves) }
        }

        // Saves when the user switches to another app.
        let observer = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
        ) { [weak documents] _ in
            MainActor.assumeIsolated { documents?.saveAll() }
        }
        context.effect { NotificationCenter.default.removeObserver(observer) }
    }

    @MainActor public func deactivateUI() {
        service?.documents.discardEmptyNotes()
        service?.documents.saveAll()
        service?.documents.textChanged = nil
        service = nil
    }

    /// Markdown files only.
    @MainActor static func canOpen(_ resource: Resource) -> Bool {
        resource.kind == .file && resource.pathExtension == "md"
    }
}


enum MarkdownEditorError: Error, LocalizedError {
    case noActiveEditor

    var errorDescription: String? { "No note is open in an editor." }
}
