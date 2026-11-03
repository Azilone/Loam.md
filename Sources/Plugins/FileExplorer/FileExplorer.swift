import Foundation
import PluginKit

/// The `FilesService` implementation over a vault.
///
/// The note graph is looked up at each call rather than at activation: it is optional and may be
/// disabled or enabled while the explorer stays active.
public final class FileExplorer: FilesService {
    static let trashFolder = ".trash"

    private let vault: VaultAccess
    private let noteGraph: () -> NoteGraphService?
    private let trashService: () -> TrashService?
    private let emit: (_ willMove: Bool, _ moves: [String: String]) -> Void

    /// - Parameters:
    ///   - noteGraph: the note graph if it is there now.
    ///   - trashService: the trash plugin's service if it is there now, told when something enters the trash so its
    ///     date is kept (without it, the trash dates the item when it first sees it).
    ///   - emit: sends `NotesWillMove` (`true`) or `NotesMoved` (`false`) for moves the note graph does not
    ///     make, so an editor saves before and follows after a plain move or a trash, too.
    public init(
        vault: VaultAccess,
        noteGraph: @escaping () -> NoteGraphService? = { nil },
        trashService: @escaping () -> TrashService? = { nil },
        emit: @escaping (_ willMove: Bool, _ moves: [String: String]) -> Void = { _, _ in }
    ) {
        self.vault = vault
        self.noteGraph = noteGraph
        self.trashService = trashService
        self.emit = emit
    }

    public func newNote(in folder: String, name: String?) throws -> String {
        let path = try newNotePath(in: folder, name: name, isTaken: { _ in false })
        try vault.write(path, "")
        return path
    }

    public func newNotePath(in folder: String, name: String?, isTaken: (String) -> Bool) throws -> String {
        let folder = try FileNames.visiblePath(folder)
        var name = try FileNames.validName(name ?? "Untitled")
        if name.lowercased().hasSuffix(".md") { name = try FileNames.validName(String(name.dropLast(3))) }
        return FileNames.unique(base: FileNames.join(folder, name), extension: ".md", in: vault, isTaken: isTaken)
    }

    public func newFolder(in folder: String, name: String?) throws -> String {
        let folder = try FileNames.visiblePath(folder)
        let name = try FileNames.validName(name ?? "New folder")
        let path = FileNames.unique(base: FileNames.join(folder, name), extension: "", in: vault)
        try vault.createFolder(path)
        return path
    }

    public func move(_ from: String, to: String) throws -> MoveResult {
        let from = try FileNames.visiblePath(from)
        let to = try FileNames.visiblePath(to)
        guard !from.isEmpty, vault.exists(from) else { throw VaultError.notFound(path: from) }
        guard !to.isEmpty else { throw FilesError.invalidName(to) }
        _ = try FileNames.validName(String(to.split(separator: "/").last!))
        if isFolder(from), to == from || to.hasPrefix(from + "/") { throw FilesError.moveIntoItself(to) }
        guard !vault.exists(to) else { throw VaultError.alreadyExists(path: to) }

        if let graph = noteGraph() { return try graph.move([from: to]) }
        let files = try fileMoves(from, to: to)
        try plainMove(from, to: to, files: files)
        return MoveResult(moves: files, updated: [])
    }

    /// Never goes through the note graph: rewriting links to point into the trash would spread `.trash/`
    /// paths through the user's notes. Links to a trashed note simply point to a missing file, as they
    /// would after deleting it in any editor, and work again if it is moved back.
    public func trash(_ path: String) throws -> String {
        let path = try VaultPath.normalize(path)
        guard !path.isEmpty, vault.exists(path) else { throw VaultError.notFound(path: path) }
        guard path != Self.trashFolder, !path.hasPrefix(Self.trashFolder + "/") else {
            throw FilesError.alreadyInTrash(path)
        }
        let folder = isFolder(path)
        let split = FileNames.splitExtension(Self.trashFolder + "/" + path, isFolder: folder)
        let destination = FileNames.unique(base: split.base, extension: split.ext, in: vault)
        try plainMove(path, to: destination, files: try fileMoves(path, to: destination))
        // The move is done; a failure to note its date must not make the trash look failed.
        try? trashService()?.record(destination, originalPath: path)
        return destination
    }

    public func list(_ folder: String) throws -> [VaultEntry] {
        try vault.list(folder)
    }

    public func tree() throws -> [FileNode] {
        try children(of: "")
    }

    private func children(of folder: String) throws -> [FileNode] {
        try vault.list(folder).map { entry in
            FileNode(
                path: entry.path,
                isFolder: entry.isFolder,
                children: entry.isFolder ? try children(of: entry.path) : nil
            )
        }
    }

    private func plainMove(_ from: String, to: String, files: [String: String]) throws {
        emit(true, files)
        try vault.move(from, to: to)
        emit(false, files)
    }

    /// Only folders can be listed; this also works for hidden ones.
    private func isFolder(_ path: String) -> Bool {
        (try? vault.list(path)) != nil
    }

    /// Old to new path of every file that moves: a folder is expanded to the visible files under it,
    /// matching what `MoveResult` and the move events promise.
    private func fileMoves(_ from: String, to: String) throws -> [String: String] {
        guard isFolder(from) else { return [from: to] }
        var files: [String: String] = [:]
        func walk(_ folder: String) throws {
            for entry in try vault.list(folder) {
                if entry.isFolder { try walk(entry.path) } else { files[entry.path] = to + entry.path.dropFirst(from.count) }
            }
        }
        try walk(from)
        return files
    }
}
