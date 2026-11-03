import AppKit
import ExcalidrawPlugin
import Observation
import PluginKitUI

/// What the drawing views share: the `excalidraw` service, the open editors (told when their file changes) and the
/// pictures of drawings shown on boards and in notes.
@MainActor
@Observable
final class ExcalidrawStore {
    @ObservationIgnored let service: ExcalidrawService
    @ObservationIgnored let vault: VaultAccess
    @ObservationIgnored let workspace: () -> (any Workspace)?
    @ObservationIgnored lazy var previews = DrawingPreviews(service: service, vault: vault)
    @ObservationIgnored private var editors: [WeakEditor] = []
    /// How many times each file changed while the app ran: pictures of a drawing redraw when it changes.
    private var versions: [String: Int] = [:]

    init(service: ExcalidrawService, vault: VaultAccess, workspace: @escaping () -> (any Workspace)?) {
        self.service = service
        self.vault = vault
        self.workspace = workspace
    }

    func register(_ editor: DrawingEditor) {
        editors.removeAll { $0.editor == nil }
        editors.append(WeakEditor(editor: editor))
    }

    func version(of path: String) -> Int { versions[path] ?? 0 }

    /// Drawings renamed or moved (`NotesMoved`): their open editors save under the new path from now on.
    func moved(_ moves: [String: String]) {
        for case let editor? in editors.map(\.editor) {
            if let destination = moves[editor.path] { editor.path = destination }
        }
    }

    func fileChanged(_ path: String) {
        guard ExcalidrawDocument.format(of: path) != nil else { return }
        previews.forget(path)
        versions[path, default: 0] += 1
        for case let editor? in editors.map(\.editor) where editor.path == path { editor.fileChanged() }
    }

    // MARK: - The library

    /// The library every drawing shares (shapes and icons to drop in), an `.excalidrawlib` file that travels with the
    /// vault in `.loam/excalidraw/`.
    @ObservationIgnored private(set) lazy var libraryText: String? = try? String(contentsOf: libraryURL, encoding: .utf8)
    @ObservationIgnored private var libraryBrowser: LibraryBrowser?

    var libraryURL: URL {
        vault.rootURL.appendingPathComponent(".loam/excalidraw/library.excalidrawlib")
    }

    /// An editor's library changed: saved, and shown in the other open drawings.
    func libraryChanged(_ library: String, by editor: DrawingEditor) {
        guard library != libraryText else { return }
        libraryText = library
        try? FileManager.default.createDirectory(at: libraryURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? library.write(to: libraryURL, atomically: true, encoding: .utf8)
        for case let other? in editors.map(\.editor) where other !== editor { other.setLibrary(library) }
    }

    /// Opens Excalidraw's library catalogue in a window of its own; a library added there goes into `editor`.
    func browseLibraries(_ url: URL, for editor: DrawingEditor) {
        libraryBrowser?.close()
        let browser = LibraryBrowser(url: url) { [weak self, weak editor] library in
            guard let self else { return }
            let target = editor ?? self.editors.compactMap(\.editor).first
            target?.addLibrary(library)
            self.libraryBrowser = nil
        }
        libraryBrowser = browser
        browser.show()
    }

    func close() {
        libraryBrowser?.close()
        libraryBrowser = nil
        previews.close()
    }

    @discardableResult
    func createDrawing(in folder: String, title: String? = nil) throws -> String {
        let path = try service.create(in: folder, title: title)
        workspace()?.open(.file(path), placement: .replace)
        return path
    }

    /// The folder of the active file, for a new drawing; empty (the inbox) when none.
    func activeFolder() -> String {
        guard let active = workspace()?.activeResource, active.kind == .file else { return "" }
        return (active.path as NSString).deletingLastPathComponent
    }

    /// Opens a link of a drawing: a web address in the browser, a note of the vault (`[[Note]]`, `Note.md`, a path
    /// from the drawing's folder or the vault's root) in Loam.
    func openLink(_ link: String, from drawing: String) {
        let trimmed = link.trimmingCharacters(in: .whitespaces)
        if let url = URL(string: trimmed), let scheme = url.scheme, scheme.count > 1 {
            NSWorkspace.shared.open(url)
            return
        }
        guard let path = Self.resolve(trimmed, from: drawing, vault: vault) else { return }
        workspace()?.open(.file(path), placement: .replace)
    }

    /// The vault file a link names, or nil.
    static func resolve(_ link: String, from drawing: String, vault: VaultAccess) -> String? {
        var target = link
        if target.hasPrefix("[["), target.hasSuffix("]]") { target = String(target.dropFirst(2).dropLast(2)) }
        target = String(target.split(separator: "|", maxSplits: 1).first ?? "")
        target = String(target.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first ?? "")
        target = target.removingPercentEncoding ?? target
        guard !target.isEmpty else { return nil }
        let folder = (drawing as NSString).deletingLastPathComponent
        let candidates = [target, target + ".md"].flatMap { name in
            [folder.isEmpty ? name : "\(folder)/\(name)", name]
        }
        for candidate in candidates {
            if let path = try? VaultPath.normalize(candidate), vault.exists(path) { return path }
        }
        // A bare note name, as `[[Note]]` is written: the first note of that name.
        let name = (target as NSString).lastPathComponent.lowercased()
        return (try? vault.markdownPaths())?.first { path in
            let file = (path as NSString).lastPathComponent.lowercased()
            return file == name || file == name + ".md"
        }
    }

    private struct WeakEditor {
        weak var editor: DrawingEditor?
    }
}
