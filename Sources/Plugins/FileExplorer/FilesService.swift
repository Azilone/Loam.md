import Foundation
import PluginKit

/// The file explorer's operations: create, move, trash and list notes, attachments and folders.
///
/// Declared here rather than in PluginKit because its only other user is the explorer's own UI module
/// (`FileExplorerUI`), which may import this logic module. Other plugins reach the same behaviour through
/// the `files.*` commands.
public protocol FilesService: AnyObject {
    /// Creates an empty note in `folder` (`""` is the root) named `name` (without `.md`), or "Untitled".
    /// A taken name gets " 2", " 3"... Returns the note's path.
    func newNote(in folder: String, name: String?) throws -> String
    /// The path `newNote` would give, without writing anything: for an app that shows the note and writes it once
    /// it has text. `isTaken` names paths that are free on disk but in use (a note still being written).
    func newNotePath(in folder: String, name: String?, isTaken: (String) -> Bool) throws -> String
    /// Creates a folder named `name`, or "New folder". A taken name gets " 2", " 3"... Returns its path.
    func newFolder(in folder: String, name: String?) throws -> String
    /// Moves or renames a note, attachment or folder. Rewrites links through note-graph when it is there,
    /// else a plain move. Never moves into `.trash` or `.loam`: `trash` is the only way into the trash.
    func move(_ from: String, to: String) throws -> MoveResult
    /// Moves a note, attachment or folder into `.trash/` at the vault root, keeping its folder path; adds
    /// " 2", " 3"... if taken. Returns the trash path. Links to it are left as they are. The `trash` service, when
    /// there, keeps the date, so the item is deleted for good after the retention (30 days by default).
    func trash(_ path: String) throws -> String
    /// One folder level, folders first (`VaultAccess.list`). Hidden entries such as `.trash` never show.
    func list(_ folder: String) throws -> [VaultEntry]
    /// The whole tree under the root, depth-first, folders before files at each level; hidden entries skipped.
    func tree() throws -> [FileNode]
}

public extension ServiceKey where Service == FilesService {
    static var files: ServiceKey<FilesService> { ServiceKey<FilesService>("files") }
}

/// One file or folder in `FilesService.tree()`.
public struct FileNode: Codable, Sendable, Equatable {
    /// Vault-relative path.
    public let path: String
    public let isFolder: Bool
    /// The folder's content, in `list` order; `nil` for a file, so an empty folder stays distinct from a file.
    public let children: [FileNode]?

    public init(path: String, isFolder: Bool, children: [FileNode]?) {
        self.path = path
        self.isFolder = isFolder
        self.children = children
    }
}

public enum FilesError: Error, Equatable {
    /// Empty, containing "/", or starting with "." (hidden files would vanish from the explorer).
    case invalidName(String)
    /// Hidden folders such as `.trash` and `.loam` are not reachable through `move` or `newNote`.
    case hiddenPath(String)
    case moveIntoItself(String)
    case alreadyInTrash(String)
}
