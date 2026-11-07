import Foundation

/// Pi (`pi --mode rpc`): JSON commands on stdin (`prompt`, `abort`), events on stdout. Pi has no permission prompts
/// of its own; it handles OpenRouter, Grok and other API keys, which is how they reach Loam.
final class PiRuntime: LineRuntime, @unchecked Sendable {
    /// Pi creates the session of a new id: Loam names it, so the chat continues after a relaunch.
    private lazy var sessionID = configuration.resumeID ?? UUID().uuidString.lowercased()
    private var titles: [String: (title: String, path: String?)] = [:]

    override func arguments() -> [String] {
        var arguments = ["--mode", "rpc", "--session-id", sessionID]
        if !configuration.model.isEmpty { arguments += ["--model", configuration.model] }
        if !configuration.instructions.isEmpty { arguments += ["--append-system-prompt", configuration.instructions] }
        return arguments
    }

    override func didStart() async throws {
        channel.send(.session(sessionID))
    }

    override func send(_ prompt: String) async throws {
        write(["type": "prompt", "message": prompt])
    }

    override func cancel() async {
        write(["type": "abort"])
    }

    override func handle(_ message: [String: Any]) {
        switch message.string("type") {
        case "session", "session_start":
            if let id = message.string("id") ?? message.string("sessionId") { channel.send(.session(id)) }
        case "message_update":
            let event = message.object("assistantMessageEvent") ?? message
            guard let delta = event.string("delta") else { return }
            if event.string("type") == "thinking_delta" {
                channel.send(.thinking(delta))
            } else if event.string("type") == "text_delta" {
                channel.send(.text(delta))
            }
        case "tool_execution_start", "tool_execution_end":
            guard let id = message.string("toolCallId") ?? message.string("id") else { return }
            let finished = message.string("type") == "tool_execution_end"
            // The end repeats neither the path nor the command: keep the start's title.
            lock.lock()
            var made = titles[id]
            lock.unlock()
            if made == nil || !finished {
                let args = message.object("args") ?? [:]
                made = ToolTitle.make(
                    tool: message.string("toolName") ?? "Tool", path: args.string("path") ?? args.string("file_path"),
                    command: args.string("command"), folder: configuration.folder
                )
                lock.lock()
                titles[id] = made
                lock.unlock()
            }
            guard let made else { return }
            channel.send(.tool(id: id, title: made.title, path: made.path, finished: finished,
                               failed: finished && message["isError"] as? Bool == true))
        case "message_end":
            // A failed request ends the message with its reason ("401 … Missing Authentication header").
            let ended = message.object("message") ?? [:]
            if ended.string("role") == "assistant", ended.string("stopReason") == "error" {
                channel.send(.failed(Self.readable(ended.string("errorMessage") ?? "Pi could not answer.")))
            }
        case "agent_end":
            channel.send(.turnEnded(cost: nil))
        case "response":
            if message["success"] as? Bool == false {
                channel.send(.failed(message.string("error") ?? "Pi refused."))
                channel.send(.turnEnded(cost: nil))
            }
        default:
            break
        }
    }

    /// A provider's error, the message out of its JSON when it has one, with a hint for a missing key.
    static func readable(_ error: String) -> String {
        var text = error
        if let brace = error.firstIndex(of: "{"), let json = JSONLine.decode(String(error[brace...])),
           let message = json.object("error")?.string("message") ?? json.string("message") {
            text = String(error[..<brace]).trimmingCharacters(in: .whitespaces) + " " + message
        }
        if error.hasPrefix("401") || error.lowercased().contains("authentication") {
            text += ". Check this provider's key in Pi (/login)."
        }
        return text.trimmingCharacters(in: .whitespaces)
    }
}
