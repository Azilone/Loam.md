import Foundation
import PluginKitUI
import ProjectsPlugin
import SwiftUI

/// Projects in the app (docs/PROJECTS.md): "Projects" in the sidebar (the projects folder as its collection, with
/// the active count), "New Project" in the "+" menu, the `projects` collection view (projects grouped by status, each
/// with where its tasks stand, its progress and due date), a progress row under a project note's fields, and the
/// project tasks due above a daily note. Everything goes
/// through the `projects` service, so the CLI and agents do the same with the `projects.*` commands.
public final class ProjectsUIPlugin: UIPlugin {
    public static let manifest = PluginManifest(
        id: "projects-ui",
        name: "Projects view",
        version: "0.1.0",
        description: "The Projects page: every project with its next task and progress.",
        icon: "square.stack.3d.up",
        requires: ["projects"],
        optionalRequires: ["collections.views", "editor", "daily-notes"],
        permissions: ["ui", "vault.read", "vault.write"]
    )

    static let progressHeaderID = "projects.progress"
    static let dayHeaderID = "projects.day"
    static let symbol = "square.stack.3d.up"
    /// Internal: lets the tests reach the shared model. Not a contract.
    static var modelKey: ServiceKey<ProjectsModel> { ServiceKey("projects-ui.model") }

    public init() {}

    @MainActor public func activateUI(context: PluginContext) throws {
        guard let service = context.service(.projects) else { throw ProjectsUIError.serviceMissing }
        let model = ProjectsModel(
            service: service,
            workspace: { [weak context] in context?.workspace },
            editor: { [weak context] in context?.editor },
            report: { [weak context] text in context?.toasts?.show(text, isError: true) },
            vault: context.vault
        )
        model.emitMoves = { [weak context] moves in context?.emit(NotesMoved(moves: moves)) }
        model.refresh()
        try context.provide(Self.modelKey, model)

        try context.addSidebarLink(SidebarLink(
            id: "projects.link", title: "Projects", symbol: Self.symbol, resource: .folder(service.folder), order: 12,
            action: { [weak model] in _ = model?.openPage() }
        ))
        try context.addNewItem(NewItem(id: "projects.new", title: "New Project", symbol: Self.symbol, order: 12) { [weak model] _ in
            model?.newProject()
        })

        context.addCollectionView(CollectionViewType(
            id: "projects",
            title: "Projects",
            symbol: Self.symbol,
            order: 3,
            groupsEntries: true,
            defaults: { definition, view in
                let status = definition.properties.first { $0.kind == .select }?.ref ?? PropertyRef("status")
                return [.setGroupBy(view: view, groupBy: CollectionSort(property: status)),
                        .setOrder(view: view, order: [.title, status, PropertyRef("due")])]
            }
        ) { [weak model] collection in
            guard let model else { return AnyView(EmptyView()) }
            return AnyView(ProjectListView(collection: collection, projects: model))
        })

        // Under a project note's fields: its progress.
        try context.addNoteHeader(NoteHeader(
            id: Self.progressHeaderID,
            order: 10,
            placement: .underTitle,
            appliesTo: { $0.kind == .file && service.isProject($0.path) },
            makeView: { [weak model] view in
                guard let model else { return AnyView(EmptyView()) }
                return AnyView(ProgressBand(model: model, path: view.resource.path))
            }
        ))

        // Above a daily note: the project task notes due that day (and, today, the late ones).
        if context.service(.dailyNotes) != nil {
            try context.addNoteHeader(NoteHeader(
                id: Self.dayHeaderID,
                order: 25,
                appliesTo: { [weak context] in Self.dailyDate(of: $0, context: context) != nil },
                makeView: { [weak context, weak model] view in
                    guard let model, let date = Self.dailyDate(of: view.resource, context: context) else { return AnyView(EmptyView()) }
                    return AnyView(DayProjectTasks(model: model, date: date))
                }
            ))
        }

        try context.registerCommand(Command(
            id: "projects.open",
            title: "Open projects",
            summary: "Opens the projects page (the projects folder as a collection, grouped by status, with each "
                + "project's progress), setting up the folder's collection the first time. Returns what it did."
        ) { _ in
            await MainActor.run { model.openPage() }
        })
        try context.registerCommand(Command(
            id: "projects.new-project",
            title: "New project",
            summary: "Creates an Active project note in the projects folder and opens it. Optional argument: title. "
                + "Writes to the vault. Returns its path."
        ) { arguments in
            try await MainActor.run {
                let title = arguments["title"].flatMap { $0.isEmpty ? nil : $0 } ?? "Untitled"
                guard let path = model.newProject(title: title) else { throw ProjectsUIError.createFailed }
                return path
            }
        })

        context.on(VaultChanged.self) { [weak model] _ in
            onMainThread { model?.refreshSoon() }
        }
        context.on(NotesMoved.self) { [weak model] _ in
            onMainThread { model?.refreshSoon() }
        }
        context.on(DocumentTextChanged.self) { [weak model] _ in
            onMainThread { model?.refreshSoon() }
        }
        context.on(ProjectsFolderChanged.self) { [weak model] _ in
            onMainThread { model?.refresh() }
        }
    }
}

extension ProjectsUIPlugin {
    /// The day of `resource` when it is a daily note (its path is the one the `daily-notes` service gives that day).
    @MainActor static func dailyDate(of resource: Resource, context: PluginContext?) -> String? {
        guard resource.kind == .file, let service = context?.service(.dailyNotes) else { return nil }
        let day = resource.name
        guard let path = try? service.path(for: day), path == resource.path else { return nil }
        return day
    }
}

enum ProjectsUIError: Error, Equatable {
    /// The host activates this plugin after `projects` (it is in `requires`), so this means a broken host.
    case serviceMissing
    case createFailed
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
