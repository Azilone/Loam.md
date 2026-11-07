import Foundation
import PluginKit

public extension ServiceKey where Service == AssistantEngine {
    /// The assistant's chats and agents; `AssistantUI` draws them.
    static var assistant: ServiceKey<AssistantEngine> { ServiceKey<AssistantEngine>("assistant") }
}

/// The assistant: the coding agent the user already has (Claude Code, Codex, Gemini, OpenCode, Pi, Antigravity),
/// started in the vault and driven over its own protocol, with saved prompts and an undo per turn (docs/AI.md).
/// Provides the `assistant` service and the `assistant.*` commands, so an agent or the CLI can do what the panel does.
public final class AssistantPlugin: Plugin {
    public static var manifest: PluginManifest {
        PluginManifest(
            id: "assistant",
            name: "Assistant",
            version: "0.1.0",
            description: "Chat with your own Claude Code, Codex, Antigravity, Pi or OpenCode, working on the whole vault.",
            icon: "sparkles",
            provides: ["assistant"],
            permissions: ["vault.read", "vault.write", "shell"],
            settings: [
                SettingDescription(
                    "agent", title: "Agent",
                    help: "The agent new chats start with. Auto picks the one you are signed in to with a plan.",
                    default: .string(Settings.auto),
                    choices: [SettingChoice(.string(Settings.auto), title: "Auto")]
                        + AgentKind.allCases.map { SettingChoice(.string($0.rawValue), title: $0.name) }
                ),
                SettingDescription(
                    "model", title: "Model",
                    help: "Empty for the agent's own default; for Claude: opus, sonnet or haiku.",
                    default: .string("")
                ),
                SettingDescription(
                    "mode", title: "Mode",
                    help: "Auto edits notes directly, Ask asks before each change, Read Only never edits.",
                    default: .string(AgentMode.auto.rawValue),
                    choices: AgentMode.allCases.map { SettingChoice(.string($0.rawValue), title: $0.title) }
                ),
            ]
        )
    }

    /// Stored in `.loam/config.json` under `plugins.assistant.settings`.
    public struct Settings: Codable, Equatable {
        /// The `agent` value that lets Loam pick (`AgentCatalog.preferred`).
        public static let auto = "auto"

        public var agent = Settings.auto
        public var model = ""
        public var mode = AgentMode.auto.rawValue

        public init(agent: String = Settings.auto, model: String = "", mode: String = AgentMode.auto.rawValue) {
            self.agent = agent
            self.model = model
            self.mode = mode
        }

        /// The agent picked by hand, or Claude Code for `auto`; `AgentCatalog.defaultAgent(setting:)` resolves `auto`.
        public var agentKind: AgentKind { AgentKind(rawValue: agent) ?? .claude }
        public var agentMode: AgentMode { AgentMode(rawValue: mode) ?? .auto }
    }

    public static var optionalTools: [String] { ["git"] }

    public required init() {}

    private var engine: AssistantEngine?

    public func activate(context: PluginContext) throws {
        // Read once so the kernel knows the defaults; commands and the panel read them again when they need them.
        _ = context.settings.value(default: Settings())
        let tools = context.service(ServiceKey<ToolLocating>.tools)
        let engine = AssistantEngine(vault: context.vault.rootURL, locateGit: { tools?.locate("git") })
        self.engine = engine
        engine.settings = { [weak context] in context?.settings.value(default: Settings()) ?? Settings() }
        try context.provide(.assistant, engine)
        context.effect { engine.stopAll() }
        // Warms the catalog, so `auto` resolves to the agent the user pays for from the first chat.
        DispatchQueue.global(qos: .utility).async { _ = engine.catalog.refresh() }

        try context.registerCommand(Command(
            id: "assistant.ask",
            title: "Ask the assistant",
            summary: "Sends a prompt to a coding agent working in the vault and prints its answer once the turn is "
                + "over. Arguments: prompt; agent (claude, codex, antigravity, pi, opencode; the setting's by "
                + "default); mode (auto, ask, readOnly); chat (an id from assistant.chats, to continue it); note (a "
                + "path given as context). Returns JSON: chat, answer, changes, error.",
            isInPalette: false
        ) { [weak context] arguments in
            let settings = context?.settings.value(default: Settings()) ?? Settings()
            let chatID: String
            if let existing = arguments["chat"], engine.chat(existing) != nil {
                chatID = existing
            } else {
                let agent = arguments["agent"].flatMap(AgentKind.init(rawValue:))
                    ?? engine.catalog.defaultAgent(setting: settings.agent)
                let mode = arguments["mode"].flatMap(AgentMode.init(rawValue:)) ?? settings.agentMode
                chatID = engine.newChat(agent: agent, model: arguments["model"] ?? settings.model, mode: mode).id
            }
            await engine.send(chatID, prompt: try arguments.require("prompt"),
                              context: arguments["note"].map { [$0] } ?? [])
            await engine.waitForTurnEnd(chatID)
            let last = engine.chat(chatID)?.messages.last
            return try JSON.string(AskResult(
                chat: chatID, answer: last?.text ?? "", changes: last?.changes ?? [], error: last?.error
            ))
        })

        try context.registerCommand(Command(
            id: "assistant.agents",
            title: "List the assistant's agents",
            summary: "Lists the coding agents the assistant can use and their state on this Mac: missing, signedOut "
                + "or ready, with the program's path and the account when known.",
            isInPalette: false
        ) { _ in
            try JSON.string(engine.catalog.refresh())
        })

        try context.registerCommand(Command(
            id: "assistant.default-agent",
            title: "Show the assistant's default agent",
            summary: "The agent new chats and captures use: the setting's, or with auto the one signed in with a plan "
                + "(a subscription first, then a free account, then an API key). Returns its status as JSON: kind, "
                + "state, account, usage.",
            isInPalette: false
        ) { [weak context] _ in
            let settings = context?.settings.value(default: Settings()) ?? Settings()
            if engine.catalog.statuses == nil { engine.catalog.refresh() }
            return try JSON.string(engine.catalog.status(engine.catalog.defaultAgent(setting: settings.agent)))
        })

        try context.registerCommand(Command(
            id: "assistant.chats",
            title: "List the assistant's chats",
            summary: "Lists this device's chats, most recent first: id, title, agent, mode, messages, updated.",
            isInPalette: false
        ) { _ in
            try JSON.string(engine.allChats().map {
                ChatSummary(id: $0.id, title: $0.title, agent: $0.agent, mode: $0.mode, messages: $0.messages.count,
                            updated: $0.updated)
            })
        })

        try context.registerCommand(Command(
            id: "assistant.prompts",
            title: "List saved prompts",
            summary: "Lists the saved prompts of .loam/ai/prompts/: id, title, prompt.",
            isInPalette: false
        ) { _ in
            try JSON.string(engine.prompts.all())
        })

        try context.registerCommand(Command(
            id: "assistant.prompt-add",
            title: "Save a prompt",
            summary: "Saves a reusable prompt in .loam/ai/prompts/ (up to 20, 1000 characters each). Arguments: "
                + "prompt; title (optional). Writes to the vault. Returns the saved prompt.",
            isInPalette: false
        ) { arguments in
            try JSON.string(try engine.prompts.save(title: arguments["title"] ?? "",
                                                    prompt: try arguments.require("prompt")))
        })

        try context.registerCommand(Command(
            id: "assistant.prompt-remove",
            title: "Delete a saved prompt",
            summary: "Deletes a saved prompt. Argument: id (from assistant.prompts). Writes to the vault.",
            isInPalette: false
        ) { arguments in
            try engine.prompts.delete(try arguments.require("id"))
            return "deleted"
        })

        try context.registerCommand(Command(
            id: "assistant.undo-turn",
            title: "Undo an assistant turn",
            summary: "Puts back the notes one turn of a chat changed. Arguments: chat; message (the answer's id, "
                + "the last one by default). Writes to the vault.",
            isInPalette: false
        ) { arguments in
            let chatID = try arguments.require("chat")
            guard let chat = engine.chat(chatID) else { throw AgentError("No such chat.") }
            let messageID = arguments["message"]
                ?? chat.messages.last(where: { $0.role == .assistant && !$0.changes.isEmpty })?.id ?? ""
            try engine.undo(chatID, messageID: messageID)
            return "undone"
        })
    }

    struct AskResult: Encodable {
        let chat: String
        let answer: String
        let changes: [ChangedFile]
        let error: String?
    }

    struct ChatSummary: Encodable {
        let id: String
        let title: String
        let agent: AgentKind
        let mode: AgentMode
        let messages: Int
        let updated: Date
    }
}
