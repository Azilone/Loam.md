import Foundation
import Observation
import PluginKitUI

/// What the Outline panel shows: the headings of the active note, read from the editor while it has the note
/// open (unsaved typing included), else from the vault.
@MainActor
@Observable
final class OutlineModel {
    /// The note followed, nil when the active tab is not a Markdown note.
    private(set) var path: String?
    private(set) var headings: [OutlineHeading] = []

    @ObservationIgnored private let vault: VaultAccess
    @ObservationIgnored private let editor: @MainActor () -> (any EditorService)?
    @ObservationIgnored private let workspace: @MainActor () -> (any Workspace)?
    /// The background parse started by the last change, dropped when a newer one starts.
    @ObservationIgnored private var parsing: Task<Void, Never>?

    init(
        vault: VaultAccess,
        editor: @escaping @MainActor () -> (any EditorService)?,
        workspace: @escaping @MainActor () -> (any Workspace)?
    ) {
        self.vault = vault
        self.editor = editor
        self.workspace = workspace
    }

    /// The headings of the note at `path`, from the editor's live text when it has it open.
    func headings(of path: String) -> [OutlineHeading]? {
        guard let text = editor()?.text(of: path) ?? (try? vault.read(path)) else { return nil }
        return OutlineHeadings.extract(from: text)
    }

    /// `ActiveResourceChanged`, and the start: follows a Markdown note, or nothing.
    func follow(_ resource: Resource?) {
        if let resource, resource.kind == .file, resource.pathExtension == "md" {
            path = resource.path
        } else {
            path = nil
        }
        // Read off the main thread: a long note took several milliseconds of the frame that opens it.
        if !headings.isEmpty { headings = [] }
        refreshInBackground()
    }

    func refresh() {
        parsing?.cancel()
        let new = path.flatMap { headings(of: $0) } ?? []
        if new != headings { headings = new }
    }

    /// `refresh()` with the parsing off the main thread: a long note takes several milliseconds, on each keystroke.
    func refreshInBackground() {
        parsing?.cancel()
        guard let path, let text = editor()?.text(of: path) ?? (try? vault.read(path)) else { return refresh() }
        parsing = Task { [weak self] in
            let new = await Task.detached(priority: .userInitiated) { OutlineHeadings.extract(from: text) }.value
            guard let self, !Task.isCancelled, self.path == path, new != headings else { return }
            headings = new
        }
    }

    /// `DocumentTextChanged`: the editor's text of a note changed.
    func documentChanged(_ changedPath: String) {
        if changedPath == path { refreshInBackground() }
    }

    /// `VaultChanged`.
    func vaultChanged(_ paths: [String]) {
        if let path, paths.contains(path) { refreshInBackground() }
    }

    /// `NotesMoved`: keeps following the note under its new path.
    func moved(_ moves: [String: String]) {
        guard let path, let new = moves[path] else { return }
        self.path = new
        refresh()
    }

    /// A click on a heading: the editor showing the note jumps to it; without one, the note opens in place.
    func select(_ heading: OutlineHeading) {
        guard let path else { return }
        if editor()?.reveal(line: heading.line, in: path) == true { return }
        workspace()?.open(.file(path), placement: .replace)
    }
}
