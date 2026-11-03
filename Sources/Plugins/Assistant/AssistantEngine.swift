import Foundation

/// The assistant's chats and the agents behind them: starts an agent when a chat sends its first prompt, turns its
/// events into messages, snapshots the vault around each turn, and undoes a turn on request. The interface and the
/// `assistant.*` commands both go through it. Thread-safe; observers are told which chat changed.
public final class AssistantEngine: @unchecked Sendable {
    public let vault: URL
    public let catalog: AgentCatalog
    public let prompts: PromptStore
    private let store: ChatStore
    private let checkpoints: Checkpoints
    private let makeRuntime: @Sendable (AgentConfiguration) -> AgentRuntime
    private let lock = StateLock()
    private var chats: [String: Chat] = [:]
    private var loaded = false
    private var runtimes: [String: AgentRuntime] = [:]
    private var listeners: [String: Task<Void, Never>] = [:]
    private var busy: Set<String> = []
    private var approvals: [String: AgentApproval] = [:]
    private var observers: [UUID: @Sendable (String) -> Void] = [:]
    private var turnWaiters: [String: [CheckedContinuation<Void, Never>]] = [:]
    /// The Assistant's settings as they stand, set by the plugin, so a panel reads them without settings of its own.
    public var settings: @Sendable () -> AssistantPlugin.Settings = { AssistantPlugin.Settings() }

    public init(
        vault: URL,
        catalog: AgentCatalog = AgentCatalog(),
        git: URL? = nil,
        locateGit: (@Sendable () -> URL?)? = nil,
        makeRuntime: @escaping @Sendable (AgentConfiguration) -> AgentRuntime = { AgentCatalog.runtime($0) }
    ) {
        self.vault = vault
        self.catalog = catalog
        self.makeRuntime = makeRuntime
        prompts = PromptStore(vault: vault)
        store = ChatStore(vault: vault)
        checkpoints = Checkpoints(folder: vault, locateGit: locateGit ?? { git })
    }

    // MARK: Observing

    /// Calls `observer` with a chat's id each time it changes. Returns the way to stop.
    public func observe(_ observer: @escaping @Sendable (String) -> Void) -> @Sendable () -> Void {
        let id = UUID()
        lock.lock()
        observers[id] = observer
        lock.unlock()
        return { [weak self] in
            self?.lock.lock()
            self?.observers[id] = nil
            self?.lock.unlock()
        }
    }

    private func changed(_ chatID: String) {
        lock.lock()
        let observers = Array(observers.values)
        lock.unlock()
        for observer in observers { observer(chatID) }
    }

    // MARK: Chats

    /// Every chat, most recent first.
    public func allChats() -> [Chat] {
        loadIfNeeded()
        lock.lock()
        defer { lock.unlock() }
        return chats.values.sorted { $0.updated > $1.updated }
    }

    public func chat(_ id: String) -> Chat? {
        loadIfNeeded()
        lock.lock()
        defer { lock.unlock() }
        return chats[id]
    }

    public func isBusy(_ id: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return busy.contains(id)
    }

    /// The question the agent of `id` waits on, if any.
    public func approval(_ id: String) -> AgentApproval? {
        lock.lock()
        defer { lock.unlock() }
        return approvals[id]
    }

    public func newChat(agent: AgentKind, model: String = "", mode: AgentMode = .auto) -> Chat {
        loadIfNeeded()
        let chat = Chat(agent: agent, model: model, mode: mode)
        lock.lock()
        chats[chat.id] = chat
        lock.unlock()
        return chat
    }

    /// Changes a chat's agent, model or mode. The running agent stops; the next prompt starts it again, continuing
    /// the conversation when the agent stays the same.
    public func configure(_ id: String, agent: AgentKind? = nil, model: String? = nil, mode: AgentMode? = nil) {
        lock.lock()
        guard var chat = chats[id] else {
            lock.unlock()
            return
        }
        if let agent, agent != chat.agent {
            chat.agent = agent
            chat.sessionID = nil
            chat.model = model ?? ""
        } else if let model {
            chat.model = model
        }
        if let mode { chat.mode = mode }
        chats[id] = chat
        let runtime = runtimes.removeValue(forKey: id)
        listeners.removeValue(forKey: id)?.cancel()
        lock.unlock()
        runtime?.stop()
        if !chat.messages.isEmpty { store.save(chat) }
        changed(id)
    }

    public func delete(_ id: String) {
        lock.lock()
        chats[id] = nil
        let runtime = runtimes.removeValue(forKey: id)
        listeners.removeValue(forKey: id)?.cancel()
        lock.unlock()
        runtime?.stop()
        store.delete(id)
        changed(id)
    }

    /// Stops every agent: the plugin is unloading or the app quits.
    public func stopAll() {
        lock.lock()
        let all = Array(runtimes.values)
        runtimes.removeAll()
        listeners.values.forEach { $0.cancel() }
        listeners.removeAll()
        lock.unlock()
        all.forEach { $0.stop() }
    }

    // MARK: Images

    /// Keeps a pasted or dropped image for the chat, in `.loam/cache/ai/attachments`, and returns its vault path:
    /// the original may be a screenshot tool's temporary file.
    public func attach(image data: Data, extension ext: String) throws -> String {
        let folder = vault.appendingPathComponent(Self.attachments, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let name = UUID().uuidString.prefix(8).lowercased() + "." + (ext.isEmpty ? "png" : ext.lowercased())
        try data.write(to: folder.appendingPathComponent(name), options: .atomic)
        return Self.attachments + "/" + name
    }

    static let attachments = ".loam/cache/ai/attachments"

    // MARK: Turns

    /// Sends `prompt` in chat `id`, with the notes in `context` named for the agent. Returns once the agent has the
    /// prompt; the answer streams in through observers. `waitForTurnEnd` waits for the whole answer.
    public func send(
        _ id: String, prompt: String, context: [String] = [], selection: NoteSelection? = nil, images: [String] = []
    ) async {
        loadIfNeeded()
        var text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty, !images.isEmpty { text = images.count == 1 ? "Look at this image." : "Look at these images." }
        lock.lock()
        guard var chat = chats[id], !text.isEmpty, !busy.contains(id) else {
            lock.unlock()
            return
        }
        if chat.messages.isEmpty { chat.title = Self.title(for: text) }
        chat.messages.append(ChatMessage(role: .user, text: text, context: context, selection: selection, images: images))
        chat.messages.append(ChatMessage(role: .assistant))
        chat.updated = Date()
        chats[id] = chat
        busy.insert(id)
        lock.unlock()
        store.save(chat)
        changed(id)

        let before = checkpoints.snapshot("Before: \(Self.title(for: text))")
        update(id) { $0.messages[$0.messages.count - 1].checkpoint = before }

        do {
            let runtime = try await runtime(for: id)
            let images = images.map { vault.appendingPathComponent($0).path }
            try await runtime.send(Self.prompt(text, context: context, selection: selection, images: images))
        } catch {
            fail(id, error.localizedDescription)
            await endTurn(id)
        }
    }

    /// Waits until chat `id` is not answering anymore.
    public func waitForTurnEnd(_ id: String) async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if busy.contains(id) {
                turnWaiters[id, default: []].append(continuation)
                lock.unlock()
            } else {
                lock.unlock()
                continuation.resume()
            }
        }
    }

    public func cancel(_ id: String) async {
        lock.lock()
        let runtime = runtimes[id]
        let waiting = approvals.removeValue(forKey: id)
        lock.unlock()
        // The turn being stopped, by its answer: a task sent after it ended is another turn.
        let turn = chat(id)?.messages.last?.id
        if let waiting, let reject = waiting.options.first(where: { $0.kind == .reject }) {
            await runtime?.answer(approval: waiting.id, option: reject)
        }
        await runtime?.cancel()
        // An agent that cannot be interrupted (or is slow to) still lets the user go on.
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        if isBusy(id), chat(id)?.messages.last?.id == turn {
            lock.lock()
            let stuck = runtimes.removeValue(forKey: id)
            listeners.removeValue(forKey: id)?.cancel()
            lock.unlock()
            stuck?.stop()
            await endTurn(id)
        }
    }

    public func answer(_ id: String, option: AgentApproval.Option) async {
        lock.lock()
        let waiting = approvals.removeValue(forKey: id)
        let runtime = runtimes[id]
        lock.unlock()
        changed(id)
        guard let waiting else { return }
        await runtime?.answer(approval: waiting.id, option: option)
    }

    /// Puts back what the turn of `messageID` changed.
    public func undo(_ id: String, messageID: String) throws {
        guard let chat = chat(id), let message = chat.messages.first(where: { $0.id == messageID }),
              let checkpoint = message.checkpoint, !message.changes.isEmpty, !message.undone else {
            throw AgentError("Nothing to undo in that turn.")
        }
        try checkpoints.restore(message.changes, to: checkpoint)
        update(id) { chat in
            guard let index = chat.messages.firstIndex(where: { $0.id == messageID }) else { return }
            chat.messages[index].undone = true
        }
        save(id)
    }

    // MARK: Agents

    private func runtime(for id: String) async throws -> AgentRuntime {
        lock.lock()
        if let existing = runtimes[id] {
            lock.unlock()
            return existing
        }
        guard let chat = chats[id] else {
            lock.unlock()
            throw AgentError("No such chat.")
        }
        lock.unlock()
        guard let executable = catalog.executable(chat.agent) else {
            throw AgentError("\(chat.agent.name) is not installed. Install it with: \(chat.agent.installHint)")
        }
        let configuration = AgentConfiguration(
            kind: chat.agent, executable: executable, environment: ShellEnvironment.shared.variables, folder: vault,
            model: chat.model, mode: chat.mode,
            instructions: AssistantInstructions.make(vault: vault, mode: chat.mode, cli: AssistantInstructions.cliPath()),
            resumeID: chat.sessionID
        )
        let runtime = makeRuntime(configuration)
        let listener = Task { [weak self] in
            for await event in runtime.events {
                await self?.handle(event, chat: id)
            }
            await self?.runtimeEnded(id, runtime: runtime)
        }
        lock.lock()
        runtimes[id] = runtime
        listeners[id] = listener
        lock.unlock()
        do {
            try await runtime.start()
        } catch {
            lock.lock()
            runtimes[id] = nil
            listeners.removeValue(forKey: id)?.cancel()
            lock.unlock()
            runtime.stop()
            throw error
        }
        return runtime
    }

    private func handle(_ event: AgentEvent, chat id: String) async {
        switch event {
        case .session(let session):
            update(id) { $0.sessionID = session }
        case .text(let text):
            updateLast(id) { $0.text += text }
        case .thinking(let text):
            updateLast(id) { $0.thinking += text }
        case let .tool(toolID, title, path, finished, failed):
            updateLast(id) { message in
                let state: ToolCall.State = failed ? .failed : finished ? .done : .running
                if let index = message.tools.firstIndex(where: { $0.id == toolID }) {
                    message.tools[index].state = state
                    message.tools[index].title = title
                    if path != nil { message.tools[index].path = path }
                } else {
                    message.tools.append(ToolCall(id: toolID, title: title, path: path, state: state))
                }
            }
        case .approval(let approval):
            let mode = chat(id)?.mode ?? .ask
            let automatic: AgentApproval.Option? = switch mode {
            case .auto: approval.options.first { $0.kind == .allowAlways } ?? approval.options.first { $0.kind == .allowOnce }
            case .readOnly: approval.options.first { $0.kind == .reject }
            case .ask: nil
            }
            lock.lock()
            let runtime = runtimes[id]
            if automatic == nil { approvals[id] = approval }
            lock.unlock()
            if let automatic {
                await runtime?.answer(approval: approval.id, option: automatic)
            } else {
                changed(id)
            }
        case .turnEnded:
            await endTurn(id)
        case .failed(let message):
            fail(id, message)
        }
    }

    private func runtimeEnded(_ id: String, runtime: AgentRuntime) async {
        lock.lock()
        let current = runtimes[id] === runtime
        if current {
            runtimes[id] = nil
            listeners[id] = nil
        }
        lock.unlock()
        if current, isBusy(id) { await endTurn(id) }
    }

    private func fail(_ id: String, _ message: String) {
        updateLast(id) { last in
            last.error = last.error.map { $0 + "\n" + message } ?? message
        }
    }

    private func endTurn(_ id: String) async {
        lock.lock()
        guard busy.contains(id) else {
            lock.unlock()
            return
        }
        lock.unlock()
        let before = chat(id)?.messages.last?.checkpoint
        if let before, let after = checkpoints.snapshot("After") {
            let changes = checkpoints.changes(from: before, to: after)
            updateLast(id) { $0.changes = changes }
        }
        updateLast(id) { message in
            for index in message.tools.indices where message.tools[index].state == .running {
                message.tools[index].state = .done
            }
        }
        lock.lock()
        busy.remove(id)
        approvals[id] = nil
        let waiters = turnWaiters.removeValue(forKey: id) ?? []
        lock.unlock()
        save(id)
        changed(id)
        waiters.forEach { $0.resume() }
    }

    // MARK: State

    private func update(_ id: String, _ change: (inout Chat) -> Void) {
        lock.lock()
        guard var chat = chats[id] else {
            lock.unlock()
            return
        }
        change(&chat)
        chat.updated = Date()
        chats[id] = chat
        lock.unlock()
        changed(id)
    }

    private func updateLast(_ id: String, _ change: (inout ChatMessage) -> Void) {
        update(id) { chat in
            guard let index = chat.messages.indices.last, chat.messages[index].role == .assistant else { return }
            change(&chat.messages[index])
        }
    }

    private func save(_ id: String) {
        if let chat = chat(id) { store.save(chat) }
    }

    private func loadIfNeeded() {
        lock.lock()
        let needed = !loaded
        loaded = true
        lock.unlock()
        guard needed else { return }
        let saved = store.all()
        lock.lock()
        for chat in saved where chats[chat.id] == nil { chats[chat.id] = chat }
        lock.unlock()
    }

    static func title(for prompt: String) -> String {
        let line = prompt.split(separator: "\n").first.map(String.init) ?? prompt
        return line.count > 48 ? String(line.prefix(47)) + "…" : line
    }

    /// The prompt as the agent gets it: the notes the user pointed at, the passage selected, then the request.
    static func prompt(_ text: String, context: [String], selection: NoteSelection? = nil, images: [String] = []) -> String {
        var lead: [String] = []
        if !context.isEmpty {
            let notes = context.map { path -> String in
                let name = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
                return "[[\(name)]] (`\(path)`)"
            }
            lead.append(context.count == 1
                ? "The user is looking at the note \(notes[0])."
                : "The user points at these notes: \(notes.joined(separator: ", ")).")
        }
        if let selection {
            let name = ((selection.path as NSString).lastPathComponent as NSString).deletingPathExtension
            let quoted = selection.text.split(separator: "\n", omittingEmptySubsequences: false).map { "> \($0)" }
                .joined(separator: "\n")
            lead.append("The user selected this passage in [[\(name)]] (`\(selection.path)`); the request is about it:\n\(quoted)")
        }
        if !images.isEmpty {
            let list = images.map { "- `\($0)`" }.joined(separator: "\n")
            lead.append("The user attached \(images.count == 1 ? "an image" : "images"); open and look at \(images.count == 1 ? "it" : "them") before answering:\n\(list)")
        }
        return lead.isEmpty ? text : lead.joined(separator: "\n\n") + "\n\n" + text
    }
}
