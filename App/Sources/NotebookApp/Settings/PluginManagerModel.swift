import Foundation
import Observation
import PluginKit
import LoamCore

/// One row of the plugin manager, decoded from the `plugins.list` command so the window and the CLI read the same
/// thing.
public struct PluginStatusRow: Decodable, Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let version: String
    /// What it does, in one line; nil from an older runtime.
    public let description: String?
    /// The SF Symbol it declares, if any (`PluginManifest.icon`, or `icon` in plugin.json).
    public let icon: String?
    /// What `.loam/config.json` says.
    public let enabled: Bool
    public let active: Bool
    public let provides: [String]
    public let requires: [String]
    public let optionalRequires: [String]
    public let failed: String?
    public let skipped: String?
    /// `builtin` or `vault` (from `.loam/plugins/`); nil from an older runtime, read as built in.
    public let source: String?
    /// Why a plugin from the vault could not be loaded (not built, built for another version, bad plugin.json).
    public let loadError: String?

    public var isFromVault: Bool { source == "vault" }

    public var state: PluginState {
        if active { return .active }
        if let failed { return .failed(failed) }
        if let skipped { return .skipped(skipped) }
        if let loadError { return .notLoaded(loadError) }
        return enabled ? .inactive : .disabled
    }
}

public enum PluginState: Equatable, Sendable {
    case active
    case disabled
    case failed(String)
    case skipped(String)
    /// Enabled, not running, and no reason recorded (the config changed since the last apply).
    case inactive
    /// A plugin from the vault whose code could not be loaded.
    case notLoaded(String)

    public var label: String {
        switch self {
        case .active: return String(localized: "Active")
        case .disabled: return String(localized: "Disabled")
        case .failed(let reason): return String(localized: "Failed: \(reason)")
        case .skipped(let reason): return String(localized: "Skipped: \(reason)")
        case .inactive: return String(localized: "Not running")
        case .notLoaded(let reason): return PluginManagerModel.describeLoadError(reason)
        }
    }
}

/// Turning a plugin off would also stop the plugins listed here: the user confirms first.
public struct DisableConfirmation: Equatable, Identifiable, Sendable {
    public let pluginID: String
    public let pluginName: String
    /// Ids of the active plugins that require it, deepest first.
    public let dependents: [String]
    public let dependentNames: [String]

    public var id: String { pluginID }
}

/// A service a plugin needs, uses or offers, with the plugins on the other side, for its page in Settings.
public struct PluginRequirement: Identifiable, Equatable, Sendable {
    public enum Kind: Sendable {
        /// In `requires`: the plugin does not start without it.
        case needs
        /// In `optionalRequires`: used when it is there.
        case uses
        /// In `provides`.
        case provides
    }

    /// A plugin on the other side.
    public struct Peer: Equatable, Sendable {
        public let id: String
        public let name: String
    }

    public let kind: Kind
    public let service: String
    /// For `needs` and `uses`, the plugins that provide the service; for `provides`, the plugins that use it; by name.
    public let peers: [Peer]

    public var names: [String] { peers.map(\.name) }
    public var id: String { "\(kind)/\(service)" }
}

/// What the Plugins tab of the settings window shows and does. Listing, enabling and disabling go through the
/// `plugins.*` commands; settings are written to `.loam/config.json` and announced with `PluginSettingsChanged`.
@MainActor
@Observable
public final class PluginManagerModel {
    public private(set) var rows: [PluginStatusRow] = []
    /// Set when turning a plugin off needs a confirmation; the view shows it as an alert.
    public var confirmation: DisableConfirmation?
    /// A short message about the last action that did not go as asked (a plugin that did not start, an error).
    public var notice: String?
    /// Bumped when settings are written, so views reading them refresh.
    private var settingsRevision = 0
    /// The notice the last refused setting left, which the next saved one clears.
    @ObservationIgnored private var settingNotice: String?

    @ObservationIgnored nonisolated(unsafe) private var removeSettingsListener: (() -> Void)?

    @ObservationIgnored public let session: ShellSession

    // MARK: Plugins from the vault (PluginManagerModel+Vault.swift)

    /// What each vault plugin's plugin.json says, by id, read again on every refresh.
    public internal(set) var vaultManifests: [String: ThirdPartyPluginManifest] = [:]
    /// Set when enabling a plugin from the vault (or after installing one): the view shows its permissions in a sheet.
    public var enableConfirmation: EnableConfirmation?
    /// Set when the user asked to remove a plugin from the vault; the view asks first.
    public var removeConfirmation: RemoveConfirmation?
    /// The plugins being built, installed or removed.
    public internal(set) var busy: [String: VaultActivity] = [:]
    /// The end of the log of a build that failed, by plugin id.
    public internal(set) var buildFailures: [String: String] = [:]
    /// Plugins rebuilt while their old code is loaded: the new build runs after a relaunch.
    public internal(set) var needsRelaunch: Set<String> = []
    /// The text of the "Install from URL" field.
    public var installURL = ""
    public internal(set) var isInstalling = false
    /// What the last update check found, by plugin id (PluginManagerModel+Updates.swift).
    public internal(set) var updates: [String: PluginUpdateInfo] = [:]
    public internal(set) var isCheckingUpdates = false
    /// The public catalog's plugins, empty until it was read (or when it cannot be).
    public internal(set) var catalog: [CatalogPlugin] = []
    /// Opens a new instance of the app on this vault and quits; nil when the app cannot (tests, no bundle).
    @ObservationIgnored public let relaunch: (@MainActor () -> Void)?

    public init(session: ShellSession, relaunch: (@MainActor () -> Void)? = nil) {
        self.session = session
        self.relaunch = relaunch
        // A change made elsewhere (the CLI, an agent, a synced config) refreshes an open page too.
        removeSettingsListener = session.runtime.kernel.events.on(PluginSettingsChanged.self) { @Sendable [weak self] _ in
            MainThread.sync { self?.settingsRevision += 1 }
        }
    }

    deinit { removeSettingsListener?() }

    public var isSafeMode: Bool { session.isSafeMode }

    /// Plugins compiled into the app.
    public var builtinRows: [PluginStatusRow] { rows.filter { !$0.isFromVault } }
    /// Plugins from `.loam/plugins/` of this vault.
    public var vaultRows: [PluginStatusRow] { rows.filter(\.isFromVault) }
    /// The built-in plugins with an interface, by name.
    public var featureRows: [PluginStatusRow] {
        Self.byName(builtinRows.filter { session.uiPluginIDs.contains($0.id) })
    }
    /// The built-in plugins without one, which features build on, by name.
    public var serviceRows: [PluginStatusRow] {
        Self.byName(builtinRows.filter { !session.uiPluginIDs.contains($0.id) })
    }

    public func row(_ id: String) -> PluginStatusRow? {
        rows.first { $0.id == id }
    }

    /// The manifest of a registered plugin; nil for a plugin from the vault whose code is not loaded.
    public func manifest(of id: String) -> PluginManifest? {
        session.runtime.host.manifests.first { $0.id == id }
    }

    nonisolated static func byName(_ rows: [PluginStatusRow]) -> [PluginStatusRow] {
        rows.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Reloads the rows from `plugins.list`, and the vault plugins' plugin.json.
    public func refresh() async {
        do {
            let json = try await session.run("plugins.list")
            rows = try JSONDecoder().decode([PluginStatusRow].self, from: Data(json.utf8))
        } catch {
            notice = String(localized: "Could not list the plugins: \(String(describing: error))")
        }
        let discovered = PluginLoader(rootURL: session.rootURL).discover().plugins
        vaultManifests = Dictionary(discovered.map { ($0.manifest.id, $0.manifest) }, uniquingKeysWith: { a, _ in a })
        if updates.isEmpty { updates = Dictionary(session.pluginUpdates.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a }) }
    }

    /// The programs the plugins run, and installing the missing ones.
    public var toolSetup: ToolSetup { session.toolSetup }

    /// The toggle of a row. Turning on a plugin from the vault shows its permissions first; turning off a plugin
    /// that others require asks for a confirmation first.
    public func setEnabled(_ enabled: Bool, id: String) async {
        notice = nil
        if enabled, rows.first(where: { $0.id == id })?.isFromVault == true {
            enableConfirmation = EnableConfirmation(
                pluginID: id,
                pluginName: name(of: id),
                permissions: permissions(of: id),
                justInstalled: false,
                buildLog: nil
            )
            return
        }
        if enabled { return await enable(id) }
        let dependents = session.runtime.host.dependents(of: id)
        if dependents.isEmpty { return await disable(id) }
        confirmation = DisableConfirmation(
            pluginID: id,
            pluginName: name(of: id),
            dependents: dependents,
            dependentNames: dependents.map(name(of:))
        )
    }

    /// The user confirmed turning off `confirmation.pluginID` and its dependents.
    public func confirm(_ confirmation: DisableConfirmation) async {
        if self.confirmation == confirmation { self.confirmation = nil }
        await disable(confirmation.pluginID)
    }

    public func cancelConfirmation() {
        confirmation = nil
    }

    func enable(_ id: String) async {
        do {
            let json = try await session.run("plugins.enable", ["id": id])
            let result = try JSONDecoder().decode(EnableResult.self, from: Data(json.utf8))
            if !result.active {
                let reason = result.failed ?? result.skipped ?? String(localized: "no reason given")
                notice = String(localized: "\(name(of: id)) did not start: \(reason)")
            }
        } catch {
            notice = String(localized: "Could not enable \(name(of: id)): \(String(describing: error))")
        }
        await refresh()
    }

    private func disable(_ id: String) async {
        do {
            _ = try await session.run("plugins.disable", ["id": id])
        } catch {
            notice = String(localized: "Could not disable \(name(of: id)): \(String(describing: error))")
        }
        await refresh()
    }

    func name(of id: String) -> String {
        rows.first { $0.id == id }?.name
            ?? session.runtime.host.manifests.first { $0.id == id }?.name
            ?? id
    }

    private struct EnableResult: Decodable {
        let active: Bool
        let failed: String?
        let skipped: String?
    }

    // MARK: Requirements

    /// What a plugin needs, uses and provides, with the names of the plugins on the other side.
    public func requirements(of id: String) -> [PluginRequirement] {
        guard let row = row(id) else { return [] }
        let manifests = session.runtime.host.manifests
        func peers(_ matching: (PluginManifest) -> Bool) -> [PluginRequirement.Peer] {
            manifests.filter(matching).map { PluginRequirement.Peer(id: $0.id, name: $0.name) }
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }
        func providers(_ service: String) -> [PluginRequirement.Peer] { peers { $0.provides.contains(service) } }
        func users(_ service: String) -> [PluginRequirement.Peer] {
            peers { $0.requires.contains(service) || $0.optionalRequires.contains(service) }
        }
        return row.requires.map { PluginRequirement(kind: .needs, service: $0, peers: providers($0)) }
            + row.optionalRequires.map { PluginRequirement(kind: .uses, service: $0, peers: providers($0)) }
            + row.provides.map { PluginRequirement(kind: .provides, service: $0, peers: users($0)) }
    }

    /// The turned-off plugins that provide a service `id` requires: why it was skipped, in words a person knows.
    public func disabledProviders(of id: String) -> [String] {
        guard let row = row(id) else { return [] }
        let names = row.requires.flatMap { service in
            rows.filter { !$0.enabled && manifest(of: $0.id)?.provides.contains(service) == true }.map(\.name)
        }
        return Array(Set(names)).sorted()
    }

    // MARK: Settings

    /// A plugin's settings, one field per key, stored or not (`Runtime.settingFields(for:)`, as `plugins.settings`).
    public func settingFields(for id: String) -> [SettingField] {
        _ = settingsRevision
        return session.runtime.settingFields(for: id)
    }

    /// Writes one setting (`key` empty: the whole value) to `.loam/config.json` and tells the plugin
    /// (`Runtime.setSetting`, as `plugins.set-setting`). A value the plugin cannot read is refused with a notice.
    public func updateSetting(_ key: String, to value: JSONValue, for id: String) {
        do {
            try session.runtime.setSetting(key, to: value, for: id)
            if notice == settingNotice { notice = nil }
            settingNotice = nil
        } catch {
            let reason = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
            notice = String(localized: "Could not save the setting: \(reason)")
            settingNotice = notice
        }
        settingsRevision += 1
    }

    /// The plugins with a row of their own in the settings sidebar, by name: the enabled ones that have settings, and
    /// `kept` (the plugin whose page is open, when its row was there) even once it is turned off or loses them.
    public func sidebarPluginIDs(keeping kept: String? = nil) -> [String] {
        Self.byName(rows.filter { ($0.enabled && !settingFields(for: $0.id).isEmpty) || $0.id == kept }).map(\.id)
    }

    /// A list or an object as indented JSON, for the read-only fields.
    public static func json(_ value: JSONValue) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(value) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }
}
