import Foundation

/// Where a device keeps its vaults' keys, by key id: the Keychain on a Mac. Never inside the vault, whose files and
/// settings sync.
public protocol VaultKeyStore: Sendable {
    func load(id: String) throws -> VaultKey?
    func save(_ key: VaultKey) throws
}

/// Why a key store failed, in one sentence.
struct KeyStoreError: Error, LocalizedError, Equatable {
    let message: String
    var errorDescription: String? { message }
}

/// Keys in a folder only the user can read, one file per key: on Linux, and in tests (`LOAM_KEY_DIR`).
struct FileKeyStore: VaultKeyStore {
    let directory: URL

    func load(id: String) throws -> VaultKey? {
        let url = directory.appendingPathComponent(id)
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        guard let key = VaultKey(exported: text), key.id == id else {
            throw KeyStoreError(message: "The key file \(url.path) is damaged.")
        }
        return key
    }

    func save(_ key: VaultKey) throws {
        let manager = FileManager.default
        try manager.createDirectory(at: directory, withIntermediateDirectories: true,
                                    attributes: [.posixPermissions: 0o700])
        let url = directory.appendingPathComponent(key.id)
        guard manager.createFile(atPath: url.path, contents: Data((key.exported + "\n").utf8),
                                 attributes: [.posixPermissions: 0o600]) else {
            throw KeyStoreError(message: "Could not write the key to \(url.path).")
        }
    }
}

/// A key handed in by the environment (`LOAM_VAULT_KEY=loam-key:…`, or inside `LOAM_CONNECT`): an agent's sandbox
/// gets it from its secrets. Read before the store under it. Saving (`sync.key.import`, `sync.join`) goes to that
/// store, so the next run finds the key without the variable.
struct EnvironmentKeyStore: VaultKeyStore {
    let key: VaultKey
    let base: VaultKeyStore

    func load(id: String) throws -> VaultKey? {
        id == key.id ? key : try base.load(id: id)
    }

    func save(_ key: VaultKey) throws {
        try base.save(key)
    }
}

public enum VaultKeyStores {
    /// The environment variable a machine can be given its vault's key in, as `sync.key.export` prints it.
    public static let environmentKey = "LOAM_VAULT_KEY"

    /// This device's store: `LOAM_KEY_DIR` when set (tests), else the Keychain on a Mac, else
    /// `~/.config/loam/keys`; with `LOAM_VAULT_KEY`'s key in front of it when set.
    public static func system(environment: [String: String] = ProcessInfo.processInfo.environment) -> VaultKeyStore {
        let base = store(environment: environment)
        // `LOAM_VAULT_KEY`, else the key inside `LOAM_CONNECT` (an agent given its connect code as a secret).
        let text = environment[environmentKey] ?? environment["LOAM_CONNECT"].flatMap { ConnectCode(encoded: $0)?.vaultKey }
        guard let text, let key = VaultKey(exported: text) else { return base }
        return EnvironmentKeyStore(key: key, base: base)
    }

    private static func store(environment: [String: String]) -> VaultKeyStore {
        if let directory = environment["LOAM_KEY_DIR"], !directory.isEmpty {
            return FileKeyStore(directory: URL(fileURLWithPath: directory))
        }
        // An agent's test instance (LOAM_INSTANCE) keeps its own keys in its folder: reading the user's Keychain would
        // ask for the login Keychain password on every start.
        if let name = environment["LOAM_INSTANCE"], !name.isEmpty {
            let base = environment["LOAM_INSTANCES_DIR"] ?? "/tmp/loam-instances"
            return FileKeyStore(directory: URL(fileURLWithPath: base).appendingPathComponent(name).appendingPathComponent("keys"))
        }
        #if canImport(Security)
        return KeychainKeyStore()
        #else
        let config = environment["XDG_CONFIG_HOME"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config")
        return FileKeyStore(directory: config.appendingPathComponent("loam/keys"))
        #endif
    }
}
