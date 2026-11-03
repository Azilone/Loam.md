import Foundation
import PluginKit

public enum RuntimeError: Error, Equatable, LocalizedError {
    case unknownPlugin(id: String)
    /// A core command ran after its runtime was released.
    case closed
    /// `plugins.set-setting` or the plugin's page was given a value the plugin cannot read for that setting;
    /// `expected` says what it takes ("text", "a whole number").
    case invalidSetting(id: String, key: String, expected: String)
    /// `plugins.set-setting` was given a key the plugin does not read; `known` lists the keys it does.
    case unknownSetting(id: String, key: String, known: [String])

    public var errorDescription: String? {
        switch self {
        case .unknownPlugin(let id): return "unknown plugin \"\(id)\"; run `loam plugins.list`"
        case .closed: return "the vault is closed"
        case .invalidSetting(let id, let key, let expected):
            return "\(key.isEmpty ? "the setting" : "\"\(key)\"") of \(id) takes \(expected); nothing was saved"
        case .unknownSetting(let id, let key, let known):
            let list = known.isEmpty ? "it has no settings" : "one of \(known.joined(separator: ", "))"
            return "\(id) does not read a setting \"\(key)\" (\(list)); nothing was saved"
        }
    }
}

/// One open vault: its kernel, plugin host and `.loam/config.json`, wired the same way for the CLI, the app and
/// tests. Which plugins run is decided by the config (and safe mode), never by the caller, so the vault
/// carries its own setup from one front end to the other.
///
/// With `thirdPartyPlugins`, the vault's own plugins (`.loam/plugins/<id>/`, compiled in `.loam/cache/plugins/`) are
/// listed too. They are off unless `.loam/config.json` says `"enabled": true`, and their code is only loaded once they
/// are enabled, never in safe mode (see `Runtime+ThirdParty.swift`).
public final class Runtime {
    public let kernel: Kernel
    public let host: PluginHost
    public let config: ConfigStore
    /// When set, only these plugins (and the providers they require, transitively) may run.
    public let safeMode: Set<String>?
    /// What the last `applyConfig` changed, with the reasons plugins did not start.
    public private(set) var lastReport = ActivationReport()

    /// Whether the vault's own plugins are listed and, once enabled, loaded.
    public let thirdPartyPlugins: Bool
    /// Finds and loads the vault's own plugins.
    let loader: PluginLoader
    /// Which of the vault's own plugins this user approved here: the vault's config alone never runs its code.
    let pluginTrust: PluginTrust
    /// The vault's own plugins by plugin.json id (or folder name when plugin.json is unusable).
    var vaultPlugins: [String: VaultPluginState] = [:]

    private var hostServiceRemovers: [() -> Void]
    private var coreCommandIDs: [String] = []

    /// - Parameters:
    ///   - hostServices: provides the front end's services (UI registries, fakes in tests) before any plugin
    ///     starts, so plugins that require them can. Returns the functions that remove them, run by `close`.
    ///   - safeMode: an allowlist of plugin ids, for starting a vault with a misbehaving plugin left out. Third-party
    ///     libraries are never loaded in safe mode.
    ///   - thirdPartyPlugins: lists the vault's own plugins and loads those the config enables.
    ///   - pluginLoader: replaces the loader, for tests.
    ///   - pluginTrust: where approvals of the vault's own plugins are kept (`.everything` in tests).
    public init(
        rootURL: URL,
        plugins: [Plugin.Type],
        hostServices: (Kernel) throws -> [() -> Void] = { _ in [] },
        safeMode: Set<String>? = nil,
        thirdPartyPlugins: Bool = false,
        pluginLoader: PluginLoader? = nil,
        pluginTrust: PluginTrust = .onThisMachine
    ) throws {
        try? VaultFolder.migrate(rootURL: rootURL)
        let vault = Vault(rootURL: rootURL)
        config = try ConfigStore(vault: vault)
        kernel = Kernel(vault: vault, config: config)
        host = PluginHost(kernel: kernel)
        self.safeMode = safeMode
        self.thirdPartyPlugins = thirdPartyPlugins
        loader = pluginLoader ?? PluginLoader(rootURL: rootURL)
        self.pluginTrust = pluginTrust
        hostServiceRemovers = try hostServices(kernel)
        do {
            for plugin in plugins { try host.register(plugin) }
            try registerCoreCommands()
        } catch {
            close()
            throw error
        }
        applyConfig()
    }

    /// Re-reads `.loam/config.json` and starts or stops plugins to match it. A config that became unreadable
    /// since the last read is ignored here (the last good one is used); the next write reports it.
    @discardableResult
    public func applyConfig() -> ActivationReport {
        _ = try? config.reload()
        loadEnabledVaultPlugins()
        lastReport = host.apply(enabled: enabledIDs())
        for (id, reason) in vaultLoadErrors() where configEnables(id) { lastReport.failed[id] = reason }
        return lastReport
    }

    /// Stops every plugin, then removes the core commands and the host services, last provided first.
    public func close() {
        host.deactivateAll()
        for id in coreCommandIDs { kernel.commands.unregister(id: id) }
        coreCommandIDs = []
        for remove in hostServiceRemovers.reversed() { remove() }
        hostServiceRemovers = []
    }

    /// Registered plugins the config enables, limited by safe mode.
    func enabledIDs() -> Set<String> {
        let enabled = Set(host.manifests.map(\.id).filter(configEnables))
        guard let allowed = allowedInSafeMode() else { return enabled }
        return enabled.intersection(allowed)
    }

    /// The safe mode allowlist plus every plugin it hard-requires, transitively; nil outside safe mode.
    func allowedInSafeMode() -> Set<String>? {
        guard let safeMode else { return nil }
        let manifests = Dictionary(uniqueKeysWithValues: host.manifests.map { ($0.id, $0) })
        var allowed: Set<String> = []
        var pending = Array(safeMode.filter { manifests[$0] != nil })
        while let id = pending.popLast() {
            guard allowed.insert(id).inserted, let manifest = manifests[id] else { continue }
            let providers = manifests.values.filter { !$0.provides.filter(manifest.requires.contains).isEmpty }
            pending += providers.map(\.id)
        }
        return allowed
    }

    func registerCore(_ command: Command) throws {
        try kernel.commands.register(command, owner: "core")
        coreCommandIDs.append(command.id)
    }

    func requireRegistered(_ id: String) throws {
        guard host.manifests.contains(where: { $0.id == id }) || vaultPlugins[id] != nil else {
            throw RuntimeError.unknownPlugin(id: id)
        }
    }
}
