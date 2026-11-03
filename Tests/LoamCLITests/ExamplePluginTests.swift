import Foundation
import XCTest

/// End to end: the `loam` release build loads the example plugin (Examples/HelloPlugin) from a vault and runs its
/// command, which reaches the note graph of the runtime `loam` loaded. Skipped until both are built:
///
///     make release && scripts/build-example-plugin.sh <any folder>
///
/// The test process cannot load the plugin itself: it links the runtime's modules statically, and a plugin loaded
/// next to them would bring a second copy of every type. So it runs `loam` as a separate process.
final class ExamplePluginTests: XCTestCase {
    private let repository = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    func testLoamRunsTheExamplePluginOnceEnabled() throws {
        #if !os(macOS)
        throw XCTSkip("checked on macOS")
        #else
        let loam = repository.appendingPathComponent("CLI/.build/release/loam")
        let library = repository.appendingPathComponent("Examples/HelloPlugin/.build/release/libHelloPlugin.dylib")
        guard FileManager.default.isExecutableFile(atPath: loam.path),
              FileManager.default.fileExists(atPath: library.path) else {
            throw XCTSkip("build them first: make release && scripts/build-example-plugin.sh <folder>")
        }

        let vault = FileManager.default.temporaryDirectory.appendingPathComponent("loam-example-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: vault, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: vault) }
        for name in ["one", "two", "three"] {
            try "# \(name)\n".write(to: vault.appendingPathComponent("\(name).md"), atomically: true, encoding: .utf8)
        }
        _ = try run(repository.appendingPathComponent("scripts/build-example-plugin.sh"), ["--no-build", vault.path])

        // Installed, off by default.
        let before = try run(loam, ["--vault", vault.path, "hello.count"])
        XCTAssertTrue(before.output.contains("unknown command"), before.output)

        let enabled = try run(loam, ["--vault", vault.path, "plugins.enable", "id=hello"])
        if enabled.output.contains("built for another version") {
            throw XCTSkip("the example and `loam` were built from different sources; rebuild both")
        }
        let count = try run(loam, ["--vault", vault.path, "hello.count"])
        XCTAssertEqual(count.status, 0, count.output)
        XCTAssertTrue(count.output.contains("Hello from a plugin loaded from the vault: 3 notes."), count.output)
        #endif
    }

    private func run(_ executable: URL, _ arguments: [String]) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        // The test runner points DYLD_* at the debug build, whose runtime is not the one `loam` was built with.
        process.environment = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("DYLD_") }
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}
