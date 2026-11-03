import LoamCore
import XCTest
import PluginKit
import PluginKitTesting
@testable import AssistantPlugin

/// An agent that edits a note and answers, as a real one would, without a process.
final class FakeRuntime: AgentRuntime, @unchecked Sendable {
    let channel = EventChannel()
    let configuration: AgentConfiguration
    var events: AsyncStream<AgentEvent> { channel.stream }
    private(set) var prompts: [String] = []

    init(_ configuration: AgentConfiguration) {
        self.configuration = configuration
    }

    func start() async throws {
        channel.send(.session("fake-session"))
    }

    func send(_ prompt: String) async throws {
        prompts.append(prompt)
        let url = configuration.folder.appendingPathComponent("Note.md")
        channel.send(.tool(id: "t1", title: "Edited Note.md", path: "Note.md", finished: false, failed: false))
        try "# Hello\n- fake\n".write(to: url, atomically: true, encoding: .utf8)
        try "new".write(to: configuration.folder.appendingPathComponent("Added.md"), atomically: true, encoding: .utf8)
        channel.send(.tool(id: "t1", title: "Edited Note.md", path: "Note.md", finished: true, failed: false))
        channel.send(.text("Done"))
        channel.send(.text("."))
        channel.send(.turnEnded(cost: nil))
    }

    func cancel() async {}
    func answer(approval id: String, option: AgentApproval.Option) async {}
    func stop() { channel.finish() }
}

final class AssistantEngineTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("assistant-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try "# Hello\n".write(to: folder.appendingPathComponent("Note.md"), atomically: true, encoding: .utf8)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private func engine() -> AssistantEngine {
        let catalog = AgentCatalog()
        return AssistantEngine(vault: folder, catalog: catalog, git: ToolLocator().locate("git")) { FakeRuntime($0) }
    }

    func testATurnStreamsTheAnswerRecordsChangesAndUndoes() async throws {
        // The fake needs an executable to "start": any program the catalog finds will do.
        let engine = AssistantEngine(vault: folder, catalog: StubCatalog(), git: ToolLocator().locate("git")) { FakeRuntime($0) }
        let chat = engine.newChat(agent: .claude)
        await engine.send(chat.id, prompt: "Add a line", context: ["Note.md"])
        await engine.waitForTurnEnd(chat.id)

        let done = try XCTUnwrap(engine.chat(chat.id))
        XCTAssertEqual(done.title, "Add a line")
        XCTAssertEqual(done.sessionID, "fake-session")
        XCTAssertEqual(done.messages.count, 2)
        let answer = done.messages[1]
        XCTAssertEqual(answer.text, "Done.")
        XCTAssertEqual(answer.tools.map(\.state), [.done])
        XCTAssertEqual(Set(answer.changes), [ChangedFile(path: "Note.md", kind: .modified),
                                            ChangedFile(path: "Added.md", kind: .added)])
        XCTAssertNil(answer.error)

        try engine.undo(chat.id, messageID: answer.id)
        XCTAssertEqual(try String(contentsOf: folder.appendingPathComponent("Note.md"), encoding: .utf8), "# Hello\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("Added.md").path))
        XCTAssertTrue(try XCTUnwrap(engine.chat(chat.id)).messages[1].undone)

        // Chats survive a relaunch.
        let reopened = AssistantEngine(vault: folder, catalog: StubCatalog(), git: ToolLocator().locate("git")) { FakeRuntime($0) }
        XCTAssertEqual(reopened.allChats().first?.id, chat.id)
    }

    func testImagesAreKeptAndNamedForTheAgent() async throws {
        let engine = AssistantEngine(vault: folder, catalog: StubCatalog(), git: ToolLocator().locate("git")) { FakeRuntime($0) }
        let image = try engine.attach(image: Data([0x89, 0x50]), extension: "PNG")
        XCTAssertTrue(image.hasPrefix(".loam/cache/ai/attachments/") && image.hasSuffix(".png"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent(image).path))

        let chat = engine.newChat(agent: .claude)
        await engine.send(chat.id, prompt: "  ", images: [image])
        await engine.waitForTurnEnd(chat.id)
        let sent = try XCTUnwrap(engine.chat(chat.id)?.messages.first)
        XCTAssertEqual(sent.text, "Look at this image.")
        XCTAssertEqual(sent.images, [image])
        XCTAssertEqual(
            AssistantEngine.prompt("What is it?", context: [], images: ["/v/a.png"]),
            "The user attached an image; open and look at it before answering:\n- `/v/a.png`\n\nWhat is it?"
        )
    }

    func testChangesKeepAccentedNames() throws {
        let checkpoints = Checkpoints(folder: folder, git: ToolLocator().locate("git"))
        let before = try XCTUnwrap(checkpoints.snapshot("before"))
        try "x".write(to: folder.appendingPathComponent("Compiègne.md"), atomically: true, encoding: .utf8)
        let after = try XCTUnwrap(checkpoints.snapshot("after"))
        XCTAssertEqual(checkpoints.changes(from: before, to: after).map(\.path.precomposedStringWithCanonicalMapping),
                       ["Compiègne.md"])
    }

    func testThePromptNamesTheContextNotes() {
        XCTAssertEqual(AssistantEngine.prompt("Summarize", context: ["Projects/Plan.md"]),
                       "The user is looking at the note [[Plan]] (`Projects/Plan.md`).\n\nSummarize")
        XCTAssertEqual(AssistantEngine.prompt("Hi", context: []), "Hi")
        XCTAssertEqual(
            AssistantEngine.prompt("Explain", context: [], selection: NoteSelection(path: "A.md", text: "one\ntwo")),
            "The user selected this passage in [[A]] (`A.md`); the request is about it:\n> one\n> two\n\nExplain"
        )
    }

    func testAMissingAgentSaysHowToInstallIt() async throws {
        let engine = AssistantEngine(vault: folder, catalog: StubCatalog(found: false), git: ToolLocator().locate("git")) { FakeRuntime($0) }
        let chat = engine.newChat(agent: .codex)
        await engine.send(chat.id, prompt: "Hello")
        await engine.waitForTurnEnd(chat.id)
        let error = try XCTUnwrap(engine.chat(chat.id)?.messages.last?.error)
        XCTAssertTrue(error.contains("Codex is not installed"), error)
        XCTAssertFalse(engine.isBusy(chat.id))
    }

    func testATaskSentRightAfterAStopKeepsRunning() async throws {
        let engine = AssistantEngine(vault: folder, catalog: StubCatalog(), git: ToolLocator().locate("git")) { SlowRuntime($0) }
        let chat = engine.newChat(agent: .claude)
        await engine.send(chat.id, prompt: "First task")
        let stopping = Task { await engine.cancel(chat.id) }
        await engine.waitForTurnEnd(chat.id)
        await engine.send(chat.id, prompt: "Second task")
        await stopping.value
        // The stop of the first task does not end the second one.
        XCTAssertTrue(engine.isBusy(chat.id))
        await engine.cancel(chat.id)
        XCTAssertFalse(engine.isBusy(chat.id))
    }
}

/// An agent that works until it is interrupted, as a long task does.
final class SlowRuntime: AgentRuntime, @unchecked Sendable {
    let channel = EventChannel()
    var events: AsyncStream<AgentEvent> { channel.stream }

    init(_ configuration: AgentConfiguration) {}
    func start() async throws {}
    func send(_ prompt: String) async throws { channel.send(.text("Working")) }
    func cancel() async { channel.send(.turnEnded(cost: nil)) }
    func answer(approval id: String, option: AgentApproval.Option) async {}
    func stop() { channel.finish() }
}

/// A catalog that finds every agent at `/bin/echo`, or none.
final class StubCatalog: AgentCatalog, @unchecked Sendable {
    let found: Bool

    init(found: Bool = true) {
        self.found = found
        super.init()
    }

    override func executable(_ kind: AgentKind) -> URL? {
        found ? URL(fileURLWithPath: "/bin/echo") : nil
    }
}

final class AgentProtocolTests: XCTestCase {
    private let folder = URL(fileURLWithPath: "/vault")

    private func fixture(_ name: String) throws -> [[String: Any]] {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/\(name)")
        return try String(contentsOf: url, encoding: .utf8).split(separator: "\n").compactMap { JSONLine.decode(String($0)) }
    }

    private func configuration(_ kind: AgentKind) -> AgentConfiguration {
        AgentConfiguration(kind: kind, executable: URL(fileURLWithPath: "/bin/echo"), environment: [:], folder: folder)
    }

    func testClaudeLeavesTheUsersOwnSetupOut() {
        for mode in [AgentMode.auto, .ask, .readOnly] {
            var configuration = configuration(.claude)
            configuration.mode = mode
            let arguments = ClaudeRuntime(configuration: configuration).arguments()
            XCTAssertTrue(arguments.contains("--strict-mcp-config"), "\(mode)")
            XCTAssertTrue(arguments.contains("--disable-slash-commands"), "\(mode)")
            let sources = arguments.firstIndex(of: "--setting-sources").map { arguments[$0 + 1] }
            XCTAssertEqual(sources, "project,local", "\(mode)")
            let tools = arguments.firstIndex(of: "--tools").map { arguments[$0 + 1] }
            XCTAssertEqual(tools, ClaudeRuntime.tools.joined(separator: ","), "\(mode)")
        }
    }

    private func collect(_ runtime: LineRuntime, _ messages: [[String: Any]]) async -> [AgentEvent] {
        for message in messages { runtime.handle(message) }
        runtime.channel.finish()
        var events: [AgentEvent] = []
        for await event in runtime.events { events.append(event) }
        return events
    }

    /// A real `codex app-server` turn (recorded on 2026-10-25): text deltas, a command, the end of the turn.
    func testCodexAppServerTranscript() async throws {
        let events = await collect(CodexRuntime(configuration: configuration(.codex)), try fixture("codex-app-server.jsonl"))
        let text = events.compactMap { if case .text(let t) = $0 { t } else { nil } }.joined()
        XCTAssertEqual(text, "Appending `- codex` to `Note.md`.\n\nOK")
        XCTAssertTrue(events.contains(.tool(id: "exec-8558b149-8b79-4034-80af-9f0e101cf176",
                                            title: "Ran printf '%s\\n' '- codex' >> Note.md", path: nil,
                                            finished: true, failed: false)))
        XCTAssertEqual(events.last, .turnEnded(cost: nil))
    }

    /// A real `agy` turn: tool steps, then the answer as deltas, then the result.
    func testAntigravityTranscript() async throws {
        let events = await collect(AntigravityRuntime(configuration: configuration(.antigravity)),
                                   try fixture("antigravity.jsonl"))
        let text = events.compactMap { if case .text(let t) = $0 { t } else { nil } }.joined()
        XCTAssertTrue(text.hasPrefix("I have appended `- agy` to [Note.md]"), text)
        XCTAssertTrue(events.contains(.tool(id: "step-8", title: "Edited Note.md", path: "Note.md", finished: true,
                                            failed: false)))
        XCTAssertEqual(events.last, .turnEnded(cost: nil))
    }

    /// A real `pi --mode rpc` turn (recorded on 2026-10-26, on Pi's ChatGPT provider): a read, an edit, then "OK".
    func testPiRPCTranscript() async throws {
        let events = await collect(PiRuntime(configuration: configuration(.pi)), try fixture("pi-rpc.jsonl"))
        let text = events.compactMap { if case .text(let t) = $0 { t } else { nil } }.joined()
        XCTAssertEqual(text, "OK")
        let tools = events.compactMap { if case let .tool(_, title, _, finished, _) = $0, finished { title } else { nil } }
        XCTAssertEqual(tools, ["Read Note.md", "Edited Note.md"])
        XCTAssertEqual(events.last, .turnEnded(cost: nil))
    }

    /// A provider refusing Pi's request ends the turn with its reason, not silently.
    func testPiProviderErrorIsShown() async {
        let lines: [[String: Any]] = [
            ["type": "message_end", "message": ["role": "assistant", "stopReason": "error", "errorMessage":
                #"401 {"type":"error","error":{"type":"authentication_error","message":"Missing Authentication header"}}"#]],
            ["type": "agent_end"],
        ]
        let events = await collect(PiRuntime(configuration: configuration(.pi)), lines)
        XCTAssertEqual(events, [
            .failed("401 Missing Authentication header. Check this provider's key in Pi (/login)."), .turnEnded(cost: nil),
        ])
    }

    /// A real `opencode acp` turn (recorded on 2026-10-26, on a free OpenCode model): a command, then the answer.
    func testOpenCodeACPTranscript() async throws {
        let events = await collect(ACPRuntime(configuration: configuration(.opencode)), try fixture("opencode-acp.jsonl"))
        let finished = events.compactMap { if case let .tool(_, title, _, done, _) = $0, done { title } else { nil } }
        XCTAssertEqual(finished, ["Ran printf '%s\\n' '- oc' >> Note.md && tail -1 Note.md"])
        XCTAssertFalse(events.compactMap { if case .text(let t) = $0 { t } else { nil } }.joined().isEmpty)
    }

    /// Claude's stream-json, in the shape `claude -p --output-format stream-json --include-partial-messages` prints.
    func testClaudeStreamJSON() async throws {
        let lines: [[String: Any]] = [
            ["type": "system", "subtype": "init", "session_id": "s1"],
            ["type": "stream_event", "event": ["type": "content_block_delta", "delta": ["type": "text_delta", "text": "On it"]]],
            ["type": "assistant", "message": ["content": [
                ["type": "text", "text": "On it"],
                ["type": "tool_use", "id": "tu1", "name": "Edit", "input": ["file_path": "/vault/Ideas/Plan.md"]],
            ]]],
            ["type": "user", "message": ["content": [["type": "tool_result", "tool_use_id": "tu1", "is_error": false]]]],
            ["type": "assistant", "message": ["content": [["type": "text", "text": " Done."]]]],
            ["type": "result", "subtype": "success", "total_cost_usd": 0.01],
        ]
        let events = await collect(ClaudeRuntime(configuration: configuration(.claude)), lines)
        XCTAssertEqual(events, [
            .session("s1"), .text("On it"),
            .tool(id: "tu1", title: "Edited Plan.md", path: "Ideas/Plan.md", finished: false, failed: false),
            .tool(id: "tu1", title: "Edited Plan.md", path: "Ideas/Plan.md", finished: true, failed: false),
            .text(" Done."), .turnEnded(cost: 0.01),
        ])
    }

    func testClaudeSignInFailureIsAnError() async {
        let lines: [[String: Any]] = [
            ["type": "assistant", "error": "authentication_failed", "is_api_error_message": true,
             "message": ["content": [["type": "text", "text": "Failed to authenticate"]]]],
        ]
        let events = await collect(ClaudeRuntime(configuration: configuration(.claude)), lines)
        XCTAssertEqual(events, [.failed("Failed to authenticate")])
    }

    func testACPUpdates() async {
        let lines: [[String: Any]] = [
            ["jsonrpc": "2.0", "method": "session/update", "params": ["sessionId": "x", "update": [
                "sessionUpdate": "agent_message_chunk", "content": ["type": "text", "text": "Hi"]]]],
            ["jsonrpc": "2.0", "method": "session/update", "params": ["sessionId": "x", "update": [
                "sessionUpdate": "tool_call", "toolCallId": "c1", "title": "Write Plan.md", "kind": "edit",
                "status": "pending", "locations": [["path": "/vault/Plan.md"]]]]],
            ["jsonrpc": "2.0", "method": "session/update", "params": ["sessionId": "x", "update": [
                "sessionUpdate": "tool_call_update", "toolCallId": "c1", "status": "completed"]]],
        ]
        let events = await collect(ACPRuntime(configuration: configuration(.opencode)), lines)
        XCTAssertEqual(events, [
            .text("Hi"),
            .tool(id: "c1", title: "Edited Plan.md", path: "Plan.md", finished: false, failed: false),
            .tool(id: "c1", title: "Edited Plan.md", path: "Plan.md", finished: true, failed: false),
        ])
    }

    func testACPReadLearnsItsFileInAnUpdate() async {
        let lines: [[String: Any]] = [
            ["jsonrpc": "2.0", "method": "session/update", "params": ["sessionId": "x", "update": [
                "sessionUpdate": "tool_call", "toolCallId": "r1", "title": "read", "kind": "read", "status": "pending"]]],
            ["jsonrpc": "2.0", "method": "session/update", "params": ["sessionId": "x", "update": [
                "sessionUpdate": "tool_call_update", "toolCallId": "r1", "kind": "read", "status": "completed",
                "locations": [["path": "/vault/Welcome.md"]]]]],
        ]
        let events = await collect(ACPRuntime(configuration: configuration(.opencode)), lines)
        XCTAssertEqual(events.last, .tool(id: "r1", title: "Read Welcome.md", path: "Welcome.md", finished: true, failed: false))
    }

    func testToolTitles() {
        XCTAssertEqual(ToolTitle.shorten("/bin/zsh -lc \"ls -la\""), "ls -la")
        XCTAssertEqual(ToolTitle.make(tool: "Bash", path: nil, command: "cd /vault/Projects && grep -l x *.md",
                                      folder: folder).title, "Ran grep -l x *.md")
        XCTAssertEqual(ToolTitle.relativePath("/private/vault/A.md", in: URL(fileURLWithPath: "/vault")), "A.md")
        XCTAssertEqual(ToolTitle.make(tool: "Grep", path: nil, command: nil, folder: folder).title, "Searched the notes")
    }

    func testProcessLinkStreamsLines() async throws {
        let link = ProcessLink(executable: URL(fileURLWithPath: "/bin/cat"), arguments: [],
                               folder: FileManager.default.temporaryDirectory, environment: [:])
        try link.start()
        link.writeJSON(["a": 1])
        link.write("plain")
        var lines: [String] = []
        for await line in link.lines {
            lines.append(line)
            if lines.count == 2 { link.stop() }
        }
        XCTAssertEqual(lines, [#"{"a":1}"#, "plain"])
    }
}

final class PromptStoreTests: XCTestCase {
    func testPromptsAreMarkdownFilesWithATitle() throws {
        let vault = try TemporaryVault()
        let store = PromptStore(vault: vault.rootURL)
        let saved = try store.save(title: "Translate to English", prompt: "Translate this note into English.")
        XCTAssertEqual(saved.id, "translate-to-english")
        XCTAssertEqual(try vault.read(".loam/ai/prompts/translate-to-english.md"),
                       "---\ntitle: \"Translate to English\"\n---\n\nTranslate this note into English.\n")
        let untitled = try store.save(title: "", prompt: "Fix the spelling")
        XCTAssertEqual(untitled.label, "Fix the spelling")
        XCTAssertEqual(store.all().map(\.label), ["Fix the spelling", "Translate to English"])
        XCTAssertThrowsError(try store.save(title: "", prompt: String(repeating: "a", count: 1001)))
        try store.delete(untitled.id)
        XCTAssertEqual(store.all().count, 1)
    }

    func testInstructionsIncludeTheUsersOwn() throws {
        let vault = try TemporaryVault()
        try vault.write(".loam/ai/instructions.md", "Always answer in French.")
        let text = AssistantInstructions.make(vault: vault.rootURL, mode: .readOnly, cli: "/x/loam")
        XCTAssertTrue(text.contains("`/x/loam projects.add-task"))
        XCTAssertTrue(text.contains("read only"))
        XCTAssertTrue(text.hasSuffix("The user's instructions:\nAlways answer in French."))
    }
}

final class AssistantPluginTests: XCTestCase {
    func testCommandsAndUnload() async throws {
        let harness = try PluginTestHarness([AssistantPlugin.self])
        let added = try await harness.run("assistant.prompt-add", ["title": "Résumer", "prompt": "Summarize the note."])
        XCTAssertTrue(added.contains("resumer"))
        let list = try await harness.run("assistant.prompts")
        XCTAssertTrue(list.contains("Summarize the note."))
        let agents = try await harness.run("assistant.agents")
        XCTAssertTrue(agents.contains("\"claude\""))
        XCTAssertNotNil(harness.kernel.services.service(.assistant))
        harness.host.deactivateAll()
        XCTAssertNil(harness.kernel.services.service(.assistant))
        XCTAssertNil(harness.kernel.commands.command(id: "assistant.ask"))
    }

    /// The real Claude Code on this Mac, signed in: set LOAM_AGENT_E2E=1 to run it (it uses the user's plan).
    func testLiveClaudeTurn() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["LOAM_AGENT_E2E"] == "1", "LOAM_AGENT_E2E=1 runs it")
        let vault = try TemporaryVault()
        try vault.write("Note.md", "# Hello\n")
        let engine = AssistantEngine(vault: vault.rootURL)
        let chat = engine.newChat(agent: .claude, model: "haiku")
        await engine.send(chat.id, prompt: "Append a line \"- live\" to Note.md, then answer OK.")
        await engine.waitForTurnEnd(chat.id)
        let answer = try XCTUnwrap(engine.chat(chat.id)?.messages.last)
        XCTAssertNil(answer.error)
        XCTAssertFalse(answer.text.isEmpty)
        XCTAssertNotNil(engine.chat(chat.id)?.sessionID)
        XCTAssertTrue(try vault.read("Note.md").contains("- live"))
        XCTAssertEqual(answer.changes, [ChangedFile(path: "Note.md", kind: .modified)])

        // A second turn in the same process.
        await engine.send(chat.id, prompt: "What line did you add? Answer with the line only.")
        await engine.waitForTurnEnd(chat.id)
        let second = try XCTUnwrap(engine.chat(chat.id)?.messages.last)
        XCTAssertTrue(second.text.contains("live"), second.text)
        engine.stopAll()
    }

    /// Claude in Ask mode: the edit waits for an approval, then happens once allowed.
    func testLiveClaudeAsksBeforeEditing() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["LOAM_AGENT_E2E"] == "1", "LOAM_AGENT_E2E=1 runs it")
        let vault = try TemporaryVault()
        try vault.write("Note.md", "# Hello\n")
        let engine = AssistantEngine(vault: vault.rootURL)
        let chat = engine.newChat(agent: .claude, model: "haiku", mode: .ask)
        await engine.send(chat.id, prompt: "Append a line \"- asked\" to Note.md with your edit tool, then answer OK.")
        var approval: AgentApproval?
        for _ in 0..<120 where approval == nil {
            try await Task.sleep(nanoseconds: 500_000_000)
            approval = engine.approval(chat.id)
        }
        let asked = try XCTUnwrap(approval, "Claude never asked")
        XCTAssertFalse(try vault.read("Note.md").contains("- asked"))
        await engine.answer(chat.id, option: try XCTUnwrap(asked.options.first { $0.kind == .allowOnce }))
        await engine.waitForTurnEnd(chat.id)
        XCTAssertTrue(try vault.read("Note.md").contains("- asked"))
        engine.stopAll()
    }

    /// The real Pi on this Mac, on its ChatGPT provider: set LOAM_AGENT_E2E=1 to run it.
    func testLivePiTurn() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["LOAM_AGENT_E2E"] == "1", "LOAM_AGENT_E2E=1 runs it")
        let vault = try TemporaryVault()
        try vault.write("Note.md", "# Hello\n")
        let engine = AssistantEngine(vault: vault.rootURL)
        let chat = engine.newChat(agent: .pi, model: ProcessInfo.processInfo.environment["LOAM_PI_MODEL"] ?? "openai-codex/gpt-5.6-luna")
        await engine.send(chat.id, prompt: "Append a line \"- live\" to Note.md, then answer OK.")
        await engine.waitForTurnEnd(chat.id)
        let answer = try XCTUnwrap(engine.chat(chat.id)?.messages.last)
        XCTAssertNil(answer.error)
        XCTAssertTrue(try vault.read("Note.md").contains("- live"))
        XCTAssertEqual(answer.changes, [ChangedFile(path: "Note.md", kind: .modified)])
        engine.stopAll()
    }

    /// The real OpenCode on this Mac, on one of its free models: set LOAM_AGENT_E2E=1 to run it.
    func testLiveOpenCodeTurn() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["LOAM_AGENT_E2E"] == "1", "LOAM_AGENT_E2E=1 runs it")
        let vault = try TemporaryVault()
        try vault.write("Note.md", "# Hello\n")
        let engine = AssistantEngine(vault: vault.rootURL)
        let chat = engine.newChat(agent: .opencode, model: ProcessInfo.processInfo.environment["LOAM_OPENCODE_MODEL"] ?? "opencode/deepseek-v4.1-flash-free")
        await engine.send(chat.id, prompt: "Append a line \"- live\" to Note.md, then answer OK.")
        await engine.waitForTurnEnd(chat.id)
        let answer = try XCTUnwrap(engine.chat(chat.id)?.messages.last)
        XCTAssertNil(answer.error)
        XCTAssertTrue(try vault.read("Note.md").contains("- live"))
        XCTAssertEqual(answer.changes, [ChangedFile(path: "Note.md", kind: .modified)])
        engine.stopAll()
    }

    /// The real Codex on this Mac, signed in: set LOAM_AGENT_E2E=1 to run it (it uses the user's plan).
    func testLiveCodexTurn() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["LOAM_AGENT_E2E"] == "1", "LOAM_AGENT_E2E=1 runs it")
        let vault = try TemporaryVault()
        try vault.write("Note.md", "# Hello\n")
        let engine = AssistantEngine(vault: vault.rootURL)
        let chat = engine.newChat(agent: .codex)
        await engine.send(chat.id, prompt: "Append a line \"- live\" to Note.md, then answer OK.")
        await engine.waitForTurnEnd(chat.id)
        let answer = try XCTUnwrap(engine.chat(chat.id)?.messages.last)
        XCTAssertNil(answer.error)
        XCTAssertTrue(try vault.read("Note.md").contains("- live"))
        XCTAssertEqual(answer.changes, [ChangedFile(path: "Note.md", kind: .modified)])
        engine.stopAll()
    }
}
