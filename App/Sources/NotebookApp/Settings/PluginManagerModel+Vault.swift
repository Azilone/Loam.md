import Foundation
import PluginKit
import LoamCore

/// Before a plugin from the vault runs, the user sees what it declares it does (docs/PERMISSIONS.md).
public struct EnableConfirmation: Equatable, Identifiable, Sendable {
    public let pluginID: String
    public let pluginName: String
    /// Riskiest first.
    public let permissions: [DeclaredPermission]
    /// Shown right after `plugins.install`: "Enable it now?" rather than "Enable it?".
    public let justInstalled: Bool
    /// The end of the build log when the install could not build it: enabling waits for a successful Rebuild.
    public let buildLog: String?

    public var id: String { pluginID }
    public var canEnable: Bool { buildLog == nil }
    public var highRisk: [DeclaredPermission] { permissions.filter { $0.risk == .high } }
}

public struct RemoveConfirmation: Equatable, Identifiable, Sendable {
    public let pluginID: String
    public let pluginName: String

    public var id: String { pluginID }
}

public enum VaultActivity: Equatable, Sendable {
    case building
    case removing
    case updating

    public var label: String {
        switch self {
        case .building: return String(localized: "Building…")
        case .updating: return String(localized: "Updating…")
        case .removing: return String(localized: "Removing…")
        }
    }
}

/// The commands behind the vault plugins' buttons. The runtime registers them (WP41); until it does, or in an app
/// that leaves them out, their buttons are disabled with a tooltip saying why.
public enum VaultCommand: String, CaseIterable, Sendable {
    case build = "plugins.build"
    case install = "plugins.install"
    case remove = "plugins.remove"
    case outdated = "plugins.outdated"
    case update = "plugins.update"
    case rollback = "plugins.rollback"
    case autoUpdate = "plugins.auto-update"
    case catalog = "plugins.catalog"
}

/// Plugins from `.loam/plugins/`: permissions, enable after consent, build, install, remove. Everything goes through
/// the `plugins.*` commands, by id, so the CLI and agents do the same thing.
extension PluginManagerModel {
    nonisolated static let explanation = String(
        localized: "Plugins from this vault run with the same access as the app. Only enable plugins you trust."
    )

    // MARK: What a plugin is

    /// The plugin.json id a row belongs to: its own, or the package's for a type like `hello.extra`.
    public func packageID(of id: String) -> String {
        if vaultManifests[id] != nil { return id }
        return vaultManifests.keys.filter { id.hasPrefix($0 + ".") }.max { $0.count < $1.count } ?? id
    }

    /// What the plugin declares, riskiest first: plugin.json for a plugin from the vault, the manifest for a built-in.
    public func permissions(of id: String) -> [DeclaredPermission] {
        if rows.first(where: { $0.id == id })?.isFromVault == true || vaultManifests[id] != nil {
            return vaultManifests[packageID(of: id)]?.declaredPermissions ?? []
        }
        return session.runtime.host.manifests.first { $0.id == id }?.declaredPermissions ?? []
    }

    /// `.loam/plugins/<id>`, shown on the row and revealed in Finder.
    public func folderPath(of id: String) -> String {
        "\(PluginLoader.pluginsFolder)/\(packageID(of: id))"
    }

    public func folderURL(of id: String) -> URL {
        session.rootURL.appendingPathComponent(folderPath(of: id), isDirectory: true)
    }

    /// The image a plugin from the vault names as its icon (`iconFile` in plugin.json), inside its folder; nil when it
    /// names none. The view falls back to the symbol when the file cannot be read.
    public func iconFileURL(of id: String) -> URL? {
        vaultManifests[packageID(of: id)]?.iconFileURL(in: folderURL(of: id))
    }

    /// A load error in words, with what to do.
    nonisolated static func describeLoadError(_ reason: String) -> String {
        if reason.hasPrefix("built for another version") {
            return String(localized: "Built for another version of the app. Rebuild it.")
        }
        if reason.hasPrefix("needs a newer version") {
            return String(localized: "Needs a newer version of Loam. Update the app to use it.")
        }
        if reason.hasPrefix("not built") { return String(localized: "Not built yet. Build it to use it.") }
        if reason.contains("relaunch the app") {
            return String(localized: "Rebuilt. Relaunch to load the new build.")
        }
        return String(localized: "Cannot be loaded: \(reason)")
    }

    /// True when the row's code is not built: its rebuild button says Build.
    public func isNotBuilt(_ row: PluginStatusRow) -> Bool {
        row.loadError?.hasPrefix("not built") == true
    }

    // MARK: Commands

    public func isAvailable(_ command: VaultCommand) -> Bool {
        session.runtime.kernel.commands.command(id: command.rawValue) != nil
    }

    /// The tooltip of a disabled button, nil when its command is there.
    public func unavailableHelp(_ command: VaultCommand) -> String? {
        isAvailable(command) ? nil
            : String(localized: "This version of the app has no \(command.rawValue) command.")
    }

    // MARK: Enable

    /// The user read the permissions and chose Enable.
    public func confirmEnable(_ confirmation: EnableConfirmation) async {
        if enableConfirmation == confirmation { enableConfirmation = nil }
        guard confirmation.canEnable else { return }
        await enable(confirmation.pluginID)
    }

    public func cancelEnable() {
        enableConfirmation = nil
    }

    // MARK: Build

    /// Runs `plugins.build id=`. An enabled plugin is then loaded at once, unless its old build is already loaded in
    /// this process (code cannot be unloaded): the row then offers a relaunch.
    public func rebuild(_ id: String) async {
        let package = packageID(of: id)
        guard isAvailable(.build), busy[package] == nil else { return }
        notice = nil
        let loadedBefore = isLoaded(package)
        busy[package] = .building
        buildFailures[package] = nil
        defer { busy[package] = nil }
        do {
            let json = try await session.run(VaultCommand.build.rawValue, ["id": package])
            let result = try JSONDecoder().decode(BuildResult.self, from: Data(json.utf8))
            guard result.ok else {
                buildFailures[package] = Self.lastLines(result.log ?? "")
                notice = String(localized: "\(name(of: package)) could not be built.")
                return await rescan()
            }
            if loadedBefore { needsRelaunch.insert(package) }
        } catch {
            buildFailures[package] = String(describing: error)
            notice = String(localized: "\(name(of: package)) could not be built.")
        }
        // Applying the config loads the new build when the plugin is enabled and no old build is loaded.
        await rescan()
        if rows.first(where: { $0.id == package })?.loadError?.contains("relaunch the app") == true {
            needsRelaunch.insert(package)
        }
    }

    // MARK: Install

    /// Runs `plugins.install url=` with the field's text, then shows the plugin's permissions and asks whether to
    /// enable it now. Installing never enables.
    public func install() async {
        let url = installURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !url.isEmpty, isAvailable(.install), !isInstalling else { return }
        notice = nil
        isInstalling = true
        defer { isInstalling = false }
        do {
            let json = try await session.run(VaultCommand.install.rawValue, ["url": url])
            let result = try JSONDecoder().decode(InstallResult.self, from: Data(json.utf8))
            installURL = ""
            await rescan()
            enableConfirmation = EnableConfirmation(
                pluginID: result.id,
                pluginName: name(of: result.id),
                permissions: DeclaredPermission.list(result.permissions),
                justInstalled: true,
                buildLog: result.built ? nil : Self.lastLines(result.log ?? String(localized: "It was not built."))
            )
        } catch {
            notice = String(localized: "Could not install \(url): \(String(describing: error))")
            await rescan()
        }
    }

    // MARK: Remove

    public func requestRemove(_ id: String) {
        let package = packageID(of: id)
        removeConfirmation = RemoveConfirmation(pluginID: package, pluginName: name(of: package))
    }

    public func cancelRemove() {
        removeConfirmation = nil
    }

    /// Runs `plugins.remove id=`, which moves the plugin's folder to the Trash.
    public func confirmRemove(_ confirmation: RemoveConfirmation) async {
        if removeConfirmation == confirmation { removeConfirmation = nil }
        let id = confirmation.pluginID
        guard isAvailable(.remove), busy[id] == nil else { return }
        notice = nil
        let loadedBefore = isLoaded(id)
        busy[id] = .removing
        defer { busy[id] = nil }
        do {
            _ = try await session.run(VaultCommand.remove.rawValue, ["id": id])
            buildFailures[id] = nil
            notice = loadedBefore
                ? String(localized: "\(confirmation.pluginName) was moved to the Trash. Its code stays loaded until you relaunch.")
                : String(localized: "\(confirmation.pluginName) was moved to the Trash.")
            if loadedBefore { needsRelaunch.insert(id) }
        } catch {
            notice = String(localized: "Could not remove \(confirmation.pluginName): \(String(describing: error))")
        }
        await rescan()
    }

    // MARK: Helpers

    /// Has the runtime read `.loam/plugins/` again (a plugin was added or removed on disk), then refreshes the rows.
    /// Applying the config also loads what it enables that is not loaded yet, as on any config change.
    func rescan() async {
        session.runtime.applyConfig()
        await refresh()
    }

    /// Whether the plugin's code is loaded in this process (some type of it is registered with the host).
    func isLoaded(_ package: String) -> Bool {
        session.runtime.host.manifests.contains { $0.id == package || $0.id.hasPrefix(package + ".") }
    }

    /// The last lines of a build log, enough to see the error.
    nonisolated static func lastLines(_ log: String, count: Int = 12) -> String {
        let lines = log.split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
            .reversed()
            .drop { $0.trimmingCharacters(in: .whitespaces).isEmpty }
            .reversed()
        return lines.suffix(count).joined(separator: "\n")
    }

    private struct BuildResult: Decodable {
        let ok: Bool
        let log: String?
    }

    private struct InstallResult: Decodable {
        let id: String
        let permissions: [String]
        let built: Bool
        let log: String?
    }
}
