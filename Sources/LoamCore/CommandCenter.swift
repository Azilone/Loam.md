import Foundation
import PluginKit

public final class CommandCenter: CommandRegistry, @unchecked Sendable {
    private let lock = NSLock()
    private var commands: [String: (command: Command, owner: String)] = [:]
    private var changes = 0

    public init() {}

    public func register(_ command: Command, owner: String) throws {
        lock.lock()
        defer { lock.unlock() }
        guard commands[command.id] == nil else { throw CommandError.duplicate(id: command.id) }
        commands[command.id] = (command, owner)
        changes += 1
    }

    public func unregister(id: String) {
        lock.lock()
        defer { lock.unlock() }
        if commands.removeValue(forKey: id) != nil { changes += 1 }
    }

    /// Changes each time a command comes or goes, so a list made from `all` can be kept until then.
    public var revision: Int {
        lock.lock()
        defer { lock.unlock() }
        return changes
    }

    public func command(id: String) -> Command? {
        lock.lock()
        defer { lock.unlock() }
        return commands[id]?.command
    }

    /// The plugin that registered the command (`shell` for the app's own), nil for an unknown id.
    public func owner(of id: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return commands[id]?.owner
    }

    public var all: [Command] {
        lock.lock()
        defer { lock.unlock() }
        return commands.values.map(\.command).sorted { $0.id < $1.id }
    }
}
