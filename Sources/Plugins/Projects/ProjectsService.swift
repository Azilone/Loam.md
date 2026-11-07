import Foundation
import PluginKit

/// Tasks of a project by state: notes of its task folder, their `status` deciding.
public struct TaskCount: Codable, Sendable, Equatable {
    public var done: Int
    public var total: Int
    /// Tasks whose status says in progress (In progress, Doing, En cours).
    public var inProgress: Int
    /// Open tasks whose `due` is before today.
    public var late: Int

    public init(done: Int = 0, total: Int = 0, inProgress: Int = 0, late: Int = 0) {
        self.done = done
        self.total = total
        self.inProgress = inProgress
        self.late = late
    }
}

/// One project: a folder of the projects folder, its note named after it, its tasks the other notes there.
/// docs/PROJECTS.md has the rules.
public struct ProjectItem: Codable, Sendable, Equatable, Identifiable {
    public let path: String
    public let title: String
    /// The note's `status`, as written (`Active`, `Idea`, `Paused`, `Done`); nil without one.
    public let status: String?
    /// `YYYY-MM-DD`, the note's `due`.
    public let due: String?
    /// The due date is before today and the project is not done.
    public let overdue: Bool
    /// Its task notes by state.
    public let tasks: TaskCount

    public var id: String { path }

    public init(path: String, title: String, status: String?, due: String?, overdue: Bool, tasks: TaskCount) {
        self.path = path
        self.title = title
        self.status = status
        self.due = due
        self.overdue = overdue
        self.tasks = tasks
    }
}

/// A task note: a note of a project's task folder.
public struct ProjectTask: Codable, Sendable, Equatable, Identifiable {
    public let path: String
    public let title: String
    /// The project note's path.
    public let project: String
    public let status: String?
    public let due: String?

    public var id: String { path }

    public init(path: String, title: String, project: String, status: String?, due: String?) {
        self.path = path
        self.title = title
        self.project = project
        self.status = status
        self.due = due
    }
}

public enum ProjectsError: Error, Equatable {
    case invalidArgument(name: String)
}

/// Projects across the vault, for the Projects UI module (`ProjectsUI`). The CLI and agents do the same with the
/// `projects.*` commands.
public protocol ProjectsService: AnyObject {
    /// Today, `YYYY-MM-DD`.
    var today: String { get }
    /// The projects folder (the plugin's `folder` setting), `Projects` by default.
    var folder: String { get }
    /// The folder's collection, `<folder>/<folder name>.base`.
    var collectionPath: String { get }
    /// True for a project note: the note named after its folder, `<folder>/<name>/<name>.md`; the other notes of
    /// that folder are its tasks.
    func isProject(_ path: String) -> Bool
    /// The folder of a project, which holds its note and its task notes.
    func taskFolder(of project: String) -> String
    /// Every project, by title.
    func projects() -> [ProjectItem]
    /// The open task notes due on `day` (and, when `day` is today, the late ones), soonest first.
    func tasks(dueOn day: String) -> [ProjectTask]
    /// Writes the folder's collection (statuses, due date, the Projects, Board and Table views) unless it exists.
    /// Returns its path.
    @discardableResult func ensureCollection() throws -> String
    /// A new project note: `status` (Active by default), `due`, a line for its description and the Kanban of its
    /// tasks; ensures the collection. Returns its path.
    func create(title: String, status: String?, due: String?) throws -> String
    /// A task of `project` (its path, or its title): a note in its folder with `status` (To do by default), maybe
    /// `due`, and `text` as body, so it shows on the project's Kanban. Returns its path.
    func addTask(project: String, title: String, status: String?, due: String?, text: String?) throws -> String
    /// Gives a new, empty project note `status: Active` and the body of a project; an empty note made directly in
    /// the projects folder (New Note there, the collection's "+") first moves into a folder of its own. Returns the
    /// note's path when it wrote.
    @discardableResult func adoptNewNote(_ path: String) throws -> String?
    /// True when a project note shows no Kanban of its tasks yet (an older note, one moved into the folder).
    func needsBoard(_ path: String) -> Bool
    /// Appends the Kanban of its task folder to a project note. Writes to the vault.
    func addBoard(to path: String) throws
    /// After notes moved: a project's note and folder keep the same name (renaming one renames the other). Returns
    /// the moves it made.
    @discardableResult func follow(_ moves: [String: String]) -> [String: String]
    /// Notes directly in the projects folder, outside any project's folder (an older layout, a note dropped there).
    func looseNotes() -> [String]
    /// Moves each loose note into a folder of its own, making it a project. Returns the moves.
    @discardableResult func tidy() throws -> [String: String]
}

public extension ServiceKey where Service == ProjectsService {
    static var projects: ServiceKey<ProjectsService> { ServiceKey<ProjectsService>("projects") }
}

/// Sent after the projects folder setting changed and the service follows the new folder.
public struct ProjectsFolderChanged: PluginEvent {
    public let folder: String

    public init(folder: String) {
        self.folder = folder
    }
}
