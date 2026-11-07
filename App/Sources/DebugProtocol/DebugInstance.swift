import Foundation

/// A named, isolated run of the app for an agent: its own folder of files and its own control socket, so several
/// instances (and several agents) never meet. Named by `LOAM_INSTANCE=<name>` or `--instance <name>`.
///
///     /tmp/loam-instances/<name>/ctl.sock     the debug channel (JSON lines)
///     /tmp/loam-instances/<name>/state.json   pid, window, vault: written when the channel is up
///     /tmp/loam-instances/<name>/vault/       the vault `scripts/agent-run.sh` copies from a template
public struct DebugInstance: Hashable, Sendable {
    public let name: String
    public let directory: URL

    /// The folder holding the instances, `LOAM_INSTANCES_DIR` or `/tmp/loam-instances` (short: a socket path may
    /// not be longer than 103 bytes).
    public static func baseDirectory(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        URL(fileURLWithPath: environment["LOAM_INSTANCES_DIR"] ?? "/tmp/loam-instances", isDirectory: true)
    }

    /// A name made of letters, digits, `.`, `_` and `-`, at most 32 characters, not starting with a dot.
    public static func isValid(name: String) -> Bool {
        guard (1...32).contains(name.count), !name.hasPrefix(".") else { return false }
        return name.unicodeScalars.allSatisfy { $0.isASCII && ($0.properties.isAlphabetic || ("0"..."9").contains($0) || "._-".unicodeScalars.contains($0)) }
    }

    public init?(name: String, base: URL = DebugInstance.baseDirectory()) {
        guard Self.isValid(name: name) else { return nil }
        self.name = name
        directory = base.appendingPathComponent(name, isDirectory: true)
    }

    public var socketPath: String { directory.appendingPathComponent("ctl.sock").path }
    public var statePath: String { directory.appendingPathComponent("state.json").path }
    public var vaultURL: URL { directory.appendingPathComponent("vault", isDirectory: true) }

    /// The instance the process was asked to be: `LOAM_INSTANCE`, else `--instance <name>`. Nil for a normal run.
    public static func requested(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        arguments: [String] = CommandLine.arguments
    ) -> DebugInstance? {
        var name = environment["LOAM_INSTANCE"]
        if let index = arguments.firstIndex(of: "--instance"), index + 1 < arguments.count { name = arguments[index + 1] }
        guard let name, !name.isEmpty else { return nil }
        return DebugInstance(name: name, base: baseDirectory(environment: environment))
    }

    /// The longest a Unix socket path can be.
    public static let maxSocketPathLength = 103
}
