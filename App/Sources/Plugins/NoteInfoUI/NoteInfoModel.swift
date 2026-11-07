import Foundation
import Observation
import PluginKitUI
import TasksPlugin

/// The inspector's state for the note in the focused tab: its properties, the notes linking to it, where it is and
/// its statistics. The view only reads it, so tests drive the tab through it.
@MainActor
@Observable
final class NoteInfoModel {
    /// One frontmatter property, its value shown as text.
    struct Property: Identifiable, Hashable, Sendable {
        var id: String { key }
        let key: String
        let value: String
    }

    /// A note linking to the followed one.
    struct Backlink: Identifiable, Hashable, Sendable {
        var id: String { path }
        let path: String
        let title: String
    }

    struct Statistics: Hashable, Sendable {
        var words = 0
        var characters = 0
        /// Nil when the `tasks` service is missing: the panel then hides the row.
        var tasksDone: Int?
        var tasksTotal: Int?

        /// Whole minutes at `wordsPerMinute`, at least 1 for a note with words.
        var readingMinutes: Int {
            words == 0 ? 0 : max(1, Int((Double(words) / Double(NoteInfoModel.wordsPerMinute)).rounded(.up)))
        }
    }

    /// Everything the panel shows about one note.
    struct Info: Hashable, Sendable {
        let path: String
        let title: String
        /// The folder it is in, empty at the root.
        let folder: String
        /// The frontmatter properties but `tags`, `created` first, then by key.
        let properties: [Property]
        /// Frontmatter and inline tags, without `#`.
        let tags: [String]
        /// The `created` property, else the file's creation date.
        let created: Date?
        let modified: Date?
        let backlinks: [Backlink]
        /// The boards with a card for the note, when the canvas plugin runs.
        let boards: [Backlink]
        let statistics: Statistics
    }

    nonisolated static let wordsPerMinute = 200

    /// The note followed: the focused tab's Markdown file, nil when none is open.
    private(set) var active: String?
    /// What the panel shows for the followed note, worked out when read: only the Stats tab reads it, so a note
    /// opened with the tab hidden costs nothing here (the file, its tasks and the boards were read on every switch).
    var info: Info? {
        _ = revision
        if isStale {
            isStale = false
            let new = active.map(info(for:))
            if new != cached { cached = new }
        }
        return cached
    }
    /// Changes when the note or what is known about it changes; `info` is worked out again on the next read.
    private var revision = 0
    @ObservationIgnored private var isStale = true
    @ObservationIgnored private var cached: Info?

    @ObservationIgnored private let vault: VaultAccess
    @ObservationIgnored private let graph: NoteGraphService
    @ObservationIgnored private let query: NoteQueryService
    @ObservationIgnored private let tasks: @MainActor () -> TasksService?
    @ObservationIgnored private let editor: @MainActor () -> (any EditorService)?
    @ObservationIgnored private let workspace: @MainActor () -> (any Workspace)?
    @ObservationIgnored private let boards: @MainActor () -> NoteBoardsService?

    init(
        vault: VaultAccess,
        graph: NoteGraphService,
        query: NoteQueryService,
        tasks: @escaping @MainActor () -> TasksService?,
        editor: @escaping @MainActor () -> (any EditorService)?,
        workspace: @escaping @MainActor () -> (any Workspace)?,
        boards: @escaping @MainActor () -> NoteBoardsService? = { nil }
    ) {
        self.vault = vault
        self.graph = graph
        self.query = query
        self.tasks = tasks
        self.editor = editor
        self.workspace = workspace
        self.boards = boards
    }

    // MARK: Following the open note

    /// Follows the focused tab: a Markdown file, or nothing.
    func activeChanged(_ resource: Resource?) {
        let path = resource.flatMap { $0.kind == .file && Self.isNote($0.path) ? $0.path : nil }
        guard path != active else { return }
        active = path
        refresh()
    }

    /// Keeps following the note when it, or its folder, moved.
    func notesMoved(_ moves: [String: String]) {
        if let active, let moved = moves[active] { self.active = moved }
        refresh()
    }

    /// The unsaved text of an open note changed.
    func textChanged(_ path: String) {
        if path == active { refresh() }
    }

    /// Reads everything about the followed note again, when `info` is next read.
    func refresh() {
        isStale = true
        revision &+= 1
    }

    /// What the panel shows for the note at `path`: the graph for properties and backlinks (the saved file), the
    /// editor's unsaved text for the statistics when the note is open.
    func info(for path: String) -> Info {
        let note = graph.note(at: path)
        let frontmatter = note?.properties ?? [:]
        let attributes = try? FileManager.default.attributesOfItem(
            atPath: vault.rootURL.appendingPathComponent(path).path
        )
        let liveText: (String) -> String? = { [editor] in editor()?.text(of: $0) }
        var statistics = Self.statistics(of: liveText(path) ?? (try? vault.read(path)) ?? "")
        if let tasks = tasks() {
            let items = (try? tasks.tasks(TaskFilter(path: path), liveText: liveText)) ?? []
            statistics.tasksTotal = items.count
            statistics.tasksDone = items.filter(\.done).count
        }
        return Info(
            path: path,
            title: Self.title(note, path: path),
            folder: VaultPath.directory(of: path),
            properties: Self.properties(frontmatter),
            tags: note?.tags ?? [],
            created: frontmatter["created"].flatMap(Self.date) ?? attributes?[.creationDate] as? Date,
            modified: attributes?[.modificationDate] as? Date,
            backlinks: graph.backlinks(to: path).map { Backlink(path: $0, title: Self.title(graph.note(at: $0), path: $0)) },
            boards: ((try? boards()?.boards(showing: path)) ?? []).map {
                Backlink(path: $0, title: (($0 as NSString).lastPathComponent as NSString).deletingPathExtension)
            },
            statistics: statistics
        )
    }

    // MARK: Actions

    /// A click on a backlink: in the focused tab, or beside it with Command held.
    func open(_ path: String, beside: Bool) {
        workspace()?.open(.file(path), placement: beside ? .beside : .replace)
    }

    /// The followed note (or the note at `path`) as JSON, for the `note-info.show` command.
    func report(for path: String?) throws -> String {
        let normalized = try path.map { try VaultPath.normalize($0) }
        guard let target = normalized ?? active else { return "No note is open." }
        guard vault.exists(target) else { throw VaultError.notFound(path: target) }
        let info = info(for: target)
        return try JSON.string(Report(
            path: info.path,
            title: info.title,
            properties: graph.note(at: target)?.properties ?? [:],
            tags: info.tags,
            backlinks: info.backlinks.map(\.path),
            boards: info.boards.map(\.path),
            words: info.statistics.words,
            characters: info.statistics.characters,
            tasksDone: info.statistics.tasksDone,
            tasksTotal: info.statistics.tasksTotal,
            readingMinutes: info.statistics.readingMinutes
        ))
    }

    private struct Report: Encodable {
        let path: String
        let title: String
        let properties: [String: PropertyValue]
        let tags: [String]
        let backlinks: [String]
        let boards: [String]
        let words: Int
        let characters: Int
        let tasksDone: Int?
        let tasksTotal: Int?
        let readingMinutes: Int
    }

    // MARK: Pure helpers (tested without a vault)

    static func isNote(_ path: String) -> Bool { path.lowercased().hasSuffix(".md") }

    static func title(_ note: NoteInfo?, path: String) -> String {
        if let title = note?.title, !title.isEmpty { return title }
        return Resource.file(path).name
    }

    /// The properties to list: every key but `tags`, `created` first, then by key.
    static func properties(_ frontmatter: [String: PropertyValue]) -> [Property] {
        frontmatter
            .filter { $0.key.lowercased() != "tags" }
            .sorted { lhs, rhs in
                if (lhs.key == "created") != (rhs.key == "created") { return lhs.key == "created" }
                return lhs.key.localizedStandardCompare(rhs.key) == .orderedAscending
            }
            .map { Property(key: $0.key, value: display($0.value)) }
    }

    static func display(_ value: PropertyValue) -> String {
        switch value {
        case .null: ""
        case .bool(let value): value ? "true" : "false"
        case .number(let value):
            value.rounded() == value && abs(value) < 1e15 ? String(Int(value)) : String(value)
        case .string(let value): value
        case .list(let values): values.map(display).joined(separator: ", ")
        case .map(let values): values.keys.sorted().map { "\($0): \(display(values[$0] ?? .null))" }.joined(separator: ", ")
        }
    }

    /// A `created` property as a date: `YYYY-MM-DD`, optionally with a time (ISO 8601).
    static func date(_ value: PropertyValue) -> Date? {
        guard case .string(let raw) = value else { return nil }
        let text = raw.trimmingCharacters(in: .whitespaces)
        if let date = ISO8601DateFormatter().date(from: text) { return date }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        for format in ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd HH:mm", "yyyy-MM-dd"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: text) { return date }
        }
        return nil
    }

    /// Link destinations and task checkboxes, which are no words of the text.
    private static let notWords = try! NSRegularExpression(
        pattern: #"\]\([^)\n]*\)|^[ \t]*(?:[-*+]|\d+[.)])[ \t]+\[[ xX]\]"#,
        options: [.anchorsMatchLines]
    )

    /// Words and characters of the note's body, the frontmatter left out. A word is a run of letters or digits
    /// (with inner apostrophes and hyphens), so Markdown syntax (`#`, `-`, `[ ]`, link destinations) counts for
    /// nothing. Characters are those of the body without line breaks.
    static func statistics(of text: String) -> Statistics {
        let body = MarkdownFrontmatter.split(text).body
        let prose = notWords.stringByReplacingMatches(
            in: body, range: NSRange(body.startIndex..., in: body), withTemplate: " "
        )
        var words = 0
        var inWord = false
        for character in prose {
            let isWordCharacter = character.isLetter || character.isNumber
                || (inWord && (character == "'" || character == "’" || character == "-"))
            if isWordCharacter, !inWord { words += 1 }
            inWord = isWordCharacter
        }
        return Statistics(words: words, characters: body.filter { !$0.isNewline }.count)
    }
}
