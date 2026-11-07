import Foundation
import XCTest

/// End to end, slow (each test compiles the runtime for its plugin, about a minute): `loam plugin new`, `build`,
/// `install`, then enable and run the plugin's command in a `loam` process. Uses the app's `loam`
/// (`App/build/Loam.app/Contents/Helpers/loam`, whose SDK is the bundle's) or else `CLI/.build/release/loam`
/// (whose SDK is this checkout); skipped until one is built (`make app` or `make release`), on Linux, and when
/// `LOAM_SKIP_SLOW=1`.
///
/// A test process cannot load a plugin itself (it links the runtime's modules statically), hence the `loam` process.
final class PluginBuildTests: XCTestCase {
    private let repository = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    private var vault: URL!
    private var loam: URL!

    override func setUpWithError() throws {
        #if !os(macOS)
        throw XCTSkip("compiles plugins on macOS only")
        #else
        if ProcessInfo.processInfo.environment["LOAM_SKIP_SLOW"] == "1" { throw XCTSkip("LOAM_SKIP_SLOW=1") }
        let candidates = ["App/build/Loam.app/Contents/Helpers/loam", "CLI/.build/release/loam"]
            .map { repository.appendingPathComponent($0) }
        guard let loam = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) else {
            throw XCTSkip("build `loam` first: make app (or make release)")
        }
        self.loam = loam
        vault = FileManager.default.temporaryDirectory.appendingPathComponent("loam-plugin-build-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: vault, withIntermediateDirectories: true)
        for name in ["one", "two", "three"] {
            try "# \(name)\n".write(to: vault.appendingPathComponent("\(name).md"), atomically: true, encoding: .utf8)
        }
        #endif
    }

    override func tearDownWithError() throws {
        if let vault {
            try? FileManager.default.removeItem(at: vault)
            try? FileManager.default.removeItem(at: vault.appendingPathExtension("trust.json"))
        }
    }

    func testNewBuildEnableAndRunALogicPlugin() throws {
        XCTAssertEqual(try loam(["plugin", "new", "hello2"]).status, 0)
        try build("hello2")
        try enable("hello2")
        let output = try loam(["hello2.hello", "name=Test"])
        XCTAssertEqual(output.status, 0, output.text)
        XCTAssertEqual(output.text, "Hello Test. Notes in this vault: 3.\n")
    }

    func testNewAndBuildAUIPluginLinkingOnlyTheRuntimes() throws {
        XCTAssertEqual(try loam(["plugin", "new", "hello-panel", "--ui"]).status, 0)
        let library = try build("hello-panel")
        // `loam` has no UI runtime to load it with; the app does (checked by hand, docs/PLUGIN-LOADING.md). Here: it
        // links the two runtime libraries by install name, and defines no type they define.
        let links = try run(URL(fileURLWithPath: "/usr/bin/otool"), ["-L", library]).text
        XCTAssertTrue(links.contains("@rpath/libLoamRuntime.dylib"), links)
        XCTAssertTrue(links.contains("@rpath/libLoamUIRuntime.dylib"), links)
        let bundle = repository.appendingPathComponent("App/build/Loam.app/Contents/Frameworks")
        if FileManager.default.fileExists(atPath: bundle.path) {
            let check = try run(repository.appendingPathComponent("scripts/check-single-copy.sh"), [
                library,
                bundle.appendingPathComponent("libLoamRuntime.dylib").path,
                bundle.appendingPathComponent("libLoamUIRuntime.dylib").path,
            ])
            XCTAssertEqual(check.status, 0, check.text)
        }
    }

    func testInstallFromAGitRepositoryThenEnableAndRun() throws {
        // A copy of the example plugin, committed in a local repository: no network.
        let source = vault.deletingLastPathComponent().appendingPathComponent("loam-hello-repo-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: source) }
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        for file in ["Package.swift", "Package.resolved", "plugin.json", "Sources"] {
            try FileManager.default.copyItem(
                at: repository.appendingPathComponent("Examples/HelloPlugin/\(file)"), to: source.appendingPathComponent(file)
            )
        }
        let git = URL(fileURLWithPath: "/usr/bin/git")
        for arguments in [["init", "-q"], ["add", "."], ["-c", "user.email=t@example.com", "-c", "user.name=T", "commit", "-q", "-m", "init"]] {
            XCTAssertEqual(try run(git, ["-C", source.path] + arguments).status, 0)
        }

        let installed = try loam(["plugin", "install", source.absoluteString])
        XCTAssertEqual(installed.status, 0, installed.text)
        let result = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(installed.text.utf8)) as? [String: Any])
        XCTAssertEqual(result["id"] as? String, "hello")
        XCTAssertEqual(result["permissions"] as? [String], ["vault.read"])
        XCTAssertEqual(result["built"] as? Bool, true, result["log"] as? String ?? "")
        // Installed, not enabled.
        XCTAssertTrue(try loam(["hello.count"]).text.contains("unknown command"))
        try enable("hello")
        let count = try loam(["hello.count"])
        XCTAssertEqual(count.text, "Hello from a plugin loaded from the vault: 3 notes.\n")

        let removed = try loam(["plugin", "remove", "hello"])
        XCTAssertEqual(removed.status, 0, removed.text)
        XCTAssertTrue(try loam(["hello.count"]).text.contains("unknown command"))
    }

    // MARK: Helpers

    /// Builds a plugin and returns its library's path.
    @discardableResult
    private func build(_ id: String) throws -> String {
        let output = try loam(["plugin", "build", id])
        XCTAssertEqual(output.status, 0, output.text)
        let result = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(output.text.utf8)) as? [String: Any], output.text)
        XCTAssertEqual(result["ok"] as? Bool, true, result["log"] as? String ?? "")
        return try XCTUnwrap(result["library"] as? String, output.text)
    }

    private func enable(_ id: String) throws {
        let output = try loam(["plugin", "enable", id])
        if output.text.contains("built for another version") || output.text.contains("needs a newer version of the app") {
            throw XCTSkip("`loam` and this checkout differ; rebuild `loam` (make app or make release): \(output.text)")
        }
        XCTAssertTrue(output.text.replacingOccurrences(of: " ", with: "").contains("\"active\":true"), output.text)
    }

    private func loam(_ arguments: [String]) throws -> (status: Int32, text: String) {
        try run(loam, ["--vault", vault.path] + arguments)
    }

    private func run(_ executable: URL, _ arguments: [String]) throws -> (status: Int32, text: String) {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        // The test runner points DYLD_* at the debug build, whose runtime is not the one `loam` was built with; LOAM_SDK
        // would override the SDK `loam` finds.
        process.environment = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("DYLD_") && $0.key != "LOAM_SDK" }
        // Plugins turned on here are remembered beside the test vault, not in this user's own file.
        process.environment?["LOAM_TRUST_FILE"] = vault.appendingPathExtension("trust.json").path
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}
