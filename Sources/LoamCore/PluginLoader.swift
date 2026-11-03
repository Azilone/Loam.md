import Foundation
import PluginKit
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// A third-party plugin found in `.loam/plugins/<id>/`, not loaded yet.
public struct DiscoveredPlugin: Equatable, Sendable {
    public let manifest: ThirdPartyPluginManifest
    /// Where its compiled library is expected: `.loam/cache/plugins/<id>/lib<library>.dylib`.
    public let libraryURL: URL
}

/// A third-party plugin whose library is loaded and checked, ready to register.
public struct LoadedPlugin {
    public let manifest: ThirdPartyPluginManifest
    /// The plugin types its entry returned. Each id is the manifest's id or starts with it and a dot.
    public let types: [Plugin.Type]
    /// The path of the library.
    public let source: String
}

/// Why a third-party plugin was not loaded. `id` is plugin.json's id, or the folder name when plugin.json is unusable.
public struct LoadFailure: Error, Equatable, Sendable {
    public let id: String
    public let reason: String

    public init(id: String, reason: String) {
        self.id = id
        self.reason = reason
    }
}

/// Finds and loads third-party plugins: Swift packages built as dynamic libraries against the app's runtime
/// (docs/PLUGIN-LOADING.md).
///
/// - `.loam/plugins/<id>/plugin.json` says a plugin is installed (`ThirdPartyPluginManifest`).
/// - `.loam/cache/plugins/<id>/lib<library>.dylib` (`.so` on Linux) is its compiled code.
///
/// Loading `dlopen`s the library, calls its `loam_plugin_entry`, and checks that this runtime can run it (a supported
/// `PluginSDKVersion` on Apple platforms, the same `PluginRuntime.buildID` on Linux) and that its plugin ids belong
/// to it. Every problem becomes a
/// `LoadFailure`; a bad file never stops the app. A library is opened at most once per process: code cannot be
/// unloaded, so disabling a plugin deactivates it and its code stays mapped until the app quits.
public struct PluginLoader {
    public static let pluginsFolder = ".loam/plugins"
    public static let cacheFolder = ".loam/cache/plugins"
    public static let manifestFile = "plugin.json"

    #if os(Linux)
    public static let libraryExtension = "so"
    #else
    public static let libraryExtension = "dylib"
    #endif

    /// Whether a plugin must have been built against this exact runtime. True where Swift has no stable ABI
    /// (Linux); on Apple platforms the SDK is built with library evolution and the SDK version decides.
    #if canImport(Darwin)
    public static let requiresSameBuild = false
    #else
    public static let requiresSameBuild = true
    #endif

    public let rootURL: URL
    /// The id a plugin's entry must carry when `requiresSameBuild`; this runtime's own by default.
    public let buildID: String
    /// The SDK version this runtime implements; a plugin needs the same major and a minor up to it.
    public let sdkVersion: PluginSDKVersion
    public let requiresSameBuild: Bool

    public init(
        rootURL: URL,
        buildID: String = PluginRuntime.buildID,
        sdkVersion: PluginSDKVersion = .current,
        requiresSameBuild: Bool = PluginLoader.requiresSameBuild
    ) {
        self.rootURL = rootURL
        self.buildID = buildID
        self.sdkVersion = sdkVersion
        self.requiresSameBuild = requiresSameBuild
    }

    /// The library file name for a plugin.json `library` value: `libHelloPlugin.dylib`.
    public static func libraryFileName(_ library: String) -> String {
        "lib\(library).\(libraryExtension)"
    }

    /// Reads every `.loam/plugins/<id>/plugin.json`. Loads no code.
    public func discover() -> (plugins: [DiscoveredPlugin], failures: [LoadFailure]) {
        let folder = rootURL.appendingPathComponent(Self.pluginsFolder, isDirectory: true)
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
            .filter { !$0.hasPrefix(".") }
            .sorted()
        var plugins: [DiscoveredPlugin] = []
        var failures: [LoadFailure] = []
        for name in names {
            var isDirectory: ObjCBool = false
            let pluginFolder = folder.appendingPathComponent(name, isDirectory: true)
            guard FileManager.default.fileExists(atPath: pluginFolder.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else { continue }
            switch readManifest(in: pluginFolder, folderName: name) {
            case .success(let manifest):
                let library = rootURL
                    .appendingPathComponent(Self.cacheFolder, isDirectory: true)
                    .appendingPathComponent(manifest.id, isDirectory: true)
                    .appendingPathComponent(Self.libraryFileName(manifest.library))
                plugins.append(DiscoveredPlugin(manifest: manifest, libraryURL: library))
            case .failure(let failure):
                failures.append(failure)
            }
        }
        return (plugins, failures)
    }

    /// Loads one discovered plugin's library, at most once per process.
    public func load(_ plugin: DiscoveredPlugin) -> Result<LoadedPlugin, LoadFailure> {
        let manifest = plugin.manifest
        let path = plugin.libraryURL.path
        guard FileManager.default.fileExists(atPath: path) else {
            return .failure(LoadFailure(id: manifest.id, reason: notBuiltReason(manifest)))
        }
        let entry: PluginEntry
        switch LibraryCache.shared.entry(at: path) {
        case .success(let loaded): entry = loaded
        case .failure(let reason): return .failure(LoadFailure(id: manifest.id, reason: reason.text))
        }
        if let reason = Self.validate(
            entryBuildID: entry.buildID, entrySDKVersion: entry.sdkVersion, pluginIDs: entry.plugins.map { $0.manifest.id },
            manifest: manifest, buildID: buildID, sdkVersion: sdkVersion, requiresSameBuild: requiresSameBuild
        ) {
            return .failure(LoadFailure(id: manifest.id, reason: reason))
        }
        return .success(LoadedPlugin(manifest: manifest, types: entry.plugins, source: path))
    }

    func notBuiltReason(_ manifest: ThirdPartyPluginManifest) -> String {
        "not built: \(Self.cacheFolder)/\(manifest.id)/\(Self.libraryFileName(manifest.library)) is missing; "
            + "build it with `loam plugin build`"
    }

    /// Discovers and loads every plugin.
    public func loadAll() -> (loaded: [LoadedPlugin], failures: [LoadFailure]) {
        let (plugins, discoveryFailures) = discover()
        var loaded: [LoadedPlugin] = []
        var failures = discoveryFailures
        for plugin in plugins {
            switch load(plugin) {
            case .success(let result): loaded.append(result)
            case .failure(let failure): failures.append(failure)
            }
        }
        return (loaded, failures)
    }

    /// Why an entry is refused, nil when it is accepted: built against an SDK this runtime cannot run (or, with
    /// `requiresSameBuild`, against another runtime), no plugin, or a plugin id that does not belong to plugin.json's
    /// id (it must equal it or start with it and a dot).
    ///
    /// A plugin "built for another version of the app" needs a rebuild; one that "needs a newer version of the app"
    /// uses SDK API this runtime does not have yet.
    public static func validate(
        entryBuildID: String,
        entrySDKVersion: PluginSDKVersion?,
        pluginIDs: [String],
        manifest: ThirdPartyPluginManifest,
        buildID: String,
        sdkVersion: PluginSDKVersion,
        requiresSameBuild: Bool
    ) -> String? {
        if requiresSameBuild {
            guard entryBuildID == buildID else {
                return "built for another version of the app (runtime \(entryBuildID), this app runs \(buildID)): "
                    + "rebuild it with `loam plugin build`"
            }
        } else {
            guard let built = entrySDKVersion else {
                return "built for another version of the app (before plugin SDK versions, this app has plugin SDK "
                    + "\(sdkVersion)): rebuild it with `loam plugin build`"
            }
            guard built.major == sdkVersion.major else {
                return "built for another version of the app (plugin SDK \(built), this app has \(sdkVersion)): "
                    + "rebuild it with `loam plugin build`"
            }
            guard built.minor <= sdkVersion.minor else {
                return "needs a newer version of the app (plugin SDK \(built), this app has \(sdkVersion)): update Loam"
            }
        }
        guard !pluginIDs.isEmpty else { return "its entry returned no plugin" }
        let foreign = pluginIDs.filter { $0 != manifest.id && !$0.hasPrefix(manifest.id + ".") }
        guard foreign.isEmpty else {
            return "plugin id \(foreign.map { "\"\($0)\"" }.joined(separator: ", ")) does not belong to "
                + "\"\(manifest.id)\": ids must be \"\(manifest.id)\" or start with \"\(manifest.id).\""
        }
        return nil
    }

    /// The plugin.json in `folder`, nil when it is missing or cannot be read.
    public static func manifest(in folder: URL) -> ThirdPartyPluginManifest? {
        guard let data = FileManager.default.contents(atPath: folder.appendingPathComponent(manifestFile).path) else { return nil }
        return try? JSONDecoder().decode(ThirdPartyPluginManifest.self, from: data)
    }

    private func readManifest(in folder: URL, folderName: String) -> Result<ThirdPartyPluginManifest, LoadFailure> {
        let url = folder.appendingPathComponent(Self.manifestFile)
        guard let data = FileManager.default.contents(atPath: url.path) else {
            return .failure(LoadFailure(id: folderName, reason: "\(Self.pluginsFolder)/\(folderName)/plugin.json is missing"))
        }
        let manifest: ThirdPartyPluginManifest
        do {
            manifest = try JSONDecoder().decode(ThirdPartyPluginManifest.self, from: data)
        } catch {
            return .failure(LoadFailure(id: folderName, reason: "plugin.json cannot be read: \(Self.describe(error))"))
        }
        if let problem = manifest.problem(folderName: folderName) {
            return .failure(LoadFailure(id: folderName, reason: problem))
        }
        return .success(manifest)
    }

    private static func describe(_ error: Error) -> String {
        switch error {
        case DecodingError.keyNotFound(let key, _): return "missing \"\(key.stringValue)\""
        case DecodingError.typeMismatch(_, let context), DecodingError.valueNotFound(_, let context):
            return "wrong type for \"\(context.codingPath.map(\.stringValue).joined(separator: "."))\""
        case DecodingError.dataCorrupted: return "not valid JSON"
        default: return "\(error)"
        }
    }
}

/// The libraries this process opened, by path. A library is opened once: dyld and glibc cannot unload Swift code
/// safely, and a second `dlopen` of a rebuilt file at the same path would not load the new code anyway.
final class LibraryCache: @unchecked Sendable {
    static let shared = LibraryCache()

    struct Reason: Error {
        let text: String
    }

    private struct Record {
        let modified: Date?
        /// Set once `dlopen` succeeded: the library is mapped for the life of the process.
        let opened: Bool
        let result: Result<PluginEntry, Reason>
    }

    private let lock = NSLock()
    private var records: [String: Record] = [:]

    /// Records `entry` as what the library at `path` returned, as if it had been opened: tests use it to load plugin
    /// types compiled into the test bundle, which cannot be opened as a separate library.
    func seed(path: String, entry: PluginEntry) {
        let key = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        let modified = (try? FileManager.default.attributesOfItem(atPath: key))?[.modificationDate] as? Date
        lock.lock()
        defer { lock.unlock() }
        records[key] = Record(modified: modified, opened: true, result: .success(entry))
    }

    func entry(at path: String) -> Result<PluginEntry, Reason> {
        let key = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        let modified = (try? FileManager.default.attributesOfItem(atPath: key))?[.modificationDate] as? Date
        lock.lock()
        defer { lock.unlock() }
        if let record = records[key] {
            if record.modified == modified { return record.result }
            if record.opened {
                return .failure(Reason(text: "the library changed after it was loaded; relaunch the app to use the new build"))
            }
        }
        let (opened, result) = open(key)
        records[key] = Record(modified: modified, opened: opened, result: result)
        return result
    }

    private func open(_ path: String) -> (opened: Bool, Result<PluginEntry, Reason>) {
        guard let handle = dlopen(path, RTLD_NOW | RTLD_LOCAL) else {
            let message = dlerror().map { String(cString: $0) } ?? "unknown error"
            return (false, .failure(Reason(text: "cannot be loaded (\(message)); rebuild it with `loam plugin build`")))
        }
        guard let symbol = dlsym(handle, PluginEntry.symbol) else {
            return (true, .failure(Reason(text: "not a Loam plugin: it does not export `\(PluginEntry.symbol)`")))
        }
        typealias Entry = @convention(c) () -> UnsafeMutableRawPointer?
        guard let raw = unsafeBitCast(symbol, to: Entry.self)() else {
            return (true, .failure(Reason(text: "its entry returned nothing")))
        }
        guard let entry = Unmanaged<AnyObject>.fromOpaque(raw).takeRetainedValue() as? PluginEntry else {
            return (true, .failure(Reason(text: "its entry did not return a PluginEntry; rebuild it with `loam plugin build`")))
        }
        return (true, .success(entry))
    }
}
