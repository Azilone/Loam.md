import Foundation
import PluginKit

/// `plugins.outdated`, `plugins.update`, `plugins.rollback`, `plugins.auto-update` and `plugins.catalog`: keeping the
/// vault's plugins up to date from where they were installed (docs/UPDATES.md). An update never runs new code with
/// permissions the user has not seen: a plugin whose update asks for more is disabled until it is enabled again.
extension Runtime {
    func registerPluginUpdateCommands() throws {
        try registerCore(Command(
            id: "plugins.outdated",
            title: "Check plugin updates",
            summary: "Asks each vault plugin's git repository (or the catalog) for a newer version, without downloading "
                + "it (network). Optional: id. Returns JSON [{id, installed, latest, kind (tag, commit or catalog), "
                + "source, updateAvailable, needsApp, autoUpdate, error}]; a plugin copied from a folder is left out.",
            isInPalette: false
        ) { [weak self] arguments in
            guard let self else { throw RuntimeError.closed }
            return try JSON.string(await outdated(only: arguments["id"]))
        })

        try registerCore(Command(
            id: "plugins.update",
            title: "Update plugin",
            summary: "Updates a vault plugin to its newest version and rebuilds it (network, writes files; takes minutes). "
                + "The previous version is kept for plugins.rollback; a failed build puts it back. A plugin that asks for "
                + "new permissions is disabled until enabled again. Argument: id, or all=true; optional: "
                + "same-permissions=true (skip an update asking for new permissions), build (\"false\" to skip the build). Returns JSON {id, updated, from, to, "
                + "addedPermissions, disabled, built, log, reason} (an array with all=true).",
            isInPalette: false
        ) { [weak self] arguments in
            guard let self else { throw RuntimeError.closed }
            let samePermissions = arguments["same-permissions"] == "true"
            let build = arguments["build"] != "false"
            if arguments["all"] == "true" {
                var results: [UpdateResult] = []
                for row in try await outdated(only: nil) where row.updateAvailable && row.needsApp == nil {
                    results.append(await updateReporting(row.id, samePermissions: samePermissions, build: build))
                }
                return try JSON.string(results)
            }
            return try JSON.string(try await update(try arguments.require("id"), samePermissions: samePermissions, build: build))
        })

        try registerCore(Command(
            id: "plugins.rollback",
            title: "Roll back plugin",
            summary: "Puts back the version of a vault plugin that its last update replaced, and rebuilds it (writes "
                + "files; takes minutes). Running it again goes forward again. Argument: id; optional: build. Returns JSON {id, updated, "
                + "from, to, addedPermissions, disabled, built, log}.",
            isInPalette: false
        ) { [weak self] arguments in
            guard let self else { throw RuntimeError.closed }
            return try JSON.string(try await rollback(try arguments.require("id"), build: arguments["build"] != "false"))
        })

        try registerCore(Command(
            id: "plugins.auto-update",
            title: "Plugin automatic updates",
            summary: "Turns automatic updates of a vault plugin installed from git on or off: the app's daily check then "
                + "applies updates that ask for no new permission (writes .loam-origin.json). Arguments: id, on (true or "
                + "false). Returns JSON {id, autoUpdate}.",
            isInPalette: false
        ) { [weak self] arguments in
            guard let self else { throw RuntimeError.closed }
            let id = try arguments.require("id")
            let folder = pluginFolder(id)
            guard var origin = try await origin(of: id) else {
                throw PluginPackageError.badSource("\(id) was not installed from git: it has no source to update from")
            }
            origin.autoUpdate = try arguments.require("on") == "true"
            try origin.write(in: folder)
            return try JSON.string(["id": id, "autoUpdate": origin.autoUpdate ? "true" : "false"])
        })

        try registerCore(Command(
            id: "plugins.catalog",
            title: "Plugin catalog",
            summary: "Lists the plugins of the public catalog (network), installable with plugins.install id=. Optional: "
                + "query (matches id, name and description), catalog (another catalog's URL or path). Returns JSON [{id, "
                + "name, description, author, repo, latest, permissions, needsApp, installed}].",
            isInPalette: false
        ) { [weak self] arguments in
            guard let self else { throw RuntimeError.closed }
            let catalog = try await PluginCatalog.fetch(arguments["catalog"].flatMap(Self.catalogURL) ?? PluginCatalog.defaultURL)
            let query = arguments["query"]?.lowercased() ?? ""
            let rows = catalog.plugins.filter { entry in
                query.isEmpty || [entry.id, entry.name, entry.description ?? ""].contains { $0.lowercased().contains(query) }
            }.map { entry -> CatalogRow in
                let latest = entry.latest()
                let installed = PluginLoader.manifest(in: self.pluginFolder(entry.id))?.version
                return CatalogRow(id: entry.id, name: entry.name, description: entry.description, author: entry.author,
                                  repo: entry.repo, latest: latest?.version ?? entry.newest?.version,
                                  permissions: (latest ?? entry.newest)?.permissions ?? [],
                                  needsApp: latest == nil ? entry.newest?.minSDK : nil, installed: installed)
            }
            return try JSON.string(rows)
        })
    }

    // MARK: Checking

    func pluginFolder(_ id: String) -> URL {
        kernel.vault.rootURL.appendingPathComponent(PluginLoader.pluginsFolder).appendingPathComponent(id)
    }

    /// The plugin's `.loam-origin.json`; for a plugin installed before origins were written, its clone's own git
    /// remote and commit, saved for next time. Nil for a plugin copied from a folder, or written in the vault.
    func origin(of id: String) async throws -> PluginOrigin? {
        let folder = pluginFolder(id)
        guard !id.isEmpty, !id.contains("/"), !id.hasPrefix("."),
              FileManager.default.fileExists(atPath: folder.appendingPathComponent(PluginLoader.manifestFile).path) else {
            throw PluginPackageError.notInstalled(id)
        }
        if let origin = PluginOrigin.read(in: folder) { return origin }
        guard FileManager.default.fileExists(atPath: folder.appendingPathComponent(".git").path),
              let remote = try? await Subprocess.output("git", ["-C", folder.path, "remote", "get-url", "origin"]),
              !remote.isEmpty,
              let commit = try? await Subprocess.output("git", ["-C", folder.path, "rev-parse", "HEAD"]) else { return nil }
        let tag = try? await Subprocess.output("git", ["-C", folder.path, "describe", "--tags", "--exact-match"])
        let origin = PluginOrigin(source: remote, ref: tag.flatMap { $0.isEmpty ? nil : $0 }, commit: commit)
        try? origin.write(in: folder)
        return origin
    }

    /// Where a plugin would go: the version or commit, and what it needs.
    struct Target {
        let ref: String?
        let label: String
        let pinned: String?
        let isNewer: Bool
        let needsApp: String?
        let kind: String
    }

    func target(for origin: PluginOrigin, installed: ThirdPartyPluginManifest, catalog: PluginCatalog?) async throws -> Target {
        let current = ReleaseVersion(installed.version)
        if origin.catalog, let entry = catalog?.entry(installed.id) {
            guard let latest = entry.latest() else {
                let newest = entry.newest
                let newer = newest.map { version in current.map { version.release > $0 } ?? true } ?? false
                return Target(ref: nil, label: newest?.version ?? installed.version, pinned: nil, isNewer: newer,
                              needsApp: newer ? newest?.minSDK : nil, kind: "catalog")
            }
            let newer = current.map { latest.release > $0 } ?? (latest.commit != origin.commit)
            return Target(ref: latest.tag, label: latest.version, pinned: latest.commit, isNewer: newer, needsApp: nil,
                          kind: "catalog")
        }
        if let tag = try await GitRemote.latestTag(origin.source) {
            let newer = current.map { tag.version > $0 } ?? (tag.tag != origin.ref)
            return Target(ref: tag.tag, label: tag.version.description, pinned: nil, isNewer: newer, needsApp: nil, kind: "tag")
        }
        // No release tags: the plugin follows its default branch, commit by commit.
        let head = try await GitRemote.headCommit(origin.source)
        return Target(ref: nil, label: head.map { String($0.prefix(7)) } ?? "?", pinned: nil,
                      isNewer: head != nil && head != origin.commit, needsApp: nil, kind: "commit")
    }

    func outdated(only: String?) async throws -> [OutdatedRow] {
        let ids = only.map { [$0] } ?? loader.discover().plugins.map(\.manifest.id)
        var rows: [OutdatedRow] = []
        var catalog: PluginCatalog?
        var catalogTried = false
        for id in ids {
            guard let origin = try await origin(of: id),
                  let installed = PluginLoader.manifest(in: pluginFolder(id)) else { continue }
            if origin.catalog, !catalogTried {
                catalogTried = true
                catalog = try? await PluginCatalog.fetch()
            }
            let installedLabel = origin.ref == nil ? String((origin.commit ?? "").prefix(7)) : installed.version
            do {
                let target = try await target(for: origin, installed: installed, catalog: catalog)
                rows.append(OutdatedRow(id: id, installed: installedLabel, latest: target.label, kind: target.kind,
                                        source: origin.source, updateAvailable: target.isNewer, needsApp: target.needsApp,
                                        autoUpdate: origin.autoUpdate, error: nil))
            } catch {
                rows.append(OutdatedRow(id: id, installed: installedLabel, latest: nil, kind: origin.catalog ? "catalog" : "tag",
                                        source: origin.source, updateAvailable: false, needsApp: nil,
                                        autoUpdate: origin.autoUpdate, error: error.localizedDescription))
            }
        }
        return rows
    }

    // MARK: Updating

    private func updateReporting(_ id: String, samePermissions: Bool, build: Bool) async -> UpdateResult {
        do {
            return try await update(id, samePermissions: samePermissions, build: build)
        } catch {
            return UpdateResult(id: id, updated: false, reason: error.localizedDescription)
        }
    }

    func update(_ id: String, samePermissions: Bool, build: Bool = true) async throws -> UpdateResult {
        guard let origin = try await origin(of: id) else {
            throw PluginPackageError.badSource("\(id) was not installed from git: it has no source to update from")
        }
        let folder = pluginFolder(id)
        guard let installed = PluginLoader.manifest(in: folder) else { throw PluginPackageError.notInstalled(id) }
        let catalog = origin.catalog ? try await PluginCatalog.fetch() : nil
        let target = try await target(for: origin, installed: installed, catalog: catalog)
        guard target.isNewer else { return UpdateResult(id: id, updated: false, from: installed.version, reason: "up to date") }
        if let sdk = target.needsApp { throw PluginPackageError.needsNewerApp(id, sdk) }

        let files = FileManager.default
        let staging = kernel.vault.rootURL.appendingPathComponent(".loam/cache/update-\(UUID().uuidString)", isDirectory: true)
        try files.createDirectory(at: staging.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? files.removeItem(at: staging) }
        let commit = try await fetchPackage(origin.source, ref: target.ref, into: staging)
        if let pinned = target.pinned, commit != pinned {
            throw PluginPackageError.badSource("\(origin.source) at \(target.ref ?? "HEAD") is commit \(commit ?? "?"), not "
                + "\(pinned) as the catalog says: refused")
        }
        let manifest = try Self.readManifest(in: staging, source: origin.source)
        guard manifest.id == id else {
            throw PluginPackageError.badSource("\(origin.source) now holds the plugin \"\(manifest.id)\", not \"\(id)\": refused")
        }
        if let problem = manifest.problem(folderName: id) { throw PluginPackageError.badSource("\(origin.source): \(problem)") }
        try Self.requireBuildable(manifest)
        let added = Self.addedPermissions(from: installed, to: manifest)
        if samePermissions, !added.isEmpty {
            return UpdateResult(id: id, updated: false, from: installed.version, to: manifest.version,
                                addedPermissions: added, reason: "asks for new permissions")
        }

        var next = origin
        next.ref = target.ref
        next.commit = commit
        try next.write(in: staging)
        return try await swapIn(staging, for: id, from: installed, to: manifest, added: added, build: build)
    }

    func rollback(_ id: String, build: Bool = true) async throws -> UpdateResult {
        let folder = pluginFolder(id)
        let previous = previousFolder(id)
        guard let installed = PluginLoader.manifest(in: folder) else { throw PluginPackageError.notInstalled(id) }
        guard let manifest = PluginLoader.manifest(in: previous) else {
            throw PluginPackageError.badSource("\(id) has no previous version to go back to")
        }
        // swapIn moves what it replaces to the previous folder, so the staging copy must live elsewhere.
        let staging = kernel.vault.rootURL.appendingPathComponent(".loam/cache/rollback-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.moveItem(at: previous, to: staging)
        defer { try? FileManager.default.removeItem(at: staging) }
        return try await swapIn(staging, for: id, from: installed, to: manifest,
                                added: Self.addedPermissions(from: installed, to: manifest), build: build)
    }

    func previousFolder(_ id: String) -> URL {
        kernel.vault.rootURL.appendingPathComponent(".loam/cache/previous").appendingPathComponent(id)
    }

    /// Replaces the plugin's folder with `staging`, keeping the old one as the previous version, and builds it. A failed
    /// build puts the old folder back (its library was never replaced). New permissions disable the plugin.
    private func swapIn(_ staging: URL, for id: String, from installed: ThirdPartyPluginManifest,
                        to manifest: ThirdPartyPluginManifest, added: [String], build: Bool) async throws -> UpdateResult {
        let files = FileManager.default
        let folder = pluginFolder(id)
        let previous = previousFolder(id)
        try files.createDirectory(at: previous.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? files.removeItem(at: previous)
        try files.moveItem(at: folder, to: previous)
        do {
            try files.moveItem(at: staging, to: folder)
        } catch {
            try? files.moveItem(at: previous, to: folder)
            throw error
        }

        let built = build ? await PluginBuilder(rootURL: kernel.vault.rootURL).build(id) : nil
        if let built, !built.ok {
            // Back to what was there: the new sources go to staging, so the caller's cleanup removes them.
            try? files.removeItem(at: staging)
            try? files.moveItem(at: folder, to: staging)
            try? files.moveItem(at: previous, to: folder)
            await refreshPlugins()
            return UpdateResult(id: id, updated: false, from: installed.version, to: manifest.version,
                                addedPermissions: added, built: false, log: built.log, reason: "the new version did not build")
        }
        nonisolated(unsafe) let runtime = self
        let wasEnabled = await MainActor.run { runtime.config.config.isExplicitlyEnabled(id) }
        if !added.isEmpty, wasEnabled { try await disableInConfig(id, onlyIfEnabled: true) }
        await refreshPlugins()
        return UpdateResult(id: id, updated: true, from: installed.version, to: manifest.version, addedPermissions: added,
                            disabled: !added.isEmpty && wasEnabled, built: built != nil, log: built?.log)
    }

    static func addedPermissions(from old: ThirdPartyPluginManifest, to new: ThirdPartyPluginManifest) -> [String] {
        let before = Set(old.permissions)
        return new.permissions.filter { !before.contains($0) }
    }

    // MARK: Results

    struct OutdatedRow: Codable, Equatable, Sendable {
        let id: String
        let installed: String
        let latest: String?
        let kind: String
        let source: String
        let updateAvailable: Bool
        let needsApp: String?
        let autoUpdate: Bool
        let error: String?
    }

    struct UpdateResult: Codable, Equatable, Sendable {
        var id: String
        var updated: Bool
        var from: String?
        var to: String?
        var addedPermissions: [String] = []
        var disabled = false
        var built = false
        var log: String?
        var reason: String?
    }

    private struct CatalogRow: Encodable {
        let id: String
        let name: String
        let description: String?
        let author: String?
        let repo: String
        let latest: String?
        let permissions: [String]
        let needsApp: String?
        let installed: String?
    }
}
