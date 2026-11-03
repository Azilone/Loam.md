import Foundation

/// One note, attachment or folder waiting in the vault's `.trash/`.
public struct TrashedItem: Codable, Sendable, Equatable {
    /// Vault-relative path inside the trash, such as `.trash/Projects/Plan.md`.
    public let path: String
    /// Where it was before, such as `Projects/Plan.md`: restoring puts it back there (a free "Name 2" variant only
    /// when something took the place meanwhile).
    public let originalPath: String
    public let isFolder: Bool
    /// When it entered the trash (ISO 8601, UTC). For an item put there by another tool, when Loam first saw it.
    public let trashedAt: String
    /// When it will be deleted for good (ISO 8601, UTC); nil when the retention is off (0 days).
    public let expiresAt: String?
    /// Whole days left before then, rounded up; nil when the retention is off.
    public let daysLeft: Int?
    /// True when Loam found the item in the trash instead of moving it there (trashed by another tool), so
    /// `trashedAt` is when it first saw it.
    public let firstSeen: Bool

    public init(
        path: String, originalPath: String, isFolder: Bool, trashedAt: String, expiresAt: String?, daysLeft: Int?,
        firstSeen: Bool = false
    ) {
        self.firstSeen = firstSeen
        self.path = path
        self.originalPath = originalPath
        self.isFolder = isFolder
        self.trashedAt = trashedAt
        self.expiresAt = expiresAt
        self.daysLeft = daysLeft
    }
}

/// The vault's trash: what `files.trash` put in `.trash/`, when, and how to get it back or finish it off. Items are
/// deleted for good a number of days after they were trashed (the plugin's `retentionDays` setting, 30 by default).
/// Provided by the `trash` plugin; the `trash.*` commands do the same for agents and the CLI.
public protocol TrashService: AnyObject {
    /// Days an item stays in the trash; 0 keeps everything until it is deleted by hand.
    var retentionDays: Int { get }
    /// Notes that `path` (a path inside `.trash/`) was just trashed, so its date is kept. Called by whoever moves
    /// something into the trash. Never touches the item's own dates.
    func record(_ path: String, originalPath: String?) throws
    /// Every item, most recently trashed first. Items the trash did not record (put there by Obsidian, say) are
    /// recorded now, with today as their date.
    func items() throws -> [TrashedItem]
    /// Moves an item back to its original path (a free "Name 2" variant when that is taken). Returns the new path.
    func restore(_ path: String) throws -> String
    /// Deletes an item for good. Returns nothing back: this cannot be undone.
    func deleteForever(_ path: String) throws
    /// Deletes everything in the trash for good. Returns how many items went.
    @discardableResult
    func empty() throws -> Int
    /// Deletes the items trashed more than `retentionDays` ago. Returns their trash paths.
    @discardableResult
    func purgeExpired() throws -> [String]
}

public extension TrashService {
    func record(_ path: String) throws { try record(path, originalPath: nil) }
}

public extension ServiceKey where Service == TrashService {
    static var trash: ServiceKey<TrashService> { ServiceKey<TrashService>("trash") }
}

/// Sent when the content of the trash changed: something was trashed, restored or deleted for good.
public struct TrashChanged: PluginEvent {
    public init() {}
}

public enum TrashError: Error, Equatable {
    /// The path is not an item inside `.trash/`.
    case notInTrash(String)
    case notFound(String)
}
