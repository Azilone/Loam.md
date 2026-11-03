import Foundation
import PluginKit
import PluginKitTesting
import XCTest
@testable import LoamCore

/// A built-in plugin, to check that its id cannot be taken by a vault plugin.
private final class Builtin: Plugin {
    static var manifest: PluginManifest { PluginManifest(id: "builtin", name: "Builtin", version: "1.0.0") }
    required init() {}
    func activate(context: PluginContext) throws {}
}

/// `plugins.new`, `plugins.remove`, `plugins.install` (without compiling) and the SDK lookup. The commands that
/// compile Swift are checked end to end by `PluginBuildTests` in LoamCLITests.
final class PluginPackagesTests: XCTestCase {
    private var vault: TemporaryVault!
    private var runtime: Runtime!
    private var scratch: URL!

    override func setUpWithError() throws {
        vault = try TemporaryVault()
        try vault.write("note.md", "# Note\n")
        runtime = try Runtime(rootURL: vault.rootURL, plugins: [Builtin.self], thirdPartyPlugins: true, pluginTrust: .everything)
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent("so-packages-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        runtime.close()
        runtime = nil
        vault = nil
        try? FileManager.default.removeItem(at: scratch)
    }

    private func run(_ id: String, _ arguments: [String: String] = [:]) async throws -> String {
        let command = try XCTUnwrap(runtime.kernel.commands.command(id: id), "no command \(id)")
        return try await command.handler(arguments)
    }

    private func json(_ text: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }

    private func row(_ id: String) async throws -> [String: Any]? {
        let output = try await run("plugins.list")
        let rows = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(output.utf8)) as? [[String: Any]])
        return rows.first { $0["id"] as? String == id }
    }

    private func exists(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: vault.url(path).path)
    }

    // MARK: plugins.new

    func testBuildRefusesSymbolsFromOutsideTheSDK() {
        let output = """
                         (undefined) external _$s9PluginKit7CommandVMn (from libLoamRuntime)
                         (undefined) external _$s11PluginKitUI5PanelVMn (from libLoamUIRuntime)
                         (undefined) external _$s8LoamCore6KernelCMn (from libLoamRuntime)
                         (undefined) external _OBJC_CLASS_$__TtC14MarkdownEditor14EditorTextView (from libLoamUIRuntime)
                         (undefined) external _$sSS10FoundationE4dataSSSg_tcfC (from libswiftFoundation)
                         (undefined) external _$s8LoamCore6KernelC4nameSSvg (from libLoamRuntime)
                         (undefined) external _swift_retain (from libswiftCore)
                         (undefined) external _$s7SwiftUI4FontV09PluginKitB0E2ui_6weightAcD6UITypeO_AC6WeightVSgtFZ (from libLoamUIRuntime)
        """
        XCTAssertEqual(PluginBuilder.unstableModules(inUndefinedSymbols: output), ["LoamCore", "MarkdownEditor"])
        XCTAssertEqual(PluginBuilder.unstableModules(inUndefinedSymbols: ""), [])
        XCTAssertEqual(PluginBuilder.mangledModule("_$s9PluginKit7CommandVMn"), "PluginKit")
        XCTAssertNil(PluginBuilder.mangledModule("_swift_retain"))
        XCTAssertNil(PluginBuilder.mangledModule("_$s99Short"))
        XCTAssertTrue(PluginBuilder.extendsInTheSDK("_$s7SwiftUI17EnvironmentValuesV09PluginKitB0E11themeTokensAD05ThemeH0Vvg"))
        XCTAssertFalse(PluginBuilder.extendsInTheSDK("_$s8LoamCore6KernelC4nameSSvg"))
    }

    func testNewWritesALogicPackage() async throws {
        let result = try json(try await run("plugins.new", ["id": "word-count"]))
        XCTAssertEqual(result["id"] as? String, "word-count")
        XCTAssertEqual(result["path"] as? String, vault.url(".loam/plugins/word-count").path)

        let manifest = try JSONDecoder().decode(
            ThirdPartyPluginManifest.self, from: Data(try vault.read(".loam/plugins/word-count/plugin.json").utf8)
        )
        XCTAssertEqual(manifest, ThirdPartyPluginManifest(
            id: "word-count", name: "Word Count", version: "0.1.0", library: "WordCountPlugin", permissions: ["vault.read"],
            description: "", icon: "puzzlepiece.extension"
        ))
        let package = try vault.read(".loam/plugins/word-count/Package.swift")
        XCTAssertTrue(package.hasPrefix("// swift-tools-version:5.10\n"), package)
        XCTAssertTrue(package.contains(#".library(name: "WordCountPlugin", type: .dynamic, targets: ["WordCount"])"#))
        XCTAssertTrue(package.contains(#"ProcessInfo.processInfo.environment["LOAM_SDK"]"#))
        XCTAssertEqual(Set(products(in: package)), ["LoamRuntime"])
        let source = try vault.read(".loam/plugins/word-count/Sources/WordCount/WordCountPlugin.swift")
        XCTAssertTrue(source.contains(#"@_cdecl("loam_plugin_entry")"#))
        XCTAssertTrue(source.contains(#"id: "word-count.hello""#))
        XCTAssertTrue(exists(".loam/plugins/word-count/Tests/WordCountTests/WordCountPluginTests.swift"))
        XCTAssertTrue(exists(".loam/plugins/word-count/README.md"))

        // Listed, off, and not built yet.
        let listed = try await row("word-count")
        XCTAssertEqual(listed?["source"] as? String, "vault")
        XCTAssertEqual(listed?["enabled"] as? Bool, false)
        XCTAssertTrue((listed?["loadError"] as? String)?.hasPrefix("not built") == true)
    }

    func testNewWritesAUIPackageLinkingOnlyTheRuntimes() async throws {
        _ = try await run("plugins.new", ["id": "hello-panel", "ui": "true", "name": "Hello \"panel\""])
        let package = try vault.read(".loam/plugins/hello-panel/Package.swift")
        XCTAssertTrue(package.hasPrefix("// swift-tools-version:6.2\n"), package)
        XCTAssertTrue(package.contains(".macOS(.v26)"))
        XCTAssertTrue(package.contains(#".package(path: sdk + "/App")"#))
        XCTAssertEqual(Set(products(in: package)), ["LoamRuntime", "LoamUIRuntime"])
        let source = try vault.read(".loam/plugins/hello-panel/Sources/HelloPanel/HelloPanelPlugin.swift")
        XCTAssertTrue(source.contains("UIPlugin"))
        XCTAssertTrue(source.contains("registerPanel"))
        XCTAssertTrue(source.contains(#"title: "Hello \"panel\"""#), source)
        let manifest = try JSONDecoder().decode(
            ThirdPartyPluginManifest.self, from: Data(try vault.read(".loam/plugins/hello-panel/plugin.json").utf8)
        )
        XCTAssertEqual(manifest.name, "Hello \"panel\"")
        XCTAssertEqual(manifest.library, "HelloPanelPlugin")
    }

    func testNewRefusesBadTakenAndBuiltinIDs() async throws {
        for id in ["Word", "word_count", "-a", "a-", "1password", "a--b", "../x", "plugin-kit"] {
            do {
                _ = try await run("plugins.new", ["id": id])
                XCTFail("accepted \(id)")
            } catch let error as PluginPackageError {
                XCTAssertTrue([.invalidID(id), .reservedName(id)].contains(error), "\(id): \(error)")
            }
        }
        do {
            _ = try await run("plugins.new", ["id": "builtin"])
            XCTFail("accepted a built-in id")
        } catch let error as PluginPackageError {
            XCTAssertEqual(error, .builtin("builtin"))
        }
        _ = try await run("plugins.new", ["id": "twice"])
        do {
            _ = try await run("plugins.new", ["id": "twice"])
            XCTFail("overwrote a plugin")
        } catch let error as PluginPackageError {
            XCTAssertEqual(error, .alreadyInstalled("twice"))
        }
    }

    // MARK: plugins.remove

    func testRemoveTrashesDisablesAndDropsTheCache() async throws {
        _ = try await run("plugins.new", ["id": "gone"])
        try vault.write(".loam/cache/plugins/gone/libGonePlugin.dylib", "binary")
        try vault.write(".loam/cache/build/gone/output", "objects")
        try runtime.config.mutate { $0.setEnabled(true, "gone") }

        let first = try json(try await run("plugins.remove", ["id": "gone"]))
        XCTAssertEqual(first["id"] as? String, "gone")
        XCTAssertEqual(first["trashedTo"] as? String, ".trash/plugins/gone")
        XCTAssertTrue(exists(".trash/plugins/gone/plugin.json"))
        XCTAssertFalse(exists(".loam/plugins/gone"))
        XCTAssertFalse(exists(".loam/cache/plugins/gone"))
        XCTAssertFalse(exists(".loam/cache/build/gone"))
        try runtime.config.reload()
        XCTAssertFalse(runtime.config.config.isEnabled("gone"))
        let listed = try await row("gone")
        XCTAssertNil(listed)

        // A second removal of the same id keeps the first in the trash.
        _ = try await run("plugins.new", ["id": "gone"])
        let second = try json(try await run("plugins.remove", ["id": "gone"]))
        XCTAssertEqual(second["trashedTo"] as? String, ".trash/plugins/gone 2")
        XCTAssertTrue(exists(".trash/plugins/gone/plugin.json"))
    }

    func testRemoveRefusesUnknownAndBuiltinPlugins() async throws {
        for (id, expected) in [("nope", PluginPackageError.notInstalled("nope")), ("builtin", .builtin("builtin")),
                               ("../..", .notInstalled("../.."))] {
            do {
                _ = try await run("plugins.remove", ["id": id])
                XCTFail("removed \(id)")
            } catch let error as PluginPackageError {
                XCTAssertEqual(error, expected)
            }
        }
    }

    // MARK: plugins.install

    /// A git repository holding a plugin package, committed, returned as a file:// URL.
    private func makeRepository(files: [String: String]) throws -> String {
        let repository = scratch.appendingPathComponent("repo-\(UUID().uuidString)")
        for (path, text) in files {
            let url = repository.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
        try git(["init", "-q"], in: repository)
        try git(["add", "."], in: repository)
        try git(["-c", "user.email=test@example.com", "-c", "user.name=Test", "commit", "-q", "-m", "init"], in: repository)
        return repository.absoluteString
    }

    private func git(_ arguments: [String], in directory: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git"] + arguments
        process.currentDirectoryURL = directory
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            throw XCTSkip("git is not available")
        }
        process.waitUntilExit()
        if process.terminationStatus == 127 { throw XCTSkip("git is not available") }
        XCTAssertEqual(process.terminationStatus, 0, "git \(arguments)")
    }

    private let shareManifest = #"{"id": "share", "name": "Share", "version": "1.2.0", "library": "SharePlugin", "permissions": ["vault.read", "network"]}"#

    func testInstallClonesAGitRepositoryWithoutEnablingIt() async throws {
        let url = try makeRepository(files: ["plugin.json": shareManifest, "Package.swift": "// a package\n"])
        // A leftover flag must not turn the new plugin on.
        try runtime.config.mutate { $0.setEnabled(true, "share") }

        let result = try json(try await run("plugins.install", ["url": url, "build": "false"]))
        XCTAssertEqual(result["id"] as? String, "share")
        XCTAssertEqual(result["path"] as? String, vault.url(".loam/plugins/share").path)
        XCTAssertEqual(result["permissions"] as? [String], ["vault.read", "network"])
        XCTAssertEqual(result["built"] as? Bool, false)
        XCTAssertTrue(exists(".loam/plugins/share/Package.swift"))
        XCTAssertFalse(runtime.config.config.isExplicitlyEnabled("share"))
        let listed = try await row("share")
        XCTAssertEqual(listed?["enabled"] as? Bool, false)
        // Nothing left in the staging area.
        let cache = try FileManager.default.contentsOfDirectory(atPath: vault.url(".loam/cache").path)
        XCTAssertFalse(cache.contains { $0.hasPrefix("install-") }, "\(cache)")

        do {
            _ = try await run("plugins.install", ["url": url, "build": "false"])
            XCTFail("installed twice")
        } catch let error as PluginPackageError {
            XCTAssertEqual(error, .alreadyInstalled("share"))
        }
    }

    func testInstallCopiesALocalFolder() async throws {
        let folder = scratch.appendingPathComponent("share")
        try FileManager.default.createDirectory(at: folder.appendingPathComponent(".build"), withIntermediateDirectories: true)
        try shareManifest.write(to: folder.appendingPathComponent("plugin.json"), atomically: true, encoding: .utf8)
        _ = try await run("plugins.install", ["url": folder.path, "build": "false"])
        XCTAssertTrue(exists(".loam/plugins/share/plugin.json"))
        XCTAssertFalse(exists(".loam/plugins/share/.build"))
    }

    func testInstallRefusesARepositoryThatIsNotAPlugin() async throws {
        let cases: [([String: String], String)] = [
            (["README.md": "nothing"], "no plugin.json"),
            (["plugin.json": "{"], "cannot be read"),
            (["plugin.json": #"{"id": "../x", "name": "X", "version": "1", "library": "X"}"#], "\"id\" must be"),
            (["plugin.json": #"{"id": "builtin", "name": "X", "version": "1", "library": "X"}"#], "built-in"),
        ]
        for (files, message) in cases {
            let url = try makeRepository(files: files)
            do {
                _ = try await run("plugins.install", ["url": url, "build": "false"])
                XCTFail("installed \(files)")
            } catch {
                XCTAssertTrue(error.localizedDescription.contains(message), "\(error.localizedDescription)")
            }
        }
        do {
            _ = try await run("plugins.install", ["url": scratch.appendingPathComponent("missing").absoluteString])
            XCTFail("installed a missing repository")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("git clone"), error.localizedDescription)
        }
        XCTAssertFalse(exists(".loam/plugins"))
    }

    // MARK: plugins.build without a compiler

    func testBuildReportsAMissingSDKOrPlugin() async throws {
        _ = try await run("plugins.new", ["id": "lonely"])
        let builder = PluginBuilder(rootURL: vault.rootURL, sdk: .failure(.notFound))
        let result = await builder.build("lonely")
        XCTAssertFalse(result.ok)
        XCTAssertNil(result.library)
        XCTAssertTrue(result.log.contains("no Loam SDK found"), result.log)

        let missing = await builder.build("nope")
        XCTAssertFalse(missing.ok)
        XCTAssertTrue(missing.log.contains("plugin.json is missing"), missing.log)

        do {
            _ = try await run("plugins.build", ["id": "nope"])
            XCTFail("built a missing plugin")
        } catch let error as PluginPackageError {
            XCTAssertEqual(error, .notInstalled("nope"))
        }
    }

    func testBuildPinsTheSDKsDependencies() throws {
        let sdk = scratch.appendingPathComponent("sdk")
        let package = scratch.appendingPathComponent("plugin")
        try FileManager.default.createDirectory(at: sdk.appendingPathComponent("App"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        func pin(_ identity: String, _ version: String) -> String {
            #"{"identity": "\#(identity)", "kind": "remoteSourceControl", "location": "https://example.com/\#(identity)", "state": {"revision": "r\#(version)", "version": "\#(version)"}}"#
        }
        try #"{"pins": [\#(pin("yams", "5.4.0"))], "version": 3}"#.write(
            to: sdk.appendingPathComponent("Package.resolved"), atomically: true, encoding: .utf8)
        try #"{"pins": [\#(pin("swift-markdown", "0.9.0"))], "version": 3}"#.write(
            to: sdk.appendingPathComponent("App/Package.resolved"), atomically: true, encoding: .utf8)
        try #"{"originHash": "x", "pins": [\#(pin("yams", "6.0.0")), \#(pin("extra", "1.0.0"))], "version": 3}"#.write(
            to: package.appendingPathComponent("Package.resolved"), atomically: true, encoding: .utf8)

        try PluginBuilder(rootURL: vault.rootURL).pinDependencies(package: package, sdk: sdk)
        let data = try Data(contentsOf: package.appendingPathComponent("Package.resolved"))
        let pins = try XCTUnwrap((try JSONSerialization.jsonObject(with: data) as? [String: Any])?["pins"] as? [[String: Any]])
        let versions = Dictionary(uniqueKeysWithValues: pins.map {
            ($0["identity"] as! String, ($0["state"] as! [String: Any])["version"] as! String)
        })
        XCTAssertEqual(versions, ["yams": "5.4.0", "swift-markdown": "0.9.0", "extra": "1.0.0"])
    }

    func testProgressLinesAreLeftOutOfTheLog() {
        XCTAssertTrue(PluginBuilder.isProgress("[12 / 480]"))
        XCTAssertTrue(PluginBuilder.isProgress("[12 / 480] Yams"))
        XCTAssertTrue(PluginBuilder.isProgress("[302\u{2009}/\u{2009}460]"))
        XCTAssertFalse(PluginBuilder.isProgress("[error] something"))
        XCTAssertFalse(PluginBuilder.isProgress("error: no such module"))
    }

    /// The `.product(name:` names a generated Package.swift links.
    private func products(in package: String) -> [String] {
        package.components(separatedBy: ".product(name: \"").dropFirst().compactMap { $0.split(separator: "\"").first.map(String.init) }
    }
}

/// Where `loam plugin build` finds the SDK: LOAM_SDK, then the app bundle, then a checkout.
final class PluginSDKTests: XCTestCase {
    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("so-sdk-\(UUID().uuidString)").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: scratch)
    }

    /// Writes the two files that make a folder an SDK.
    @discardableResult
    private func makeSDK(_ path: String) throws -> URL {
        let url = scratch.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.appendingPathComponent("Sources/PluginKit"), withIntermediateDirectories: true)
        try "// manifest".write(to: url.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        try "// entry".write(to: url.appendingPathComponent("Sources/PluginKit/PluginEntry.swift"), atomically: true, encoding: .utf8)
        return url
    }

    private func makeExecutable(_ path: String) throws -> URL {
        let url = scratch.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: url.path, contents: Data())
        return url
    }

    func testPrecedence() throws {
        let environment = try makeSDK("env-sdk")
        let bundled = try makeSDK("Loam.app/Contents/Resources/SDK/loam")
        let bundleExecutable = try makeExecutable("Loam.app/Contents/Helpers/loam")
        let checkout = try makeSDK("checkout")
        let checkoutExecutable = try makeExecutable("checkout/CLI/.build/release/loam")
        let compiled = try makeSDK("compiled").appendingPathComponent("Sources/LoamCore/PluginSDK.swift").path

        func locate(_ env: [String: String], _ executable: URL?, _ source: String = "/nowhere/a/b/c.swift") -> PluginSDK? {
            try? PluginSDK.locate(environment: env, executableURL: executable, sourceFile: source).get()
        }
        // 1. LOAM_SDK wins over everything.
        XCTAssertEqual(locate(["LOAM_SDK": environment.path], bundleExecutable, compiled),
                       PluginSDK(url: environment, origin: .environment))
        // 2. Then the bundle of the running executable.
        XCTAssertEqual(locate([:], bundleExecutable, compiled), PluginSDK(url: bundled, origin: .bundle))
        // 3. Then a checkout containing the executable, then the checkout this file was compiled in.
        XCTAssertEqual(locate([:], checkoutExecutable, compiled), PluginSDK(url: checkout, origin: .checkout))
        XCTAssertEqual(locate([:], scratch.appendingPathComponent("elsewhere/so"), compiled),
                       PluginSDK(url: scratch.appendingPathComponent("compiled"), origin: .checkout))
        XCTAssertEqual(PluginSDK.locate(environment: [:], executableURL: nil, sourceFile: "/nowhere/a/b/c.swift"),
                       .failure(.notFound))
    }

    func testAnSDKThatIsNotThereIsAnErrorNotAFallback() throws {
        let bundleExecutable = try makeExecutable("Loam.app/Contents/Helpers/loam")
        try makeSDK("Loam.app/Contents/Resources/SDK/loam")
        let missing = scratch.appendingPathComponent("missing").path
        XCTAssertEqual(PluginSDK.locate(environment: ["LOAM_SDK": missing], executableURL: bundleExecutable),
                       .failure(.invalidEnvironment(missing)))
    }

    func testAnEmptyBundleSDKFallsBackToTheCheckout() throws {
        // A bundle without its SDK (a dev build of the app inside a checkout): the checkout around it is used.
        try makeSDK("checkout")
        let executable = try makeExecutable("checkout/App/build/Loam.app/Contents/Helpers/loam")
        XCTAssertEqual(try PluginSDK.locate(environment: [:], executableURL: executable).get(),
                       PluginSDK(url: scratch.appendingPathComponent("checkout"), origin: .checkout))
    }

    func testFollowsASymlinkedExecutable() throws {
        let bundled = try makeSDK("Loam.app/Contents/Resources/SDK/loam")
        let executable = try makeExecutable("Loam.app/Contents/Helpers/loam")
        let link = scratch.appendingPathComponent("bin/loam")
        try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: executable)
        XCTAssertEqual(try PluginSDK.locate(environment: [:], executableURL: link).get(), PluginSDK(url: bundled, origin: .bundle))
    }

    func testThisCheckoutIsFoundByDefault() throws {
        let sdk = try PluginSDK.locate(environment: [:]).get()
        XCTAssertTrue(sdk.isCheckout)
        XCTAssertTrue(PluginSDK.isSDK(sdk.url))
    }
}
