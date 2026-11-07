import Foundation

/// What the runtimes share: a process speaking JSON lines, read on a task that hands each message to `handle`, and
/// the event channel. A subclass says how to start (`arguments`, `didStart`), how to send a prompt and how to read
/// a message.
class LineRuntime: AgentRuntime, @unchecked Sendable {
    let configuration: AgentConfiguration
    let channel = EventChannel()
    private(set) var link: ProcessLink?
    private var reader: Task<Void, Never>?
    let lock = StateLock()

    var events: AsyncStream<AgentEvent> { channel.stream }

    init(configuration: AgentConfiguration) {
        self.configuration = configuration
    }

    /// The program's arguments.
    func arguments() -> [String] { [] }

    /// Called once the process runs, before the first prompt (a handshake).
    func didStart() async throws {}

    func send(_ prompt: String) async throws {}

    /// One message the program printed.
    func handle(_ message: [String: Any]) {}

    /// A line that is not JSON: most agents print a warning or two this way.
    func handleText(_ line: String) {}

    func cancel() async {}

    func answer(approval id: String, option: AgentApproval.Option) async {}

    func start() async throws {
        let link = ProcessLink(
            executable: configuration.executable, arguments: arguments(), folder: configuration.folder,
            environment: configuration.environment
        )
        do {
            try link.start()
        } catch {
            throw AgentError("\(configuration.kind.name) could not start: \(error.localizedDescription)")
        }
        lock.lock()
        self.link = link
        lock.unlock()
        reader = Task { [weak self] in
            for await line in link.lines {
                guard let self else { return }
                if let message = JSONLine.decode(line) {
                    self.handle(message)
                } else {
                    self.handleText(line)
                }
            }
            self?.processEnded()
        }
        try await didStart()
    }

    /// The program exited: a failure unless `stop` asked for it.
    func processEnded() {
        lock.lock()
        let stopped = isStopped
        lock.unlock()
        if !stopped {
            let detail = link?.errorOutput ?? ""
            channel.send(.failed(detail.isEmpty
                ? "\(configuration.kind.name) stopped."
                : "\(configuration.kind.name) stopped: \(String(detail.suffix(400)))"))
        }
        failPending(AgentError("\(configuration.kind.name) stopped."))
        channel.finish()
    }

    private var isStopped = false

    func stop() {
        lock.lock()
        isStopped = true
        let link = link
        lock.unlock()
        link?.stop()
        failPending(AgentError("Stopped."))
    }

    func write(_ object: [String: Any]) {
        link?.writeJSON(object)
    }

    // MARK: JSON-RPC, for the agents that speak it (Codex's app server, ACP)

    private var nextID = 0
    private var pending: [Int: CheckedContinuation<[String: Any], Error>] = [:]

    /// Sends a request and waits for its result.
    func request(_ method: String, _ params: [String: Any]) async throws -> [String: Any] {
        lock.lock()
        nextID += 1
        let id = nextID
        lock.unlock()
        return try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            pending[id] = continuation
            lock.unlock()
            write(["jsonrpc": "2.0", "id": id, "method": method, "params": params])
        }
    }

    func notify(_ method: String, _ params: [String: Any]? = nil) {
        var message: [String: Any] = ["jsonrpc": "2.0", "method": method]
        if let params { message["params"] = params }
        write(message)
    }

    func respond(to id: Any, result: Any) {
        write(["jsonrpc": "2.0", "id": id, "result": result])
    }

    func respond(to id: Any, error message: String) {
        write(["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": message]])
    }

    /// Hands a response to its waiting request; true when `message` was one.
    func resolveResponse(_ message: [String: Any]) -> Bool {
        guard message["method"] == nil, let id = message["id"] as? Int else { return false }
        lock.lock()
        let continuation = pending.removeValue(forKey: id)
        lock.unlock()
        guard let continuation else { return true }
        if let error = message.object("error") {
            continuation.resume(throwing: AgentError(error.string("message") ?? "\(configuration.kind.name) refused."))
        } else {
            continuation.resume(returning: message.object("result") ?? [:])
        }
        return true
    }

    private func failPending(_ error: Error) {
        lock.lock()
        let waiting = pending.values
        pending.removeAll()
        lock.unlock()
        for continuation in waiting { continuation.resume(throwing: error) }
    }
}
