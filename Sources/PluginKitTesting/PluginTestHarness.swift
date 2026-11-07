import Foundation
import PluginKit
import LoamCore

public enum PluginTestHarnessError: Error, Equatable {
    case unknownCommand(id: String)
}

/// A kernel and a plugin host on a `TemporaryVault`, with the given plugins registered and active:
/// what a plugin test needs to run commands and observe events the way the app would.
public final class PluginTestHarness {
    public let vault: TemporaryVault
    public let kernel: Kernel
    public let host: PluginHost

    /// - Parameter files: vault-relative path to text, written before the plugins activate.
    public init(_ plugins: [Plugin.Type], files: [String: String] = [:]) throws {
        vault = try TemporaryVault()
        for (path, text) in files { try vault.write(path, text) }
        kernel = Kernel(vault: vault)
        host = PluginHost(kernel: kernel)
        for plugin in plugins { try host.register(plugin) }
        try host.activateAll()
    }

    deinit {
        host.deactivateAll()
    }

    /// Runs a registered command, as the palette or the CLI would.
    public func run(_ command: String, _ args: [String: String] = [:]) async throws -> String {
        guard let found = kernel.commands.command(id: command) else {
            throw PluginTestHarnessError.unknownCommand(id: command)
        }
        return try await found.handler(args)
    }
}
