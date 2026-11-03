import Foundation

/// A tool call shown in the chat: "Edited Plan.md", "Ran ls".
public struct ToolCall: Codable, Equatable, Sendable, Identifiable {
    public enum State: String, Codable, Sendable { case running, done, failed }
    public let id: String
    public var title: String
    public var path: String?
    public var state: State

    public init(id: String, title: String, path: String? = nil, state: State = .running) {
        self.id = id
        self.title = title
        self.path = path
        self.state = state
    }
}

public struct ChatMessage: Codable, Equatable, Sendable, Identifiable {
    public enum Role: String, Codable, Sendable { case user, assistant }
    public let id: String
    public let role: Role
    public var text: String
    public var thinking: String
    public var tools: [ToolCall]
    /// What the turn changed in the vault, once it ended (assistant messages).
    public var changes: [ChangedFile]
    /// The snapshot before the turn, to undo it.
    public var checkpoint: String?
    public var undone: Bool
    public var error: String?
    /// The notes given as context with a user message.
    public var context: [String]
    /// The passage the user had selected when sending.
    public var selection: NoteSelection?
    /// The images pasted or dropped with a user message: vault paths in `.loam/cache/ai/attachments`; nil when none.
    public var images: [String]?
    public let date: Date

    public init(
        id: String = UUID().uuidString, role: Role, text: String = "", context: [String] = [],
        selection: NoteSelection? = nil, images: [String] = [], date: Date = Date()
    ) {
        self.id = id
        self.role = role
        self.text = text
        thinking = ""
        tools = []
        changes = []
        checkpoint = nil
        undone = false
        error = nil
        self.context = context
        self.selection = selection
        self.images = images.isEmpty ? nil : images
        self.date = date
    }
}

/// A passage selected in a note.
public struct NoteSelection: Codable, Equatable, Hashable, Sendable {
    public let path: String
    public let text: String

    public init(path: String, text: String) {
        self.path = path
        self.text = text
    }
}

/// One conversation with one agent. Kept per device, in `.loam/cache/ai/chats/<id>.json`.
public struct Chat: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public var title: String
    public var agent: AgentKind
    public var model: String
    public var mode: AgentMode
    /// The agent's own id of the conversation, to continue it after a relaunch.
    public var sessionID: String?
    public var messages: [ChatMessage]
    public let created: Date
    public var updated: Date

    public init(id: String = UUID().uuidString, agent: AgentKind, model: String = "", mode: AgentMode = .auto) {
        self.id = id
        title = "New Chat"
        self.agent = agent
        self.model = model
        self.mode = mode
        sessionID = nil
        messages = []
        created = Date()
        updated = created
    }
}

/// The chats of this device.
public final class ChatStore: @unchecked Sendable {
    private let folder: URL
    private let lock = StateLock()

    public init(vault: URL) {
        folder = vault.appendingPathComponent(".loam/cache/ai/chats")
    }

    /// Every chat, most recent first.
    public func all() -> [Chat] {
        lock.lock()
        defer { lock.unlock() }
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }
            .compactMap { try? Self.decoder.decode(Chat.self, from: Data(contentsOf: $0)) }
            .sorted { $0.updated > $1.updated }
    }

    public func chat(_ id: String) -> Chat? {
        lock.lock()
        defer { lock.unlock() }
        return try? Self.decoder.decode(Chat.self, from: Data(contentsOf: url(id)))
    }

    public func save(_ chat: Chat) {
        lock.lock()
        defer { lock.unlock() }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if let data = try? Self.encoder.encode(chat) { try? data.write(to: url(chat.id), options: .atomic) }
    }

    public func delete(_ id: String) {
        lock.lock()
        defer { lock.unlock() }
        try? FileManager.default.removeItem(at: url(id))
    }

    private func url(_ id: String) -> URL {
        folder.appendingPathComponent(id.replacingOccurrences(of: "/", with: "-") + ".json")
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
