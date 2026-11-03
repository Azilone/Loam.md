import Foundation
import PluginKit
import LoamCore

/// One plugin of the public catalog, as `plugins.catalog` lists it.
public struct CatalogPlugin: Decodable, Equatable, Identifiable, Sendable {
    public let id: String
    public let name: String
    public let description: String?
    public let author: String?
    public let repo: String
    public let latest: String?
    public let permissions: [String]
    public let needsApp: String?
    public let installed: String?
}

/// Updating the vault's plugins from Settings: the same `plugins.outdated`, `plugins.update`, `plugins.rollback` and
/// `plugins.auto-update` commands as the CLI (docs/UPDATES.md).
extension PluginManagerModel {
    /// The newer version waiting for a plugin, nil when it is up to date or was not checked.
    public func availableUpdate(of id: String) -> PluginUpdateInfo? {
        guard let info = updates[packageID(of: id)], info.updateAvailable else { return nil }
        return info
    }

    /// Whether a plugin was installed from a source it can be updated from.
    public func isUpdatable(_ id: String) -> Bool { updates[packageID(of: id)] != nil }

    /// Whether the last update left the version it replaced, for Roll Back.
    public func hasPreviousVersion(_ id: String) -> Bool {
        let folder = session.rootURL.appendingPathComponent(".loam/cache/previous/\(packageID(of: id))")
        return FileManager.default.fileExists(atPath: folder.appendingPathComponent(PluginLoader.manifestFile).path)
    }

    /// Asks every plugin's source for a newer version (network).
    public func checkForUpdates() async {
        guard isAvailable(.outdated), !isCheckingUpdates else { return }
        isCheckingUpdates = true
        defer { isCheckingUpdates = false }
        let rows = await session.checkPluginUpdates(announce: false)
        updates = Dictionary(rows.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        if let failed = rows.first(where: { $0.error != nil }) {
            notice = String(localized: "Could not check \(name(of: failed.id)) for updates: \(failed.error ?? "")")
        }
    }

    /// Runs `plugins.update id=`. New permissions leave the plugin off: the permissions sheet then asks to enable it.
    public func update(_ id: String) async {
        await replace(id, with: .update)
    }

    /// Runs `plugins.rollback id=`.
    public func rollBack(_ id: String) async {
        await replace(id, with: .rollback)
    }

    public func setAutoUpdate(_ on: Bool, id: String) async {
        let package = packageID(of: id)
        do {
            _ = try await session.run(VaultCommand.autoUpdate.rawValue, ["id": package, "on": on ? "true" : "false"])
            await checkForUpdates()
        } catch {
            notice = String(localized: "Could not change automatic updates: \(String(describing: error))")
        }
    }

    /// Reads the public catalog; it stays empty when the catalog cannot be reached.
    public func loadCatalog() async {
        guard isAvailable(.catalog),
              let json = try? await session.run(VaultCommand.catalog.rawValue),
              let rows = try? JSONDecoder().decode([CatalogPlugin].self, from: Data(json.utf8)) else { return }
        catalog = rows
    }

    /// Runs `plugins.install id=` for a catalog plugin, then asks whether to enable it, as an install from a URL.
    public func install(fromCatalog plugin: CatalogPlugin) async {
        guard isAvailable(.install), !isInstalling, busy[plugin.id] == nil else { return }
        notice = nil
        isInstalling = true
        busy[plugin.id] = .building
        defer {
            isInstalling = false
            busy[plugin.id] = nil
        }
        do {
            let json = try await session.run(VaultCommand.install.rawValue, ["id": plugin.id])
            let result = try JSONDecoder().decode(CatalogInstall.self, from: Data(json.utf8))
            await rescan()
            await loadCatalog()
            await checkForUpdates()
            enableConfirmation = EnableConfirmation(
                pluginID: result.id, pluginName: name(of: result.id),
                permissions: DeclaredPermission.list(result.permissions), justInstalled: true,
                buildLog: result.built ? nil : Self.lastLines(result.log ?? String(localized: "It was not built."))
            )
        } catch {
            notice = String(localized: "Could not install \(plugin.name): \(String(describing: error))")
            await rescan()
        }
    }

    private func replace(_ id: String, with command: VaultCommand) async {
        let package = packageID(of: id)
        guard isAvailable(command), busy[package] == nil else { return }
        notice = nil
        let loadedBefore = isLoaded(package)
        busy[package] = .updating
        buildFailures[package] = nil
        defer { busy[package] = nil }
        do {
            let json = try await session.run(command.rawValue, ["id": package])
            let result = try JSONDecoder().decode(UpdateResult.self, from: Data(json.utf8))
            guard result.updated else {
                if let log = result.log { buildFailures[package] = Self.lastLines(log) }
                notice = String(localized: "\(name(of: package)) was not updated: \(result.reason ?? "")")
                return await rescan()
            }
            if loadedBefore { needsRelaunch.insert(package) }
            await rescan()
            await checkForUpdates()
            if result.disabled {
                enableConfirmation = EnableConfirmation(
                    pluginID: package, pluginName: name(of: package),
                    permissions: permissions(of: package), justInstalled: false, buildLog: nil
                )
                notice = String(localized: "\(name(of: package)) \(result.to ?? "") asks for new permissions: \(result.addedPermissions.joined(separator: ", ")). It stays off until you enable it.")
            }
        } catch {
            notice = String(localized: "Could not update \(name(of: package)): \(String(describing: error))")
            await rescan()
        }
    }

    private struct CatalogInstall: Decodable {
        let id: String
        let permissions: [String]
        let built: Bool
        let log: String?
    }

    private struct UpdateResult: Decodable {
        let updated: Bool
        let to: String?
        let addedPermissions: [String]
        let disabled: Bool
        let log: String?
        let reason: String?
    }
}
