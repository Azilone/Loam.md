import XCTest
import PluginKit
import PluginKitTesting
@testable import LoamCore
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Stands for a third-party plugin: registers a command. Its type is compiled into the test bundle and handed to the
/// loader through `LibraryCache.seed`, since a test cannot build a real plugin library.
private final class VaultHello: Plugin {
    static var manifest: PluginManifest { PluginManifest(id: "hello", name: "Hello", version: "0.1.0") }
    required init() {}
    func activate(context: PluginContext) throws {
        try context.registerCommand(Command(id: "hello.say", title: "Hello", summary: "Says hello from the vault") { _ in
            "hello"
        })
    }
}

/// A second plugin type in the same package, with an id extending the package's.
private final class VaultHelloExtra: Plugin {
    static var manifest: PluginManifest { PluginManifest(id: "hello.extra", name: "Hello extra", version: "0.1.0") }
    required init() {}
    func activate(context: PluginContext) throws {}
}

/// Claims an id that is not its package's.
private final class Squatter: Plugin {
    static var manifest: PluginManifest { PluginManifest(id: "other", name: "Other", version: "0.1.0") }
    required init() {}
    func activate(context: PluginContext) throws {}
}

/// A built-in plugin, to check sources and id clashes.
private final class Builtin: Plugin {
    static var manifest: PluginManifest { PluginManifest(id: "builtin", name: "Builtin", version: "1.0.0") }
    required init() {}
    func activate(context: PluginContext) throws {}
}

final class PluginLoaderTests: XCTestCase {
    private var vault: TemporaryVault!

    override func setUpWithError() throws {
        vault = try TemporaryVault()
    }

    override func tearDown() {
        vault = nil
    }

    // MARK: Helpers

    private func install(
        _ id: String,
        json: String? = nil,
        library: String = "HelloPlugin",
        folder: String? = nil
    ) throws {
        let folder = folder ?? id
        try vault.write(
            ".loam/plugins/\(folder)/plugin.json",
            json ?? #"{"id": "\#(id)", "name": "Hello", "version": "0.1.0", "library": "\#(library)", "permissions": ["vault.read"]}"#
        )
    }

    private func libraryPath(_ id: String, _ library: String = "HelloPlugin") -> String {
        vault.url(".loam/cache/plugins/\(id)/\(PluginLoader.libraryFileName(library))").path
    }

    /// Writes a library file and makes the loader return `entry` for it, as if the library had been opened.
    private func installLibrary(_ id: String, entry: PluginEntry) throws {
        let path = libraryPath(id)
        try FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true
        )
        // A unique content per test, so two tests never share a cached library path.
        try Data(UUID().uuidString.utf8).write(to: URL(fileURLWithPath: path))
        LibraryCache.shared.seed(path: path, entry: entry)
    }

    private func onlyFailure(_ loader: PluginLoader) -> LoadFailure? {
        let (loaded, failures) = loader.loadAll()
        XCTAssertTrue(loaded.isEmpty)
        XCTAssertEqual(failures.count, 1)
        return failures.first
    }

    private func rows(_ runtime: Runtime) async throws -> [[String: Any]] {
        let output = try await runtime.kernel.commands.command(id: "plugins.list")!.handler([:])
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(output.utf8)) as? [[String: Any]])
    }

    private func row(_ id: String, in runtime: Runtime) async throws -> [String: Any] {
        let all = try await rows(runtime)
        return try XCTUnwrap(all.first { $0["id"] as? String == id })
    }

    // MARK: Discovery and loading

    func testNoPluginsFolderFindsNothing() {
        let (loaded, failures) = PluginLoader(rootURL: vault.rootURL).loadAll()
        XCTAssertTrue(loaded.isEmpty)
        XCTAssertTrue(failures.isEmpty)
    }

    func testReadsPluginJSON() throws {
        try install("hello")
        let (plugins, failures) = PluginLoader(rootURL: vault.rootURL).discover()
        XCTAssertEqual(failures, [])
        XCTAssertEqual(plugins.map(\.manifest), [
            ThirdPartyPluginManifest(id: "hello", name: "Hello", version: "0.1.0", library: "HelloPlugin", permissions: ["vault.read"]),
        ])
        XCTAssertEqual(plugins.first?.libraryURL.path, libraryPath("hello"))
    }

    func testPermissionsAreOptional() throws {
        try install("hello", json: #"{"id": "hello", "name": "Hello", "version": "1", "library": "HelloPlugin"}"#)
        XCTAssertEqual(PluginLoader(rootURL: vault.rootURL).discover().plugins.first?.manifest.permissions, [])
    }

    func testPluginJSONMaySayWhatThePluginIsAndNameItsIcon() throws {
        try install("hello", json: """
        {"id": "hello", "name": "Hello", "version": "1", "library": "HelloPlugin",
         "description": "Says hello.", "icon": "hand.wave", "iconFile": "assets/icon.png"}
        """)
        let manifest = try XCTUnwrap(PluginLoader(rootURL: vault.rootURL).discover().plugins.first?.manifest)
        XCTAssertEqual(manifest.description, "Says hello.")
        XCTAssertEqual(manifest.icon, "hand.wave")
        let folder = URL(fileURLWithPath: "/vault/.loam/plugins/hello")
        XCTAssertEqual(manifest.iconFileURL(in: folder)?.path, "/vault/.loam/plugins/hello/assets/icon.png")

        var outside = manifest
        for path in ["../other/icon.png", "/etc/icon.png", "a/../../icon.png", "", "~/icon.png"] {
            outside.iconFile = path
            XCTAssertNil(outside.iconFileURL(in: folder), path)
        }
        outside.iconFile = nil
        XCTAssertNil(outside.iconFileURL(in: folder))
    }

    func testACosmeticFieldOfTheWrongTypeDoesNotDisableThePlugin() throws {
        try install("hello", json: """
        {"id": "hello", "name": "Hello", "version": "1", "library": "HelloPlugin",
         "icon": {"light": "a.png"}, "iconFile": 3, "description": ["x"]}
        """)
        let discovery = PluginLoader(rootURL: vault.rootURL).discover()
        let manifest = try XCTUnwrap(discovery.plugins.first?.manifest)
        XCTAssertNil(manifest.icon)
        XCTAssertNil(manifest.iconFile)
        XCTAssertNil(manifest.description)
        XCTAssertTrue(discovery.failures.isEmpty)
    }

    func testMissingPluginJSON() throws {
        try FileManager.default.createDirectory(at: vault.url(".loam/plugins/hello"), withIntermediateDirectories: true)
        let failure = onlyFailure(PluginLoader(rootURL: vault.rootURL))
        XCTAssertEqual(failure?.id, "hello")
        XCTAssertEqual(failure?.reason, ".loam/plugins/hello/plugin.json is missing")
    }

    func testBadPluginJSON() throws {
        try install("broken", json: "{ not json")
        try install("partial", json: #"{"id": "partial", "name": "Partial"}"#)
        let (_, failures) = PluginLoader(rootURL: vault.rootURL).loadAll()
        XCTAssertEqual(failures, [
            LoadFailure(id: "broken", reason: "plugin.json cannot be read: not valid JSON"),
            LoadFailure(id: "partial", reason: "plugin.json cannot be read: missing \"version\""),
        ])
    }

    func testPluginJSONMustMatchItsFolderAndNameAFile() throws {
        try install("hello", folder: "elsewhere")
        try install("lib", library: "../evil")
        try install("Upper")
        let reasons = Dictionary(uniqueKeysWithValues: PluginLoader(rootURL: vault.rootURL).loadAll().failures.map {
            ($0.id, $0.reason)
        })
        XCTAssertEqual(reasons["elsewhere"], "plugin.json: \"id\" is \"hello\" but the folder is \"elsewhere\"")
        XCTAssertEqual(reasons["lib"], "plugin.json: \"library\" must be a product name (letters, digits, \"_\")")
        XCTAssertEqual(reasons["Upper"], "plugin.json: \"id\" must be lowercase letters, digits, \"-\" and \".\"")
    }

    func testMissingLibraryIsNotBuilt() throws {
        try install("hello")
        let failure = onlyFailure(PluginLoader(rootURL: vault.rootURL))
        XCTAssertEqual(failure?.id, "hello")
        XCTAssertTrue(failure?.reason.hasPrefix("not built: .loam/cache/plugins/hello/libHelloPlugin.") == true)
    }

    func testFileThatIsNotALibrary() throws {
        try install("hello")
        try vault.write(".loam/cache/plugins/hello/\(PluginLoader.libraryFileName("HelloPlugin"))", "not machine code")
        let failure = onlyFailure(PluginLoader(rootURL: vault.rootURL))
        XCTAssertTrue(failure?.reason.hasPrefix("cannot be loaded (") == true, failure?.reason ?? "")
    }

    /// A real library that is not a plugin: it has no `loam_plugin_entry`.
    func testLibraryWithoutEntrySymbol() throws {
        let library = try XCTUnwrap(Self.nonPluginLibrary(), "no library on disk to try")
        try install("hello")
        let path = libraryPath("hello")
        try FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(atPath: path, withDestinationPath: library)
        let failure = onlyFailure(PluginLoader(rootURL: vault.rootURL))
        XCTAssertEqual(failure?.reason, "not a Loam plugin: it does not export `loam_plugin_entry`")
    }

    func testLoadsAnEntryBuiltForThisRuntime() throws {
        try install("hello")
        try installLibrary("hello", entry: PluginEntry(plugins: [VaultHello.self, VaultHelloExtra.self]))
        let (loaded, failures) = PluginLoader(rootURL: vault.rootURL).loadAll()
        XCTAssertEqual(failures, [])
        XCTAssertEqual(loaded.first?.manifest.id, "hello")
        XCTAssertEqual(loaded.first?.types.map { $0.manifest.id }, ["hello", "hello.extra"])
        XCTAssertEqual(loaded.first?.source, libraryPath("hello"))
    }

    func testRefusesAnEntryBuiltForAnotherRuntime() throws {
        try install("hello")
        try installLibrary("hello", entry: PluginEntry(plugins: [VaultHello.self], buildID: "another-build"))
        let failure = onlyFailure(PluginLoader(rootURL: vault.rootURL))
        if PluginLoader.requiresSameBuild {
            XCTAssertEqual(
                failure?.reason,
                "built for another version of the app (runtime another-build, this app runs \(PluginRuntime.buildID)): "
                    + "rebuild it with `loam plugin build`"
            )
        } else {
            // An entry without an SDK version comes from a plugin built before the SDK was stable.
            XCTAssertEqual(
                failure?.reason,
                "built for another version of the app (before plugin SDK versions, this app has plugin SDK "
                    + "\(PluginSDKVersion.current)): rebuild it with `loam plugin build`"
            )
        }
    }

    func testAcceptsAnEntryFromAnotherBuildOfTheSameSDK() throws {
        guard !PluginLoader.requiresSameBuild else { return }
        try install("hello")
        try installLibrary("hello", entry: PluginEntry(
            plugins: [VaultHello.self], buildID: "an-older-release", sdkVersion: PluginSDKVersion.current
        ))
        let (loaded, failures) = PluginLoader(rootURL: vault.rootURL).loadAll()
        XCTAssertEqual(failures, [])
        XCTAssertEqual(loaded.first?.manifest.id, "hello")
    }

    func testEntryRecordsTheRuntimeAndSDKItIsBuiltAgainst() {
        let entry = PluginEntry(plugins: [])
        XCTAssertEqual(entry.buildID, PluginRuntime.buildID)
        XCTAssertEqual(entry.sdkVersion, PluginSDKVersion.current)
        XCTAssertFalse(PluginRuntime.buildID.isEmpty)
    }

    func testValidateChecksTheSDKVersionAndPluginIDs() {
        let manifest = ThirdPartyPluginManifest(id: "hello", name: "Hello", version: "1", library: "HelloPlugin")
        let app = PluginSDKVersion(major: 2, minor: 3)
        func check(_ built: PluginSDKVersion?, _ ids: [String] = ["hello"]) -> String? {
            PluginLoader.validate(
                entryBuildID: "plugin", entrySDKVersion: built, pluginIDs: ids, manifest: manifest,
                buildID: "app", sdkVersion: app, requiresSameBuild: false
            )
        }
        // Same major, minor up to the app's: another build is fine.
        XCTAssertNil(check(PluginSDKVersion(major: 2, minor: 3)))
        XCTAssertNil(check(PluginSDKVersion(major: 2, minor: 0)))
        XCTAssertNil(check(app, ["hello", "hello.extra"]))
        XCTAssertEqual(
            check(PluginSDKVersion(major: 2, minor: 4)),
            "needs a newer version of the app (plugin SDK 2.4, this app has 2.3): update Loam"
        )
        XCTAssertEqual(
            check(PluginSDKVersion(major: 1, minor: 9)),
            "built for another version of the app (plugin SDK 1.9, this app has 2.3): rebuild it with `loam plugin build`"
        )
        XCTAssertEqual(
            check(nil),
            "built for another version of the app (before plugin SDK versions, this app has plugin SDK 2.3): "
                + "rebuild it with `loam plugin build`"
        )
        XCTAssertEqual(check(app, []), "its entry returned no plugin")
        XCTAssertEqual(
            check(app, ["hello", "helloworld", "other"]),
            "plugin id \"helloworld\", \"other\" does not belong to \"hello\": ids must be \"hello\" or start with \"hello.\""
        )
    }

    func testValidateChecksTheBuildIDWhereTheABIIsNotStable() {
        let manifest = ThirdPartyPluginManifest(id: "hello", name: "Hello", version: "1", library: "HelloPlugin")
        func check(_ buildID: String) -> String? {
            PluginLoader.validate(
                entryBuildID: buildID, entrySDKVersion: .current, pluginIDs: ["hello"], manifest: manifest,
                buildID: "app", sdkVersion: .current, requiresSameBuild: true
            )
        }
        XCTAssertNil(check("app"))
        XCTAssertEqual(
            check("old"),
            "built for another version of the app (runtime old, this app runs app): rebuild it with `loam plugin build`"
        )
    }

    func testRefusesPluginIDsOutsideItsPackage() throws {
        try install("hello")
        try installLibrary("hello", entry: PluginEntry(plugins: [VaultHello.self, Squatter.self]))
        XCTAssertTrue(onlyFailure(PluginLoader(rootURL: vault.rootURL))?.reason.hasPrefix("plugin id \"other\"") == true)
    }

    func testRebuiltLibraryNeedsARelaunch() throws {
        try install("hello")
        try installLibrary("hello", entry: PluginEntry(plugins: [VaultHello.self]))
        XCTAssertEqual(PluginLoader(rootURL: vault.rootURL).loadAll().loaded.count, 1)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(60)], ofItemAtPath: libraryPath("hello")
        )
        XCTAssertEqual(
            onlyFailure(PluginLoader(rootURL: vault.rootURL))?.reason,
            "the library changed after it was loaded; relaunch the app to use the new build"
        )
    }

    // MARK: Runtime

    func testRuntimeIgnoresVaultPluginsUnlessAsked() async throws {
        try install("hello")
        try installLibrary("hello", entry: PluginEntry(plugins: [VaultHello.self]))
        try vault.write(".loam/config.json", #"{"plugins": {"hello": {"enabled": true}}}"#)
        let runtime = try Runtime(rootURL: vault.rootURL, plugins: [Builtin.self])
        defer { runtime.close() }
        let ids = try await rows(runtime).map { $0["id"] as? String }
        XCTAssertEqual(ids, ["builtin"])
    }

    func testVaultPluginsAreDisabledByDefault() async throws {
        try install("hello")
        try installLibrary("hello", entry: PluginEntry(plugins: [VaultHello.self]))
        let runtime = try Runtime(rootURL: vault.rootURL, plugins: [Builtin.self], thirdPartyPlugins: true, pluginTrust: .everything)
        defer { runtime.close() }

        XCTAssertNil(runtime.kernel.commands.command(id: "hello.say"))
        let hello = try await row("hello", in: runtime)
        XCTAssertEqual(hello["source"] as? String, "vault")
        XCTAssertEqual(hello["enabled"] as? Bool, false)
        XCTAssertEqual(hello["active"] as? Bool, false)
        XCTAssertEqual(hello["name"] as? String, "Hello")
        XCTAssertNil(hello["loadError"])
        let builtin = try await row("builtin", in: runtime)
        XCTAssertEqual(builtin["source"] as? String, "builtin")
        XCTAssertEqual(builtin["enabled"] as? Bool, true)
    }

    func testEnablingLoadsAndStartsAVaultPlugin() async throws {
        try install("hello")
        try installLibrary("hello", entry: PluginEntry(plugins: [VaultHello.self, VaultHelloExtra.self]))
        let runtime = try Runtime(rootURL: vault.rootURL, plugins: [Builtin.self], thirdPartyPlugins: true, pluginTrust: .everything)
        defer { runtime.close() }

        _ = try await runtime.kernel.commands.command(id: "plugins.enable")!.handler(["id": "hello"])
        XCTAssertTrue(runtime.config.config.isExplicitlyEnabled("hello"))
        let output = try await runtime.kernel.commands.command(id: "hello.say")?.handler([:])
        XCTAssertEqual(output, "hello")
        // A plugin type extending the package's id follows the package.
        XCTAssertEqual(Set(runtime.host.activeIDs), ["builtin", "hello", "hello.extra"])
        let hello = try await row("hello", in: runtime)
        XCTAssertEqual(hello["source"] as? String, "vault")
        XCTAssertEqual(hello["active"] as? Bool, true)
        let extra = try await row("hello.extra", in: runtime)
        XCTAssertEqual(extra["source"] as? String, "vault")

        // Disabling deactivates it; the code stays loaded and starts again on the next enable.
        _ = try await runtime.kernel.commands.command(id: "plugins.disable")!.handler(["id": "hello"])
        XCTAssertNil(runtime.kernel.commands.command(id: "hello.say"))
        XCTAssertEqual(runtime.host.activeIDs, ["builtin"])
        _ = try await runtime.kernel.commands.command(id: "plugins.enable")!.handler(["id": "hello"])
        XCTAssertNotNil(runtime.kernel.commands.command(id: "hello.say"))
    }

    func testAVaultThatEnablesItsOwnPluginDoesNotRunItUntilTurnedOnHere() async throws {
        try install("hello")
        try installLibrary("hello", entry: PluginEntry(plugins: [VaultHello.self]))
        try vault.write(".loam/config.json", #"{"plugins": {"hello": {"enabled": true}}}"#)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("trust-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let trust = PluginTrust(fileURL: file)

        let received = try Runtime(rootURL: vault.rootURL, plugins: [Builtin.self], thirdPartyPlugins: true, pluginTrust: trust)
        XCTAssertNil(received.kernel.commands.command(id: "hello.say"), "the vault's config alone runs no code")
        let hello = try await row("hello", in: received)
        XCTAssertNotNil(hello["loadError"])
        _ = try await received.kernel.commands.command(id: "plugins.enable")!.handler(["id": "hello"])
        XCTAssertNotNil(received.kernel.commands.command(id: "hello.say"))
        received.close()

        let reopened = try Runtime(rootURL: vault.rootURL, plugins: [Builtin.self], thirdPartyPlugins: true, pluginTrust: trust)
        defer { reopened.close() }
        XCTAssertTrue(trust.isTrusted("hello", in: vault.rootURL))
        XCTAssertFalse(trust.isTrusted("hello", in: vault.rootURL.appendingPathComponent("copy")))
    }

    func testEnabledInConfigLoadsAtStart() throws {
        try install("hello")
        try installLibrary("hello", entry: PluginEntry(plugins: [VaultHello.self]))
        try vault.write(".loam/config.json", #"{"plugins": {"hello": {"enabled": true}}}"#)
        let runtime = try Runtime(rootURL: vault.rootURL, plugins: [], thirdPartyPlugins: true, pluginTrust: .everything)
        defer { runtime.close() }
        XCTAssertEqual(runtime.host.activeIDs, ["hello"])
        XCTAssertEqual(runtime.thirdPartyLoadFailures, [])
    }

    func testSafeModeNeverLoadsVaultPlugins() async throws {
        try install("hello")
        // Not a library: opening it would record "cannot be loaded".
        try vault.write(".loam/cache/plugins/hello/\(PluginLoader.libraryFileName("HelloPlugin"))", "not machine code")
        try vault.write(".loam/config.json", #"{"plugins": {"hello": {"enabled": true}}}"#)
        let runtime = try Runtime(
            rootURL: vault.rootURL, plugins: [Builtin.self], safeMode: ["builtin"], thirdPartyPlugins: true, pluginTrust: .everything
        )
        defer { runtime.close() }

        let hello = try await row("hello", in: runtime)
        XCTAssertNil(hello["loadError"])
        XCTAssertEqual(hello["active"] as? Bool, false)
        XCTAssertEqual(hello["skipped"] as? String, "safe mode: plugins from the vault are not loaded")
        XCTAssertEqual(runtime.thirdPartyLoadFailures, [])
    }

    func testLoadErrorsAreListedAndReported() async throws {
        try install("hello")
        try install("built-elsewhere")
        try installLibrary("built-elsewhere", entry: PluginEntry(plugins: [VaultHello.self], buildID: "old"))
        try vault.write(".loam/config.json", #"{"plugins": {"built-elsewhere": {"enabled": true}}}"#)
        let runtime = try Runtime(rootURL: vault.rootURL, plugins: [], thirdPartyPlugins: true, pluginTrust: .everything)
        defer { runtime.close() }

        // Disabled but not built: the row says so; nothing is reported as failed.
        let hello = try await row("hello", in: runtime)
        XCTAssertEqual(hello["enabled"] as? Bool, false)
        XCTAssertTrue((hello["loadError"] as? String)?.hasPrefix("not built") == true)
        // Enabled and refused: in the row, in the activation report and in the failures.
        let refused = try await row("built-elsewhere", in: runtime)
        XCTAssertTrue((refused["loadError"] as? String)?.hasPrefix("built for another version of the app") == true)
        XCTAssertNotNil(runtime.lastReport.failed["built-elsewhere"])
        XCTAssertEqual(runtime.thirdPartyLoadFailures.map(\.id), ["built-elsewhere"])
    }

    func testAVaultPluginCannotTakeABuiltinID() async throws {
        try install("builtin")
        try installLibrary("builtin", entry: PluginEntry(plugins: [Builtin.self]))
        try vault.write(".loam/config.json", #"{"plugins": {"builtin": {"enabled": true}}}"#)
        let runtime = try Runtime(rootURL: vault.rootURL, plugins: [Builtin.self], thirdPartyPlugins: true, pluginTrust: .everything)
        defer { runtime.close() }
        XCTAssertEqual(runtime.lastReport.failed["builtin"], "a plugin with the id \"builtin\" is already installed")
    }

    func testEnableAcceptsAVaultPluginThatIsNotLoaded() async throws {
        try install("hello")
        let runtime = try Runtime(rootURL: vault.rootURL, plugins: [], thirdPartyPlugins: true, pluginTrust: .everything)
        defer { runtime.close() }
        let output = try await runtime.kernel.commands.command(id: "plugins.enable")!.handler(["id": "hello"])
        XCTAssertTrue(output.contains("not built"), output)
    }

    // MARK: A library on disk that is not a plugin

    /// A shared library on disk without the plugin entry: the test bundle itself on macOS (already loaded, so opening
    /// it again is harmless), a system library this process mapped on Linux.
    private static func nonPluginLibrary() -> String? {
        #if os(Linux)
        guard let maps = try? String(contentsOfFile: "/proc/self/maps", encoding: .utf8) else { return nil }
        return maps.split(separator: "\n").compactMap { line in line.split(separator: " ").last.map(String.init) }
            .first { $0.hasPrefix("/") && ($0.contains("/libc.so") || $0.contains("/libc-")) }
        #else
        var info = Dl_info()
        let symbol = unsafeBitCast(nonPluginLibraryAnchor, to: UnsafeRawPointer.self)
        guard dladdr(symbol, &info) != 0, let name = info.dli_fname else { return nil }
        let path = String(cString: name)
        return FileManager.default.fileExists(atPath: path) ? path : nil
        #endif
    }
}

#if !os(Linux)
/// A C function in the test bundle, to find the bundle's file with `dladdr`.
@_cdecl("so_plugin_loader_tests_anchor")
private func soPluginLoaderTestsAnchorImplementation() {}
private let nonPluginLibraryAnchor: @convention(c) () -> Void = soPluginLoaderTestsAnchorImplementation
#endif
