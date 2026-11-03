import Foundation
import PluginKit

/// What the runtime knows about one of the vault's own plugins (`.loam/plugins/<id>/`).
struct VaultPluginState {
    /// Nil when plugin.json is unusable.
    var manifest: ThirdPartyPluginManifest?
    var discovered: DiscoveredPlugin?
    /// The ids of the plugin types it registered, once loaded.
    var registeredIDs: [String] = []
    /// Why it is not loaded, when loading (or reading plugin.json) failed.
    var loadError: String?

    var isLoaded: Bool { !registeredIDs.isEmpty }
}

/// Third-party plugins: listed from `.loam/plugins/`, off by default, loaded once enabled.
///
/// - A third-party plugin runs only when `.loam/config.json` says `"enabled": true` for its id and this user turned it
///   on here (`PluginTrust`), so a vault received from someone else never runs its code on opening. A plugin type whose id
///   extends the package's (`hello.extra` in `hello`) follows the package unless it has its own `"enabled"`.
/// - Its library is opened only when it is enabled, so a disabled plugin's code never runs, and never in safe mode.
/// - Disabling deactivates it; its code stays mapped until the process ends (code cannot be unloaded).
extension Runtime {
    /// Reads `.loam/plugins/` again and loads the plugins the config enables that are not loaded yet. A failure is kept
    /// as the plugin's `loadError` and retried on the next call (a library that failed to open is opened again only
    /// once it changed on disk).
    func loadEnabledVaultPlugins() {
        guard thirdPartyPlugins else { return }
        let (discovered, failures) = loader.discover()
        var seen: Set<String> = []
        for plugin in discovered {
            let id = plugin.manifest.id
            seen.insert(id)
            var state = vaultPlugins[id] ?? VaultPluginState()
            if !state.isLoaded {
                state.manifest = plugin.manifest
                state.discovered = plugin
                // Shown even while the plugin is off, so the plugin manager can say it must be built first.
                state.loadError = FileManager.default.fileExists(atPath: plugin.libraryURL.path)
                    ? nil : loader.notBuiltReason(plugin.manifest)
            }
            vaultPlugins[id] = state
        }
        for failure in failures where vaultPlugins[failure.id]?.isLoaded != true {
            seen.insert(failure.id)
            vaultPlugins[failure.id] = VaultPluginState(loadError: failure.reason)
        }
        // A plugin removed from disk while loaded stays registered: its code is mapped and may be running.
        for id in vaultPlugins.keys where !seen.contains(id) && vaultPlugins[id]?.isLoaded != true {
            vaultPlugins[id] = nil
        }

        guard safeMode == nil else { return }
        for id in vaultPlugins.keys.sorted() {
            guard let state = vaultPlugins[id], !state.isLoaded, let plugin = state.discovered,
                  config.config.isExplicitlyEnabled(id) else { continue }
            guard pluginTrust.isTrusted(id, in: kernel.vault.rootURL) else {
                vaultPlugins[id]?.loadError = "this vault turns it on, but it was never turned on here: turn it on in "
                    + "Settings › Plugins (or `loam plugin enable \(id)`) to run its code"
                continue
            }
            let problem = register(loader.load(plugin))
            vaultPlugins[id]?.loadError = problem
        }
    }

    /// Registers a loaded plugin's types, all or none. Returns why it did not, nil when it did.
    private func register(_ result: Result<LoadedPlugin, LoadFailure>) -> String? {
        let loaded: LoadedPlugin
        switch result {
        case .success(let value): loaded = value
        case .failure(let failure): return failure.reason
        }
        let ids = loaded.types.map { $0.manifest.id }
        let taken = Set(host.manifests.map(\.id))
        if let clash = ids.first(where: taken.contains) {
            return "a plugin with the id \"\(clash)\" is already installed"
        }
        if Set(ids).count != ids.count { return "its entry returned one plugin id twice" }
        for type in loaded.types {
            do {
                try host.register(type)
            } catch {
                return "\(error)"
            }
        }
        vaultPlugins[loaded.manifest.id]?.registeredIDs = ids
        return nil
    }

    /// The package id owning a registered plugin type, when it comes from the vault.
    func vaultOwner(of id: String) -> String? {
        vaultPlugins.first { $0.value.registeredIDs.contains(id) }?.key
    }

    /// Whether `.loam/config.json` turns a plugin on: built-in plugins unless disabled, the vault's own only when
    /// enabled explicitly.
    func configEnables(_ id: String) -> Bool {
        let config = config.config
        guard let owner = vaultOwner(of: id) ?? (vaultPlugins[id] != nil ? id : nil) else { return config.isEnabled(id) }
        if config.isExplicitlyEnabled(id) { return true }
        return id != owner && config.isExplicitlyEnabled(owner) && config.isEnabled(id)
    }

    /// The vault's own plugins that are not loaded, with why, when it is known.
    func vaultLoadErrors() -> [String: String] {
        vaultPlugins.compactMapValues(\.loadError)
    }

    /// Why the vault's own plugins did not load, for warnings: those the config enables.
    public var thirdPartyLoadFailures: [LoadFailure] {
        vaultLoadErrors().filter { configEnables($0.key) }.map { LoadFailure(id: $0.key, reason: $0.value) }
            .sorted { $0.id < $1.id }
    }

    /// `builtin` for a plugin compiled into the app, `vault` for one from `.loam/plugins/`.
    public func source(of id: String) -> String {
        vaultOwner(of: id) != nil || vaultPlugins[id] != nil ? "vault" : "builtin"
    }
}
