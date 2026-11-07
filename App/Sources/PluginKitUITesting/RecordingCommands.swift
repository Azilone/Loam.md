import PluginKitUI

/// A `CommandLauncher` that keeps the ids a plugin ran, so a test can check what a button did. Every id is available unless
/// listed in `unavailable`; `shortcuts` gives the ones that have a shortcut.
@MainActor
public final class RecordingCommands: CommandLauncher {
    public private(set) var ran: [String] = []
    /// The arguments of the commands run with some, by id.
    public private(set) var arguments: [String: [String: String]] = [:]
    public var unavailable: Set<String> = []
    public var shortcuts: [String: String] = [:]

    public init() {}

    public func isAvailable(_ id: String) -> Bool { !unavailable.contains(id) }
    public func run(_ id: String) { ran.append(id) }
    public func run(_ id: String, arguments: [String: String]) async throws -> String {
        ran.append(id)
        self.arguments[id] = arguments
        return ""
    }
    public func shortcut(for id: String) -> String? { shortcuts[id] }
}
