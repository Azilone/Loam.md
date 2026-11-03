import Foundation
import PluginKit

/// How urgent a task is: `⏫` or `!high`, `🔽` or `!low`, else normal.
public enum TaskPriority: String, Codable, Sendable, Comparable {
    case high, normal, low

    var rank: Int {
        switch self {
        case .high: return 0
        case .normal: return 1
        case .low: return 2
        }
    }

    public static func < (lhs: TaskPriority, rhs: TaskPriority) -> Bool { lhs.rank < rhs.rank }
}

/// One GFM task-list line (`- [ ] text`, `- [x] text`) somewhere in the vault. The syntax is in docs/TASKS.md.
public struct TaskItem: Codable, Sendable, Equatable, Identifiable {
    /// Vault-relative path of the note.
    public let path: String
    /// 1-based line number in the note.
    public let line: Int
    /// The text without the checkbox and without the metadata the parser reads (due date, priority, completion
    /// date). Tags stay in it, as written. `toggle` checks the line still has this text.
    public let text: String
    public let done: Bool
    /// `YYYY-MM-DD`, from `📅 YYYY-MM-DD` or `due:YYYY-MM-DD`.
    public let due: String?
    /// `YYYY-MM-DD`, from `✅ YYYY-MM-DD` (which `toggle` writes when it checks a task).
    public let completed: String?
    public let priority: TaskPriority
    /// The `#tags` of the line, without `#`, in order.
    public let tags: [String]
    /// The note's frontmatter `project` property, else the note's folder (`""` at the vault root).
    public let project: String

    /// `path:line`, unique in the vault.
    public var id: String { "\(path):\(line)" }

    public init(
        path: String,
        line: Int,
        text: String,
        done: Bool,
        due: String? = nil,
        completed: String? = nil,
        priority: TaskPriority = .normal,
        tags: [String] = [],
        project: String = ""
    ) {
        self.path = path
        self.line = line
        self.text = text
        self.done = done
        self.due = due
        self.completed = completed
        self.priority = priority
        self.tags = tags
        self.project = project
    }
}

/// Which tasks to list. Every field may be left out (of the JSON too); an empty filter lists every task.
///
/// - `done`: only done (true) or open (false) tasks.
/// - `dueBefore`: a due date strictly before this day (`YYYY-MM-DD`); `dueOn`: due that day.
/// - `project`: the task's project, ignoring case.
/// - `tag`: the task's line has this tag (with or without `#`, ignoring case); `#a/b` counts for `a`.
/// - `path`: the note, or every note under this folder.
/// - `text`: the task's text contains this, ignoring case.
public struct TaskFilter: Codable, Sendable, Equatable {
    public var done: Bool?
    public var dueBefore: String?
    public var dueOn: String?
    public var project: String?
    public var tag: String?
    public var path: String?
    public var text: String?

    public init(
        done: Bool? = nil,
        dueBefore: String? = nil,
        dueOn: String? = nil,
        project: String? = nil,
        tag: String? = nil,
        path: String? = nil,
        text: String? = nil
    ) {
        self.done = done
        self.dueBefore = dueBefore
        self.dueOn = dueOn
        self.project = project
        self.tag = tag
        self.path = path
        self.text = text
    }
}

public enum TasksError: Error, Equatable {
    /// The line is no longer the task the caller saw (edited, moved or gone): nothing was written.
    case lineChanged(path: String, line: Int)
    /// A task text that is empty.
    case emptyText
    /// A path that is not a Markdown note (`.md`).
    case notANote(String)
    /// A date that is not `YYYY-MM-DD` (or `today`, in command arguments).
    case invalidDate(String)
    /// A command argument that is not of the expected shape.
    case invalidArgument(name: String)
}

/// Tasks across the vault, for the Tasks UI module (`TasksUI`), which may import this logic module. The CLI and
/// agents do the same with the `tasks.*` commands.
public protocol TasksService: AnyObject {
    /// Today, `YYYY-MM-DD`, as the service sees it (the completion date `toggle` writes).
    var today: String { get }
    /// The tasks matching `filter`, sorted by due date (none last), then priority (high first), then path and line.
    /// `liveText` gives the unsaved text of a note open in an editor, read instead of the file; nil reads the file.
    func tasks(_ filter: TaskFilter, liveText: ((String) -> String?)?) throws -> [TaskItem]
    /// Flips `[ ]` and `[x]` on one line, only when that line is still a task with the text `expectedText`;
    /// else throws `TasksError.lineChanged` and writes nothing. Checking appends ` ✅ YYYY-MM-DD` (today),
    /// unchecking removes it. Keeps the rest of the note, line endings included. Writes to the vault.
    @discardableResult func toggle(path: String, line: Int, expectedText: String) throws -> TaskItem
    /// Adds `- [ ] text` to a note: at the end of its `## Tasks` section when it has one, else at the end of the
    /// note, which is created if missing. Writes to the vault. Returns the new task.
    @discardableResult func add(_ text: String, to path: String) throws -> TaskItem
}

public extension TasksService {
    func tasks(filter: TaskFilter = TaskFilter()) throws -> [TaskItem] {
        try tasks(filter, liveText: nil)
    }
}

public extension ServiceKey where Service == TasksService {
    static var tasks: ServiceKey<TasksService> { ServiceKey<TasksService>("tasks") }
}
