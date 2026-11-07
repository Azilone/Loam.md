import Foundation

/// An agent on this Mac and whether it can be used.
public struct AgentStatus: Codable, Equatable, Sendable {
    public enum State: String, Codable, Sendable {
        case missing
        case signedOut
        case ready
    }

    public let kind: AgentKind
    public let state: State
    /// The program, when found.
    public let path: String?
    /// Who is signed in, or the plan, when the agent says ("ChatGPT", "Claude Max").
    public let account: String?
    /// The models it offers on this Mac, its default excepted.
    public let models: [AgentModel]
    /// How much of its plan's limits is used, when the agent says (Codex). Nil when unknown.
    public let usage: [UsageWindow]?

    public init(kind: AgentKind, state: State, path: String?, account: String? = nil, models: [AgentModel] = [],
                usage: [UsageWindow]? = nil) {
        self.kind = kind
        self.state = state
        self.path = path
        self.account = account
        self.models = models
        self.usage = usage
    }
}

/// Finds the agents installed on this Mac and asks each whether it is signed in. Checks run the agents' own status
/// commands, so they take a moment: the catalog keeps the last answer.
public class AgentCatalog: @unchecked Sendable {
    private let environment: ShellEnvironment
    private let lock = StateLock()
    private var cached: [AgentStatus]?

    public init(environment: ShellEnvironment = .shared) {
        self.environment = environment
    }

    /// The last statuses, or nil before the first `refresh`.
    public var statuses: [AgentStatus]? {
        lock.lock()
        defer { lock.unlock() }
        return cached
    }

    @discardableResult
    public func refresh() -> [AgentStatus] {
        let variables = environment.variables
        let statuses = AgentKind.allCases.map { kind -> AgentStatus in
            guard let url = environment.find(kind.executable) else {
                return AgentStatus(kind: kind, state: .missing, path: nil)
            }
            var (state, account) = Self.signIn(kind, url, variables)
            var usage: [UsageWindow]?
            // Codex's app server says the plan and how much of it is used (as CodexBar reads it).
            if kind == .codex, state == .ready, let reading = CodexAccount.read(url, environment: variables) {
                account = reading.plan ?? account
                usage = reading.usage
            }
            let models = state == .ready ? Self.models(kind, url, variables) : []
            // Pi without any provider signed in has no model to run.
            if kind == .pi, models.isEmpty { state = .signedOut }
            return AgentStatus(kind: kind, state: state, path: url.path, account: account, models: models, usage: usage)
        }
        lock.lock()
        cached = statuses
        lock.unlock()
        return statuses
    }

    public func status(_ kind: AgentKind) -> AgentStatus {
        (statuses ?? refresh()).first { $0.kind == kind } ?? AgentStatus(kind: kind, state: .missing, path: nil)
    }

    /// The agent's program, found on the login shell's PATH.
    public func executable(_ kind: AgentKind) -> URL? {
        environment.find(kind.executable)
    }

    static func signIn(_ kind: AgentKind, _ url: URL, _ environment: [String: String])
        -> (AgentStatus.State, String?)
    {
        switch kind {
        case .claude:
            let result = QuickCommand.run(url, ["auth", "status", "--json"], environment: environment)
            guard let json = JSONLine.decode(result.output) else { return (.ready, nil) }
            if json["loggedIn"] as? Bool == false { return (.signedOut, nil) }
            return (.ready, json.string("subscriptionType").map { "Claude \($0.capitalized)" })
        case .codex:
            let result = QuickCommand.run(url, ["login", "status"], environment: environment)
            if result.output.contains("Not logged in") { return (.signedOut, nil) }
            if result.output.contains("ChatGPT") { return (.ready, "ChatGPT") }
            return (.ready, result.output.contains("API key") ? "API key" : nil)
        default:
            // Gemini, OpenCode, Pi and Antigravity have no quick status command: they say so on the first prompt.
            return (.ready, nil)
        }
    }

    /// What the agent can run: Claude's three, Codex's from its own cache, the rest from the agent's model listing.
    static func models(_ kind: AgentKind, _ url: URL, _ environment: [String: String]) -> [AgentModel] {
        switch kind {
        case .claude:
            return kind.models
        case .codex:
            let cache = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/models_cache.json")
            guard let data = try? Data(contentsOf: cache),
                  let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return [] }
            return json.objects("models").compactMap { model in
                guard model.string("visibility") == "list", let slug = model.string("slug") else { return nil }
                return AgentModel(id: slug, name: model.string("display_name") ?? slug)
            }
        case .antigravity:
            // `agy models`: "id<TAB>Name" lines.
            return QuickCommand.run(url, ["models"], environment: environment, timeout: 15).output
                .split(separator: "\n").compactMap { line in
                    let parts = line.split(separator: "\t", maxSplits: 1).map(String.init)
                    return parts.count == 2 ? AgentModel(id: parts[0], name: parts[1]) : nil
                }
        case .pi:
            // `pi --list-models`: a table, "provider model context …", for the providers signed in.
            return QuickCommand.run(url, ["--list-models"], environment: environment, timeout: 15).output
                .split(separator: "\n").dropFirst().compactMap { line in
                    let columns = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
                    guard columns.count >= 2 else { return nil }
                    return AgentModel(id: "\(columns[0])/\(columns[1])", name: columns[1], provider: columns[0])
                }
        case .opencode:
            // `opencode models`: "provider/model" lines.
            return QuickCommand.run(url, ["models"], environment: environment, timeout: 15).output
                .split(separator: "\n").compactMap { line in
                    let id = line.trimmingCharacters(in: .whitespaces)
                    guard let slash = id.firstIndex(of: "/"), !id.contains(" ") else { return nil }
                    return AgentModel(id: id, name: String(id[id.index(after: slash)...]), provider: String(id[..<slash]))
                }
        }
    }

    /// A runtime for `configuration`, speaking its agent's protocol.
    public static func runtime(_ configuration: AgentConfiguration) -> AgentRuntime {
        switch configuration.kind {
        case .claude: ClaudeRuntime(configuration: configuration)
        case .codex: CodexRuntime(configuration: configuration)
        case .opencode: ACPRuntime(configuration: configuration)
        case .pi: PiRuntime(configuration: configuration)
        case .antigravity: AntigravityRuntime(configuration: configuration)
        }
    }
}
