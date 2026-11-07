import Foundation

/// An agent speaking the Agent Client Protocol (agentclientprotocol.com) over stdio: OpenCode (`opencode acp`), and any
/// ACP agent added later. A session per chat, `session/prompt` per turn (its response ends the turn), updates as
/// `session/update` notifications, permission questions as `session/request_permission`. The agent may ask Loam to
/// read and write files; Loam answers inside the vault only.
final class ACPRuntime: LineRuntime, @unchecked Sendable {
    private var sessionID: String?
    private var sentInstructions = false
    private var approvalRequests: [String: (id: Any, options: [String: String])] = [:]
    private var toolTitles: [String: (title: String, path: String?)] = [:]

    override func arguments() -> [String] {
        switch configuration.kind {
        case .opencode:
            return ["acp", "--cwd", configuration.folder.path]
        default:
            return ["--acp"]
        }
    }

    override func didStart() async throws {
        let initialized = try await request("initialize", [
            "protocolVersion": 1,
            "clientCapabilities": ["fs": ["readTextFile": true, "writeTextFile": true], "terminal": false],
            "clientInfo": ["name": "loam", "title": "Loam", "version": "1.0"],
        ])
        let canLoad = initialized.object("agentCapabilities")?["loadSession"] as? Bool ?? false
        if let resume = configuration.resumeID, canLoad,
           (try? await request("session/load", ["sessionId": resume, "cwd": configuration.folder.path,
                                                "mcpServers": [] as [Any]])) != nil {
            lock.lock()
            sessionID = resume
            sentInstructions = true
            lock.unlock()
            channel.send(.session(resume))
            return
        }
        let result = try await request("session/new", ["cwd": configuration.folder.path, "mcpServers": [] as [Any]])
        guard let id = result.string("sessionId") else {
            throw AgentError("\(configuration.kind.name) did not open a session.")
        }
        lock.lock()
        sessionID = id
        lock.unlock()
        channel.send(.session(id))
        // ACP has no model flag: the session takes it (OpenCode's `opencode/deepseek-v4.1-flash-free`).
        if !configuration.model.isEmpty {
            _ = try? await request("session/set_model", ["sessionId": id, "modelId": configuration.model])
        }
    }

    override func send(_ prompt: String) async throws {
        lock.lock()
        let session = sessionID
        // ACP has no system prompt: the instructions open the first message.
        let text = sentInstructions || configuration.instructions.isEmpty
            ? prompt : "\(configuration.instructions)\n\n---\n\n\(prompt)"
        sentInstructions = true
        lock.unlock()
        guard let session else { throw AgentError("\(configuration.kind.name) is not ready.") }
        // The answer comes when the turn is over; meanwhile updates stream in.
        Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await self.request(
                    "session/prompt", ["sessionId": session, "prompt": [["type": "text", "text": text]]]
                )
                if result.string("stopReason") == "refusal" { self.channel.send(.failed("The agent refused.")) }
            } catch {
                self.channel.send(.failed(error.localizedDescription))
            }
            self.channel.send(.turnEnded(cost: nil))
        }
    }

    override func cancel() async {
        lock.lock()
        let session = sessionID
        lock.unlock()
        if let session { notify("session/cancel", ["sessionId": session]) }
    }

    override func answer(approval id: String, option: AgentApproval.Option) async {
        lock.lock()
        let pending = approvalRequests.removeValue(forKey: id)
        lock.unlock()
        guard let pending else { return }
        respond(to: pending.id, result: ["outcome": ["outcome": "selected", "optionId": option.id]])
    }

    override func handle(_ message: [String: Any]) {
        if resolveResponse(message) { return }
        guard let method = message.string("method") else { return }
        let params = message.object("params") ?? [:]
        if let id = message["id"] {
            clientRequest(id: id, method: method, params: params)
            return
        }
        guard method == "session/update", let update = params.object("update") else { return }
        switch update.string("sessionUpdate") {
        case "agent_message_chunk":
            if let text = update.object("content")?.string("text") { channel.send(.text(text)) }
        case "agent_thought_chunk":
            if let text = update.object("content")?.string("text") { channel.send(.thinking(text)) }
        case "tool_call":
            guard let id = update.string("toolCallId") else { return }
            let path = update.objects("locations").first?.string("path")
            let kind = update.string("kind") ?? ""
            let made = ToolTitle.make(
                tool: kind == "edit" ? "Edit" : kind == "read" ? "Read" : (update.string("title") ?? "Tool"),
                path: path, command: kind == "execute" ? update.string("title") : nil, folder: configuration.folder
            )
            lock.lock()
            toolTitles[id] = made
            lock.unlock()
            let status = update.string("status")
            channel.send(.tool(id: id, title: made.title, path: made.path,
                               finished: status == "completed" || status == "failed", failed: status == "failed"))
        case "tool_call_update":
            guard let id = update.string("toolCallId") else { return }
            let status = update.string("status")
            lock.lock()
            var made = toolTitles[id] ?? (update.string("title") ?? "Tool", nil)
            // A command's real line comes in an update ("bash" first, then "printf … >> Note.md").
            if update.string("kind") == "execute", let line = update.string("title"), line != "bash" {
                made = ToolTitle.make(tool: "Run", path: nil, command: line, folder: configuration.folder)
                toolTitles[id] = made
            } else if made.path == nil, let path = update.objects("locations").first?.string("path") {
                // A read or an edit learns its file in an update too.
                let kind = update.string("kind") ?? ""
                made = ToolTitle.make(tool: kind == "edit" ? "Edit" : kind == "read" ? "Read" : made.title, path: path,
                                      command: nil, folder: configuration.folder)
                toolTitles[id] = made
            }
            lock.unlock()
            let finished = status == "completed" || status == "failed"
            channel.send(.tool(id: id, title: made.title, path: made.path, finished: finished, failed: status == "failed"))
        default:
            break
        }
    }

    private func clientRequest(id: Any, method: String, params: [String: Any]) {
        switch method {
        case "session/request_permission":
            let key = UUID().uuidString
            let options = params.objects("options").compactMap { option -> AgentApproval.Option? in
                guard let optionID = option.string("optionId") else { return nil }
                let kind: AgentApproval.Option.Kind = switch option.string("kind") {
                case "allow_always": .allowAlways
                case "reject_once", "reject_always": .reject
                default: .allowOnce
                }
                return .init(id: optionID, label: option.string("name") ?? optionID, kind: kind)
            }
            lock.lock()
            approvalRequests[key] = (id, [:])
            lock.unlock()
            let call = params.object("toolCall") ?? [:]
            channel.send(.approval(AgentApproval(
                id: key, title: call.string("title") ?? "Allow this action?",
                detail: call.objects("locations").first?.string("path") ?? "", options: options
            )))
        case "fs/read_text_file":
            guard let url = insideVault(params.string("path")),
                  let text = try? String(contentsOf: url, encoding: .utf8) else {
                respond(to: id, error: "No such file in the vault.")
                return
            }
            var lines = text.components(separatedBy: "\n")
            if let line = params["line"] as? Int, line > 0 { lines = Array(lines.dropFirst(line - 1)) }
            if let limit = params["limit"] as? Int, limit >= 0 { lines = Array(lines.prefix(limit)) }
            respond(to: id, result: ["content": lines.joined(separator: "\n")])
        case "fs/write_text_file":
            guard configuration.mode != .readOnly, let url = insideVault(params.string("path")),
                  let content = params.string("content") else {
                respond(to: id, error: "Loam does not allow writing there.")
                return
            }
            do {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                        withIntermediateDirectories: true)
                try content.write(to: url, atomically: true, encoding: .utf8)
                respond(to: id, result: NSNull())
            } catch {
                respond(to: id, error: error.localizedDescription)
            }
        default:
            respond(to: id, error: "Loam does not handle \(method).")
        }
    }

    /// `path` when it is a file inside the vault.
    private func insideVault(_ path: String?) -> URL? {
        guard let path else { return nil }
        let root = configuration.folder.standardizedFileURL.resolvingSymlinksInPath().path
        let url = (path.hasPrefix("/") ? URL(fileURLWithPath: path) : configuration.folder.appendingPathComponent(path))
            .standardizedFileURL
        let resolved = url.deletingLastPathComponent().resolvingSymlinksInPath().appendingPathComponent(url.lastPathComponent)
        return resolved.path.hasPrefix(root + "/") ? resolved : nil
    }
}
