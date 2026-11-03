import Foundation

/// Antigravity (`agy`), which took over Gemini CLI's subscribers in June 2026. Print mode with JSON streams: one
/// `{"event":"user"}` message per turn in, `step_update` events out (tool steps, then the answer as `text_delta`s),
/// and a `result` closing the turn. It cannot ask for permission while printing, so Auto approves everything and
/// the other modes keep to edits.
final class AntigravityRuntime: LineRuntime, @unchecked Sendable {
    private var streamedText = false

    override func arguments() -> [String] {
        var arguments = ["--input-format", "stream-json", "--output-format", "stream-json"]
        switch configuration.mode {
        case .auto: arguments.append("--dangerously-skip-permissions")
        case .ask: arguments += ["--mode", "accept-edits"]
        case .readOnly: arguments += ["--mode", "plan"]
        }
        if !configuration.model.isEmpty { arguments += ["--model", configuration.model] }
        if let resume = configuration.resumeID { arguments += ["--conversation", resume] }
        // `--print` takes the prompt as its value: an empty one, the prompts come on stdin.
        arguments.append("--print=")
        return arguments
    }

    private var sentInstructions = false

    override func send(_ prompt: String) async throws {
        lock.lock()
        let text = sentInstructions || configuration.instructions.isEmpty
            ? prompt : "\(configuration.instructions)\n\n---\n\n\(prompt)"
        sentInstructions = true
        streamedText = false
        lock.unlock()
        write(["event": "user", "message": ["role": "user", "content": text]])
    }

    override func cancel() async {
        // No interrupt in print mode: the next prompt waits for this turn.
    }

    override func handle(_ message: [String: Any]) {
        switch message.string("event") {
        case "init":
            if let id = message.string("conversation_id") { channel.send(.session(id)) }
        case "step_update":
            step(message.object("step_update") ?? [:])
        case "result":
            let result = message.object("result") ?? [:]
            lock.lock()
            let streamed = streamedText
            lock.unlock()
            if !streamed, let response = result.string("response"), !response.isEmpty { channel.send(.text(response)) }
            if result.string("status") == "ERROR" {
                channel.send(.failed(result.string("error") ?? "Antigravity failed."))
            }
            channel.send(.turnEnded(cost: nil))
        default:
            break
        }
    }

    override func handleText(_ line: String) {
        if line.hasPrefix("error:") { channel.send(.failed(String(line.dropFirst(6)).trimmingCharacters(in: .whitespaces))) }
    }

    private func step(_ step: [String: Any]) {
        let index = step["step_index"].map { "\($0)" } ?? UUID().uuidString
        switch step.string("step_type") {
        case "agent_response":
            if let delta = step.string("text_delta") {
                lock.lock()
                streamedText = true
                lock.unlock()
                channel.send(.text(delta))
            }
        case "tool":
            let info = step.object("tool_info") ?? [:]
            let parameters = info.object("parameters") ?? [:]
            let made = ToolTitle.make(
                tool: step.string("tool_name") ?? "Tool",
                path: parameters.string("Path") ?? parameters.string("AbsolutePath") ?? parameters.string("TargetFile"),
                command: parameters.string("CommandLine"), folder: configuration.folder
            )
            let state = step.string("state")
            channel.send(.tool(id: "step-\(index)", title: made.title, path: made.path,
                               finished: state == "DONE" || state == "ERROR", failed: state == "ERROR"))
        default:
            break
        }
    }
}
