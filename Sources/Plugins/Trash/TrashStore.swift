import Foundation
import PluginKit

/// The `TrashService` over a vault: the items of `.trash/`, the date each one was trashed, and the purge.
///
/// Dates live in a small hidden index, `.trash/.trashed.json`, keyed by the item's path inside the trash, so no
/// file's own dates are touched (a note's modification date means something to the user and to sync tools):
///
///     { "version": 1, "trashed": { "Projects/Plan.md": { "date": "2026-10-20T09:00:00Z", "original": "Projects/Plan.md" } } }
///
/// `original` is where the item was before, which the trash path does not say when the name was taken in the trash
/// (`Projects 2`). Older indexes held the bare date string; both are read. `seen` marks an item Loam found without
/// having trashed it.
///
/// An item with no entry (put there by Obsidian, or by hand) is dated when Loam first sees it, never from the
/// file's own dates: a note last edited two years ago and trashed yesterday would otherwise be purged at once, and
/// a move leaves no trace of when it happened. Entries of items that left the trash are dropped.
///
/// Permanent deletion goes through the file manager at the vault's root: the vault contract has no way to remove a
/// file, and this is the only place that needs it.
public final class TrashStore: TrashService {
    public static let folder = ".trash"
    static let indexPath = ".trash/.trashed.json"
    public static let defaultRetentionDays = 30

    private let vault: VaultAccess
    private let retention: () -> Int
    private let now: () -> Date
    private let changed: () -> Void
    /// The index is read, changed and written back by several callers (commands run off the main thread).
    private let lock = NSRecursiveLock()
    private let restored: ([String]) -> Void

    /// - Parameters:
    ///   - retentionDays: read at each call, so a setting change applies at once.
    ///   - now: the clock; tests move it.
    ///   - changed: called after the content of the trash changed.
    ///   - restored: called with the vault paths of the files an item brought back.
    public init(
        vault: VaultAccess,
        retentionDays: @escaping () -> Int = { TrashStore.defaultRetentionDays },
        now: @escaping () -> Date = Date.init,
        changed: @escaping () -> Void = {},
        restored: @escaping ([String]) -> Void = { _ in }
    ) {
        self.vault = vault
        self.retention = retentionDays
        self.now = now
        self.changed = changed
        self.restored = restored
    }

    public var retentionDays: Int { max(0, retention()) }

    // MARK: Index

    private struct Entry: Codable, Equatable {
        var date: String
        var original: String?
        var seen: Bool?

        init(date: String, original: String?, seen: Bool? = nil) {
            self.date = date
            self.original = original
            self.seen = seen
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let text = try? container.decode(String.self) {
                self.init(date: text, original: nil)
            } else {
                let keyed = try decoder.container(keyedBy: CodingKeys.self)
                self.init(
                    date: try keyed.decode(String.self, forKey: .date),
                    original: try keyed.decodeIfPresent(String.self, forKey: .original),
                    seen: try keyed.decodeIfPresent(Bool.self, forKey: .seen)
                )
            }
        }
    }

    private struct Index: Codable, Equatable {
        var version = 1
        var trashed: [String: Entry] = [:]
    }

    /// Made once: making one per item took most of a scan, which runs on each change to the vault.
    nonisolated(unsafe) private static let formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private static func stamp(_ date: Date) -> String { formatter.string(from: date) }

    private static func date(_ text: String) -> Date? { formatter.date(from: text) }

    private func loadIndex() -> Index {
        guard vault.exists(Self.indexPath), let text = try? vault.read(Self.indexPath),
              let index = try? JSONDecoder().decode(Index.self, from: Data(text.utf8)) else { return Index() }
        return index
    }

    private func saveIndex(_ index: Index) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try vault.write(Self.indexPath, String(decoding: try encoder.encode(index), as: UTF8.self) + "\n")
    }

    /// The path inside the trash for `path` (`.trash/a/b.md` or `a/b.md`), refusing anything else.
    private func key(for path: String) throws -> String {
        var normalized = try VaultPath.normalize(path)
        if normalized.hasPrefix(Self.folder + "/") { normalized.removeFirst(Self.folder.count + 1) }
        guard !normalized.isEmpty, normalized != ".trash", normalized != ".trashed.json" else {
            throw TrashError.notInTrash(path)
        }
        return normalized
    }

    // MARK: Service

    public func record(_ path: String, originalPath: String?) throws {
        lock.lock(); defer { lock.unlock() }
        let key = try key(for: path)
        guard vault.exists(Self.folder + "/" + key) else { throw TrashError.notFound(path) }
        var index = loadIndex()
        index.trashed[key] = Entry(date: Self.stamp(now()), original: originalPath ?? key)
        try saveIndex(index)
        changed()
    }

    public func items() throws -> [TrashedItem] {
        lock.lock(); defer { lock.unlock() }
        return try scan().items
    }

    public func restore(_ path: String) throws -> String {
        lock.lock(); defer { lock.unlock() }
        let key = try key(for: path)
        let source = Self.folder + "/" + key
        guard vault.exists(source) else { throw TrashError.notFound(path) }
        var destination = (try? VaultPath.normalize(loadIndex().trashed[key]?.original ?? key)) ?? key
        if destination.isEmpty || destination == Self.folder || destination.hasPrefix(Self.folder + "/") { destination = key }
        if vault.exists(destination) {
            let split = Self.splitExtension(destination, isFolder: isFolder(source))
            var number = 2
            while vault.exists("\(split.base) \(number)\(split.ext)") { number += 1 }
            destination = "\(split.base) \(number)\(split.ext)"
        }
        let files = isFolder(source) ? filesUnder(source) : [source]
        try vault.move(source, to: destination)
        var index = loadIndex()
        removeEntries(of: key, from: &index)
        try? saveIndex(index)
        pruneEmptyFolders(above: source)
        let prefix = source
        restored(files.map { destination + $0.dropFirst(prefix.count) })
        changed()
        return destination
    }

    public func deleteForever(_ path: String) throws {
        lock.lock(); defer { lock.unlock() }
        let key = try key(for: path)
        guard vault.exists(Self.folder + "/" + key) else { throw TrashError.notFound(path) }
        try erase(key)
        changed()
    }

    @discardableResult
    public func empty() throws -> Int {
        lock.lock(); defer { lock.unlock() }
        let current = try scan().items
        for item in current { try erase(String(item.path.dropFirst(Self.folder.count + 1)), notify: false) }
        if !current.isEmpty { changed() }
        return current.count
    }

    @discardableResult
    public func purgeExpired() throws -> [String] {
        lock.lock(); defer { lock.unlock() }
        let days = retentionDays
        guard days > 0 else { return [] }
        let expired = try scan().items.filter { ($0.daysLeft ?? 1) <= 0 }
        for item in expired { try erase(String(item.path.dropFirst(Self.folder.count + 1)), notify: false) }
        if !expired.isEmpty { changed() }
        return expired.map(\.path)
    }

    // MARK: Scan

    private struct Scan {
        var items: [TrashedItem]
    }

    /// Lists the items and records the unrecorded ones. A recorded folder is one item (its content is not
    /// listed); it is dated by the latest of its own date and its recorded content's.
    private func scan() throws -> Scan {
        guard vault.exists(Self.folder) else { return Scan(items: []) }
        var index = loadIndex()
        let before = index
        let today = now()
        var found: [(key: String, isFolder: Bool)] = []

        func walk(_ folder: String) throws {
            for entry in try vault.list(folder) {
                let key = String(entry.path.dropFirst(Self.folder.count + 1))
                if index.trashed[key] != nil {
                    found.append((key, entry.isFolder))
                } else if entry.isFolder {
                    try walk(entry.path)
                } else {
                    index.trashed[key] = Entry(date: Self.stamp(today), original: key, seen: true)
                    found.append((key, false))
                }
            }
        }
        try walk(Self.folder)

        // Entries whose item left the trash.
        for key in index.trashed.keys where !vault.exists(Self.folder + "/" + key) { index.trashed[key] = nil }
        if index != before { try saveIndex(index) }

        let days = retentionDays
        let items = found.map { item -> TrashedItem in
            let entry = index.trashed[item.key]
            var trashed = Self.date(entry?.date ?? "") ?? today
            if item.isFolder {
                for (other, value) in index.trashed where other.hasPrefix(item.key + "/") {
                    if let date = Self.date(value.date), date > trashed { trashed = date }
                }
            }
            var expires: Date?
            var left: Int?
            if days > 0 {
                let end = trashed.addingTimeInterval(Double(days) * 86_400)
                expires = end
                left = max(0, Int((end.timeIntervalSince(today) / 86_400).rounded(.up)))
            }
            return TrashedItem(
                path: Self.folder + "/" + item.key,
                originalPath: entry?.original ?? item.key,
                isFolder: item.isFolder,
                trashedAt: Self.stamp(trashed),
                expiresAt: expires.map(Self.stamp),
                daysLeft: left,
                firstSeen: entry?.seen == true
            )
        }
        return Scan(items: items.sorted { a, b in
            a.trashedAt == b.trashedAt ? a.path < b.path : a.trashedAt > b.trashedAt
        })
    }

    // MARK: Disk

    private func erase(_ key: String, notify: Bool = true) throws {
        let path = Self.folder + "/" + key
        let url = vault.rootURL.appendingPathComponent(path)
        try FileManager.default.removeItem(at: url)
        var index = loadIndex()
        removeEntries(of: key, from: &index)
        try? saveIndex(index)
        pruneEmptyFolders(above: path)
    }

    private func removeEntries(of key: String, from index: inout Index) {
        for other in index.trashed.keys where other == key || other.hasPrefix(key + "/") { index.trashed[other] = nil }
    }

    /// Removes the folders left empty above `path` inside the trash (never `.trash` itself): a restored
    /// `.trash/Projects/Plan.md` must not leave `.trash/Projects` behind.
    private func pruneEmptyFolders(above path: String) {
        var parent = (path as NSString).deletingLastPathComponent
        while parent.hasPrefix(Self.folder + "/") {
            let url = vault.rootURL.appendingPathComponent(parent)
            let contents = ((try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? ["."])
                .filter { $0 != ".DS_Store" }
            guard contents.isEmpty else { return }
            try? FileManager.default.removeItem(at: url)
            parent = (parent as NSString).deletingLastPathComponent
        }
    }

    private func isFolder(_ path: String) -> Bool {
        (try? vault.list(path)) != nil
    }

    private func filesUnder(_ folder: String) -> [String] {
        var files: [String] = []
        for entry in (try? vault.list(folder)) ?? [] {
            if entry.isFolder { files += filesUnder(entry.path) } else { files.append(entry.path) }
        }
        return files
    }

    /// `a/b.md` -> (`a/b`, `.md`); folders and extension-less files keep the whole name as base.
    static func splitExtension(_ path: String, isFolder: Bool) -> (base: String, ext: String) {
        let nameStart = path.lastIndex(of: "/").map { path.index(after: $0) } ?? path.startIndex
        guard !isFolder, let dot = path[nameStart...].lastIndex(of: "."), dot > nameStart else { return (path, "") }
        return (String(path[..<dot]), String(path[dot...]))
    }
}
