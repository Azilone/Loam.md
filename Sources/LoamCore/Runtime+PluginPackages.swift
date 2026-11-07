import Foundation
import PluginKit

public enum PluginPackageError: Error, Equatable, LocalizedError {
    case invalidID(String)
    case reservedName(String)
    case alreadyInstalled(String)
    case notInstalled(String)
    case builtin(String)
    case badSource(String)
    case needsNewerApp(String, String)

    public var errorDescription: String? {
        switch self {
        case .invalidID(let id):
            return "invalid plugin id \"\(id)\": use kebab-case starting with a letter, such as \"word-count\""
        case .reservedName(let id):
            return "the plugin id \"\(id)\" would reuse the name of a module of the app; pick another"
        case .alreadyInstalled(let id):
            return "a plugin \"\(id)\" is already installed (\(PluginLoader.pluginsFolder)/\(id)); remove it first with "
                + "`loam plugin remove \(id)`"
        case .notInstalled(let id):
            return "no plugin \"\(id)\" in \(PluginLoader.pluginsFolder)/"
        case .builtin(let id):
            return "\"\(id)\" is a built-in plugin; disable it instead with `loam plugins.disable id=\(id)`"
        case .badSource(let message):
            return message
        case .needsNewerApp(let id, let sdk):
            return "\(id) needs a newer version of Loam (plugin SDK \(sdk)); update the app first"
        }
    }
}

/// The `plugins.new`, `plugins.build`, `plugins.install` and `plugins.remove` commands: making, compiling, installing
/// and removing the vault's own plugins (`.loam/plugins/<id>/`). Builds take minutes; the handlers wait for them off
/// the main actor, and only hop to it to refresh the plugin list (`applyConfig`). None of them enables a plugin.
extension Runtime {
    func registerPluginPackageCommands() throws {
        try registerCore(Command(
            id: "plugins.new",
            title: "New plugin",
            summary: "Creates a plugin package to edit in .loam/plugins/<id>/ (writes files): Package.swift, the source, "
                + "a test, plugin.json, a README. Arguments: id (kebab-case); optional: name, ui (\"true\" for a plugin "
                + "with a panel). Returns JSON {id, path}. Build it with plugins.build.",
            isInPalette: false
        ) { [weak self] arguments in
            guard let root = self?.kernel.vault.rootURL else { throw RuntimeError.closed }
            let template = try PluginTemplate(id: try arguments.require("id"), name: arguments["name"],
                                              ui: arguments["ui"] == "true")
            try await self?.requireNotTaken(template.id)
            let folder = root.appendingPathComponent(PluginLoader.pluginsFolder).appendingPathComponent(template.id)
            for (path, text) in template.files {
                let url = folder.appendingPathComponent(path)
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try text.write(to: url, atomically: true, encoding: .utf8)
            }
            await self?.refreshPlugins()
            return try JSON.string(NewResult(id: template.id, path: folder.path))
        })

        try registerCore(Command(
            id: "plugins.build",
            title: "Build plugin",
            summary: "Compiles a plugin from .loam/plugins/<id>/ into .loam/cache/plugins/<id>/ with the app's SDK and the "
                + "swift on the PATH (writes the cache; takes minutes). Argument: id, or all=true. Returns JSON {id, ok, "
                + "library, log} (an array with all=true); log is the last 40 lines. A loaded plugin needs a relaunch.",
            isInPalette: false
        ) { [weak self] arguments in
            guard let self else { throw RuntimeError.closed }
            let builder = PluginBuilder(rootURL: kernel.vault.rootURL, tools: kernel.tools)
            if arguments["all"] == "true" {
                var results: [PluginBuilder.Result] = []
                for plugin in loader.discover().plugins { results.append(await builder.build(plugin.manifest.id)) }
                await refreshPlugins()
                return try JSON.string(results)
            }
            let id = try arguments.require("id")
            guard FileManager.default.fileExists(atPath: builder.packageURL(id).path) else {
                throw PluginPackageError.notInstalled(id)
            }
            let result = await builder.build(id)
            await refreshPlugins()
            return try JSON.string(result)
        })

        try registerCore(Command(
            id: "plugins.test",
            title: "Test plugin",
            summary: "Runs the tests of a plugin of .loam/plugins/<id>/ (swift test against the app's SDK; writes the "
                + "cache; takes minutes). Argument: id. Returns JSON {id, ok, log}; log is the last 40 lines.",
            isInPalette: false
        ) { [weak self] arguments in
            guard let self else { throw RuntimeError.closed }
            let builder = PluginBuilder(rootURL: kernel.vault.rootURL, tools: kernel.tools)
            let id = try arguments.require("id")
            guard FileManager.default.fileExists(atPath: builder.packageURL(id).path) else {
                throw PluginPackageError.notInstalled(id)
            }
            return try JSON.string(await builder.test(id))
        })

        try registerCore(Command(
            id: "plugins.install",
            title: "Install plugin",
            summary: "Installs a plugin from a git URL, a local folder or the plugin catalog into .loam/plugins/<id>/ and "
                + "builds it (writes files; takes minutes). From git, its highest release tag. Never enables it: check its "
                + "permissions first. Argument: url, or id (a catalog plugin); optional: ref (a tag or branch), build "
                + "(\"false\" to skip the build), catalog (another catalog's URL). Returns JSON {id, path, version, "
                + "permissions, built, log}.",
            isInPalette: false
        ) { [weak self] arguments in
            guard let self else { throw RuntimeError.closed }
            return try await install(arguments)
        })

        try registerCore(Command(
            id: "plugins.remove",
            title: "Remove plugin",
            summary: "Removes a plugin from the vault: moves .loam/plugins/<id> to .trash/plugins/, deletes its compiled "
                + "cache and disables it in .loam/config.json (writes files). Argument: id. Returns JSON {id, trashedTo}. "
                + "A loaded plugin's code stays until the app relaunches.",
            isInPalette: false
        ) { [weak self] arguments in
            guard let self else { throw RuntimeError.closed }
            return try await remove(try arguments.require("id"))
        })
    }

    /// Re-reads `.loam/plugins/` and the config on the main actor, where the host lives.
    func refreshPlugins() async {
        nonisolated(unsafe) let runtime = self
        await MainActor.run { _ = runtime.applyConfig() }
    }

    /// Writes `"enabled": false` for `id` on the main actor, where the config is changed.
    func disableInConfig(_ id: String, onlyIfEnabled: Bool) async throws {
        nonisolated(unsafe) let runtime = self
        try await MainActor.run {
            guard !onlyIfEnabled || runtime.config.config.isExplicitlyEnabled(id) else { return }
            try runtime.config.mutate { $0.setEnabled(false, id) }
        }
    }

    /// Throws when `id` names a built-in plugin or an installed one.
    func requireNotTaken(_ id: String) async throws {
        nonisolated(unsafe) let runtime = self
        let builtin = await MainActor.run { runtime.host.manifests.contains { $0.id == id } && runtime.source(of: id) == "builtin" }
        if builtin { throw PluginPackageError.builtin(id) }
        let folder = kernel.vault.rootURL.appendingPathComponent(PluginLoader.pluginsFolder).appendingPathComponent(id)
        if FileManager.default.fileExists(atPath: folder.path) { throw PluginPackageError.alreadyInstalled(id) }
    }

    /// `plugins.install`: `url` (a git URL or a folder), or `id` for a plugin of the catalog. From git, the highest
    /// release tag is installed (`ref` picks another tag or a branch); without tags, the default branch.
    private func install(_ arguments: [String: String]) async throws -> String {
        var source: String
        var ref = arguments["ref"]
        var pinned: String?
        var fromCatalog = false
        if let url = arguments["url"], !url.isEmpty {
            source = url
        } else {
            let id = try arguments.require("id")
            let catalog = try await PluginCatalog.fetch(arguments["catalog"].flatMap(Self.catalogURL) ?? PluginCatalog.defaultURL)
            guard let entry = catalog.entry(id) else { throw PluginPackageError.badSource("no plugin \"\(id)\" in the catalog") }
            guard let version = entry.latest() else {
                throw PluginPackageError.badSource("\(id) needs a newer version of Loam (plugin SDK \(entry.newest?.minSDK ?? "?"))")
            }
            source = entry.repo
            ref = version.tag
            pinned = version.commit
            fromCatalog = true
        }
        let root = kernel.vault.rootURL
        let files = FileManager.default
        // Staged in the vault's cache, so the final move stays on one volume.
        let staging = root.appendingPathComponent(".loam/cache/install-\(UUID().uuidString)", isDirectory: true)
        try files.createDirectory(at: staging.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? files.removeItem(at: staging) }

        // An unreachable source fails in the clone below, with git's own words.
        if ref == nil, Self.isGitSource(source) { ref = (try? await GitRemote.latestTag(source))??.tag }
        let commit = try await fetchPackage(source, ref: ref, into: staging)
        if let pinned, commit != pinned {
            throw PluginPackageError.badSource("\(source) at \(ref ?? "HEAD") is commit \(commit ?? "?"), not \(pinned) as the "
                + "catalog says: refused")
        }
        let manifest = try Self.readManifest(in: staging, source: source)
        if let problem = manifest.problem(folderName: manifest.id) {
            throw PluginPackageError.badSource("\(source): \(problem)")
        }
        try Self.requireBuildable(manifest)
        try await requireNotTaken(manifest.id)

        let folder = root.appendingPathComponent(PluginLoader.pluginsFolder).appendingPathComponent(manifest.id)
        try files.createDirectory(at: folder.deletingLastPathComponent(), withIntermediateDirectories: true)
        try files.moveItem(at: staging, to: folder)
        if commit != nil {
            let origin = PluginOrigin(source: source, ref: ref, commit: commit, catalog: fromCatalog)
            try origin.write(in: folder)
        }
        // Installing never enables: a leftover "enabled": true would load the plugin before its permissions are seen.
        try await disableInConfig(manifest.id, onlyIfEnabled: true)

        var result = InstallResult(id: manifest.id, path: folder.path, version: manifest.version,
                                   permissions: manifest.permissions, built: false, log: nil)
        if arguments["build"] != "false" {
            let built = await PluginBuilder(rootURL: root).build(manifest.id)
            result.built = built.ok
            result.log = built.log
        }
        await refreshPlugins()
        return try JSON.string(result)
    }

    /// A git URL or a local repository, as opposed to a plain folder that is copied.
    static func isGitSource(_ source: String) -> Bool {
        if source.contains("://") || source.hasPrefix("git@") { return true }
        let local = URL(fileURLWithPath: (source as NSString).expandingTildeInPath)
        return FileManager.default.fileExists(atPath: local.appendingPathComponent(".git").path)
            || local.pathExtension == "git"
    }

    static func catalogURL(_ value: String) -> URL? {
        value.isEmpty ? nil : value.contains("://") ? URL(string: value) : URL(fileURLWithPath: value)
    }

    /// Puts the plugin's files into `staging` (which must not exist): a shallow clone at `ref` for a git source, a copy
    /// for a folder. Returns the commit checked out, nil for a copied folder.
    func fetchPackage(_ source: String, ref: String?, into staging: URL) async throws -> String? {
        let files = FileManager.default
        let local = URL(fileURLWithPath: (source as NSString).expandingTildeInPath)
        guard Self.isGitSource(source) else {
            var isDirectory: ObjCBool = false
            guard files.fileExists(atPath: local.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                throw PluginPackageError.badSource("\(source) is neither a git URL nor a folder")
            }
            try files.copyItem(at: local, to: staging)
            try? files.removeItem(at: staging.appendingPathComponent(".build"))
            return nil
        }
        let root = kernel.vault.rootURL
        let log = root.appendingPathComponent(".loam/cache/install-\(UUID().uuidString).log")
        defer { try? files.removeItem(at: log) }
        var arguments = ["clone", "--depth", "1"]
        if let ref { arguments += ["--branch", ref] }
        let status = try await Subprocess.run("git", arguments + ["--", source, staging.path], log: log)
        guard status == 0 else {
            let output = Subprocess.lastLines((try? String(contentsOf: log, encoding: .utf8)) ?? "", 10)
            throw PluginPackageError.badSource("git clone \(source) failed: \(output)")
        }
        return try await Subprocess.output("git", ["-C", staging.path, "rev-parse", "HEAD"])
    }

    static func readManifest(in folder: URL, source: String) throws -> ThirdPartyPluginManifest {
        guard let data = FileManager.default.contents(atPath: folder.appendingPathComponent(PluginLoader.manifestFile).path) else {
            throw PluginPackageError.badSource("\(source) has no plugin.json at its root: not a Loam plugin")
        }
        do {
            return try JSONDecoder().decode(ThirdPartyPluginManifest.self, from: data)
        } catch {
            throw PluginPackageError.badSource("\(source): plugin.json cannot be read: \(error)")
        }
    }

    /// Throws when the plugin needs a newer plugin SDK than this app's (`minSDK`), or another major version.
    static func requireBuildable(_ manifest: ThirdPartyPluginManifest, sdk: PluginSDKVersion = .current) throws {
        guard let required = manifest.requiredSDK else { return }
        if required.major != sdk.major || sdk < required {
            throw PluginPackageError.needsNewerApp(manifest.id, required.description)
        }
    }

    private func remove(_ id: String) async throws -> String {
        let root = kernel.vault.rootURL
        let files = FileManager.default
        let folder = root.appendingPathComponent(PluginLoader.pluginsFolder).appendingPathComponent(id)
        // The id names folders: refuse anything that could leave .loam/plugins/.
        guard !id.isEmpty, !id.contains("/"), !id.hasPrefix("."), files.fileExists(atPath: folder.path) else {
            nonisolated(unsafe) let runtime = self
            let builtin = await MainActor.run { runtime.host.manifests.contains { $0.id == id } }
            throw builtin ? PluginPackageError.builtin(id) : PluginPackageError.notInstalled(id)
        }
        try await disableInConfig(id, onlyIfEnabled: false)

        let trash = root.appendingPathComponent(".trash/plugins", isDirectory: true)
        try files.createDirectory(at: trash, withIntermediateDirectories: true)
        var target = trash.appendingPathComponent(id)
        var counter = 2
        while files.fileExists(atPath: target.path) {
            target = trash.appendingPathComponent("\(id) \(counter)")
            counter += 1
        }
        try files.moveItem(at: folder, to: target)
        for disposable in [PluginLoader.cacheFolder, PluginBuilder.buildFolder] {
            try? files.removeItem(at: root.appendingPathComponent(disposable).appendingPathComponent(id))
        }
        try? files.removeItem(at: root.appendingPathComponent(PluginBuilder.buildFolder).appendingPathComponent("\(id).log"))
        await refreshPlugins()
        let relative = String(target.path.dropFirst(root.path.count + 1))
        return try JSON.string(RemoveResult(id: id, trashedTo: relative))
    }

    private struct NewResult: Encodable {
        let id: String
        let path: String
    }

    private struct InstallResult: Encodable {
        let id: String
        let path: String
        let version: String
        let permissions: [String]
        var built: Bool
        var log: String?
    }

    private struct RemoveResult: Encodable {
        let id: String
        let trashedTo: String
    }
}
