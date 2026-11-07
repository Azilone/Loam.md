import Foundation
import PluginKit

/// The `collections` service: reads `.base` YAML, runs a view over `note-query`'s notes, and edits the YAML.
final class CollectionEngine: CollectionAdopting {
    private let vault: VaultAccess
    private let noteQuery: () -> NoteQueryService?
    private let didWrite: ([VaultChange]) -> Void
    private let lock = NSLock()
    private var cachedCollections: [String]?
    /// The moves announced since `newEntry` wrote its note: another plugin may file it elsewhere on the spot.
    private var movesDuringWrite: [String: String]?

    /// - Parameter didWrite: called after the engine wrote files, so the plugin announces them at once.
    init(vault: VaultAccess, noteQuery: @escaping () -> NoteQueryService?, didWrite: @escaping ([VaultChange]) -> Void) {
        self.vault = vault
        self.noteQuery = noteQuery
        self.didWrite = didWrite
    }

    static let fileExtension = "base"

    /// Forgets the list of `.base` files; the plugin calls it when one appears or disappears.
    func invalidate() {
        lock.lock()
        cachedCollections = nil
        lock.unlock()
    }

    func collections() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        if let cachedCollections { return cachedCollections }
        let paths = ((try? vault.stamps()) ?? [:]).keys.filter { $0.lowercased().hasSuffix("." + Self.fileExtension) }.sorted()
        cachedCollections = paths
        return paths
    }

    func collections(containing path: String) -> [String] {
        guard let path = try? VaultPath.normalize(path), !path.lowercased().hasSuffix("." + Self.fileExtension) else { return [] }
        let folder = VaultPath.directory(of: path)
        // Nearest first: the deepest folder, then by name.
        let bases = collections().sorted { a, b in
            let (da, db) = (a.split(separator: "/").count, b.split(separator: "/").count)
            return da != db ? da > db : a < b
        }
        var record: NoteRecord??
        return bases.filter { base in
            guard let loaded = try? load(.file(base)) else { return false }
            var evaluator = FilterEvaluator(entry: loaded.host ?? FileFacts(path: "", tags: [], properties: [:], modified: 0),
                                            host: loaded.host)
            if let home = Self.home(of: loaded.base.filters, evaluator: &evaluator),
               !home.isEmpty, folder != home, !folder.hasPrefix(home + "/") { return false }
            if record == nil { record = noteQuery()?.run(NoteQuery(folder: folder)).first { $0.path == path } }
            guard let found = record ?? nil else { return false }
            var matcher = FilterEvaluator(entry: FileFacts(found), host: loaded.host)
            return matcher.matches(.and([loaded.base.filters].compactMap { $0 })) != false
        }
    }

    // MARK: Reading

    private struct Loaded {
        let base: BaseFile
        let name: String
        let host: FileFacts?
    }

    private func load(_ source: CollectionSource) throws -> Loaded {
        switch source {
        case .file(let path):
            let path = try VaultPath.normalize(path)
            guard path.lowercased().hasSuffix("." + Self.fileExtension), vault.exists(path) else {
                throw CollectionError.notACollection(path)
            }
            let name = String((path.split(separator: "/").last ?? "").dropLast(Self.fileExtension.count + 1))
            return Loaded(base: try BaseFile(yaml: try vault.read(path)), name: name,
                          host: FileFacts(path: path, tags: [], properties: [:], modified: 0))
        case .inline(let yaml, let host):
            let facts = host.flatMap { path -> FileFacts? in
                let path = (try? VaultPath.normalize(path)) ?? path
                let record = noteQuery()?.run(NoteQuery(folder: VaultPath.directory(of: path))).first { $0.path == path }
                return record.map(FileFacts.init) ?? FileFacts(path: path, tags: [], properties: [:], modified: 0)
            }
            // A block is named by its `name:` key (Loam's, as a `.base` file is named by its file), else "Collection".
            let base = try BaseFile(yaml: yaml)
            return Loaded(base: base, name: base.name ?? "Collection", host: facts)
        }
    }

    func definition(_ source: CollectionSource) throws -> CollectionDefinition {
        let loaded = try load(source)
        var evaluator = FilterEvaluator(entry: loaded.host ?? FileFacts(path: "", tags: [], properties: [:], modified: 0),
                                        host: loaded.host)
        let home = Self.home(of: loaded.base.filters, evaluator: &evaluator)
        return CollectionDefinition(
            source: source,
            name: loaded.name,
            home: home,
            properties: loaded.base.properties,
            views: loaded.base.views,
            warnings: evaluator.unknowns.sorted()
        )
    }

    func entries(_ source: CollectionSource, view name: String?) throws -> CollectionResult {
        let loaded = try load(source)
        let definition = try definition(source)
        let view: CollectionViewConfig
        if let name {
            guard let found = definition.views.first(where: { $0.name == name }) else {
                throw CollectionError.unknownView(name)
            }
            view = found
        } else {
            view = definition.views.first ?? CollectionViewConfig(type: "table", name: "Table", order: [.title])
        }
        let filters = [loaded.base.filters, loaded.base.viewFilters(view.name)].compactMap { $0 }

        var warnings = Set(definition.warnings)
        let candidates = noteQuery()?.run(NoteQuery(folder: definition.home)) ?? []
        var entries = candidates.filter { record in
            var evaluator = FilterEvaluator(entry: FileFacts(record), host: loaded.host)
            let keep = evaluator.matches(.and(filters)) != false
            warnings.formUnion(evaluator.unknowns)
            return keep
        }
        entries = sort(entries, by: view.sort.isEmpty ? [CollectionSort(property: .title)] : view.sort)
        if let limit = view.limit { entries = Array(entries.prefix(max(0, limit))) }

        var kinds: [String: PropertyKind] = [:]
        for ref in view.order + [view.groupBy?.property].compactMap({ $0 }) {
            kinds[ref.description] = kind(of: ref, in: definition, entries: entries)
        }
        let groups = view.groupBy.map { group(entries, by: $0, options: definition.property($0.property).options) }
        return CollectionResult(view: view, entries: entries, groups: groups, kinds: kinds, warnings: warnings.sorted())
    }

    /// The folder of the first `file.inFolder(...)` the filter requires.
    static func home(of filters: FilterTree?, evaluator: inout FilterEvaluator) -> String? {
        for case .expression(let text) in requirements(of: filters) {
            guard case .call(.member(.identifier("file"), "inFolder"), let arguments)? = try? FilterExpression.parse(text),
                  let argument = arguments.first, case .string(let folder) = evaluator.evaluate(argument)
            else { continue }
            let trimmed = folder.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let normalized = (try? VaultPath.normalize(trimmed)) ?? trimmed
            return normalized.isEmpty ? nil : normalized
        }
        return nil
    }

    /// The conditions every entry must meet: the items of a top-level `and`, or the filter itself.
    private static func requirements(of filters: FilterTree?) -> [FilterTree] {
        switch filters {
        case .and(let items)?: return items
        case let tree?: return [tree]
        case nil: return []
        }
    }

    /// What a value of an entry is, for sorting and grouping: `file.name` is the note's title.
    static func value(_ ref: PropertyRef, of record: NoteRecord) -> PropertyValue? {
        let value: PropertyValue?
        switch ref.namespace {
        case .note:
            value = PropertyComparison.property(ref.name, of: record.properties)
        case .formula:
            value = nil
        case .file:
            let facts = FileFacts(record)
            switch ref.name {
            case "name": value = .string(record.title)
            case "basename": value = .string(facts.basename)
            case "path": value = .string(record.path)
            case "folder": value = .string(facts.folder)
            case "ext": value = .string(facts.ext)
            case "mtime": value = .number(record.modified * 1000)
            case "tags": value = .list(record.tags.map { .string($0) })
            default: value = nil
            }
        }
        return value == .null ? nil : value
    }

    private func sort(_ records: [NoteRecord], by keys: [CollectionSort]) -> [NoteRecord] {
        records.enumerated().sorted { a, b in
            for key in keys {
                switch (Self.value(key.property, of: a.element), Self.value(key.property, of: b.element)) {
                case (nil, nil): continue
                case (nil, _): return false
                case (_, nil): return true
                case (let left?, let right?):
                    let result = PropertyComparison.sortOrder(left, right)
                    if result == .orderedSame { continue }
                    return (result == .orderedAscending) != key.descending
                }
            }
            return a.offset < b.offset
        }.map(\.element)
    }

    /// The value a board files an entry under: the first item of a list.
    static func groupValue(_ ref: PropertyRef, of record: NoteRecord) -> PropertyValue? {
        guard let value = value(ref, of: record) else { return nil }
        if case .list(let items) = value { return items.first { $0 != .null } }
        return value
    }

    private func group(_ entries: [NoteRecord], by groupBy: CollectionSort, options: [String]) -> [CollectionGroup] {
        var optionEntries = Array(repeating: [NoteRecord](), count: options.count)
        var others: [(value: PropertyValue, entries: [NoteRecord])] = []
        var none: [NoteRecord] = []
        for record in entries {
            guard let value = Self.groupValue(groupBy.property, of: record) else {
                none.append(record)
                continue
            }
            let text = PropertyComparison.text(of: value)
            if let text, let index = options.firstIndex(where: { $0.caseInsensitiveCompare(text) == .orderedSame }) {
                optionEntries[index].append(record)
            } else if let index = others.firstIndex(where: { PropertyComparison.equals($0.value, value) }) {
                others[index].entries.append(record)
            } else {
                others.append((value, [record]))
            }
        }
        others.sort { PropertyComparison.sortOrder($0.value, $1.value) == .orderedAscending }
        var groups = zip(options, optionEntries).map { CollectionGroup(value: .string($0), entries: $1) }
            + others.map { CollectionGroup(value: $0.value, entries: $0.entries) }
        if groupBy.descending { groups.reverse() }
        if !none.isEmpty { groups.append(CollectionGroup(value: nil, entries: none)) }
        return groups
    }

    private func kind(of ref: PropertyRef, in definition: CollectionDefinition, entries: [NoteRecord]) -> PropertyKind {
        let property = definition.property(ref)
        if let kind = property.kind { return kind }
        if !property.options.isEmpty { return .select }
        switch ref.namespace {
        case .file:
            switch ref.name {
            case "mtime", "ctime": return .date
            case "tags": return .multiselect
            default: return .text
            }
        case .formula:
            return .text
        case .note:
            return Self.inferKind(entries.compactMap { Self.value(ref, of: $0) })
        }
    }

    static func inferKind(_ values: [PropertyValue]) -> PropertyKind {
        guard !values.isEmpty else { return .text }
        func all(_ test: (PropertyValue) -> Bool) -> Bool { values.allSatisfy(test) }
        if all({ if case .bool = $0 { return true } else { return false } }) { return .checkbox }
        if all({ if case .number = $0 { return true } else { return false } }) { return .number }
        if values.contains(where: { if case .list = $0 { return true } else { return false } }) { return .multiselect }
        if all({ if case .string(let text) = $0 { return isDate(text) } else { return false } }) { return .date }
        if all({ if case .string(let text) = $0 { return text.hasPrefix("http://") || text.hasPrefix("https://") }
                 else { return false } }) { return .url }
        return .text
    }

    static func isDate(_ text: String) -> Bool {
        text.range(of: #"^[0-9]{4}-[0-9]{2}-[0-9]{2}([T ][0-9:.]+(Z|[+-][0-9:]+)?)?$"#, options: .regularExpression) != nil
    }

    // MARK: Writing

    func create(folder: String) throws -> String {
        let folder = try VaultPath.normalize(folder)
        guard let name = folder.split(separator: "/").last.map(String.init) else {
            throw CollectionError.invalidArgument("folder")
        }
        let path = folder + "/" + name + "." + Self.fileExtension
        if vault.exists(path) { return path }
        let quoted = folder.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let inFolder = FrontmatterEditor.serializeString("file.inFolder(\"\(quoted)\")", flow: false)
        let yaml = """
        filters:
          and:
            - \(inFolder)
            - file.ext == "md"
        views:
          - type: table
            name: Table
            order:
              - file.name

        """
        try vault.write(path, yaml)
        invalidate()
        didWrite([VaultChange(kind: .added, path: path)])
        return path
    }

    func folderToAdopt(_ path: String) -> String? {
        guard let path = try? VaultPath.normalize(path), path.lowercased().hasSuffix("." + Self.fileExtension),
              let folder = (try? definition(.file(path)))?.home, vault.exists(folder),
              let name = folder.split(separator: "/").last
        else { return nil }
        let own = folder + "/" + name + "." + Self.fileExtension
        return own == path || vault.exists(own) ? nil : folder
    }

    func adopt(_ path: String) throws -> String {
        let path = try VaultPath.normalize(path)
        guard let folder = folderToAdopt(path), let name = folder.split(separator: "/").last else {
            throw CollectionError.notACollection(path)
        }
        let destination = folder + "/" + name + "." + Self.fileExtension
        try vault.move(path, to: destination)
        invalidate()
        didWrite([VaultChange(kind: .removed, path: path), VaultChange(kind: .added, path: destination)])
        return destination
    }

    func apply(_ edits: [CollectionEdit], to source: CollectionSource) throws -> CollectionSource {
        var base = try load(source).base
        let before = try base.yaml()
        for edit in edits { try base.apply(edit) }
        let after = try base.yaml()
        switch source {
        case .file(let path):
            guard after != before else { return source }
            let path = try VaultPath.normalize(path)
            try vault.write(path, after)
            didWrite([VaultChange(kind: .modified, path: path)])
            return source
        case .inline(_, let host):
            return .inline(yaml: after, host: host)
        }
    }

    func newEntry(in source: CollectionSource, title: String?, values: [String: PropertyValue]) throws -> String {
        let loaded = try load(source)
        let definition = try definition(source)
        // Without a folder in the filter, the entry goes next to the note or `.base` that holds the collection.
        let folder = definition.home ?? loaded.host.map { VaultPath.directory(of: $0.path) } ?? VaultPath.inbox
        let prefix = folder.isEmpty ? "" : folder + "/"
        let name = Self.fileName(title)
        var path = prefix + name + ".md"
        var number = 2
        while vault.exists(path) {
            path = prefix + name + " \(number).md"
            number += 1
        }

        var properties: [(String, PropertyValue)] = []
        var tags: [String] = []
        var evaluator = FilterEvaluator(entry: loaded.host ?? FileFacts(path: "", tags: [], properties: [:], modified: 0),
                                        host: loaded.host)
        for case .expression(let text) in Self.requirements(of: loaded.base.filters) {
            guard let expression = try? FilterExpression.parse(text) else { continue }
            switch expression {
            case .call(.member(.identifier("file"), "hasTag"), let arguments) where arguments.count == 1:
                if case .string(let tag) = evaluator.evaluate(arguments[0]) { tags.append(tag) }
            case .binary("==", let left, let right):
                if let key = Self.propertyName(left), let value = evaluator.evaluate(right).property {
                    properties.append((key, value))
                } else if let key = Self.propertyName(right), let value = evaluator.evaluate(left).property {
                    properties.append((key, value))
                }
            default:
                continue
            }
        }
        for (key, value) in values.sorted(by: { $0.key < $1.key }) {
            properties.removeAll { $0.0.caseInsensitiveCompare(key) == .orderedSame }
            properties.append((key, value))
        }
        if !tags.isEmpty, !properties.contains(where: { $0.0.lowercased() == "tags" }) {
            properties.append(("tags", .list(tags.map { .string($0.hasPrefix("#") ? String($0.dropFirst()) : $0) })))
        }

        var text = ""
        for (key, value) in properties { text = FrontmatterEditor.setting(key, to: value, in: text) }
        try vault.write(path, text)
        lock.withLock { movesDuringWrite = [:] }
        didWrite([VaultChange(kind: .added, path: path)])
        let moved = lock.withLock {
            defer { movesDuringWrite = nil }
            return movesDuringWrite?[path]
        }
        return moved ?? path
    }

    /// The property a `x` or `note.x` names.
    private static func propertyName(_ expression: FilterExpression) -> String? {
        switch expression {
        case .identifier(let name) where !["file", "note", "this", "formula"].contains(name): return name
        case .member(.identifier("note"), let name): return name
        case .index(.identifier("note"), .literal(.string(let name))): return name
        default: return nil
        }
    }

    static func fileName(_ title: String?) -> String {
        let cleaned = (title ?? "").components(separatedBy: CharacterSet(charactersIn: "/\\:\n\r\t"))
            .joined(separator: "-").trimmingCharacters(in: .whitespaces)
        let name = cleaned.hasPrefix(".") ? String(cleaned.drop { $0 == "." }) : cleaned
        return name.isEmpty ? "Untitled" : name
    }

    // MARK: Following moves

    /// After files were moved or renamed: the entries of a renamed note's blocks follow it, and the folders.
    func follow(_ moves: [String: String]) {
        lock.withLock { movesDuringWrite?.merge(moves) { $1 } }
        followRenamedNotes(moves)
        followFolders(moves)
    }

    /// A renamed note keeps its blocks' entries: every `collection: <old name>` takes the new name.
    private func followRenamedNotes(_ moves: [String: String]) {
        func basename(_ path: String) -> String? {
            guard path.lowercased().hasSuffix(".md") else { return nil }
            return FileFacts(path: path, tags: [], properties: [:], modified: 0).basename
        }
        var renames: [String: String] = [:]
        for (old, new) in moves {
            if let from = basename(old), let to = basename(new), from != to { renames[from] = to }
        }
        guard !renames.isEmpty, let noteQuery = noteQuery() else { return }
        var changes: [VaultChange] = []
        for record in noteQuery.run(NoteQuery(filters: [PropertyFilter(key: "collection", op: .exists)])) {
            guard case .string(let name)? = record.properties["collection"], let renamed = renames[name],
                  let text = try? vault.read(record.path) else { continue }
            let rewritten = FrontmatterEditor.setting("collection", to: .string(renamed), in: text)
            if rewritten != text, (try? vault.write(record.path, rewritten)) != nil {
                changes.append(VaultChange(kind: .modified, path: record.path))
            }
        }
        if !changes.isEmpty { didWrite(changes) }
    }

    /// `file.inFolder("old/…")` in every `.base` points to the new folder, and a folder's own `<old name>.base` takes
    /// the folder's new name.
    private func followFolders(_ moves: [String: String]) {
        var folders: [String: String] = [:]
        for (old, new) in moves {
            var (from, to) = (VaultPath.directory(of: old), VaultPath.directory(of: new))
            while !from.isEmpty, !to.isEmpty, from != to, !vault.exists(from) {
                folders[from] = to
                let (parentFrom, parentTo) = (VaultPath.directory(of: from), VaultPath.directory(of: to))
                guard from.split(separator: "/").last == to.split(separator: "/").last else { break }
                (from, to) = (parentFrom, parentTo)
            }
        }
        guard !folders.isEmpty else { return }
        invalidate()
        var changes: [VaultChange] = []
        for path in collections() {
            guard var text = try? vault.read(path) else { continue }
            let rewritten = Self.rewritingFolders(in: text, folders)
            if rewritten != text, (try? vault.write(path, rewritten)) != nil {
                text = rewritten
                changes.append(VaultChange(kind: .modified, path: path))
            }
            let folder = VaultPath.directory(of: path)
            guard let old = folders.first(where: { $0.value == folder })?.key,
                  let oldName = old.split(separator: "/").last, let newName = folder.split(separator: "/").last,
                  path.split(separator: "/").last == oldName + "." + Self.fileExtension
            else { continue }
            let renamed = folder + "/" + newName + "." + Self.fileExtension
            if !vault.exists(renamed), (try? vault.move(path, to: renamed)) != nil {
                changes.append(VaultChange(kind: .removed, path: path))
                changes.append(VaultChange(kind: .added, path: renamed))
            }
        }
        invalidate()
        if !changes.isEmpty { didWrite(changes) }
    }

    /// The text with each `inFolder("…")` argument under a moved folder pointing to its new place.
    static func rewritingFolders(in text: String, _ folders: [String: String]) -> String {
        let pattern = #"inFolder\(\s*(["'])((?:\\.|(?!\1).)*)\1\s*\)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        var result = text
        for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
            guard let range = Range(match.range(at: 2), in: text), let whole = Range(match.range(at: 2), in: result)
            else { continue }
            let folder = String(text[range])
            let best = folders.keys.filter { folder == $0 || folder.hasPrefix($0 + "/") }.max { $0.count < $1.count }
            guard let best else { continue }
            result.replaceSubrange(whole, with: folders[best]! + folder.dropFirst(best.count))
        }
        return result
    }
}
