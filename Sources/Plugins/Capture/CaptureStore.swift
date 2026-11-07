import Foundation
import PluginKit

/// Stored in `.loam/config.json` under `plugins.capture.settings`.
public struct CaptureSettings: Codable, Equatable, Sendable {
    public static let defaultCollection = "Saved for later"

    /// The folder of the collection captures go into, vault-relative.
    public var collection = CaptureSettings.defaultCollection
    /// `auto`, or an agent id (`claude`, `codex`…): who sorts and summarizes.
    public var agent = "auto"
    /// Whether the agent is asked at all. Off: captures are saved with their metadata, no AI.
    public var useAgent = true

    public init(collection: String = CaptureSettings.defaultCollection, agent: String = "auto", useAgent: Bool = true) {
        self.collection = collection
        self.agent = agent
        self.useAgent = useAgent
    }
}

/// Saves captures as notes in one collection, at once and without any agent: the note, its files, the frontmatter
/// that recognises a duplicate. Everything after (page metadata, the agent) only improves a note that already exists.
public final class CaptureStore: @unchecked Sendable {
    public static let maxBytes = 200_000_000

    private let vault: VaultAccess
    private let settings: () -> CaptureSettings
    private let attachments: () -> AttachmentsService?
    private let noteQuery: () -> NoteQueryService?
    private let trash: () -> TrashService?
    private let now: () -> Date
    private let lock = NSLock()
    private var recentOutcomes: [CaptureOutcome] = []

    public init(
        vault: VaultAccess,
        settings: @escaping () -> CaptureSettings,
        attachments: @escaping () -> AttachmentsService? = { nil },
        noteQuery: @escaping () -> NoteQueryService? = { nil },
        trash: @escaping () -> TrashService? = { nil },
        now: @escaping () -> Date = Date.init
    ) {
        self.vault = vault
        self.settings = settings
        self.attachments = attachments
        self.noteQuery = noteQuery
        self.trash = trash
        self.now = now
    }

    /// The plugin's settings now (the window and the agent step read them through the store).
    public var currentSettings: CaptureSettings { settings() }

    /// The collection's folder, from the settings; the default one when the setting is empty or invalid.
    public var folder: String {
        let raw = settings().collection.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = (try? VaultPath.normalize(raw)) ?? ""
        return normalized.isEmpty || normalized.hasPrefix(".") ? CaptureSettings.defaultCollection : normalized
    }

    public var collectionName: String { (folder as NSString).lastPathComponent }

    // MARK: Saving

    /// Saves each item as its own note (a typed note alone becomes a text capture). Exact duplicates are not saved
    /// again: their outcome points at the existing note, and the typed note is added to it.
    /// `allowDuplicates` saves an item again even when it is already there ("Save as new").
    public func save(_ items: [CaptureContent], note: String = "", allowDuplicates: Bool = false) async throws -> [CaptureOutcome] {
        let note = note.trimmingCharacters(in: .whitespacesAndNewlines)
        if items.isEmpty {
            guard !note.isEmpty else { throw CaptureError.empty }
            return [try await save(.text(note), note: "", allowDuplicate: allowDuplicates)]
        }
        var outcomes: [CaptureOutcome] = []
        for item in items { outcomes.append(try await save(item, note: note, allowDuplicate: allowDuplicates)) }
        return outcomes
    }

    public func save(_ item: CaptureContent, note: String, allowDuplicate: Bool = false) async throws -> CaptureOutcome {
        let (source, hash, data) = try identity(of: item)
        if !allowDuplicate, let existing = duplicate(source: source, hash: hash) {
            if !note.isEmpty { try appendNote(note, to: existing) }
            let outcome = CaptureOutcome(path: existing, title: Self.title(of: existing), kind: item.kind, duplicate: true)
            remember(outcome)
            return outcome
        }
        try ensureCollection()
        let title = item.provisionalTitle(now: now())
        let path = uniquePath(for: title)
        var files: [String] = []
        var embed: String?
        var cover: String?
        if case let .file(name, _) = item, let data {
            if let attachments = attachments() {
                let imported = try await attachments.importFile(AttachmentImport(name: name, contents: .data(data), notePath: path))
                files.append(imported.path)
                embed = imported.markdown
                if imported.kind == .image { cover = imported.path }
            } else {
                // Without the Attachments plugin the file goes next to the note.
                let filePath = folder + "/" + name
                try vault.writeData(filePath, data)
                files.append(filePath)
                embed = "[\(name)](\(filePath.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? filePath))"
            }
        }
        let text = Self.noteText(
            item: item, title: title, source: source, hash: hash, cover: cover, embed: embed, note: note,
            captured: Self.timestamp(now())
        )
        try vault.write(path, text)
        let outcome = CaptureOutcome(path: path, title: title, kind: item.kind, duplicate: false, files: files)
        remember(outcome)
        return outcome
    }

    /// The URL (for a link) or the hash that recognises the item again, and a file's bytes.
    private func identity(of item: CaptureContent) throws -> (source: String?, hash: String?, data: Data?) {
        switch item {
        case let .link(url, _):
            guard let canonical = CaptureIdentity.canonicalURL(url) else { throw CaptureError.unsupported(url) }
            return (canonical, nil, nil)
        case .text(let text):
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw CaptureError.empty }
            return (nil, CaptureIdentity.hash(text: text), nil)
        case let .file(_, contents):
            let data = try contents.data()
            guard data.count <= Self.maxBytes else { throw CaptureError.tooLarge(bytes: data.count) }
            return (nil, CaptureIdentity.hash(data), data)
        }
    }

    // MARK: After saving

    /// Fills in what the page says about itself: a better title (the note is renamed, it has no links yet), its
    /// description and its preview picture. Returns the note's path, which may have changed.
    @discardableResult
    public func enrich(_ path: String, with metadata: LinkMetadata, cover: (name: String, data: Data)?) async throws -> String {
        var path = path
        var text = try vault.read(path)
        if let title = metadata.title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty,
           title != Self.title(of: path) {
            let renamed = uniquePath(for: Self.shorten(title))
            let oldHeading = "# " + Self.title(of: path)
            if let range = text.range(of: oldHeading) {
                text.replaceSubrange(range, with: "# " + Self.title(of: renamed))
            }
            try vault.move(path, to: renamed)
            replaceRecent(path, with: renamed)
            path = renamed
        }
        if let description = metadata.description?.trimmingCharacters(in: .whitespacesAndNewlines), !description.isEmpty,
           !text.contains("> " + description) {
            text = Self.insertAfterHeading("> " + description.replacingOccurrences(of: "\n", with: " "), in: text)
        }
        if let cover, let attachments = attachments(), !text.contains("\ncover:") {
            if let imported = try? await attachments.importFile(AttachmentImport(name: cover.name, contents: .data(cover.data), notePath: path)) {
                text = FrontmatterEditor.setting("cover", to: .string(imported.path), in: text)
                addFile(imported.path, to: path)
            }
        }
        try vault.write(path, text)
        return path
    }

    /// Adds a cover picture to a note (a PDF's first page drawn by the app).
    public func setCover(_ path: String, name: String, data: Data) async throws {
        guard let attachments = attachments() else { return }
        let imported = try await attachments.importFile(AttachmentImport(name: name, contents: .data(data), notePath: path))
        let text = try vault.read(path)
        try vault.write(path, FrontmatterEditor.setting("cover", to: .string(imported.path), in: text))
        addFile(imported.path, to: path)
    }

    /// Adds the user's words to an item already saved, under its `## Note` heading, dated.
    public func appendNote(_ note: String, to path: String) throws {
        var text = try vault.read(path)
        let line = "- \(Self.day(now())): \(note.replacingOccurrences(of: "\n", with: " "))"
        if text.contains("\n## Note\n") {
            text = text.replacingOccurrences(of: "\n## Note\n", with: "\n## Note\n\(line)\n")
        } else {
            if !text.hasSuffix("\n") { text += "\n" }
            text += "\n## Note\n\(line)\n"
        }
        try vault.write(path, text)
    }

    /// Puts a capture back: the note and the files imported for it go to `.trash/` (Recently Deleted).
    public func undo(_ outcome: CaptureOutcome) throws {
        guard !outcome.duplicate else { return }
        let current = recent().first { $0.path == outcome.path || $0.files == outcome.files && !$0.files.isEmpty } ?? outcome
        for path in [current.path] + current.files where vault.exists(path) {
            try moveToTrash(path)
        }
        lock.lock()
        recentOutcomes.removeAll { $0.path == current.path }
        lock.unlock()
    }

    private func moveToTrash(_ path: String) throws {
        let ext = (path as NSString).pathExtension
        let base = ".trash/" + (ext.isEmpty ? path : String(path.dropLast(ext.count + 1)))
        var destination = ext.isEmpty ? base : base + "." + ext
        var number = 2
        while vault.exists(destination) {
            destination = ext.isEmpty ? "\(base) \(number)" : "\(base) \(number).\(ext)"
            number += 1
        }
        try vault.move(path, to: destination)
        try? trash()?.record(destination, originalPath: path)
    }

    // MARK: Recent captures

    /// The last captures of this session, newest first.
    public func recent() -> [CaptureOutcome] {
        lock.lock()
        defer { lock.unlock() }
        return recentOutcomes
    }

    /// Follows a note the agent renamed or moved, so Undo and Open still find it.
    public func follow(_ old: String, to new: String) {
        replaceRecent(old, with: new)
    }

    private func remember(_ outcome: CaptureOutcome) {
        lock.lock()
        recentOutcomes.removeAll { $0.path == outcome.path }
        recentOutcomes.insert(outcome, at: 0)
        if recentOutcomes.count > 20 { recentOutcomes.removeLast(recentOutcomes.count - 20) }
        lock.unlock()
    }

    private func replaceRecent(_ old: String, with new: String) {
        lock.lock()
        for index in recentOutcomes.indices where recentOutcomes[index].path == old {
            recentOutcomes[index].path = new
            recentOutcomes[index].title = Self.title(of: new)
        }
        lock.unlock()
    }

    private func addFile(_ file: String, to path: String) {
        lock.lock()
        for index in recentOutcomes.indices where recentOutcomes[index].path == path {
            recentOutcomes[index].files.append(file)
        }
        lock.unlock()
    }

    // MARK: Duplicates

    /// The note already holding this URL or these bytes: first in the collection (read directly, so a capture made
    /// a second ago counts), then anywhere through the note index.
    public func duplicate(source: String?, hash: String?) -> String? {
        let wanted: [(String, String)] = [source.map { ("source", $0) }, hash.map { ("content-hash", $0) }].compactMap { $0 }
        guard !wanted.isEmpty else { return nil }
        let folder = self.folder
        let paths = ((try? vault.markdownPaths()) ?? []).filter { $0.hasPrefix(folder + "/") }
        for path in paths {
            guard let text = try? vault.read(path), let yaml = MarkdownFrontmatter.split(text).yaml else { continue }
            for (key, value) in wanted where Self.value(of: key, in: yaml) == value { return path }
        }
        guard let query = noteQuery() else { return nil }
        for (key, value) in wanted {
            let found = query.run(NoteQuery(filters: [PropertyFilter(key: key, op: .equals, value: .string(value))], limit: 1))
            if let first = found.first { return first.path }
        }
        return nil
    }

    static func value(of key: String, in yaml: String) -> String? {
        for line in yaml.split(separator: "\n") where line.hasPrefix(key + ":") {
            var value = line.dropFirst(key.count + 1).trimmingCharacters(in: .whitespaces)
            if value.count >= 2, value.first == "\"" || value.first == "'", value.last == value.first {
                value = String(value.dropFirst().dropLast()).replacingOccurrences(of: "\\\"", with: "\"")
            }
            return value
        }
        return nil
    }

    // MARK: The collection

    /// Writes the collection's `.base` (Gallery with the covers, then a table) the first time; an existing one is
    /// never touched. Returns its path.
    @discardableResult
    public func ensureCollection() throws -> String {
        let folder = self.folder
        let path = folder + "/" + collectionName + ".base"
        if vault.exists(path) { return path }
        // A folder the user already made into a collection under another name keeps it.
        if let entries = try? vault.list(folder), entries.contains(where: { $0.path.hasSuffix(".base") }) {
            return entries.first { $0.path.hasSuffix(".base") }!.path
        }
        let quoted = folder.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let filter = FrontmatterEditor.serializeString("file.inFolder(\"\(quoted)\")", flow: false)
        try vault.write(path, """
        filters:
          and:
            - \(filter)
            - file.ext == "md"
        properties:
          note.type:
            displayName: Type
            type: select
            options:
              - link
              - image
              - pdf
              - text
              - file
          note.captured:
            displayName: Saved
        views:
          - type: cards
            name: Gallery
            image: note.cover
            order:
              - file.name
              - note.type
              - note.tags
            sort:
              - property: note.captured
                direction: DESC
          - type: table
            name: Table
            order:
              - file.name
              - note.type
              - note.tags
              - note.captured
            sort:
              - property: note.captured
                direction: DESC

        """)
        return path
    }

    /// Tags in use across the vault, most used first, for the agent to reuse.
    public func tagsInUse(limit: Int = 30) -> [String] {
        guard let query = noteQuery() else { return [] }
        var counts: [String: Int] = [:]
        for record in query.run(NoteQuery()) {
            for tag in record.tags { counts[tag.lowercased(), default: 0] += 1 }
        }
        return counts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.prefix(limit).map(\.key)
    }

    // MARK: Note text

    static func noteText(
        item: CaptureContent, title: String, source: String?, hash: String?, cover: String?, embed: String?, note: String,
        captured: String
    ) -> String {
        var front = [FrontmatterEditor.line("type", .string(item.kind.rawValue))]
        switch item {
        case .link: if let source { front.append(FrontmatterEditor.line("source", .string(source))) }
        case .file(let name, _): front.append(FrontmatterEditor.line("source", .string(name)))
        case .text: break
        }
        front.append(FrontmatterEditor.line("captured", .string(captured)))
        if let cover { front.append(FrontmatterEditor.line("cover", .string(cover))) }
        if let hash { front.append(FrontmatterEditor.line("content-hash", .string(hash))) }

        var body = ["# \(title)"]
        switch item {
        case let .link(url, _): body.append("[Open the original](\(url))")
        case .text(let text): body.append(text.trimmingCharacters(in: .whitespacesAndNewlines))
        case .file: if let embed { body.append(embed) }
        }
        if !note.isEmpty { body.append("## Note\n\(note)") }
        return "---\n" + front.joined(separator: "\n") + "\n---\n" + body.joined(separator: "\n\n") + "\n"
    }

    static func insertAfterHeading(_ line: String, in text: String) -> String {
        guard let heading = text.range(of: "\n# ") else { return text + "\n" + line + "\n" }
        let end = text[heading.upperBound...].firstIndex(of: "\n") ?? text.endIndex
        var result = text
        result.insert(contentsOf: "\n\n" + line, at: end)
        return result
    }

    /// A free note path in the collection for `title`: characters files cannot hold removed, `Title 2.md` when taken.
    func uniquePath(for title: String) -> String {
        let illegal = CharacterSet(charactersIn: "/\\:*?\"<>|#^[]").union(.newlines).union(.controlCharacters)
        var name = title.components(separatedBy: illegal).joined(separator: " ")
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        while name.hasPrefix(".") { name.removeFirst() }
        if name.isEmpty { name = "Capture" }
        if name.count > 80 { name = String(name.prefix(80)).trimmingCharacters(in: .whitespaces) }
        var candidate = "\(folder)/\(name).md"
        var number = 2
        while vault.exists(candidate) {
            candidate = "\(folder)/\(name) \(number).md"
            number += 1
        }
        return candidate
    }

    static func shorten(_ title: String) -> String {
        let oneLine = title.split(whereSeparator: \.isNewline).joined(separator: " ")
        return oneLine.count > 70 ? String(oneLine.prefix(69)) + "…" : oneLine
    }

    public static func title(of path: String) -> String {
        ((path as NSString).lastPathComponent as NSString).deletingPathExtension
    }

    static func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = .current
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    static func day(_ date: Date) -> String {
        String(timestamp(date).prefix(10))
    }
}
