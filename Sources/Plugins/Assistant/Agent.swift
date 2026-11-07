import Foundation

/// The coding agents the assistant can drive. Each is the CLI the user installed and signed in to; Loam starts it in
/// the vault and never sees its credentials (docs/AI.md, "Choices").
public enum AgentKind: String, Codable, CaseIterable, Sendable {
    case claude
    case codex
    case antigravity
    case pi
    case opencode

    /// A chat saved with Gemini CLI, which Google replaced with Antigravity in June 2026, opens on Antigravity.
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = AgentKind(rawValue: raw == "gemini" ? "antigravity" : raw) ?? .claude
    }

    public var name: String {
        switch self {
        case .claude: "Claude Code"
        case .codex: "Codex"
        case .opencode: "OpenCode"
        case .pi: "Pi"
        case .antigravity: "Antigravity CLI"
        }
    }

    /// The program on the PATH.
    public var executable: String {
        switch self {
        case .antigravity: "agy"
        default: rawValue
        }
    }

    /// What the user runs in a terminal to sign in.
    public var loginCommand: String {
        switch self {
        case .claude: "claude login"
        case .codex: "codex login"
        case .opencode: "opencode auth login"
        case .pi: "pi, then /login"
        case .antigravity: "agy"
        }
    }

    /// Where to get it, shown when it is missing.
    public var installHint: String {
        switch self {
        case .claude: "curl -fsSL https://claude.ai/install.sh | bash"
        case .codex: "npm install -g @openai/codex"
        case .opencode: "curl -fsSL https://opencode.ai/install | bash"
        case .pi: "npm install -g @earendil-works/pi-coding-agent"
        case .antigravity: "https://antigravity.google/cli"
        }
    }

    /// The models known without asking the agent (`AgentCatalog` lists the others from the agent itself).
    public var models: [AgentModel] {
        switch self {
        case .claude:
            [AgentModel(id: "sonnet", name: "Sonnet"), AgentModel(id: "opus", name: "Opus"),
             AgentModel(id: "haiku", name: "Haiku")]
        default:
            []
        }
    }
}

public struct AgentModel: Codable, Equatable, Hashable, Sendable {
    /// Passed as the agent's model; empty for the agent's own default.
    public var id: String
    public var name: String
    /// Who serves it, for an agent with several providers (Pi's `openrouter`, `openai-codex`); nil otherwise.
    public var provider: String?

    public init(id: String, name: String, provider: String? = nil) {
        self.id = id
        self.name = name
        self.provider = provider
    }
}

/// How far the agent may go, the mode menu of the composer (Craft's Explore and Execute, plus read only).
public enum AgentMode: String, Codable, CaseIterable, Sendable {
    /// Edits notes and runs commands without asking. Each turn can still be undone.
    case auto
    /// Asks before each edit or command, where the agent can ask.
    case ask
    /// Reads and answers; never edits.
    case readOnly

    public var title: String {
        switch self {
        case .auto: "Full access"
        case .ask: "Guard"
        case .readOnly: "Read only"
        }
    }

    public var subtitle: String {
        switch self {
        case .auto: "Edits notes and runs commands without asking"
        case .ask: "Asks before each change"
        case .readOnly: "Reads and answers, never changes a note"
        }
    }
}

/// What starting an agent needs.
public struct AgentConfiguration: Sendable {
    public var kind: AgentKind
    /// The agent's program, already resolved.
    public var executable: URL
    /// The environment the program runs with: the login shell's, so it finds node, git and its own config.
    public var environment: [String: String]
    /// The vault: the agent's working folder.
    public var folder: URL
    /// Empty for the agent's default.
    public var model: String
    public var mode: AgentMode
    /// Loam's conventions and the user's own instructions, given once per chat.
    public var instructions: String
    /// The agent's own id of the conversation to continue, after a relaunch.
    public var resumeID: String?

    public init(
        kind: AgentKind, executable: URL, environment: [String: String], folder: URL, model: String = "",
        mode: AgentMode = .auto, instructions: String = "", resumeID: String? = nil
    ) {
        self.kind = kind
        self.executable = executable
        self.environment = environment
        self.folder = folder
        self.model = model
        self.mode = mode
        self.instructions = instructions
        self.resumeID = resumeID
    }
}

/// A question the agent asks before acting, in Ask mode.
public struct AgentApproval: Equatable, Sendable {
    public struct Option: Equatable, Sendable {
        public enum Kind: Sendable { case allowOnce, allowAlways, reject }
        public let id: String
        public let label: String
        public let kind: Kind

        public init(id: String, label: String, kind: Kind) {
            self.id = id
            self.label = label
            self.kind = kind
        }
    }

    public let id: String
    public let title: String
    /// The command or the file, when known.
    public let detail: String
    public let options: [Option]

    public init(id: String, title: String, detail: String = "", options: [Option]) {
        self.id = id
        self.title = title
        self.detail = detail
        self.options = options
    }
}

/// What an agent reports while it works, the same for every agent.
public enum AgentEvent: Equatable, Sendable {
    /// The agent's id for this conversation, to continue it later.
    case session(String)
    /// A piece of the answer, to append.
    case text(String)
    /// A piece of the agent's reasoning.
    case thinking(String)
    /// A tool started (`finished` false) or ended. `path` is the note it read or changed, relative to the vault when
    /// it is inside.
    case tool(id: String, title: String, path: String?, finished: Bool, failed: Bool)
    case approval(AgentApproval)
    /// The turn is over; the agent waits for the next prompt.
    case turnEnded(cost: Double?)
    case failed(String)
}

/// One running agent: started once per chat, then one `send` per turn. Implementations turn their CLI's protocol
/// into `AgentEvent`s.
public protocol AgentRuntime: AnyObject, Sendable {
    var events: AsyncStream<AgentEvent> { get }
    func start() async throws
    func send(_ prompt: String) async throws
    /// Stops the current turn; the agent stays ready for the next.
    func cancel() async
    func answer(approval id: String, option: AgentApproval.Option) async
    /// Ends the agent and its process.
    func stop()
}

public struct AgentError: Error, LocalizedError, Equatable {
    public let message: String

    public init(_ message: String) {
        self.message = message
    }

    public var errorDescription: String? { message }
}

/// A runtime's event stream and the continuation that feeds it.
final class EventChannel: @unchecked Sendable {
    let stream: AsyncStream<AgentEvent>
    private let continuation: AsyncStream<AgentEvent>.Continuation

    init() {
        (stream, continuation) = AsyncStream.makeStream(of: AgentEvent.self)
    }

    func send(_ event: AgentEvent) {
        continuation.yield(event)
    }

    func finish() {
        continuation.finish()
    }
}

/// A short title for a tool call, as the panel lists it: "Edited Ideas.md", "Ran ls", "Read Plan.md".
enum ToolTitle {
    static func make(tool: String, path: String?, command: String?, folder: URL) -> (title: String, path: String?) {
        let relative = path.map { relativePath($0, in: folder) }
        let name = relative.map { ($0 as NSString).lastPathComponent }
        let lower = tool.lowercased()
        if let command, !command.isEmpty {
            // Paths inside the vault, as the user sees them; a leading `cd <dir> &&` says nothing.
            var shown = command
            for root in [folder.standardizedFileURL.path, "/private" + folder.standardizedFileURL.path] {
                shown = shown.replacingOccurrences(of: root + "/", with: "").replacingOccurrences(of: root, with: ".")
            }
            shown = shown.replacingOccurrences(of: #"^cd\s+\S+\s*&&\s*"#, with: "", options: .regularExpression)
            return ("Ran \(shorten(shown))", nil)
        }
        if let name {
            if lower.contains("write") || lower.contains("edit") || lower.contains("patch") || lower.contains("replace")
                || lower.contains("create") {
                return ("Edited \(name)", relative)
            }
            if lower.contains("read") || lower.contains("view") { return ("Read \(name)", relative) }
            return ("\(tool) \(name)", relative)
        }
        if lower.contains("grep") || lower.contains("glob") || lower.contains("search") || lower.contains("find") {
            return ("Searched the notes", nil)
        }
        return (tool, nil)
    }

    /// `path` relative to `folder` when it is inside, else as given.
    static func relativePath(_ path: String, in folder: URL) -> String {
        var path = path
        if path.hasPrefix("file://"), let url = URL(string: path) { path = url.path }
        let root = folder.standardizedFileURL.path
        let candidates = [root, root.replacingOccurrences(of: "/private/", with: "/"), "/private" + root]
        for base in candidates where path.hasPrefix(base + "/") {
            return String(path.dropFirst(base.count + 1))
        }
        return path
    }

    static func shorten(_ command: String) -> String {
        var command = command
        // `/bin/zsh -lc "printf …"`: the inner command is what the user cares about.
        if let range = command.range(of: #"^\S*sh -l?c "(.*)"$"#, options: .regularExpression) {
            command = String(command[range]).replacingOccurrences(of: #"^\S*sh -l?c ""#, with: "", options: .regularExpression)
            command.removeLast()
        }
        let line = command.split(separator: "\n").first.map(String.init) ?? command
        return line.count > 60 ? String(line.prefix(59)) + "…" : line
    }
}

/// A lock for state shared between the reading task and callers. Never held across an `await`.
final class StateLock: @unchecked Sendable {
    private let inner = NSLock()

    func lock() { inner.lock() }
    func unlock() { inner.unlock() }
}
