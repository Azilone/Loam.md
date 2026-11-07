import Foundation

/// One limit of an agent's plan, as the agent reports it: how much of the window is used and when it starts again.
public struct UsageWindow: Codable, Equatable, Sendable {
    /// "5 hours", "Week", "Month": from the window's length.
    public let name: String
    public let usedPercent: Double
    public let resetsAt: Date?

    public init(name: String, usedPercent: Double, resetsAt: Date?) {
        self.name = name
        self.usedPercent = usedPercent
        self.resetsAt = resetsAt
    }

    /// A window's name from its length in minutes.
    static func name(minutes: Int) -> String {
        switch minutes {
        case ..<1: return "Limit"
        case 300: return "5 hours"
        case 1440: return "Day"
        case 10080: return "Week"
        case 40000...46000: return "Month"
        default: return minutes % 1440 == 0 ? "\(minutes / 1440) days" : "\(minutes / 60) hours"
        }
    }
}

/// Codex's account through its own app server (`account/read`, `account/rateLimits/read`), as CodexBar does: the
/// plan ("Plus", "Pro", "Free") and the rate-limit windows. The CLI keeps its credentials; Loam never sees them.
enum CodexAccount {
    struct Reading: Equatable {
        var plan: String?
        var usage: [UsageWindow]
    }

    static func read(_ executable: URL, environment: [String: String], timeout: TimeInterval = 10) -> Reading? {
        let requests = [
            #"{"id":1,"method":"initialize","params":{"clientInfo":{"name":"loam","version":"1"}}}"#,
            #"{"method":"initialized","params":{}}"#,
            #"{"id":2,"method":"account/read","params":{}}"#,
            #"{"id":3,"method":"account/rateLimits/read","params":{}}"#,
        ]
        let process = Process()
        process.executableURL = executable
        process.arguments = ["app-server"]
        process.environment = environment
        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        defer {
            if process.isRunning { process.terminate() }
        }
        input.fileHandleForWriting.write(Data((requests.joined(separator: "\n") + "\n").utf8))

        let lock = NSLock()
        var lines: [String] = []
        var buffer = Data()
        let done = DispatchSemaphore(value: 0)
        output.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            lock.lock()
            defer { lock.unlock() }
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                done.signal()
                return
            }
            buffer.append(chunk)
            while let newline = buffer.firstIndex(of: 0x0A) {
                lines.append(String(decoding: buffer[buffer.startIndex..<newline], as: UTF8.self))
                buffer.removeSubrange(buffer.startIndex...newline)
                if lines.last?.hasPrefix(#"{"id":3"#) == true { done.signal() }
            }
        }
        _ = done.wait(timeout: .now() + timeout)
        output.fileHandleForReading.readabilityHandler = nil
        lock.lock()
        let answer = lines
        lock.unlock()
        return parse(answer)
    }

    /// Reads the answers to `account/read` (id 2) and `account/rateLimits/read` (id 3).
    static func parse(_ lines: [String]) -> Reading? {
        var plan: String?
        var usage: [UsageWindow] = []
        var answered = false
        for line in lines {
            guard let json = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
                  let id = json["id"] as? Int, let result = json["result"] as? [String: Any] else { continue }
            if id == 2 {
                answered = true
                let account = result["account"] as? [String: Any]
                plan = (account?["planType"] as? String).map(planName)
                if account == nil { plan = nil }
            } else if id == 3, let limits = result["rateLimits"] as? [String: Any] {
                answered = true
                if plan == nil { plan = (limits["planType"] as? String).map(planName) }
                for key in ["primary", "secondary"] {
                    guard let window = limits[key] as? [String: Any],
                          let used = (window["usedPercent"] as? NSNumber)?.doubleValue else { continue }
                    let minutes = (window["windowDurationMins"] as? NSNumber)?.intValue ?? 0
                    let reset = (window["resetsAt"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
                    usage.append(UsageWindow(name: UsageWindow.name(minutes: minutes), usedPercent: used, resetsAt: reset))
                }
            }
        }
        return answered ? Reading(plan: plan, usage: usage) : nil
    }

    /// `plus` → "ChatGPT Plus".
    static func planName(_ raw: String) -> String {
        let words = raw.replacingOccurrences(of: "_", with: " ").split(separator: " ").map { $0.capitalized }
        return "ChatGPT " + words.joined(separator: " ")
    }
}

public extension AgentCatalog {
    /// The agent to use when the user did not pick one: the one they pay for. A subscription (Claude Pro or Max,
    /// ChatGPT Plus or Pro…) first, then a free account, then an API key, then any agent that is ready; Claude
    /// Code, Codex, Antigravity, Pi, OpenCode in that order among equals. Nil when none is ready.
    static func preferred(_ statuses: [AgentStatus]) -> AgentKind? {
        let order: [AgentKind] = [.claude, .codex, .antigravity, .pi, .opencode]
        return statuses.filter { $0.state == .ready }.min { left, right in
            let (a, b) = (rank(left.account), rank(right.account))
            if a != b { return a < b }
            return (order.firstIndex(of: left.kind) ?? order.count) < (order.firstIndex(of: right.kind) ?? order.count)
        }?.kind
    }

    /// 0: a subscription, 1: a free account or a plan not known yet, 2: an API key, 3: nothing said.
    static func rank(_ account: String?) -> Int {
        guard let account = account?.lowercased(), !account.isEmpty else { return 3 }
        if account.contains("api key") { return 2 }
        if account.contains("free") || account == "chatgpt" { return 1 }
        return 0
    }

    /// The agent new chats and captures use: the setting's, or with `auto` the preferred one among the last statuses
    /// (Claude Code before the first check).
    func defaultAgent(setting: String) -> AgentKind {
        if let kind = AgentKind(rawValue: setting) { return kind }
        return statuses.flatMap(Self.preferred) ?? .claude
    }
}
