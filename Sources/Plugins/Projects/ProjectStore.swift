import Foundation
import PluginKit

/// The `projects` service over the vault. A project is a note directly in the projects folder; its tasks are the
/// notes of the folder named after it, each with a `status` (its Kanban column) and maybe a `due`. Writes only new
/// notes, the folder's collection and, when a project is renamed, its task folder and Kanban; then sends the changes
/// through `didWrite`.
public final class ProjectStore: ProjectsService {
    private let vault: VaultAccess
    private let noteQuery: () -> NoteQueryService?
    private let clock: () -> String
    private let didWrite: (VaultChange) -> Void
    private let lock = NSLock()
    private var currentFolder: String

    public init(
        vault: VaultAccess,
        folder: String = ProjectsSettings().folder,
        noteQuery: @escaping () -> NoteQueryService?,
        today: @escaping () -> String = ProjectStore.systemToday,
        didWrite: @escaping (VaultChange) -> Void = { _ in }
    ) {
        self.vault = vault
        self.noteQuery = noteQuery
        self.clock = today
        self.didWrite = didWrite
        self.currentFolder = ProjectsSettings.resolve(folder)
    }

    public static func systemToday() -> String {
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        return String(format: "%04d-%02d-%02d", parts.year!, parts.month!, parts.day!)
    }

    public var today: String { clock() }

    public var folder: String {
        get { lock.withLock { currentFolder } }
        set { lock.withLock { currentFolder = ProjectsSettings.resolve(newValue) } }
    }

    public var collectionPath: String {
        let folder = folder
        let name = folder.split(separator: "/").last.map(String.init) ?? folder
        return folder + "/" + name + ".base"
    }

    /// A project is the note named after its folder: `<folder>/<name>/<name>.md`.
    public func isProject(_ path: String) -> Bool {
        guard let parts = parts(path), parts.count == 2 else { return false }
        return parts[1] == parts[0] + ".md"
    }

    public func taskFolder(of project: String) -> String {
        VaultPath.directory(of: project)
    }

    /// The path below the projects folder, split; nil outside it or for a file that is not a note.
    private func parts(_ path: String) -> [String]? {
        let folder = folder
        guard path.lowercased().hasSuffix(".md"), path.hasPrefix(folder + "/") else { return nil }
        return path.dropFirst(folder.count + 1).split(separator: "/").map(String.init)
    }

    // MARK: Reading

    public func projects() -> [ProjectItem] {
        guard let noteQuery = noteQuery() else { return [] }
        let notes = noteQuery.run(NoteQuery(folder: folder))
        let today = today
        var tasksByProject: [String: TaskCount] = [:]
        for note in notes where !isProject(note.path) {
            guard let project = project(ofTask: note.path) else { continue }
            let status = Self.string(note.properties["status"])
            var count = tasksByProject[project, default: TaskCount()]
            count.total += 1
            if Self.isDone(status) {
                count.done += 1
            } else {
                if Self.isInProgress(status) { count.inProgress += 1 }
                if let due = Self.string(note.properties["due"]).flatMap(Self.day), due < today { count.late += 1 }
            }
            tasksByProject[project] = count
        }
        return notes.filter { isProject($0.path) }.map { note in
            let status = Self.string(note.properties["status"])
            let due = Self.string(note.properties["due"]).flatMap(Self.day)
            var tasks = tasksByProject[note.path] ?? TaskCount()
            // The note's own checkboxes count too: a project's tasks are often a list in it before they are notes.
            if let text = try? vault.read(note.path) {
                let boxes = Self.checkboxes(in: text)
                tasks.total += boxes.total
                tasks.done += boxes.done
            }
            let done = Self.isDone(status) || (tasks.total > 0 && tasks.done == tasks.total)
            return ProjectItem(
                path: note.path, title: Self.basename(note.path), status: status, due: due,
                overdue: due.map { $0 < today && !done } ?? false, tasks: tasks
            )
        }
        .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    public func tasks(dueOn day: String) -> [ProjectTask] {
        guard let noteQuery = noteQuery() else { return [] }
        let includeLate = day == today
        return noteQuery.run(NoteQuery(folder: folder)).compactMap { note -> ProjectTask? in
            guard !isProject(note.path), let project = project(ofTask: note.path),
                  let due = Self.string(note.properties["due"]).flatMap(Self.day) else { return nil }
            let status = Self.string(note.properties["status"])
            guard !Self.isDone(status), due == day || (includeLate && due < day) else { return nil }
            return ProjectTask(path: note.path, title: note.title, project: project, status: status, due: due)
        }
        .sorted { ($0.due ?? "", $0.title) < ($1.due ?? "", $1.title) }
    }

    /// The project note a task note belongs to: `<folder>/<name>/task.md` is a task of `<folder>/<name>/<name>.md`.
    private func project(ofTask path: String) -> String? {
        guard let parts = parts(path), parts.count == 2, parts[1] != parts[0] + ".md" else { return nil }
        return folder + "/" + parts[0] + "/" + parts[0] + ".md"
    }

    // MARK: Writing

    @discardableResult
    public func ensureCollection() throws -> String {
        let path = collectionPath
        let filter = FrontmatterEditor.serializeString("file.folder == \"\(Self.escaped(folder))/\" + file.basename", flow: false)
        if vault.exists(path) {
            // A collection of the old layout lists the notes directly in the folder, so it misses every project now
            // that each lives in a folder of its own: its filter follows.
            let text = try vault.read(path)
            // Or every note below it, tasks too, when the folder was made a collection before it held projects.
            let rules = ["file.folder == \"\(Self.escaped(folder))\"", "file.inFolder(\"\(Self.escaped(folder))\")"]
            let olds = rules.flatMap { ["- " + $0, "- " + FrontmatterEditor.serializeString($0, flow: false)] }
            if let range = olds.lazy.compactMap({ old in text.range(of: old).flatMap { text[$0.upperBound...].hasPrefix("\n") ? $0 : nil } }).first {
                try vault.write(path, text.replacingCharacters(in: range, with: "- " + filter))
                didWrite(VaultChange(kind: .modified, path: path))
            }
            return path
        }
        let yaml = """
        filters:
          and:
            - \(filter)
            - file.ext == "md"
        properties:
          status:
            displayName: Status
            type: select
            options:
              - Active
              - Idea
              - Paused
              - Done
          due:
            displayName: Due
            type: date
        views:
          - type: projects
            name: Projects
            groupBy:
              property: status
              direction: ASC
            order:
              - file.name
              - status
              - due
          - type: kanban
            name: Board
            groupBy:
              property: status
              direction: ASC
            order:
              - file.name
              - due
          - type: table
            name: Table
            order:
              - file.name
              - status
              - due

        """
        try vault.write(path, yaml)
        didWrite(VaultChange(kind: .added, path: path))
        return path
    }

    public func create(title: String, status: String?, due: String?) throws -> String {
        let name = Self.fileName(title)
        if let due, !due.isEmpty, Self.day(due) == nil { throw ProjectsError.invalidArgument(name: "due") }
        try ensureCollection()
        var unique = name
        var number = 2
        while vault.exists(folder + "/" + unique) || vault.exists(folder + "/" + unique + ".md") {
            unique = name + " \(number)"
            number += 1
        }
        let path = folder + "/" + unique + "/" + unique + ".md"
        var text = FrontmatterEditor.setting("status", to: .string(status.flatMap { $0.isEmpty ? nil : $0 } ?? "Active"), in: "")
        if let due, !due.isEmpty { text = FrontmatterEditor.setting("due", to: .string(due), in: text) }
        try vault.write(path, text + Self.body)
        didWrite(VaultChange(kind: .added, path: path))
        return path
    }

    public func addTask(project: String, title: String, status: String?, due: String?, text: String?) throws -> String {
        let named = folder + "/" + Self.fileName(project) + "/" + Self.fileName(project) + ".md"
        let note = isProject(project) ? project : named
        guard isProject(note), vault.exists(note) else { throw ProjectsError.invalidArgument(name: "project") }
        if let due, !due.isEmpty, Self.day(due) == nil { throw ProjectsError.invalidArgument(name: "due") }
        let directory = taskFolder(of: note)
        let name = Self.fileName(title)
        var unique = name
        var number = 2
        while vault.exists(directory + "/" + unique + ".md") || directory + "/" + unique + ".md" == note {
            unique = name + " \(number)"
            number += 1
        }
        let path = directory + "/" + unique + ".md"
        var content = FrontmatterEditor.setting("status", to: .string(status.flatMap { $0.isEmpty ? nil : $0 } ?? "To do"), in: "")
        if let due, !due.isEmpty { content = FrontmatterEditor.setting("due", to: .string(due), in: content) }
        if let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            content += "\n" + text.trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
        }
        try vault.write(path, content)
        didWrite(VaultChange(kind: .added, path: path))
        return path
    }

    @discardableResult
    public func adoptNewNote(_ path: String) throws -> String? {
        let folder = folder
        // Fields alone count as new too: a board's "+" writes the column's status, a view's the filter's values.
        guard let parts = parts(path), let text = try? vault.read(path), NoteContent.hasNoBody(text) else { return nil }
        let fields = MarkdownFrontmatter.split(text).raw
        let hasStatus = (MarkdownFrontmatter.split(text).yaml ?? "").split(whereSeparator: \.isNewline)
            .contains { $0.lowercased().hasPrefix("status:") }
        let start = (hasStatus ? fields : FrontmatterEditor.setting("status", to: .string("Active"), in: fields)) + Self.body
        if isProject(path) {
            try vault.write(path, start)
            didWrite(VaultChange(kind: .modified, path: path))
            return path
        }
        // An empty note made directly in the folder (New Note there, the collection's "+"): into a folder of its own.
        guard parts.count == 1 else { return nil }
        let name = Self.basename(path)
        let target = folder + "/" + name + "/" + name + ".md"
        guard !vault.exists(folder + "/" + name) else { return nil }
        try vault.createFolder(folder + "/" + name)
        try vault.move(path, to: target)
        try vault.write(target, start)
        didWrite(VaultChange(kind: .removed, path: path))
        didWrite(VaultChange(kind: .added, path: target))
        return target
    }

    /// Mends the boards an earlier tidy broke: their two filters joined on one line (`- a - b`), which the
    /// collection read as one filter it could not use, listing every note of the vault. Returns the notes mended.
    @discardableResult
    public func mendBoards() throws -> [String] {
        let joined = Self.boardFilter + " " + Self.notItself
        var mended: [String] = []
        // From the files, not the index: this runs as the plugin starts, before the index is built.
        let prefix = folder + "/"
        for path in (try? vault.markdownPaths()) ?? [] where path.hasPrefix(prefix) && isProject(path) {
            guard let text = try? vault.read(path), text.contains(joined) else { continue }
            try vault.write(path, Self.replacingFilter(joined, in: text, with: [Self.boardFilter, Self.notItself]))
            didWrite(VaultChange(kind: .modified, path: path))
            mended.append(path)
        }
        return mended
    }

    /// `text` with the line holding `old` replaced by `lines`, each at that line's indentation, so they stay items
    /// of the same list.
    static func replacingFilter(_ old: String, in text: String, with lines: [String]) -> String {
        text.components(separatedBy: "\n").map { line in
            guard let range = line.range(of: old) else { return line }
            let indent = line[..<range.lowerBound]
            return lines.map { indent + $0 }.joined(separator: "\n")
        }.joined(separator: "\n")
    }

    static let notItself = "- file.basename != this.file.basename"

    public func needsBoard(_ path: String) -> Bool {
        guard isProject(path), let text = try? vault.read(path) else { return false }
        return !text.contains(Self.boardFilter)
    }

    public func addBoard(to path: String) throws {
        guard needsBoard(path) else { return }
        var text = try vault.read(path)
        while text.hasSuffix("\n\n") { text.removeLast() }
        if !text.isEmpty, !text.hasSuffix("\n") { text += "\n" }
        try vault.write(path, text + Self.body.dropFirst())
        didWrite(VaultChange(kind: .modified, path: path))
    }

    public func looseNotes() -> [String] {
        guard let noteQuery = noteQuery() else { return [] }
        return noteQuery.run(NoteQuery(folder: folder))
            .filter { parts($0.path)?.count == 1 && $0.properties["collection"] == nil }
            .map(\.path)
            .sorted()
    }

    @discardableResult
    public func tidy() throws -> [String: String] {
        var moves: [String: String] = [:]
        for path in looseNotes() {
            let name = Self.basename(path)
            let target = folder + "/" + name + "/" + name + ".md"
            guard !vault.exists(target) else { continue }
            if !vault.exists(folder + "/" + name) { try vault.createFolder(folder + "/" + name) }
            try vault.move(path, to: target)
            moves[path] = target
            // A board of the old layout (`file.inFolder("<folder>/<name>")`) reads the note's own folder now.
            let text = try vault.read(target)
            let old = Self.folderFilter(folder + "/" + name)
            if text.contains(old) {
                try vault.write(target, Self.replacingFilter(old, in: text, with: [Self.boardFilter, Self.notItself]))
            }
            didWrite(VaultChange(kind: .removed, path: path))
            didWrite(VaultChange(kind: .added, path: target))
        }
        return moves
    }

    @discardableResult
    public func follow(_ moves: [String: String]) -> [String: String] {
        var made: [String: String] = [:]
        for (old, new) in moves where isProject(old) && !isProject(new) && parts(new)?.count == 2 {
            let (oldFolder, newFolder) = (VaultPath.directory(of: old), VaultPath.directory(of: new))
            if oldFolder == newFolder {
                // The project's note was renamed: its folder takes the name.
                let target = folder + "/" + Self.basename(new)
                guard !vault.exists(target), (try? vault.move(newFolder, to: target)) != nil else { continue }
                made[new] = target + "/" + Self.basename(new) + ".md"
                didWrite(VaultChange(kind: .removed, path: newFolder))
                didWrite(VaultChange(kind: .added, path: target))
            } else {
                // The project's folder was renamed: its note takes the name.
                let target = newFolder + "/" + Self.basename(newFolder) + ".md"
                guard !vault.exists(target), (try? vault.move(new, to: target)) != nil else { continue }
                made[new] = target
                didWrite(VaultChange(kind: .removed, path: new))
                didWrite(VaultChange(kind: .added, path: target))
            }
        }
        return made
    }

    // MARK: Helpers

    /// The task list items of a note's text (`- [ ]`, `- [x]`, any bullet and indent), outside code fences.
    static func checkboxes(in text: String) -> (done: Int, total: Int) {
        var done = 0, total = 0, inFence = false
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.drop { $0 == " " || $0 == "\t" }
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") { inFence.toggle(); continue }
            guard !inFence, let bullet = trimmed.first, "-*+".contains(bullet) else { continue }
            let rest = trimmed.dropFirst()
            guard rest.hasPrefix(" [") , rest.count >= 4 else { continue }
            let mark = rest[rest.index(rest.startIndex, offsetBy: 2)]
            guard rest[rest.index(rest.startIndex, offsetBy: 3)] == "]" else { continue }
            if mark == " " { total += 1 } else if mark == "x" || mark == "X" { total += 1; done += 1 }
        }
        return (done, total)
    }

    /// The board's filter: the notes of the project note's own folder, so a rename needs no rewrite.
    static let boardFilter = "- file.inFolder(this.file.folder)"

    /// The filter an older board used, naming its folder.
    static func folderFilter(_ folder: String) -> String {
        "- " + FrontmatterEditor.serializeString("file.inFolder(\"\(escaped(folder))\")", flow: false)
    }

    /// A new project's body: a line for what it is about, then the Kanban of its task notes, a ` ```base ` block of
    /// the other notes of its folder grouped by `status`. Its "+" writes a task note there with that column's status.
    static let body = """


        ```base
        name: Tasks
        filters:
          and:
            \(boardFilter)
            - file.basename != this.file.basename
            - file.ext == "md"
        properties:
          status:
            type: select
            options:
              - To do
              - In progress
              - Done
          due:
            displayName: Due
            type: date
        views:
          - type: kanban
            name: Board
            groupBy:
              property: status
              direction: ASC
            order:
              - file.name
              - due
        ```

        """

    static let doneNames: Set<String> = ["done", "fait", "terminé", "termine", "completed", "finished"]
    static let inProgressNames: Set<String> = ["in progress", "doing", "en cours", "wip"]

    static func isDone(_ status: String?) -> Bool {
        guard let status else { return false }
        return doneNames.contains(status.trimmingCharacters(in: .whitespaces).lowercased())
    }

    static func isInProgress(_ status: String?) -> Bool {
        guard let status else { return false }
        return inProgressNames.contains(status.trimmingCharacters(in: .whitespaces).lowercased())
    }

    /// A path inside a `"…"` string of a filter expression.
    static func escaped(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    /// The note's name: its file name without `.md`.
    public static func basename(_ path: String) -> String {
        let name = path.split(separator: "/").last.map(String.init) ?? path
        return name.lowercased().hasSuffix(".md") ? String(name.dropLast(3)) : name
    }

    static func string(_ value: PropertyValue?) -> String? {
        switch value {
        case .string(let text)?: return text.isEmpty ? nil : text
        case .number(let number)?: return number == number.rounded() ? String(Int(number)) : String(number)
        default: return nil
        }
    }

    /// The `YYYY-MM-DD` at the start of a date value (a `2026-11-19T10:00` keeps its day).
    static func day(_ text: String) -> String? {
        let day = String(text.trimmingCharacters(in: .whitespaces).prefix(10))
        return day.range(of: "^[0-9]{4}-[0-9]{2}-[0-9]{2}$", options: .regularExpression) != nil ? day : nil
    }

    static func fileName(_ title: String) -> String {
        let cleaned = title.components(separatedBy: CharacterSet(charactersIn: "/\\:\n\r\t"))
            .joined(separator: "-").trimmingCharacters(in: .whitespaces)
        let name = cleaned.hasPrefix(".") ? String(cleaned.drop { $0 == "." }) : cleaned
        return name.isEmpty ? "Untitled" : name
    }
}

/// The plugin's settings: where projects live.
public struct ProjectsSettings: Codable, Equatable, Sendable {
    public var folder = "Projects"

    public init(folder: String = "Projects") {
        self.folder = folder
    }

    static func resolve(_ folder: String) -> String {
        let trimmed = folder.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        return (try? VaultPath.normalize(trimmed)).flatMap { $0.isEmpty ? nil : $0 } ?? "Projects"
    }
}
