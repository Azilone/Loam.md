import Foundation

/// Claude Code, the official `claude` binary in print mode with JSON streams in and out: one process per chat, one
/// `user` message per turn. Its sign-in stays its own (Anthropic allows a user's subscription in the unmodified
/// binary, not through an SDK). In Ask mode its permission prompts come over stdio as `control_request`s.
final class ClaudeRuntime: LineRuntime, @unchecked Sendable {
    /// Tool calls by id, to title their results.
    private var tools: [String: (title: String, path: String?)] = [:]
    /// Whether this turn's answer already came as deltas, so the full message that follows is not added twice.
    private var streamedText = false
    private var approvals: [String: [String: Any]] = [:]

    override func arguments() -> [String] {
        var arguments = [
            "-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
            "--include-partial-messages",
        ]
        // Only the tools a notebook needs. The user's own Claude setup (MCP servers, skills, plugins, hooks, settings
        // that may allow every tool) is left out: it would cost ~35k tokens per chat and skip Ask's questions.
        arguments += ["--tools", Self.tools.joined(separator: ","), "--strict-mcp-config", "--disable-slash-commands",
                      "--setting-sources", "project,local"]
        switch configuration.mode {
        case .auto:
            arguments += ["--permission-mode", "acceptEdits", "--allowedTools"] + Self.tools
        case .ask:
            arguments += ["--permission-mode", "default", "--permission-prompt-tool", "stdio"]
        case .readOnly:
            arguments += ["--permission-mode", "plan"]
        }
        if !configuration.model.isEmpty { arguments += ["--model", configuration.model] }
        if !configuration.instructions.isEmpty { arguments += ["--append-system-prompt", configuration.instructions] }
        // A resumed chat whose mode changed needs the new instructions, not the ones recorded on its first turn.
        if let resume = configuration.resumeID { arguments += ["--resume", resume, "--system-prompt-snapshot", "off"] }
        return arguments
    }

    static let tools = ["Bash", "Read", "Edit", "Write", "Glob", "Grep", "WebFetch", "WebSearch", "TodoWrite"]

    override func send(_ prompt: String) async throws {
        lock.lock()
        streamedText = false
        lock.unlock()
        write(["type": "user", "message": ["role": "user", "content": prompt]])
    }

    override func cancel() async {
        write(["type": "control_request", "request_id": UUID().uuidString, "request": ["subtype": "interrupt"]])
    }

    override func answer(approval id: String, option: AgentApproval.Option) async {
        lock.lock()
        let request = approvals.removeValue(forKey: id)
        lock.unlock()
        let input = request?.object("input") ?? [:]
        let response: [String: Any] = option.kind == .reject
            ? ["behavior": "deny", "message": "The user declined."]
            : ["behavior": "allow", "updatedInput": input]
        write(["type": "control_response",
               "response": ["subtype": "success", "request_id": id, "response": response]])
    }

    override func handle(_ message: [String: Any]) {
        switch message.string("type") {
        case "system":
            if message.string("subtype") == "init", let session = message.string("session_id") {
                channel.send(.session(session))
            }
        case "stream_event":
            guard let event = message.object("event"), event.string("type") == "content_block_delta",
                  let delta = event.object("delta") else { return }
            if delta.string("type") == "text_delta", let text = delta.string("text") {
                lock.lock()
                streamedText = true
                lock.unlock()
                channel.send(.text(text))
            } else if delta.string("type") == "thinking_delta", let text = delta.string("thinking") {
                channel.send(.thinking(text))
            }
        case "assistant":
            assistant(message)
        case "user":
            for block in message.object("message")?.objects("content") ?? [] where block.string("type") == "tool_result" {
                guard let id = block.string("tool_use_id") else { continue }
                lock.lock()
                let tool = tools[id]
                lock.unlock()
                guard let tool else { continue }
                channel.send(.tool(id: id, title: tool.title, path: tool.path, finished: true,
                                   failed: block["is_error"] as? Bool ?? false))
            }
        case "result":
            if message["is_error"] as? Bool == true, let text = message.string("result"), !text.isEmpty {
                channel.send(.failed(text))
            }
            channel.send(.turnEnded(cost: message["total_cost_usd"] as? Double))
        case "control_request":
            controlRequest(message)
        default:
            break
        }
    }

    private func assistant(_ message: [String: Any]) {
        if message["error"] != nil || message["is_api_error_message"] as? Bool == true {
            let text = message.object("message")?.objects("content").compactMap { $0.string("text") }.joined() ?? ""
            channel.send(.failed(text.isEmpty ? "Claude could not answer." : text))
            return
        }
        for block in message.object("message")?.objects("content") ?? [] {
            switch block.string("type") {
            case "text":
                lock.lock()
                let streamed = streamedText
                lock.unlock()
                if !streamed, let text = block.string("text") { channel.send(.text(text)) }
            case "tool_use":
                guard let id = block.string("id") else { continue }
                let input = block.object("input") ?? [:]
                let made = ToolTitle.make(
                    tool: block.string("name") ?? "Tool",
                    path: input.string("file_path") ?? input.string("path") ?? input.string("notebook_path"),
                    command: input.string("command"), folder: configuration.folder
                )
                lock.lock()
                tools[id] = made
                lock.unlock()
                channel.send(.tool(id: id, title: made.title, path: made.path, finished: false, failed: false))
            default:
                break
            }
        }
        // A new message starts with its own text: the next deltas belong to it.
        lock.lock()
        streamedText = false
        lock.unlock()
    }

    private func controlRequest(_ message: [String: Any]) {
        guard let id = message.string("request_id"), let request = message.object("request") else { return }
        guard request.string("subtype") == "can_use_tool" else {
            write(["type": "control_response",
                   "response": ["subtype": "error", "request_id": id, "error": "Not supported by Loam."]])
            return
        }
        let input = request.object("input") ?? [:]
        let made = ToolTitle.make(
            tool: request.string("tool_name") ?? "Tool", path: input.string("file_path") ?? input.string("path"),
            command: input.string("command"), folder: configuration.folder
        )
        lock.lock()
        approvals[id] = request
        lock.unlock()
        channel.send(.approval(AgentApproval(
            id: id, title: Self.question(made.title), detail: input.string("command") ?? made.path ?? "",
            options: [
                .init(id: "allow", label: "Allow", kind: .allowOnce),
                .init(id: "deny", label: "Decline", kind: .reject),
            ]
        )))
    }

    /// "Edited Plan.md" asked before it happens: "Edit Plan.md?".
    static func question(_ title: String) -> String {
        for (done, ask) in [("Edited ", "Edit "), ("Read ", "Read "), ("Ran ", "Run ")] where title.hasPrefix(done) {
            return ask + title.dropFirst(done.count) + "?"
        }
        return "Allow \(title)?"
    }
}
