import Foundation
import PluginKit

public enum ConfigError: Error, Equatable, LocalizedError {
    /// The file exists but is not a config this version can read. It is left as is for the user to fix.
    case corrupt(path: String, reason: String)

    public var errorDescription: String? {
        switch self {
        case .corrupt(let path, let reason):
            return "\(path) cannot be read (\(reason)); fix or delete it, it will not be overwritten"
        }
    }
}

/// Reads and writes `.loam/config.json`. The file belongs to the user as much as to the app (it syncs with
/// the vault and can be edited by hand), so:
/// - a missing file is an empty config, and the file is only created by the first change;
/// - a file that cannot be read throws `ConfigError.corrupt` and is never overwritten;
/// - every change re-reads the file first, so edits made by another process (the CLI while the app runs)
///   are kept.
public final class ConfigStore {
    public static let path = ".loam/config.json"

    public let vault: VaultAccess
    public private(set) var config: VaultConfig

    public init(vault: VaultAccess) throws {
        self.vault = vault
        config = try Self.load(from: vault)
    }

    /// Reads the file again. Returns true when the config changed.
    @discardableResult
    public func reload() throws -> Bool {
        let fresh = try Self.load(from: vault)
        defer { config = fresh }
        return fresh != config
    }

    /// Applies `change` to the latest config on disk and writes it atomically. Writes nothing when the
    /// change leaves the config as it was.
    public func mutate(_ change: (inout VaultConfig) -> Void) throws {
        try reload()
        var updated = config
        change(&updated)
        guard updated != config else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let text = String(decoding: try encoder.encode(updated), as: UTF8.self) + "\n"
        try vault.write(Self.path, text)
        config = updated
    }

    private static func load(from vault: VaultAccess) throws -> VaultConfig {
        guard vault.exists(path) else { return VaultConfig() }
        let text: String
        do {
            text = try vault.read(path)
        } catch {
            throw ConfigError.corrupt(path: path, reason: "\(error)")
        }
        do {
            return try JSONDecoder().decode(VaultConfig.self, from: Data(text.utf8))
        } catch let DecodingError.dataCorrupted(context) {
            throw ConfigError.corrupt(path: path, reason: context.debugDescription)
        } catch {
            throw ConfigError.corrupt(path: path, reason: "not a JSON object")
        }
    }
}
