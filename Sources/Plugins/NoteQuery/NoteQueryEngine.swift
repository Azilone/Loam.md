import Foundation
import PluginKit

/// The `note-query` service: queries over the note graph's current state, and property edits through the vault.
final class NoteQueryEngine: NoteQueryService {
    private let vault: VaultAccess
    private let noteGraph: () -> NoteGraphService?
    private let didWrite: (String) -> Void
    private let lock = NSLock()
    /// The vault's note stamps (for `modified`), walked once per change rather than once per query.
    private var cachedStamps: [String: FileStamp]?

    /// - Parameter didWrite: called with the path after `setProperty` wrote a note, so the plugin can announce
    ///   the change and the graph rereads that note at once instead of on the next scan of the disk.
    init(vault: VaultAccess, noteGraph: @escaping () -> NoteGraphService?, didWrite: @escaping (String) -> Void) {
        self.vault = vault
        self.noteGraph = noteGraph
        self.didWrite = didWrite
    }

    func run(_ query: NoteQuery) -> [NoteRecord] {
        let folder = (try? VaultPath.normalize(query.folder ?? "")) ?? query.folder ?? ""
        let tags = query.tags.map { ($0.hasPrefix("#") ? String($0.dropFirst()) : $0).lowercased() }
        let stamps = currentStamps()

        let matching = (noteGraph()?.notes ?? []).filter { note in
            (folder.isEmpty || note.path.hasPrefix(folder + "/"))
                && tags.allSatisfy { wanted in
                    note.tags.contains { tag in
                        let tag = tag.lowercased()
                        return tag == wanted || tag.hasPrefix(wanted + "/")
                    }
                }
                && query.filters.allSatisfy { PropertyComparison.matches($0, Self.property($0.key, of: note.properties)) }
        }
        let records = matching.map {
            NoteRecord(path: $0.path, title: $0.title, properties: $0.properties, tags: $0.tags,
                       modified: stamps[$0.path]?.modified ?? 0)
        }
        let sorted = sort(records, by: query.sort.isEmpty ? [SortKey(key: "title")] : query.sort)
        guard let limit = query.limit else { return sorted }
        return Array(sorted.prefix(max(0, limit)))
    }

    func values(of key: String, in query: NoteQuery) -> [PropertyValue] {
        var distinct: [PropertyValue] = []
        for record in run(query) {
            guard let value = Self.property(key, of: record.properties) else { continue }
            let elements: [PropertyValue]
            if case .list(let list) = value { elements = list } else { elements = [value] }
            for element in elements where element != .null {
                if !distinct.contains(where: { PropertyComparison.equals($0, element) }) { distinct.append(element) }
            }
        }
        return distinct.enumerated().sorted { a, b in
            let result = PropertyComparison.sortOrder(a.element, b.element)
            return result == .orderedSame ? a.offset < b.offset : result == .orderedAscending
        }.map(\.element)
    }

    func setProperty(_ key: String, to value: PropertyValue?, in path: String) throws {
        guard !key.isEmpty, !key.contains(where: { $0.isNewline }) else { throw NoteQueryError.invalidKey(key) }
        let path = try VaultPath.normalize(path)
        guard path.lowercased().hasSuffix(".md"), vault.exists(path) else { throw VaultError.notFound(path: path) }
        let text = try vault.read(path)
        let edited = FrontmatterEditor.setting(key, to: value, in: text)
        guard edited != text else { return }
        try vault.write(path, edited)
        update([VaultChange(kind: .modified, path: path)])
        didWrite(path)
    }

    /// Forgets the cached stamps.
    func invalidate() {
        lock.lock()
        cachedStamps = nil
        lock.unlock()
    }

    /// Brings the cached stamps up to date with `changes`, one file at a time; the plugin calls it on every
    /// `VaultChanged`. Walking the vault again at each save cost every query after it (an open note finding its
    /// collection, the tags) ~15-25 ms on 600 notes. A change it cannot apply alone (a folder) forgets them all.
    func update(_ changes: [VaultChange]) {
        lock.lock()
        defer { lock.unlock() }
        guard var stamps = cachedStamps else { return }
        for change in changes {
            if change.path.split(separator: "/").contains(where: { $0.hasPrefix(".") }) { continue }
            let values = try? vault.rootURL.appendingPathComponent(change.path)
                .resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey])
            if let values, values.isRegularFile == true {
                stamps[change.path] = FileStamp(modified: values.contentModificationDate?.timeIntervalSince1970 ?? 0,
                                                size: values.fileSize ?? 0)
            } else if values == nil, change.kind == .removed, stamps[change.path] != nil {
                stamps[change.path] = nil
            } else {
                cachedStamps = nil
                return
            }
        }
        cachedStamps = stamps
    }

    private func currentStamps() -> [String: FileStamp] {
        lock.lock()
        defer { lock.unlock() }
        if let cachedStamps { return cachedStamps }
        let stamps = (try? vault.stamps()) ?? [:]
        cachedStamps = stamps
        return stamps
    }

    static func property(_ key: String, of properties: [String: PropertyValue]) -> PropertyValue? {
        PropertyComparison.property(key, of: properties)
    }

    private func sort(_ records: [NoteRecord], by keys: [SortKey]) -> [NoteRecord] {
        records.enumerated().sorted { a, b in
            for key in keys {
                let (left, right) = (Self.sortValue(key.key, of: a.element), Self.sortValue(key.key, of: b.element))
                switch (left, right) {
                case (nil, nil):
                    continue
                case (nil, _):
                    return false
                case (_, nil):
                    return true
                case (let left?, let right?):
                    let result = PropertyComparison.sortOrder(left, right)
                    if result == .orderedSame { continue }
                    return (result == .orderedAscending) != key.descending
                }
            }
            return a.offset < b.offset
        }.map(\.element)
    }

    /// The value a sort key reads: a reserved name, else a property; nil (sorted last) when missing or null.
    private static func sortValue(_ key: String, of record: NoteRecord) -> PropertyValue? {
        switch key {
        case "title": return .string(record.title)
        case "path": return .string(record.path)
        case "modified": return .number(record.modified)
        default:
            let value = property(key, of: record.properties)
            return value == .null ? nil : value
        }
    }
}
