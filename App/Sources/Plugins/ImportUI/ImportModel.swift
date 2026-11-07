import AssistantPlugin
import Foundation
import Observation
import ObsidianImportPlugin
import PluginKitUI

/// The import page's state. Its first screen hands the user a prompt for their own agent, which migrates any app's
/// notes into a new vault (`loam guide migrate`). `ObsidianImportRequested` still imports an Obsidian vault here
/// with Loam's converter (to the vault's root when it holds no notes yet), the agent finishing what plain Markdown
/// loses when asked.
@MainActor
@Observable
final class ImportModel {
    enum Step: Equatable {
        /// The migration prompt.
        case choose
        case importing(ObsidianVault, ImportProgress)
        /// The agent at work; `status` is what it is doing now.
        case finishing(ObsidianVault, ImportReport, status: String)
        /// Over: the report note is at `reportPath`.
        case done(ObsidianVault, ImportReport, reportPath: String)
        /// Stopped: why, and how far it went.
        case failed(String, ImportProgress)
    }

    /// An agent ready to finish the import.
    struct ReadyAgent: Equatable {
        let kind: AgentKind
        var name: String { kind.name }
    }

    static let folder = "Imported"

    private(set) var step: Step = .choose {
        didSet { if let progress = progress(of: step) { report(progress) } }
    }
    private(set) var agent: ReadyAgent?
    private var agentCheck: Task<Void, Never>?
    /// Whether the agent finishes the import; off keeps everything on this Mac.
    var useAgent = true
    /// Tells the anonymous usage statistics how an import ended (`UsageEvent`): the count of notes, never their names.
    @ObservationIgnored var onUsage: (String, [String: String]) -> Void = { _, _ in }

    @ObservationIgnored private let importer: () -> (any ObsidianImporting)?
    @ObservationIgnored private let assistant: () -> AssistantEngine?
    @ObservationIgnored private let notes: () -> VaultAccess?
    @ObservationIgnored private let workspace: () -> (any Workspace)?
    /// Told where an import started by the onboarding stands (`ObsidianImportProgress`).
    @ObservationIgnored var report: (ObsidianImportProgress) -> Void = { _ in }

    init(
        importer: @escaping () -> (any ObsidianImporting)?,
        assistant: @escaping () -> AssistantEngine?,
        vault: @escaping () -> VaultAccess?,
        workspace: @escaping () -> (any Workspace)?
    ) {
        self.importer = importer
        self.assistant = assistant
        notes = vault
        self.workspace = workspace
    }

    /// What the user pastes into their agent: where Loam's command line is, and to follow its migration guide, which
    /// ships with the app and so always matches it.
    static func migrationPrompt(cli: String) -> String {
        let quoted = "\"\(cli)\""
        return """
            Migrate my notes into Loam, the Markdown notebook app on this Mac.
            Its command line is \(quoted). Run \(quoted) guide migrate and follow that guide: ask me its three \
            questions, then do the whole migration without stopping.
            """
    }

    /// The prompt with this app's own command line.
    var migrationPrompt: String {
        Self.migrationPrompt(cli: AssistantInstructions.cliPath() ?? "/Applications/Loam.app/Contents/Helpers/loam")
    }

    /// Looks for a ready agent again. The agents' status commands take a moment: off the main thread.
    func load() async {
        guard let engine = assistant() else { return agent = nil }
        let kind = engine.settings().agentKind
        let check = Task.detached { engine.catalog.status(kind).state }
        agentCheck = Task { _ = await check.value }
        let state = await check.value
        agent = state == .ready ? ReadyAgent(kind: kind) : nil
        agentCheck = nil
    }

    /// True while Loam asks the agent whether it is signed in.
    var isCheckingAgent: Bool { agentCheck != nil }

    /// The folder `vault` goes into.
    static func destination(of vault: ObsidianVault) -> String {
        "\(folder)/\(vault.name)"
    }

    /// `step` as the onboarding shows it; nil before an import.
    func progress(of step: Step) -> ObsidianImportProgress? {
        switch step {
        case .choose: nil
        case .importing(_, let progress): .copying(progress)
        case .finishing(_, _, let status): .finishing(agent: agent?.name ?? "", status: status)
        case .done(_, let report, let path): .done(converted: report.converted, reportPath: path)
        case .failed(let message, let progress): .failed(message: message, progress: progress)
        }
    }

    func back() {
        step = .choose
    }

    /// Imports `vault` into `into` (`Imported/<vault>` by default; empty is the vault's root), then lets the agent
    /// finish when it is on and has something to do.
    func start(_ vault: ObsidianVault, into: String? = nil) async {
        let into = into ?? Self.destination(of: vault)
        step = .importing(vault, ImportProgress(done: 0, total: vault.notes))
        let report: ImportReport
        do {
            report = try await run(vault, into: into) { [weak self] progress in self?.copied(progress, of: vault) }
        } catch let failure as ImportFailure {
            let progress = ImportProgress(done: failure.done, total: failure.total, file: failure.file)
            onUsage("import_finished", ["source": "obsidian", "ok": "false", "notes_count": String(failure.done)])
            return step = .failed(String(localized: "\(failure.file) could not be copied: \(failure.reason)."), progress)
        } catch {
            onUsage("import_finished", ["source": "obsidian", "ok": "false", "notes_count": "0"])
            return step = .failed(String(describing: error), ImportProgress(done: 0, total: vault.notes))
        }
        var summary: String?
        // An import started before the agent answered waits for its answer.
        await agentCheck?.value
        if useAgent, let agent, let engine = assistant(), Self.needsAgent(report) {
            step = .finishing(vault, report, status: String(localized: "Starting \(agent.name)…"))
            summary = await finish(vault, report, with: engine, agent: agent.kind)
        }
        let path = into.isEmpty ? "Import report.md" : "\(into)/Import report.md"
        try? notes()?.write(path, Self.reportNote(vault, report, agentSummary: summary))
        onUsage("import_finished", [
            "source": "obsidian", "ok": "true", "notes_count": String(report.converted), "agent": summary == nil ? "false" : "true",
        ])
        step = .done(vault, report, reportPath: path)
    }

    /// Opens the page on its first screen, unless an import is running.
    func show(_ page: Resource) {
        if case .importing = step {} else if case .finishing = step {} else { step = .choose }
        workspace()?.open(page, placement: .replace, from: nil)
    }

    /// Opens the page on `path` and imports it into this vault: to its root when it holds nothing of the user's yet,
    /// else beside their notes.
    func importRequested(_ path: String, useAgent: Bool, page: Resource) async {
        let vault = ObsidianVaults.vault(at: URL(fileURLWithPath: path))
        step = .importing(vault, ImportProgress(done: 0, total: vault.notes))
        workspace()?.open(page, placement: .replace, from: nil)
        await load()
        // The vault's root when it holds nothing of the user's yet; else a folder of its own, beside their notes.
        let empty = notes().map { Self.holdsNoNotes($0.rootURL) } ?? false
        self.useAgent = useAgent && agent != nil
        await start(vault, into: empty ? "" : nil)
    }

    /// True when `root` has nothing but Loam's own files (hidden ones, the welcome note).
    static func holdsNoNotes(_ root: URL) -> Bool {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        return names.allSatisfy { $0.hasPrefix(".") || $0.hasPrefix("Welcome to Loam") }
    }

    func openReport() {
        guard case .done(_, _, let path) = step else { return }
        workspace()?.open(.file(path), placement: .replace, from: nil)
    }

    private func run(_ vault: ObsidianVault, into: String, progress: @escaping (ImportProgress) -> Void) async throws -> ImportReport {
        guard let importer = importer() else { throw ImportUIError.importerMissing }
        return try await importer.run(
            ImportOptions(source: URL(fileURLWithPath: vault.path), into: into),
            progress: progress,
            isolation: MainActor.shared
        )
    }

    /// When the page and the onboarding last heard of the copy: told at most every 40 ms, and always of the end.
    @ObservationIgnored private var lastCopyReport = ContinuousClock.now - .seconds(1)

    private func copied(_ progress: ImportProgress, of vault: ObsidianVault) {
        let now = ContinuousClock.now
        guard progress.done == progress.total || now - lastCopyReport > .milliseconds(40) else { return }
        lastCopyReport = now
        step = .importing(vault, progress)
    }

    // MARK: Agent

    /// True when plain Markdown lost something the agent can bring back.
    static func needsAgent(_ report: ImportReport) -> Bool {
        report.dailyNotes != nil || !report.communityPlugins.isEmpty
    }

    /// Sends the agent its brief and follows its turn; returns its answer.
    private func finish(_ vault: ObsidianVault, _ report: ImportReport, with engine: AssistantEngine, agent: AgentKind) async -> String? {
        let answer = await run(Self.brief(vault, report), with: engine, agent: agent) { [weak self] status in
            guard let self, case .finishing(let vault, let report, _) = self.step else { return }
            self.step = .finishing(vault, report, status: status)
        }
        if let error = answer.error { return String(localized: "The agent stopped: \(error)") }
        return answer.text
    }

    /// Runs one turn of the agent on `prompt` in a new chat, telling `status` what it is doing; returns its last words
    /// or its error.
    private func run(
        _ prompt: String, with engine: AssistantEngine, agent: AgentKind, status: @escaping @MainActor (String) -> Void
    ) async -> (text: String?, error: String?) {
        let chat = engine.newChat(agent: agent, mode: .auto)
        let stop = engine.observe { id in
            guard id == chat.id, let message = engine.chat(id)?.messages.last, message.role == .assistant else { return }
            let title = message.tools.last(where: { $0.state == .running })?.title ?? message.tools.last?.title
            guard let title else { return }
            Task { @MainActor in status(title) }
        }
        defer { stop() }
        await engine.send(chat.id, prompt: prompt)
        await engine.waitForTurnEnd(chat.id)
        let last = engine.chat(chat.id)?.messages.last
        return (last?.text, last?.error.map { "\($0)" })
    }

    /// What the agent is asked to do. The converter already turned links, embeds and callouts into standard Markdown.
    static func brief(_ vault: ObsidianVault, _ report: ImportReport) -> String {
        let into = destination(of: vault)
        var tasks: [String] = []
        if report.communityPlugins.contains("dataview") {
            tasks.append("""
                Dataview: find the ```dataview blocks and inline `= ` queries in \(into)/. Replace each query with an \
                equivalent collection (a `.base` file, Obsidian Bases YAML, through the `collection.*` commands) and \
                a link to it; when there is no equivalent, keep the query in a plain code block and say so.
                """)
        }
        if report.communityPlugins.contains("templater-obsidian") {
            tasks.append("""
                Templater: in the templates, replace `<% %>` tags with plain text or the date placeholders Loam's \
                daily notes understand; keep anything you cannot replace and list it.
                """)
        }
        if let daily = report.dailyNotes {
            tasks.append("""
                Daily notes: Obsidian kept them in "\(daily.folder)" (now \(into)/\(daily.folder)), named \
                "\(daily.format)", template "\(daily.template)". Set Loam's daily notes plugin to match.
                """)
        }
        let others = report.communityPlugins.filter { !["dataview", "templater-obsidian"].contains($0) }
        if !others.isEmpty {
            tasks.append("Other Obsidian plugins it used: \(others.joined(separator: ", ")). Say what each one's "
                + "notes may be missing in Loam; change nothing for them.")
        }
        return """
            An Obsidian vault was just imported into this Loam vault, in \(into)/. Links, embeds and callouts are \
            already standard Markdown. Finish what plain Markdown lost:

            \(tasks.map { "- \($0)" }.joined(separator: "\n"))

            Rules: change only files in \(into)/ and Loam's settings, which are this vault's `.loam/config.json` at \
            its root: never create another `.loam` folder. Never touch the original vault at \(vault.path). \
            Keep notes plain Markdown. End with a short list, in the user's language: what you changed, and what \
            you could not convert.
            """
    }

    // MARK: Report

    static func reportNote(_ vault: ObsidianVault, _ report: ImportReport, agentSummary: String?) -> String {
        var lines = [
            "# Import of \(vault.name)",
            "",
            "From `\(vault.path)`, left untouched.",
            "",
            "- \(report.converted) notes converted",
            "- \(report.copied) other files copied",
        ]
        if !report.skipped.isEmpty { lines.append("- \(report.skipped.count) files already here, left alone") }
        if let agentSummary, !agentSummary.isEmpty {
            lines += ["", "## Finished by the agent", "", agentSummary]
        }
        if !report.warnings.isEmpty {
            lines += ["", "## To check", ""] + report.warnings.prefix(50).map { "- \($0)" }
            if report.warnings.count > 50 { lines.append("- … and \(report.warnings.count - 50) more") }
        }
        return lines.joined(separator: "\n") + "\n"
    }
}

enum ImportUIError: Error, CustomStringConvertible {
    case importerMissing

    var description: String { "The Obsidian import plugin is off." }
}
