import Foundation

/// Codex through `codex app-server`, the JSON-RPC server its own editors use: a thread per chat, a turn per prompt,
/// approvals as requests from the server. The ChatGPT sign-in stays Codex's.
final class CodexRuntime: LineRuntime, @unchecked Sendable {
    private var threadID: String?
    private var turnID: String?
    /// Whether text was added in this turn, so the next message starts on a new paragraph.
    private var wroteText = false
    private var approvalRequests: [String: Any] = [:]

    override func arguments() -> [String] { ["app-server"] }

    override func didStart() async throws {
        _ = try await request("initialize", ["clientInfo": ["name": "loam", "title": "Loam", "version": "1.0"]])
        notify("initialized")
        var params: [String: Any] = [
            "cwd": configuration.folder.path,
            "approvalPolicy": configuration.mode == .ask ? "on-request" : "never",
            "sandbox": configuration.mode == .readOnly ? "read-only" : "workspace-write",
        ]
        if !configuration.model.isEmpty { params["model"] = configuration.model }
        if !configuration.instructions.isEmpty { params["developerInstructions"] = configuration.instructions }
        let result: [String: Any]
        if let resume = configuration.resumeID,
           let resumed = try? await request("thread/resume", params.merging(["threadId": resume]) { $1 }) {
            result = resumed
        } else {
            result = try await request("thread/start", params)
        }
        guard let id = result.object("thread")?.string("id") else { throw AgentError("Codex did not start a thread.") }
        lock.lock()
        threadID = id
        lock.unlock()
        channel.send(.session(id))
    }

    override func send(_ prompt: String) async throws {
        lock.lock()
        let thread = threadID
        wroteText = false
        lock.unlock()
        guard let thread else { throw AgentError("Codex is not ready.") }
        let result = try await request("turn/start", ["threadId": thread, "input": [["type": "text", "text": prompt]]])
        lock.lock()
        turnID = result.object("turn")?.string("id")
        lock.unlock()
    }

    override func cancel() async {
        lock.lock()
        let thread = threadID
        let turn = turnID
        lock.unlock()
        guard let thread, let turn else { return }
        _ = try? await request("turn/interrupt", ["threadId": thread, "turnId": turn])
    }

    override func answer(approval id: String, option: AgentApproval.Option) async {
        lock.lock()
        let requestID = approvalRequests.removeValue(forKey: id)
        lock.unlock()
        guard let requestID else { return }
        let decision = switch option.kind {
        case .allowOnce: "accept"
        case .allowAlways: "acceptForSession"
        case .reject: "decline"
        }
        respond(to: requestID, result: ["decision": decision])
    }

    override func handle(_ message: [String: Any]) {
        if resolveResponse(message) { return }
        guard let method = message.string("method") else { return }
        let params = message.object("params") ?? [:]
        if let id = message["id"] {
            serverRequest(id: id, method: method, params: params)
            return
        }
        switch method {
        case "item/agentMessage/delta":
            guard let delta = params.string("delta") else { return }
            lock.lock()
            wroteText = true
            lock.unlock()
            channel.send(.text(delta))
        case "item/reasoning/summaryTextDelta", "item/reasoning/textDelta":
            if let delta = params.string("delta") { channel.send(.thinking(delta)) }
        case "item/started", "item/completed":
            item(params.object("item") ?? [:], finished: method == "item/completed")
        case "turn/completed":
            let turn = params.object("turn") ?? [:]
            if turn.string("status") == "failed", let error = turn.object("error") {
                channel.send(.failed(error.string("message") ?? "Codex failed."))
            }
            lock.lock()
            turnID = nil
            lock.unlock()
            channel.send(.turnEnded(cost: nil))
        case "error":
            if params["willRetry"] as? Bool == true { return }
            let error = params.object("error")
            channel.send(.failed(error?.string("message") ?? params.string("message") ?? "Codex failed."))
        default:
            break
        }
    }

    private func item(_ item: [String: Any], finished: Bool) {
        guard let id = item.string("id") else { return }
        switch item.string("type") {
        case "agentMessage":
            // Two messages in one turn (a comment, then the answer) are two paragraphs.
            guard !finished else { return }
            lock.lock()
            let separate = wroteText
            lock.unlock()
            if separate { channel.send(.text("\n\n")) }
        case "commandExecution":
            let command = item.objects("commandActions").first?.string("command") ?? item.string("command") ?? ""
            let made = ToolTitle.make(tool: "Run", path: nil, command: command, folder: configuration.folder)
            channel.send(.tool(id: id, title: made.title, path: nil, finished: finished,
                               failed: finished && (item["exitCode"] as? Int ?? 0) != 0))
        case "fileChange":
            let path = item.objects("changes").first?.string("path")
            let made = ToolTitle.make(tool: "Edit", path: path, command: nil, folder: configuration.folder)
            channel.send(.tool(id: id, title: made.title, path: made.path, finished: finished,
                               failed: finished && item.string("status") == "failed"))
        case "webSearch":
            channel.send(.tool(id: id, title: "Searched the web", path: nil, finished: finished, failed: false))
        case "mcpToolCall":
            channel.send(.tool(id: id, title: item.string("tool") ?? "Tool", path: nil, finished: finished,
                               failed: false))
        default:
            break
        }
    }

    private func serverRequest(id: Any, method: String, params: [String: Any]) {
        switch method {
        case "item/commandExecution/requestApproval", "item/fileChange/requestApproval",
             "execCommandApproval", "applyPatchApproval":
            let key = UUID().uuidString
            lock.lock()
            approvalRequests[key] = id
            lock.unlock()
            let command = params.string("command") ?? (params["command"] as? [String])?.joined(separator: " ")
            let title = command.map { "Run \(ToolTitle.shorten($0))?" } ?? "Change files?"
            channel.send(.approval(AgentApproval(
                id: key, title: title, detail: params.string("reason") ?? "",
                options: [
                    .init(id: "accept", label: "Allow Once", kind: .allowOnce),
                    .init(id: "acceptForSession", label: "Allow for This Chat", kind: .allowAlways),
                    .init(id: "decline", label: "Decline", kind: .reject),
                ]
            )))
        default:
            respond(to: id, error: "Loam does not handle \(method).")
        }
    }
}
