import Foundation
import Observation
import PluginKitUI
import TasksPlugin

/// The plugin's state, shared by the commands, every `tasks:` tab and the Tasks panel: every task of the vault,
/// read and written through the `tasks` service only. This class groups them by date and decides where to open a
/// note and where a quick task goes.
@MainActor
@Observable
final class TaskBoard {
    /// Where a quick task goes when there is no daily notes service.
    static let inboxPath = "Inbox.md"

    enum SectionKind: String, CaseIterable, Sendable {
        case overdue, today, upcoming, noDate, done

        var title: String {
            switch self {
            case .overdue: return "Overdue"
            case .today: return "Today"
            case .upcoming: return "Upcoming"
            case .noDate: return "No date"
            case .done: return "Done"
            }
        }
    }

    struct Section: Identifiable, Equatable {
        var id: SectionKind { kind }
        let kind: SectionKind
        let tasks: [TaskItem]
    }

    /// What one tab filters on, saved in its `ViewContext` state.
    struct Filter: Codable, Equatable, Sendable {
        /// A project, ignoring case; nil for all.
        var project: String?
        /// A tag, with or without `#`; empty for all.
        var tag = ""
        /// Whether the Done section is expanded.
        var showDone = false
        /// Which of Craft's views the list shows; nil (a tab saved before) is All.
        var mode: Mode?

        var currentMode: Mode { mode ?? .all }
    }

    /// Craft's switch above its task list.
    enum Mode: String, Codable, CaseIterable, Sendable {
        /// Open tasks without a date.
        case inbox
        /// Open tasks due today or before, and the undated ones of today's daily note.
        case today
        /// Open tasks due after today, by date.
        case upcoming
        /// Every open task, under the note it is in.
        case all

        var title: String {
            switch self {
            case .inbox: "Inbox"
            case .today: "Today"
            case .upcoming: "Upcoming"
            case .all: "All Tasks"
            }
        }
    }

    /// A run of tasks under one heading: a note (All), a date (Upcoming), Overdue or Today.
    struct Group: Identifiable, Equatable {
        let id: String
        let title: String
        /// The note the group is, when it is one: its tasks then show no note name.
        let notePath: String?
        let isOverdue: Bool
        let tasks: [TaskItem]
    }

    /// What the list shows for `filter`'s mode: the open tasks in groups, then the done ones (all modes share them).
    /// The done tasks in `keeping` (ids, checked during this visit of the list) stay in their group, struck through,
    /// so a click does not make a task vanish under the pointer and it can be unchecked in place.
    /// Kept until the tasks change: the list asks on every redraw, typing in its fields included, and grouping a
    /// large vault's tasks takes milliseconds.
    func groups(_ filter: Filter, scope: String? = nil, keeping: Set<String> = []) -> [Group] {
        let key = GroupsKey(filter: filter, scope: scope, keeping: keeping)
        if let cached = groupsCache[key] { return cached }
        let groups = makeGroups(filter, scope: scope, keeping: keeping)
        groupsCache[key] = groups
        return groups
    }

    private struct GroupsKey: Hashable {
        let project: String?
        let tag: String
        let mode: Mode
        let scope: String?
        let keeping: Set<String>

        init(filter: Filter, scope: String?, keeping: Set<String>) {
            project = filter.project
            tag = filter.tag
            mode = filter.currentMode
            self.scope = scope
            self.keeping = keeping
        }
    }

    @ObservationIgnored private var groupsCache: [GroupsKey: [Group]] = [:]
    @ObservationIgnored private var sectionsCache: [GroupsKey: [Section]] = [:]

    private func makeGroups(_ filter: Filter, scope: String?, keeping: Set<String>) -> [Group] {
        let sections = sections(filter, scope: scope, keeping: keeping)
        func tasks(_ kind: SectionKind) -> [TaskItem] { sections.first { $0.kind == kind }?.tasks ?? [] }
        switch filter.currentMode {
        case .inbox:
            return Self.group("inbox", "No date", tasks(.noDate))
        case .today:
            return Self.group("overdue", "Overdue", tasks(.overdue), overdue: true) + Self.group("today", "Today", tasks(.today))
        case .upcoming:
            var byDate: [String: [TaskItem]] = [:]
            for task in tasks(.upcoming) { byDate[day(of: task) ?? "", default: []].append(task) }
            return byDate.keys.sorted().map { date in
                Group(id: date, title: Self.dayTitle(date), notePath: nil, isOverdue: false, tasks: byDate[date] ?? [])
            }
        case .all:
            let open = [SectionKind.overdue, .today, .upcoming, .noDate].flatMap { tasks($0) }
            var byNote: [String: [TaskItem]] = [:]
            for task in open { byNote[task.path, default: []].append(task) }
            return byNote.keys
                .map { (path: $0, title: Self.noteTitle($0)) }
                .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
                .map { note in
                    Group(id: note.path, title: note.title, notePath: note.path, isOverdue: false,
                          tasks: (byNote[note.path] ?? []).sorted { $0.line < $1.line })
                }
        }
    }

    /// The done tasks matching `filter`, most recently completed first, without those kept in their group.
    func doneTasks(_ filter: Filter, scope: String? = nil, keeping: Set<String> = []) -> [TaskItem] {
        sections(filter, scope: scope, keeping: keeping).first { $0.kind == .done }?.tasks ?? []
    }

    private static func group(_ id: String, _ title: String, _ tasks: [TaskItem], overdue: Bool = false) -> [Group] {
        tasks.isEmpty ? [] : [Group(id: id, title: title, notePath: nil, isOverdue: overdue, tasks: tasks)]
    }

    /// Whole days from one `YYYY-MM-DD` to another; nil when one does not read as a date.
    static func daysBetween(_ from: String, _ to: String) -> Int? {
        let format = Date.ISO8601FormatStyle().year().month().day()
        guard let start = try? format.parse(from), let end = try? format.parse(to) else { return nil }
        return Calendar(identifier: .gregorian).dateComponents([.day], from: start, to: end).day
    }

    /// A note's name as the list shows it: its file name without `.md`.
    static func noteTitle(_ path: String) -> String {
        let name = path.split(separator: "/").last.map(String.init) ?? path
        return name.hasSuffix(".md") ? String(name.dropLast(3)) : name
    }

    /// `2026-10-21` as "Wed, Oct 21".
    static func dayTitle(_ date: String) -> String {
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.dateFormat = "yyyy-MM-dd"
        guard let day = parser.date(from: date) else { return date }
        return day.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
    }

    /// Every task of the vault, in the service's order (due date, priority, path, line).
    private(set) var tasks: [TaskItem] = [] {
        didSet { clearCaches() }
    }
    /// `YYYY-MM-DD`, as the service sees it.
    private(set) var today = "" {
        didSet { clearCaches() }
    }

    /// The daily notes, from today on, holding an undated task: path to day. Such a task is planned on its note's
    /// day, as in Craft. Older daily notes are left out, so their forgotten tasks stay in Inbox, not Overdue.
    private(set) var dailyNoteDays: [String: String] = [:] {
        didSet { clearCaches() }
    }

    private func clearCaches() {
        groupsCache = [:]
        sectionsCache = [:]
    }
    /// What the last action that failed said, shown above the list until the next one succeeds.
    private(set) var error: String?
    /// Grows each time a command asks the open list to focus its quick add field.
    private(set) var focusRequest = 0

    @ObservationIgnored private let service: TasksService
    @ObservationIgnored private let workspace: @MainActor () -> (any Workspace)?
    @ObservationIgnored private let editor: @MainActor () -> (any EditorService)?
    @ObservationIgnored private let dailyNotes: @MainActor () -> DailyNotesService?

    init(
        service: TasksService,
        workspace: @escaping @MainActor () -> (any Workspace)?,
        editor: @escaping @MainActor () -> (any EditorService)?,
        dailyNotes: @escaping @MainActor () -> DailyNotesService?
    ) {
        self.service = service
        self.workspace = workspace
        self.editor = editor
        self.dailyNotes = dailyNotes
    }

    /// `YYYY-MM-DD` now, from the service (not the last refresh's `today`).
    var currentDay: String { service.today }

    /// Reads every task again, from the editor's unsaved text for the notes it has open.
    /// The refresh `refreshSoon()` waits to run.
    @ObservationIgnored private var pendingRefresh: Task<Void, Never>?

    /// `refresh()` once typing and saving pause: it reads every note's stamp and parses the open one again, too much
    /// for each keystroke of a long note.
    func refreshSoon() {
        pendingRefresh?.cancel()
        pendingRefresh = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            self?.refresh()
        }
    }

    /// The first `refresh()`, after reading every note on a background queue: at launch, a large vault would
    /// otherwise hold the window. The index keeps what it read, so the refresh on the main actor is short.
    func refreshAfterWarmingUp() {
        nonisolated(unsafe) let service = service
        LaunchWork.run({ _ = try? service.tasks(TaskFilter(), liveText: nil) }, then: { [weak self] in self?.refresh() })
    }

    func refresh() {
        pendingRefresh?.cancel()
        pendingRefresh = nil
        let newToday = service.today
        if newToday != today { today = newToday }
        let editor = editor
        do {
            let newTasks = try service.tasks(TaskFilter(), liveText: { path in
                // The service calls this synchronously from `refresh`, which runs on the main actor.
                MainActor.assumeIsolated { editor()?.text(of: path) }
            })
            if newTasks != tasks { tasks = newTasks }
            let days = dailyNoteDays(of: newTasks, today: newToday)
            if days != dailyNoteDays { dailyNoteDays = days }
        } catch {
            self.error = "Could not read the tasks: \(error)"
        }
    }

    /// Which notes of `tasks` with an undated task are daily notes of today or later: a note named like a day whose
    /// path is that day's daily note.
    private func dailyNoteDays(of tasks: [TaskItem], today: String) -> [String: String] {
        guard let daily = dailyNotes() else { return [:] }
        var days: [String: String] = [:]
        for path in Set(tasks.filter { $0.due == nil }.map(\.path)) {
            let name = Self.noteTitle(path)
            guard name.count == 10, name >= today, (try? daily.path(for: name)) == path else { continue }
            days[path] = name
        }
        return days
    }

    /// The day a task is planned on: its due date, else its daily note's day.
    func day(of task: TaskItem) -> String? {
        task.due ?? dailyNoteDays[task.path]
    }

    // MARK: Grouping

    /// The projects of the tasks, for the filter's picker: distinct ignoring case, without the vault root's "".
    var projects: [String] {
        var seen = Set<String>()
        return tasks.map(\.project).filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// The non-empty sections, in order, of the tasks matching `filter` (and `scope`, the project of a
    /// `tasks:<project>` tab, which wins over the filter's). Done holds every done task, whether it is expanded or not,
    /// but those in `keeping`, which stay in the section of their date.
    func sections(_ filter: Filter, scope: String? = nil, keeping: Set<String> = []) -> [Section] {
        let key = GroupsKey(filter: filter, scope: scope, keeping: keeping)
        if let cached = sectionsCache[key] { return cached }
        let sections = makeSections(filter, scope: scope, keeping: keeping)
        sectionsCache[key] = sections
        return sections
    }

    private func makeSections(_ filter: Filter, scope: String?, keeping: Set<String>) -> [Section] {
        let project = scope ?? filter.project
        let tag = filter.tag.trimmingCharacters(in: .whitespaces)
        let wanted = (tag.hasPrefix("#") ? String(tag.dropFirst()) : tag).lowercased()
        let matching = tasks.filter { task in
            (project.map { task.project.caseInsensitiveCompare($0) == .orderedSame } ?? true)
                && (wanted.isEmpty || task.tags.contains { $0.lowercased() == wanted || $0.lowercased().hasPrefix(wanted + "/") })
        }
        var grouped: [SectionKind: [TaskItem]] = [:]
        for task in matching { grouped[kind(of: task, keeping: keeping), default: []].append(task) }
        return SectionKind.allCases.compactMap { kind in
            guard let tasks = grouped[kind], !tasks.isEmpty else { return nil }
            // Done: the most recently completed first.
            let ordered = kind == .done ? tasks.sorted { ($0.completed ?? "") > ($1.completed ?? "") } : tasks
            return Section(kind: kind, tasks: ordered)
        }
    }

    func kind(of task: TaskItem, keeping: Set<String> = []) -> SectionKind {
        if task.done, !keeping.contains(task.id) { return .done }
        guard let due = day(of: task) else { return .noDate }
        if due < today { return .overdue }
        return due == today ? .today : .upcoming
    }

    /// The panel's tasks: open ones due today or before, with today's daily note's.
    var dueTasks: [TaskItem] {
        tasks.filter { !$0.done && (day(of: $0).map { $0 <= today } ?? false) }
    }

    /// The tasks due on `date`, grouped by note in path order, without the note at `path` (a daily note's own tasks
    /// are in its text). Open tasks first within a note.
    struct DayGroup: Equatable {
        let path: String
        let tasks: [TaskItem]
    }

    func dayGroups(date: String, excluding path: String) -> [DayGroup] {
        let due = tasks.filter { $0.due == date && $0.path != path }
        return Dictionary(grouping: due, by: \.path)
            .map { DayGroup(path: $0.key, tasks: $0.value.sorted { ($0.done ? 1 : 0, $0.line) < ($1.done ? 1 : 0, $1.line) }) }
            .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    // MARK: Actions

    /// Checks or unchecks a task through the service, which refuses a line that changed since it was read. Returns the
    /// task as it is now; nil (and `error` set) when it was left alone.
    @discardableResult
    func toggle(_ task: TaskItem) -> TaskItem? {
        var toggled: TaskItem?
        do {
            toggled = try service.toggle(path: task.path, line: task.line, expectedText: task.text)
            error = nil
        } catch TasksError.lineChanged(let path, _) {
            error = "\"\(task.text)\" changed in \(path) since the list was read, so it was left alone. "
                + "The list is up to date now: try again."
        } catch {
            self.error = "Could not change \(task.path): \(error)"
        }
        refresh()
        if let toggled { Sounds.taskChecked(done: toggled.done) }
        return toggled
    }

    /// Adds a task to today's daily note (created from its template if needed), or to `Inbox.md` without daily
    /// notes. Returns the note's path; nil (and `error` set) when it failed or the text is empty.
    @discardableResult
    func quickAdd(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        var path: String?
        do {
            let target = try dailyNotes()?.ensure(date: nil) ?? Self.inboxPath
            path = try service.add(trimmed, to: target).path
            error = nil
        } catch {
            self.error = "Could not add the task: \(error)"
        }
        refresh()
        return path
    }

    /// Opens today's daily note (made from its template if needed), or `Inbox.md` without daily notes, beside the list:
    /// where `/todo` writes a task.
    func openTodayNote() {
        do {
            let path = try dailyNotes()?.ensure(date: nil) ?? Self.inboxPath
            workspace()?.open(.file(path), placement: .beside)
        } catch {
            self.error = "Could not open today's note: \(error)"
        }
    }

    /// Opens a task's note beside the list and puts the caret on its line when an editor shows it.
    func open(_ task: TaskItem) {
        guard let workspace = workspace() else { return }
        workspace.open(.file(task.path), placement: .beside)
        reveal(line: task.line, in: task.path, attempts: 3)
    }

    /// The editor may only show the note once SwiftUI has laid the new tab out, so a failed reveal is tried again a
    /// little later.
    private func reveal(line: Int, in path: String, attempts: Int) {
        guard let editor = editor(), attempts > 0 else { return }
        if editor.reveal(line: line, in: path) { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            MainActor.assumeIsolated { self?.reveal(line: line, in: path, attempts: attempts - 1) }
        }
    }

    /// Opens the list (of one project, when given) in a new tab, or says why it cannot (the CLI has no workspace).
    func openList(project: String? = nil, focusAdd: Bool = false) -> String {
        guard let workspace = workspace() else { return "No workspace in this host." }
        workspace.open(TasksUIPlugin.resource(project: project), placement: .newTab)
        if focusAdd { focusRequest += 1 }
        return project.map { "Opened the tasks of \($0)." } ?? "Opened the tasks."
    }

    // MARK: Display

    /// A task's text without its tags, which the row shows apart.
    static func displayText(_ task: TaskItem) -> String {
        var text = task.text
        // Longest first, so `#work` does not cut `#work/review`.
        for tag in task.tags.sorted(by: { $0.count > $1.count }) {
            text = text.replacingOccurrences(of: "#" + tag, with: "")
        }
        let words = text.split(whereSeparator: { $0 == " " || $0 == "\t" })
        return words.isEmpty ? task.text : words.joined(separator: " ")
    }

    /// `displayText` as the row shows it: inline Markdown drawn (bold, code, a date link's label) and HTML tags such
    /// as `<mark>` left out, never the marks themselves.
    static func displayAttributed(_ task: TaskItem) -> AttributedString {
        let text = displayText(task).replacingOccurrences(of: #"</?[A-Za-z][^>]*>"#, with: "", options: .regularExpression)
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }
}
