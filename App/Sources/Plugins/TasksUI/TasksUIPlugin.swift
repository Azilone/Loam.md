import Foundation
import PluginKitUI
import SwiftUI
import TasksPlugin

/// The tasks of every note: a list view (`tasks:`, or `tasks:<project>` for one project) grouped into Overdue,
/// Today, Upcoming, No date and Done, a compact "Tasks" panel in the right sidebar (due today and overdue), and
/// `tasks.open` / `tasks.add-quick`. Tasks are read and written through the `tasks` service of the logic plugin, so
/// the CLI and agents do the same with its `tasks.*` commands. Quick tasks go to today's daily note when the
/// `daily-notes` service is there, else to `Inbox.md`; with an editor, opening a task puts the caret on its line.
public final class TasksUIPlugin: UIPlugin {
    public static let manifest = PluginManifest(
        id: "tasks-ui",
        name: "Tasks view",
        version: "0.1.0",
        description: "The Tasks page and panel: what is overdue, due today and upcoming.",
        icon: "checklist",
        requires: ["tasks"],
        optionalRequires: ["editor", "daily-notes"],
        permissions: ["ui", "vault.read", "vault.write"]
    )

    static let viewTypeID = "tasks.list"
    static let sectionID = "tasks.due"
    static let dayHeaderID = "tasks.day-header"
    static let scheme = "tasks:"
    /// Internal: lets the tests reach the shared model. Not a contract.
    static var modelKey: ServiceKey<TaskBoard> { ServiceKey("tasks-ui.model") }

    public init() {}

    @MainActor public func activateUI(context: PluginContext) throws {
        guard let service = context.service(.tasks) else { throw TasksUIError.serviceMissing }
        let model = TaskBoard(
            service: service,
            workspace: { [weak context] in context?.workspace },
            editor: { [weak context] in context?.editor },
            dailyNotes: { [weak context] in context?.service(.dailyNotes) }
        )
        model.refreshAfterWarmingUp()
        try context.provide(Self.modelKey, model)
        // A check plays the big chime only when it leaves no open task in the whole vault (unsaved edits included).
        let openTasksLeft: () -> Bool = { [weak context] in
            let editor = context?.editor
            let open = try? service.tasks(TaskFilter(done: false), liveText: { path in MainActor.assumeIsolated { editor?.text(of: path) } })
            return open.map { !$0.isEmpty } ?? true
        }
        Sounds.openTasksLeft = openTasksLeft
        context.effect { MainActor.assumeIsolated { Sounds.openTasksLeft = nil } }

        try context.registerView(ViewType(
            id: Self.viewTypeID,
            title: "Tasks",
            canOpen: { $0.kind == .virtual && $0.path.hasPrefix(Self.scheme) },
            makeView: { view in
                AnyView(TaskListView(
                    model: model,
                    scope: Self.project(of: view.resource),
                    initialFilter: view.state(TaskBoard.Filter.self) ?? TaskBoard.Filter(),
                    saveFilter: { filter in view.setState(filter) }
                ))
            }
        ))

        // Under a daily note's date: the tasks due that day in other notes.
        if context.service(.dailyNotes) != nil {
            try context.addNoteHeader(NoteHeader(
                id: Self.dayHeaderID,
                order: 20,
                appliesTo: { [weak context] in Self.dailyDate(of: $0, context: context) != nil },
                makeView: { [weak context] view in
                    guard let date = Self.dailyDate(of: view.resource, context: context) else { return AnyView(EmptyView()) }
                    return AnyView(DayTasksHeader(model: model, date: date, notePath: view.resource.path))
                }
            ))
        }

        try context.addSidebarLink(SidebarLink(
            id: "tasks.link", title: "Tasks", symbol: "checkmark.circle", resource: Self.resource(project: nil), order: 10,
            // Only what asks for action: the overdue tasks, not every open one.
            count: { [weak model] in
                model.flatMap { $0.sections(TaskBoard.Filter()).first { $0.kind == .overdue }?.tasks.count }
                    .flatMap { $0 > 0 ? $0 : nil }
            }
        ))

        // The tasks due across the vault, beside a daily note's calendar.
        if context.service(.dailyNotes) != nil {
            try context.addInspectorSection(InspectorSection(
                id: Self.sectionID, placement: .tab(InspectorPage(id: "daily.day", title: "Day", order: -10)),
                order: 10,
                appliesTo: { [weak context] in Self.dailyDate(of: $0, context: context) != nil }
            ) { _ in
                AnyView(TasksPanelView(model: model))
            })
        }

        try context.registerCommand(Command(
            id: "tasks.open",
            title: "Open tasks",
            summary: "Opens the list of every task of the vault (overdue, today, upcoming, no date, done) in a new tab. "
                + "Optional argument: project, to list only its tasks. Returns what it did."
        ) { arguments in
            let project = arguments["project"].flatMap { $0.isEmpty ? nil : $0 }
            return await MainActor.run { model.openList(project: project) }
        })

        try context.registerCommand(Command(
            id: "tasks.add-quick",
            title: "Quick add task",
            summary: "Opens the task list with its quick add field focused. With a text argument, adds \"- [ ] text\" "
                + "to today's daily note (or Inbox.md without daily notes) instead, which writes to the vault, and "
                + "returns the note's path."
        ) { arguments in
            if let text = arguments["text"], !text.isEmpty {
                return try await MainActor.run {
                    guard let path = model.quickAdd(text) else { throw TasksUIError.addFailed(model.error ?? "") }
                    return path
                }
            }
            return await MainActor.run { model.openList(focusAdd: true) }
        })

        // `@tomorrow` in a note: the line's due date. The service's day, read at each keystroke so it follows midnight.
        context.addMentionSource(DateMentions.source { [weak model] in model?.currentDay ?? "" })

        context.on(VaultChanged.self) { [weak model] event in
            guard !event.noteChanges.isEmpty else { return }
            onMainThread { model?.refreshSoon() }
        }
        context.on(NotesMoved.self) { [weak model] _ in
            onMainThread { model?.refreshSoon() }
        }
        context.on(DocumentTextChanged.self) { [weak model] _ in
            onMainThread { model?.refreshSoon() }
        }
    }

    /// The day of `resource` when it is a daily note (its path is the one the `daily-notes` service gives that day).
    @MainActor static func dailyDate(of resource: Resource, context: PluginContext?) -> String? {
        guard resource.kind == .file, let service = context?.service(.dailyNotes) else { return nil }
        let day = resource.name
        guard let path = try? service.path(for: day), path == resource.path else { return nil }
        return day
    }

    /// `tasks:` lists every task; `tasks:<project>` only that project's.
    static func resource(project: String?) -> Resource {
        .virtual(scheme + (project ?? ""))
    }

    /// The project a `tasks:<project>` resource names; nil for `tasks:` and anything else.
    static func project(of resource: Resource) -> String? {
        guard resource.kind == .virtual, resource.path.hasPrefix(scheme) else { return nil }
        let rest = String(resource.path.dropFirst(scheme.count))
        return rest.isEmpty ? nil : rest
    }
}

enum TasksUIError: Error, Equatable {
    /// The host activates this plugin after `tasks` (it is in `requires`), so this means a broken host.
    case serviceMissing
    /// `tasks.add-quick` with a text that could not be added; says why.
    case addFailed(String)
}

/// Runs main-actor code from an event listener, which Swift cannot prove runs on the main thread. The kernel is
/// main-thread only, so this is normally a direct call.
func onMainThread(_ body: @MainActor @Sendable () -> Void) {
    if Thread.isMainThread {
        MainActor.assumeIsolated { body() }
    } else {
        DispatchQueue.main.sync { MainActor.assumeIsolated { body() } }
    }
}
