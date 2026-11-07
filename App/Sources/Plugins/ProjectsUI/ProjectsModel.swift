import Foundation
import Observation
import PluginKitUI
import ProjectsPlugin

/// The projects as the UI shows them: read through the `projects` service, refreshed a
/// moment after the vault changes. The sidebar's count, the Projects view and the progress row read it.
@MainActor
@Observable
final class ProjectsModel {
    @ObservationIgnored let service: ProjectsService
    @ObservationIgnored private let vault: VaultAccess?
    @ObservationIgnored private let workspace: @MainActor () -> (any Workspace)?
    @ObservationIgnored private let editor: @MainActor () -> (any EditorService)?
    @ObservationIgnored private let report: @MainActor (String) -> Void
    @ObservationIgnored private var pending: Task<Void, Never>?

    private(set) var projects: [ProjectItem] = []
    /// Notes directly in the projects folder, outside a project's folder: the Projects page offers to tidy them.
    private(set) var looseNotes: [String] = []

    init(
        service: ProjectsService,
        workspace: @escaping @MainActor () -> (any Workspace)?,
        editor: @escaping @MainActor () -> (any EditorService)?,
        report: @escaping @MainActor (String) -> Void,
        vault: VaultAccess? = nil
    ) {
        self.service = service
        self.vault = vault
        self.workspace = workspace
        self.editor = editor
        self.report = report
    }

    func refresh() {
        pending?.cancel()
        pending = nil
        let fresh = service.projects()
        if fresh != projects { projects = fresh }
        let loose = service.looseNotes()
        if loose != looseNotes { looseNotes = loose }
    }

    /// Coalesces bursts of changes (typing, a sync) into one read.
    func refreshSoon() {
        pending?.cancel()
        pending = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            self?.refresh()
        }
    }

    func project(_ path: String) -> ProjectItem? {
        projects.first { $0.path == path }
    }

    /// Projects whose status is Active: the sidebar's count.
    var activeCount: Int {
        projects.filter { $0.status?.caseInsensitiveCompare("Active") == .orderedSame }.count
    }

    // MARK: Acting

    /// Opens the projects folder as its collection, writing the collection the first time.
    func openPage() -> String {
        do {
            try service.ensureCollection()
        } catch {
            report("Could not set up the projects folder: \(error)")
            return "Failed: \(error)"
        }
        guard let workspace = workspace() else { return "No workspace in this host." }
        workspace.open(.folder(service.folder), placement: .replace)
        return "Opened \(service.folder)."
    }

    /// A new project with `status` (Active by default), opened in the current tab.
    @discardableResult
    func newProject(title: String = "Untitled", status: String? = nil) -> String? {
        do {
            let path = try service.create(title: title, status: status, due: nil)
            Sounds.play(.created)
            workspace()?.open(.file(path), placement: .replace)
            // The caret waits on the line under the fields, so the first thing typed is what the project is about.
            if let text = vault.flatMap({ try? $0.read(path) }) {
                let lines = text.components(separatedBy: "\n")
                let close = lines.indices.dropFirst().first { lines[$0] == "---" } ?? 0
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                    _ = self?.editor()?.reveal(line: close + 2, in: path)
                }
            }
            refreshSoon()
            return path
        } catch {
            report("Could not create the project: \(error)")
            return nil
        }
    }

    /// The open task notes due on `day` (the late ones too on today).
    func tasks(dueOn day: String) -> [ProjectTask] {
        service.tasks(dueOn: day)
    }

    func needsBoard(_ path: String) -> Bool {
        _ = projects
        return service.needsBoard(path)
    }

    func addBoard(to path: String) {
        do {
            try service.addBoard(to: path)
            refresh()
        } catch {
            report("Could not add the task board: \(error)")
        }
    }

    /// Moves the loose notes into folders of their own (each becomes a project); open tabs follow.
    func tidy() {
        do {
            let moves = try service.tidy()
            if !moves.isEmpty { emitMoves(moves) }
            refresh()
        } catch {
            report("Could not tidy the projects folder: \(error)")
        }
    }

    /// Set by the plugin: announces moves, so open tabs and links follow.
    @ObservationIgnored var emitMoves: @MainActor ([String: String]) -> Void = { _ in }

    func open(_ path: String) {
        workspace()?.open(.file(path), placement: .replace)
    }
}
