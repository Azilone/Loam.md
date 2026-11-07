import AppKit
import CapturePlugin
import Observation
import PluginKit
import PluginKitUI

/// The state of the capture window and of the line that follows it, and the whole flow: read the clipboard, save at
/// once, fill in what the page or the PDF says, then one turn of the user's agent. Main actor; the slow parts run in
/// tasks and come back here.
@MainActor
@Observable
final class CaptureModel {
    // MARK: The window

    var drafts: [CaptureDraft] = []
    var note = ""
    /// What the empty window says: nothing copied, or what could not be read.
    var emptyMessage: String?
    /// The note an exact duplicate already lives in, found before saving.
    var existing: (path: String, title: String, age: String)?
    var isOpen = false

    // MARK: The line after Enter

    enum Line: Equatable {
        case saved(String)
        case sorting(String)
        case done(title: String, detail: String)
        case merged(String)
        case already(String)
        case notSorted(String, reason: String, retry: Bool)
        case failed(String)
    }

    var line: Line?
    /// What Open and Undo act on.
    private(set) var outcomes: [CaptureOutcome] = []
    private(set) var chat: String?

    // MARK: Wiring

    let store: CaptureStore
    var settings: () -> CaptureSettings = { CaptureSettings() }
    /// Runs another plugin's command (`assistant.ask`, `files.trash`…) and returns its answer.
    var run: (_ id: String, _ arguments: [String: String]) async throws -> String = { _, _ in "" }
    var isAvailable: (_ id: String) -> Bool = { _ in false }
    var openNote: (_ path: String) -> Void = { _ in }
    var openSettings: (_ plugin: String) -> Void = { _ in }
    var readVault: (_ path: String) -> String? = { _ in nil }
    var showWindow: () -> Void = {}
    var hideWindow: () -> Void = {}
    var showLine: () -> Void = {}
    var shortcutText: () -> String = { "⌃⌥Space" }
    /// The clipboard's `changeCount` at the last capture: the same copy is not offered twice.
    private var lastChangeCount: Int?
    private var lineTask: Task<Void, Never>?

    init(store: CaptureStore) {
        self.store = store
    }

    // MARK: Opening

    /// Opens the window with what the clipboard holds (empty when it has not changed since the last capture).
    func open(pasteboard: NSPasteboard = .general) {
        note = ""
        existing = nil
        if pasteboard.changeCount == lastChangeCount {
            drafts = []
            emptyMessage = nil
        } else {
            load(PasteboardReader.read(pasteboard))
        }
        isOpen = true
        showWindow()
    }

    /// ⌘V in the window: adds what the clipboard holds now.
    func paste(pasteboard: NSPasteboard = .general) {
        let reading = PasteboardReader.read(pasteboard)
        if case .items(let new) = reading {
            drafts += new.filter { draft in !drafts.contains { $0.content == draft.content } }
            emptyMessage = nil
            checkDuplicate()
        } else if drafts.isEmpty {
            load(reading)
        }
    }

    private func load(_ reading: PasteboardReader.Reading) {
        switch reading {
        case .items(let items):
            drafts = items
            emptyMessage = nil
        case .empty:
            drafts = []
            emptyMessage = nil
        case .unsupported(let type):
            drafts = []
            emptyMessage = "Loam can't capture this yet (\(type))."
        }
        checkDuplicate()
    }

    func remove(_ draft: CaptureDraft) {
        drafts.removeAll { $0.id == draft.id }
        checkDuplicate()
    }

    /// An exact duplicate of a single link or text, found before anything is written.
    private func checkDuplicate() {
        existing = nil
        guard drafts.count == 1 else { return }
        let found: String? = switch drafts[0].content {
        case .link(let url, _): store.duplicate(source: CaptureIdentity.canonicalURL(url), hash: nil)
        case .text(let text): store.duplicate(source: nil, hash: CaptureIdentity.hash(text: text))
        case .file: nil
        }
        guard let found else { return }
        existing = (found, CaptureStore.title(of: found), Self.age(of: found, text: readVault(found)))
    }

    func close() {
        isOpen = false
        hideWindow()
    }

    // MARK: Saving

    var canSave: Bool { !drafts.isEmpty || !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    /// Enter: saves at once, closes the window, then fills in and sorts in the background.
    func confirm(pasteboard: NSPasteboard = .general, asNew: Bool = false) {
        guard canSave else { return }
        let contents = drafts.map(\.content)
        let note = self.note.trimmingCharacters(in: .whitespacesAndNewlines)
        let previews = drafts
        lastChangeCount = pasteboard.changeCount
        close()
        if let existing, contents.count == 1, !asNew {
            if !note.isEmpty { try? store.appendNote(note, to: existing.path) }
            outcomes = [CaptureOutcome(path: existing.path, title: existing.title, kind: contents[0].kind, duplicate: true)]
            present(.already(existing.title), autoHide: true)
            return
        }
        Task { await save(contents, note: note, previews: previews, asNew: asNew) }
    }

    func save(_ contents: [CaptureContent], note: String, previews: [CaptureDraft] = [], asNew: Bool = false) async {
        do {
            let saved = try await store.save(contents, note: note, allowDuplicates: asNew)
            outcomes = saved
            chat = nil
            Sounds.play(.created)
            let fresh = saved.filter { !$0.duplicate }
            guard !fresh.isEmpty else {
                present(.already(saved.first?.title ?? ""), autoHide: true)
                return
            }
            present(.saved(where_()), autoHide: false)
            let items = await fillIn(fresh, contents: contents)
            await sort(items, note: note)
        } catch {
            Sounds.play(.failed)
            present(.failed("Not saved · \(error.localizedDescription)"), autoHide: true)
        }
    }

    /// Page metadata and covers: what makes the note look right without any agent. `saved` has one outcome per
    /// content (a note typed alone is one text).
    private func fillIn(_ saved: [CaptureOutcome], contents: [CaptureContent]) async -> [CapturePrompt.Item] {
        var updated = saved
        var items: [CapturePrompt.Item] = []
        let pairs = Array(zip(contents.isEmpty ? [CaptureContent.text("")] : contents, saved.indices))
        for (content, index) in pairs where !saved[index].duplicate {
            var path = saved[index].path
            var item = CapturePrompt.Item(path: path, kind: saved[index].kind, title: saved[index].title, file: saved[index].files.first)
            switch content {
            case let .link(url, _):
                item.source = CaptureIdentity.canonicalURL(url)
                if let address = URL(string: url), let metadata = await LinkMetadata.fetch(address) {
                    let cover = await CapturePlugin.cover(for: metadata)
                    if let renamed = try? await store.enrich(path, with: metadata, cover: cover) { path = renamed }
                    item.description = metadata.description
                    item.text = metadata.text
                }
            case let .file(_, contents) where saved[index].kind == .pdf:
                if let data = try? contents.data() {
                    item.text = PDFPreview.text(data)
                    if let png = PDFPreview.coverPNG(data) { try? await store.setCover(path, name: "cover.png", data: png) }
                }
            default:
                break
            }
            item.path = path
            item.title = CaptureStore.title(of: path)
            updated[index] = store.recent().first { $0.path == path } ?? updated[index]
            items.append(item)
        }
        outcomes = updated
        return items
    }

    // MARK: The agent

    /// One turn of the user's agent on the new notes. Never blocks: the notes are saved already.
    func sort(_ items: [CapturePrompt.Item], note: String) async {
        let settings = self.settings()
        guard settings.useAgent, !items.isEmpty else {
            present(.done(title: items.first?.title ?? "", detail: store.collectionName), autoHide: true)
            return
        }
        guard isAvailable("assistant.ask") else {
            present(.notSorted(where_(), reason: "turn on the Assistant to sort it", retry: false), autoHide: true)
            return
        }
        let agent = await agentStatus(setting: settings.agent)
        guard let agent, agent.state == "ready" else {
            let reason = agent.map { $0.state == "signedOut" ? "sign in to \(Self.name($0.kind)) to sort it" : "connect an agent to sort it" }
                ?? "connect an agent to sort it"
            present(.notSorted(where_(), reason: reason, retry: false), autoHide: true)
            return
        }
        present(.sorting(where_()), autoHide: false)
        let prompt = CapturePrompt.make(
            items: items, collection: store.collectionName, folder: store.folder, note: note, tags: store.tagsInUse(),
            cli: Self.cliPath(), instructions: readVault(CapturePrompt.overrideFile)
        )
        var ask = ["prompt": prompt, "mode": "auto", "note": items[0].path]
        if settings.agent != "auto" { ask["agent"] = agent.kind }
        let arguments = ask
        do {
            let answer = try await withTimeout(seconds: 180) { [self] in try await self.run("assistant.ask", arguments) }
            guard let answer else {
                present(.notSorted(where_(), reason: "still sorting, it will show up in the note", retry: false), autoHide: true)
                return
            }
            finish(answer, items: items)
        } catch {
            present(.notSorted(where_(), reason: "couldn't sort it", retry: true), autoHide: true)
        }
    }

    private struct Ask: Decodable {
        struct Change: Decodable { let path: String }
        let chat: String
        let answer: String
        let changes: [Change]
        let error: String?
    }

    private func finish(_ json: String, items: [CapturePrompt.Item]) {
        guard let ask = try? JSONDecoder().decode(Ask.self, from: Data(json.utf8)) else {
            present(.notSorted(where_(), reason: "couldn't sort it", retry: true), autoHide: true)
            return
        }
        chat = ask.chat
        if let error = ask.error, !error.isEmpty, ask.changes.isEmpty {
            present(.notSorted(where_(), reason: Self.short(error), retry: true), autoHide: true)
            return
        }
        let results = CapturePrompt.results(in: ask.answer) ?? []
        // Follow renames, so Open and Undo find the notes.
        for result in results {
            guard let path = result.path, result.n >= 1, result.n <= items.count else { continue }
            store.follow(items[result.n - 1].path, to: path)
            if let index = outcomes.firstIndex(where: { $0.path == items[result.n - 1].path }) {
                outcomes[index].path = path
                outcomes[index].title = CaptureStore.title(of: path)
            }
        }
        let merged = results.compactMap(\.mergedInto)
        let outside = CapturePrompt.outOfScope(
            changes: ask.changes.map(\.path), folder: store.folder, files: outcomes.flatMap(\.files), mergedInto: merged
        )
        if !outside.isEmpty {
            present(.done(title: outcomes.first?.title ?? "", detail: "also changed \(outside.count) other note\(outside.count == 1 ? "" : "s")"), autoHide: false)
            return
        }
        if let into = merged.first {
            present(.merged(CaptureStore.title(of: into)), autoHide: true)
            return
        }
        if outcomes.count > 1 {
            present(.done(title: "\(outcomes.count) items", detail: store.collectionName), autoHide: true)
            return
        }
        let tags = results.first?.tags?.prefix(2).map { "#" + $0 }.joined(separator: " ") ?? ""
        present(.done(title: outcomes.first?.title ?? "", detail: tags.isEmpty ? store.collectionName : tags), autoHide: true)
    }

    /// The agent the Assistant would use (`auto`), or the one named in capture's setting.
    private func agentStatus(setting: String) async -> (kind: String, state: String)? {
        struct Status: Decodable { let kind: String; let state: String }
        if setting == "auto" {
            guard let json = try? await run("assistant.default-agent", [:]),
                  let status = try? JSONDecoder().decode(Status.self, from: Data(json.utf8)) else { return nil }
            return (status.kind, status.state)
        }
        guard let json = try? await run("assistant.agents", [:]),
              let all = try? JSONDecoder().decode([Status].self, from: Data(json.utf8)),
              let status = all.first(where: { $0.kind == setting }) else { return nil }
        return (status.kind, status.state)
    }

    func retry() {
        let items = outcomes.filter { !$0.duplicate }.map {
            CapturePrompt.Item(path: $0.path, kind: $0.kind, title: $0.title, file: $0.files.first)
        }
        Task { await sort(items, note: "") }
    }

    // MARK: Open and Undo

    func openFirst() {
        guard let path = outcomes.first?.path else { return }
        openNote(path)
        dismissLine()
    }

    /// Puts the capture back: the agent's turn first (its checkpoint), then the notes and files to the trash.
    func undo() {
        let outcomes = self.outcomes
        let chat = self.chat
        dismissLine()
        Task {
            if let chat { _ = try? await run("assistant.undo-turn", ["chat": chat]) }
            for outcome in outcomes where !outcome.duplicate {
                // The agent's undo may have put the note back under its first name.
                let current = store.recent().first { $0.files == outcome.files && !outcome.files.isEmpty } ?? outcome
                try? store.undo(current)
            }
            self.outcomes = []
        }
    }

    var canUndo: Bool { outcomes.contains { !$0.duplicate } }

    func dismissLine() {
        lineTask?.cancel()
        line = nil
    }

    /// Hovering the line keeps it.
    var isHoveringLine = false {
        didSet { if !isHoveringLine, line != nil, lineTask == nil { scheduleHide(after: 3) } }
    }

    private func present(_ line: Line, autoHide: Bool) {
        lineTask?.cancel()
        lineTask = nil
        self.line = line
        showLine()
        if autoHide { scheduleHide(after: 6) }
    }

    private func scheduleHide(after seconds: Double) {
        lineTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled, let self else { return }
            if self.isHoveringLine {
                self.lineTask = nil
                return
            }
            self.line = nil
            self.lineTask = nil
        }
    }

    // MARK: Helpers

    private func where_() -> String { store.collectionName }

    static func name(_ kind: String) -> String {
        ["claude": "Claude Code", "codex": "Codex", "antigravity": "Antigravity", "pi": "Pi", "opencode": "OpenCode"][kind] ?? kind
    }

    static func short(_ error: String) -> String {
        let line = error.split(whereSeparator: \.isNewline).first.map(String.init) ?? error
        return line.count > 60 ? String(line.prefix(59)) + "…" : line
    }

    /// The `loam` command line shipped in the app, else the one on the PATH.
    static func cliPath() -> String {
        let bundled = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/loam")
        return FileManager.default.isExecutableFile(atPath: bundled.path) ? bundled.path : "loam"
    }

    static func age(of path: String, text: String?) -> String {
        guard let text, let yaml = MarkdownFrontmatter.split(text).yaml,
              let line = yaml.split(separator: "\n").first(where: { $0.hasPrefix("captured:") }) else { return "" }
        let value = line.dropFirst("captured:".count).trimmingCharacters(in: CharacterSet(charactersIn: " \"'"))
        guard let date = ISO8601DateFormatter().date(from: value) else { return "" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return "saved " + formatter.localizedString(for: date, relativeTo: Date())
    }
}

/// Runs `operation`, giving up waiting after `seconds` (the operation goes on).
func withTimeout<T: Sendable>(seconds: Double, _ operation: @escaping @Sendable @MainActor () async throws -> T) async throws -> T? {
    try await withThrowingTaskGroup(of: T?.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(for: .seconds(seconds))
            return nil
        }
        let first = try await group.next() ?? nil
        group.cancelAll()
        return first
    }
}
