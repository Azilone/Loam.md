import Foundation

/// Cheap fingerprint of a file, used to detect changes without reading it.
public struct FileStamp: Codable, Sendable, Equatable {
    public let modified: TimeInterval
    public let size: Int

    public init(modified: TimeInterval, size: Int) {
        self.modified = modified
        self.size = size
    }
}

public struct VaultChange: Sendable, Equatable {
    public enum Kind: String, Sendable { case added, modified, removed }
    public let kind: Kind
    public let path: String

    public init(kind: Kind, path: String) {
        self.kind = kind
        self.path = path
    }
}

/// Sent on the event bus when files appeared, changed or disappeared on disk: notes and every other non-hidden
/// file (a `.canvas` board, an image), so a plugin owning a file type follows its files too. A listener that only
/// cares about notes skips the paths not ending in `.md`.
public struct VaultChanged: PluginEvent {
    public let changes: [VaultChange]

    public init(changes: [VaultChange]) {
        self.changes = changes
    }
}

public extension VaultChange {
    /// Whether the change is to a note (a `.md` file).
    var isNote: Bool { path.lowercased().hasSuffix(".md") }
}

public extension VaultChanged {
    /// The changes to notes, for a listener that only follows notes: empty when only other files changed.
    var noteChanges: [VaultChange] { changes.filter(\.isNote) }
}

/// Sent by a plugin's `context.vault` just before it reads a file, with the plugin's id. An editor holding unsaved
/// text of that note saves it first, so a plugin that reads, edits and writes a note starts from what the user
/// sees. Emitted on the reading thread; the kernel's own reads send nothing.
public struct NoteWillRead: PluginEvent {
    /// Vault-relative and normalized.
    public let path: String
    /// The plugin whose `context.vault` reads.
    public let pluginID: String

    public init(path: String, pluginID: String) {
        self.path = path
        self.pluginID = pluginID
    }
}

/// Sent by a plugin's `context.vault` just before it writes or moves a file (for a move: once for the source and
/// once for the destination). `NoteDidChange` follows only if the write succeeded.
public struct NoteWillChange: PluginEvent {
    /// Vault-relative and normalized.
    public let path: String
    /// The plugin whose `context.vault` writes.
    public let pluginID: String

    public init(path: String, pluginID: String) {
        self.path = path
        self.pluginID = pluginID
    }
}

/// Sent by a plugin's `context.vault` right after a write or move succeeded, before the file system reports it
/// (`VaultChanged`): an editor showing the note reloads it at once.
public struct NoteDidChange: PluginEvent {
    /// Vault-relative and normalized.
    public let path: String
    /// The plugin whose `context.vault` wrote.
    public let pluginID: String

    public init(path: String, pluginID: String) {
        self.path = path
        self.pluginID = pluginID
    }
}

/// One file or folder in a folder listing.
public struct VaultEntry: Codable, Sendable, Equatable {
    /// Vault-relative path of the entry, not just its name.
    public let path: String
    public let isFolder: Bool

    public init(path: String, isFolder: Bool) {
        self.path = path
        self.isFolder = isFolder
    }
}

public enum VaultError: Error, Equatable {
    case outsideVault(path: String)
    case alreadyExists(path: String)
    case notFound(path: String)
}

/// Access to the vault (a folder of Markdown files). Every path is relative to the vault root,
/// uses `/` separators, and may never leave the root.
public protocol VaultAccess {
    var rootURL: URL { get }
    /// Relative paths of every `.md` file, sorted. Hidden files and folders are skipped.
    func markdownPaths() throws -> [String]
    /// Fingerprint of every file, by relative path: notes and any other file (`.canvas`, images), not folders.
    /// Hidden files and folders are skipped. A caller that only wants notes keeps the `.md` paths.
    func stamps() throws -> [String: FileStamp]
    func exists(_ path: String) -> Bool
    func read(_ path: String) throws -> String
    /// Writes atomically and creates missing folders.
    func write(_ path: String, _ contents: String) throws
    /// Same as `write`, for binary files such as images.
    func writeData(_ path: String, _ data: Data) throws
    /// Moves a file or a folder, creating missing folders. Throws if the destination exists.
    func move(_ from: String, to: String) throws
    /// The files and folders directly inside `folder` (`""` is the root), folders first, then by name
    /// ignoring case. Hidden entries (`.loam`, `.trash`) are skipped, so a file browser never shows them.
    func list(_ folder: String) throws -> [VaultEntry]
    /// Creates a folder and its missing parents. Creating a folder that already exists does nothing,
    /// so callers need not check first; a file at that path throws `alreadyExists`.
    func createFolder(_ path: String) throws
    /// Deletes the note at `path` when it holds nothing (`NoteContent.isEmpty`) and returns true; leaves any
    /// other file, and a missing one, alone and returns false. It cannot destroy content, which is why a plugin
    /// may call it on a note it made itself.
    @discardableResult func removeIfEmpty(_ path: String) throws -> Bool
}

/// Helpers for vault-relative paths.
public enum VaultPath {
    /// Where a new note goes when nothing picks a folder for it: notes do not land at the vault's root by default.
    /// Notes with a home of their own, such as daily notes, keep it.
    public static let inbox = "Inbox"

    /// Removes `.` and empty parts and resolves `..`. Throws if the path is absolute or leaves the vault.
    public static func normalize(_ path: String) throws -> String {
        guard !path.hasPrefix("/") else { throw VaultError.outsideVault(path: path) }
        var parts: [Substring] = []
        for part in path.split(separator: "/", omittingEmptySubsequences: true) {
            switch part {
            case ".":
                continue
            case "..":
                guard !parts.isEmpty else { throw VaultError.outsideVault(path: path) }
                parts.removeLast()
            default:
                parts.append(part)
            }
        }
        return parts.joined(separator: "/")
    }

    /// The destination to write in a Markdown link from a note in `directory` to the note or file at
    /// `path`: relative, with each path part percent-encoded.
    public static func relativeDestination(fromDirectory directory: String, to path: String) -> String {
        let base = directory.split(separator: "/").map(String.init)
        let target = path.split(separator: "/").map(String.init)
        var common = 0
        while common < base.count, common < target.count - 1, base[common] == target[common] { common += 1 }
        let parts = Array(repeating: "..", count: base.count - common) + target[common...]
        return parts.map(encode).joined(separator: "/")
    }

    private static func encode(_ component: String) -> String {
        if component == ".." { return component }
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "()/")
        return component.addingPercentEncoding(withAllowedCharacters: allowed) ?? component
    }

    /// The folder part of a path, empty for a file at the vault root.
    public static func directory(of path: String) -> String {
        guard let slash = path.lastIndex(of: "/") else { return "" }
        return String(path[..<slash])
    }

    /// Resolves `relative` (a link destination) against the note that contains it.
    public static func resolve(_ relative: String, from notePath: String) throws -> String {
        let directory = directory(of: notePath)
        return try normalize(directory.isEmpty ? relative : directory + "/" + relative)
    }
}
