import Foundation
import PluginKit

/// The `plugins.*` commands: the one path the settings window, the CLI and agents use to list, enable and
/// disable plugins. They belong to the runtime, not to a plugin, since a plugin could disable itself.
///
/// The kernel and the host are main-thread objects, and UI plugins check that they start and stop on the main
/// actor. A command handler runs on whatever executor calls it, so the handlers that start or stop plugins hop to
/// the main actor first.
extension Runtime {
    /// One row of `plugins.list`.
    struct PluginRow: Encodable {
        let id: String
        let name: String
        let version: String
        /// What it does, in one line; empty when it does not say.
        let description: String
        /// An SF Symbol name for its icon, when it declares one.
        let icon: String?
        /// `builtin` (compiled into the app) or `vault` (from `.loam/plugins/`).
        let source: String
        /// What `.loam/config.json` says. The vault's own plugins are off unless enabled explicitly.
        let enabled: Bool
        let active: Bool
        let provides: [String]
        let requires: [String]
        let optionalRequires: [String]
        /// The programs it cannot run without, and the ones it uses when installed; `missingTools` are those of
        /// `requiresTools` that are not installed (the plugin waits for them).
        let requiresTools: [String]
        let optionalTools: [String]
        let missingTools: [String]
        /// Why an enabled plugin did not start, when it did not.
        let failed: String?
        let skipped: String?
        /// Why a plugin from the vault could not be loaded (not built, built for another version, bad plugin.json).
        let loadError: String?
    }

    func registerCoreCommands() throws {
        try registerCore(Command(
            id: "plugins.list",
            title: "List plugins",
            summary: "Every installed plugin as JSON: id, name, version, description, icon, source (builtin or vault), "
                + "enabled, active, the services it provides and requires, and why it did not start (failed, skipped or "
                + "loadError).",
            isInPalette: false
        ) { [weak self] _ in
            guard let self else { throw RuntimeError.closed }
            return try JSON.string(pluginRows())
        })

        try registerCore(Command(
            id: "tools.list",
            title: "List tools",
            summary: "Every program the plugins use, as JSON: name, formula (the Homebrew package that installs it, null "
                + "when it comes with the developer tools), path (null when not installed), requiredBy and optionalFor "
                + "(the plugins).",
            isInPalette: false
        ) { [weak self] _ in
            guard let self else { throw RuntimeError.closed }
            return try JSON.string(toolRows())
        })

        try registerCore(Command(
            id: "tools.check",
            title: "Check tools",
            summary: "Looks for the programs again, then starts the plugins that were waiting for them. Returns the tools as "
                + "tools.list does.",
            isInPalette: false
        ) { [weak self] _ in
            // The runtime is not `Sendable`; it is only touched on the main actor, inside the hop.
            nonisolated(unsafe) let runtime = self
            await runtime?.lookForToolsAgain()
            return try await MainActor.run {
                guard let runtime else { throw RuntimeError.closed }
                runtime.applyConfig()
                return try JSON.string(runtime.toolRows())
            }
        })

        try registerCore(Command(
            id: "tools.install",
            title: "Install missing tools",
            summary: "Takes the next step to install the missing programs (argument names: some of them, comma "
                + "separated; all by default), then starts the plugins that were waiting. Returns JSON: step "
                + "(nothing, developer-tools: Apple's installer is open, homebrew: Homebrew must be installed in a "
                + "Terminal first, brew: installed with brew), installed and missing.",
            isInPalette: false
        ) { [weak self] arguments in
            nonisolated(unsafe) let runtime = self
            let names = arguments["names"]?.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            await runtime?.lookForToolsAgain()
            let (missing, brew) = try await MainActor.run {
                guard let runtime else { throw RuntimeError.closed }
                let missing = runtime.toolRows().filter { $0.path == nil && (names?.contains($0.name) ?? true) }
                return (missing.map(\.name), runtime.kernel.tools.locate("brew"))
            }
            let step = ToolInstaller.plan(
                missing: missing, hasDeveloperTools: ToolLocator.developerToolsInstalled(), hasHomebrew: brew != nil
            )
            switch step {
            case .developerTools: ToolInstaller.openDeveloperToolsInstaller()
            case .brew(let formulas): if let brew { try await ToolInstaller.brewInstall(formulas, brew: brew) }
            case .nothing, .homebrew: break
            }
            await runtime?.lookForToolsAgain()
            return try await MainActor.run {
                guard let runtime else { throw RuntimeError.closed }
                runtime.applyConfig()
                let still = Set(runtime.toolRows().filter { $0.path == nil }.map(\.name))
                return try JSON.string(ToolInstallResult(
                    step: step.name, installed: missing.filter { !still.contains($0) },
                    missing: missing.filter(still.contains)
                ))
            }
        })

        try registerCore(Command(
            id: "plugins.enable",
            title: "Enable plugin",
            summary: "Enables a plugin and starts it with what it requires; writes .loam/config.json. "
                + "Argument: id. Returns JSON with what started and why the plugin did not, if it did not.",
            isInPalette: false
        ) { [weak self] arguments in
            // The runtime is not `Sendable`; it is only touched on the main actor, inside the hop.
            nonisolated(unsafe) let runtime = self
            return try await MainActor.run {
                guard let runtime else { throw RuntimeError.closed }
                return try runtime.enable(arguments)
            }
        })

        try registerCore(Command(
            id: "plugins.disable",
            title: "Disable plugin",
            summary: "Disables a plugin and stops the plugins that require it; writes .loam/config.json. "
                + "Argument: id. Returns JSON {disabled, alsoDeactivated}; the others stay enabled in the config.",
            isInPalette: false
        ) { [weak self] arguments in
            // The runtime is not `Sendable`; it is only touched on the main actor, inside the hop.
            nonisolated(unsafe) let runtime = self
            return try await MainActor.run {
                guard let runtime else { throw RuntimeError.closed }
                return try runtime.disable(arguments)
            }
        })

        // Reading and changing plugin settings (Runtime+Settings.swift).
        try registerSettingsCommands()
        // Making, building, installing and removing the vault's own plugins (Runtime+PluginPackages.swift).
        if thirdPartyPlugins {
            try registerPluginPackageCommands()
            try registerPluginUpdateCommands()
        }
    }

    private func enable(_ arguments: [String: String]) throws -> String {
        let id = try arguments.require("id")
        try requireRegistered(id)
        if vaultPlugins[id] != nil { try pluginTrust.trust(id, in: kernel.vault.rootURL) }
        try config.mutate { $0.setEnabled(true, id) }
        let report = applyConfig()
        return try JSON.string(EnableResult(
            enabled: id,
            active: host.isActive(id),
            activated: report.activated,
            failed: report.failed[id],
            skipped: report.skipped[id] ?? safeModeReason(id)
        ))
    }

    private func disable(_ arguments: [String: String]) throws -> String {
        let id = try arguments.require("id")
        try requireRegistered(id)
        let dependents = host.dependents(of: id)
        try config.mutate { $0.setEnabled(false, id) }
        applyConfig()
        return try JSON.string(DisableResult(disabled: id, alsoDeactivated: dependents))
    }

    /// The registered plugins, then the vault's own plugins that are not loaded (off, failed, or safe mode), by id.
    func pluginRows() -> [PluginRow] {
        let registered = host.manifests.map { manifest in
            // A plugin from the vault may say what it is in plugin.json rather than in its Swift manifest.
            let file = vaultPlugins[manifest.id]?.manifest
            return PluginRow(
                id: manifest.id,
                name: manifest.name,
                version: manifest.version,
                description: manifest.description.isEmpty ? file?.description ?? "" : manifest.description,
                icon: manifest.icon ?? file?.icon,
                source: source(of: manifest.id),
                enabled: configEnables(manifest.id),
                active: host.isActive(manifest.id),
                provides: manifest.provides,
                requires: manifest.requires,
                optionalRequires: manifest.optionalRequires,
                requiresTools: host.requiredTools(of: manifest.id),
                optionalTools: host.optionalTools(of: manifest.id),
                missingTools: host.missingTools(of: manifest.id),
                failed: lastReport.failed[manifest.id],
                skipped: lastReport.skipped[manifest.id] ?? safeModeReason(manifest.id),
                loadError: nil
            )
        }
        let notLoaded = vaultPlugins.filter { !$0.value.isLoaded }.map { id, state in
            PluginRow(
                id: id,
                name: state.manifest?.name ?? id,
                version: state.manifest?.version ?? "",
                description: state.manifest?.description ?? "",
                icon: state.manifest?.icon,
                source: "vault",
                enabled: configEnables(id),
                active: false,
                provides: [],
                requires: [],
                optionalRequires: [],
                requiresTools: [],
                optionalTools: [],
                missingTools: [],
                failed: nil,
                skipped: safeModeReason(id),
                loadError: state.loadError
            )
        }
        return (registered + notLoaded).sorted { $0.id < $1.id }
    }

    /// The programs `toolRows` lists, by name.
    func toolNames() -> [String] {
        var names = Set(ToolCatalog.known)
        for manifest in host.manifests {
            names.formUnion(host.requiredTools(of: manifest.id) + host.optionalTools(of: manifest.id))
        }
        return names.sorted()
    }

    /// Forgets what the locator found and looks for every program again, off the main thread: it asks the login
    /// shell, which can take a moment. `applyConfig` then reads the answers from the cache, and `tools.install` finds
    /// brew.
    func lookForToolsAgain() async {
        nonisolated(unsafe) let runtime = self
        let (tools, names) = await MainActor.run { (runtime.kernel.tools, runtime.toolNames()) }
        tools.refresh()
        for name in names + ["brew"] { _ = tools.locate(name) }
    }

    /// Every program the plugins use, the ones Settings always lists first: what each is for and whether it is found.
    func toolRows() -> [ToolRow] {
        let manifests = host.manifests
        return toolNames().map { name in
            ToolRow(
                name: name,
                formula: ToolCatalog.formula(for: name),
                path: kernel.tools.locate(name)?.path,
                requiredBy: manifests.filter { host.requiredTools(of: $0.id).contains(name) }.map(\.id),
                optionalFor: manifests.filter { host.optionalTools(of: $0.id).contains(name) }.map(\.id)
            )
        }
    }

    /// Why an enabled plugin is held back by safe mode, nil otherwise.
    private func safeModeReason(_ id: String) -> String? {
        guard configEnables(id), let allowed = allowedInSafeMode(), !allowed.contains(id) else { return nil }
        if source(of: id) == "vault" { return "safe mode: plugins from the vault are not loaded" }
        return "safe mode: not in the allowlist"
    }

    private struct EnableResult: Encodable {
        let enabled: String
        let active: Bool
        let activated: [String]
        let failed: String?
        let skipped: String?
    }

    private struct DisableResult: Encodable {
        let disabled: String
        let alsoDeactivated: [String]
    }

    /// What `tools.install` did.
    struct ToolInstallResult: Encodable {
        let step: String
        /// The programs found now that were missing.
        let installed: [String]
        /// The programs still missing.
        let missing: [String]
    }

    /// One row of `tools.list`: a program the plugins use, where it is, and who needs or uses it.
    struct ToolRow: Encodable {
        let name: String
        /// The Homebrew formula that installs it; nil when it comes with the developer tools.
        let formula: String?
        /// Where it is, nil when it is not installed.
        let path: String?
        /// The plugins that cannot start without it.
        let requiredBy: [String]
        /// The plugins that use it when it is installed.
        let optionalFor: [String]
    }
}
