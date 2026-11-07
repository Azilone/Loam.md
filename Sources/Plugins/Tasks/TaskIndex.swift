import Foundation
import PluginKit

/// The `tasks` service: reads the vault's task lines (each note parsed again only when its file changed), and
/// edits one line at a time.
public final class TaskIndex: TasksService {
    private let vault: VaultAccess
    private let clock: () -> String
    private let didWrite: (String) -> Void
    private let lock = NSLock()
    /// The tasks of each note, with the file stamp they were read at.
    private var cache: [String: (stamp: FileStamp, tasks: [TaskItem])] = [:]

    /// - Parameters:
    ///   - today: `YYYY-MM-DD`; the system's day by default.
    ///   - didWrite: called with the path after a write, so the plugin can announce the change at once.
    public init(
        vault: VaultAccess,
        today: @escaping () -> String = TaskIndex.systemToday,
        didWrite: @escaping (String) -> Void = { _ in }
    ) {
        self.vault = vault
        self.clock = today
        self.didWrite = didWrite
    }

    public static func systemToday() -> String {
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        return String(format: "%04d-%02d-%02d", parts.year!, parts.month!, parts.day!)
    }

    public var today: String { clock() }

    // MARK: Reading

    public func tasks(_ filter: TaskFilter, liveText: ((String) -> String?)?) throws -> [TaskItem] {
        // One note's tasks (the Info panel, on every note switch) need that file's stamp, not a walk of the vault.
        let note = filter.path.flatMap { $0.lowercased().hasSuffix(".md") ? $0 : nil }
        let stamps = try note.map(stamp(of:)) ?? vault.stamps()
        var all: [TaskItem] = []
        // The lock guards the cache only, never a read: a read may wait for the main thread (an editor saving
        // unsaved typing first, `NoteWillRead`), which may itself be waiting for this lock.
        for path in stamps.keys.sorted() where path.lowercased().hasSuffix(".md") {
            let stamp = stamps[path]!
            if let live = liveText?(path) {
                all += TaskParser.tasks(in: live, path: path)
                continue
            }
            lock.lock()
            let cached = cache[path]
            lock.unlock()
            if let cached, cached.stamp == stamp {
                all += cached.tasks
            } else {
                guard let text = try? vault.read(path) else { continue }
                let tasks = TaskParser.tasks(in: text, path: path)
                lock.lock()
                cache[path] = (stamp, tasks)
                lock.unlock()
                all += tasks
            }
        }
        if note == nil {
            lock.lock()
            for path in cache.keys where stamps[path] == nil { cache[path] = nil }
            lock.unlock()
        }
        return Self.sorted(all.filter { Self.matches($0, filter) })
    }

    private func stamp(of path: String) -> [String: FileStamp] {
        let url = vault.rootURL.appendingPathComponent(path)
        guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]) else {
            return [:]
        }
        let stamp = FileStamp(
            modified: values.contentModificationDate?.timeIntervalSince1970 ?? 0,
            size: values.fileSize ?? 0
        )
        return [path: stamp]
    }

    static func matches(_ task: TaskItem, _ filter: TaskFilter) -> Bool {
        if let done = filter.done, task.done != done { return false }
        if let before = filter.dueBefore, !before.isEmpty {
            guard let due = task.due, due < before else { return false }
        }
        if let on = filter.dueOn, !on.isEmpty, task.due != on { return false }
        if let project = filter.project, task.project.caseInsensitiveCompare(project) != .orderedSame { return false }
        if let tag = filter.tag, !tag.isEmpty {
            let wanted = (tag.hasPrefix("#") ? String(tag.dropFirst()) : tag).lowercased()
            guard task.tags.contains(where: { $0.lowercased() == wanted || $0.lowercased().hasPrefix(wanted + "/") })
            else { return false }
        }
        if let path = filter.path, !path.isEmpty {
            let folder = path.hasSuffix("/") ? String(path.dropLast()) : path
            guard task.path == folder || task.path.hasPrefix(folder + "/") else { return false }
        }
        if let text = filter.text, !text.isEmpty, task.text.range(of: text, options: .caseInsensitive) == nil {
            return false
        }
        return true
    }

    /// Due date (none last), priority (high first), path, line.
    static func sorted(_ tasks: [TaskItem]) -> [TaskItem] {
        tasks.sorted { a, b in
            switch (a.due, b.due) {
            case (let x?, let y?) where x != y: return x < y
            case (.some, nil): return true
            case (nil, .some): return false
            default: break
            }
            if a.priority != b.priority { return a.priority < b.priority }
            if a.path != b.path { return a.path < b.path }
            return a.line < b.line
        }
    }

    // MARK: Writing

    @discardableResult
    public func toggle(path: String, line: Int, expectedText: String) throws -> TaskItem {
        let path = try notePath(path)
        guard vault.exists(path) else { throw TasksError.lineChanged(path: path, line: line) }
        let text = try vault.read(path)
        guard let task = TaskParser.tasks(in: text, path: path).first(where: { $0.line == line }),
              task.text == expectedText else { throw TasksError.lineChanged(path: path, line: line) }

        var lines = TaskParser.lines(text)
        let (content, carriageReturn) = TaskParser.content(lines[line - 1])
        guard let parts = TaskParser.taskLine(content) else { throw TasksError.lineChanged(path: path, line: line) }
        var characters = Array(content)
        characters[parts.stateOffset] = parts.done ? " " : "x"
        var edited = TaskParser.replace(TaskParser.completion, in: String(characters), with: "")
        if !parts.done {
            edited = edited.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression) + " ✅ " + today
        }
        lines[line - 1] = edited + (carriageReturn ? "\r" : "")
        try write(path, lines.joined(separator: "\n"))
        return try readTask(at: line, in: path)
    }

    @discardableResult
    public func add(_ text: String, to path: String) throws -> TaskItem {
        let body = text.components(separatedBy: .newlines).joined(separator: " ").trimmingCharacters(in: .whitespaces)
        guard !body.isEmpty else { throw TasksError.emptyText }
        let path = try notePath(path)
        let entry = "- [ ] " + body
        guard vault.exists(path) else {
            try write(path, entry + "\n")
            return try readTask(at: 1, in: path)
        }
        let note = try vault.read(path)
        let newline = note.contains("\r\n") ? "\r\n" : "\n"
        var lines = TaskParser.lines(note)
        let frontmatterLines = MarkdownFrontmatter.split(note).raw.unicodeScalars.filter { $0 == "\n" }.count
        let index: Int
        if let section = tasksSection(lines, skipping: frontmatterLines) {
            let lastFilled = section.dropFirst().last { !TaskParser.content(lines[$0]).text.trimmingCharacters(in: .whitespaces).isEmpty }
            index = (lastFilled ?? section.lowerBound) + 1
            lines.insert(entry + (newline == "\r\n" ? "\r" : ""), at: index)
        } else {
            // The text ends with a newline when the last line is empty: the entry replaces that empty line.
            if lines.last == "" { lines.removeLast() }
            let previous = lines.last.map { TaskParser.content($0).text.trimmingCharacters(in: .whitespaces) } ?? ""
            let isListItem = previous.hasPrefix("- ") || previous.hasPrefix("* ") || previous.hasPrefix("+ ")
                || previous.range(of: "^[0-9]+[.)] ", options: .regularExpression) != nil
            if !previous.isEmpty, !isListItem { lines.append(newline == "\r\n" ? "\r" : "") }
            lines.append(entry + (newline == "\r\n" ? "\r" : ""))
            lines.append("")
            index = lines.count - 2
        }
        try write(path, lines.joined(separator: "\n"))
        return try readTask(at: index + 1, in: path)
    }

    /// The line indices of the first `## Tasks` heading (any level) and the lines under it, up to the next heading
    /// of the same or a higher level.
    private func tasksSection(_ lines: [String], skipping: Int) -> Range<Int>? {
        var headings: [(index: Int, level: Int, title: String)] = []
        TaskParser.forEachBodyLine(lines, skipping: skipping) { index, line in
            let level = line.prefix { $0 == "#" }.count
            guard (1...6).contains(level), line.dropFirst(level).first == " " else { return }
            let title = line.dropFirst(level).trimmingCharacters(in: CharacterSet(charactersIn: " \t#"))
            headings.append((index, level, title))
        }
        guard let start = headings.firstIndex(where: { $0.title.lowercased() == "tasks" }) else { return nil }
        let heading = headings[start]
        let end = headings[(start + 1)...].first { $0.level <= heading.level }?.index ?? lines.count
        // A note ending with a newline has an empty last "line" that is not part of any section.
        let last = lines.last == "" && end == lines.count ? end - 1 : end
        return heading.index..<max(heading.index + 1, last)
    }

    private func notePath(_ path: String) throws -> String {
        let normalized = try VaultPath.normalize(path)
        guard normalized.lowercased().hasSuffix(".md") else { throw TasksError.notANote(path) }
        return normalized
    }

    private func write(_ path: String, _ text: String) throws {
        try vault.write(path, text)
        lock.lock()
        cache[path] = nil
        lock.unlock()
        didWrite(path)
    }

    private func readTask(at line: Int, in path: String) throws -> TaskItem {
        guard let task = TaskParser.tasks(in: try vault.read(path), path: path).first(where: { $0.line == line }) else {
            throw TasksError.lineChanged(path: path, line: line)
        }
        return task
    }
}
