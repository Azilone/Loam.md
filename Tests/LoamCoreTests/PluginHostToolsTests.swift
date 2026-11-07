import XCTest
import PluginKit
@testable import LoamCore

final class PluginHostToolsTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("host-tools-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private final class Needy: Plugin {
        static var manifest: PluginManifest {
            PluginManifest(id: "needy", name: "Needy", version: "1.0.0")
        }
        static var requiresTools: [String] { ["needy-tool"] }
        required init() {}
        func activate(context: PluginContext) throws {}
    }

    /// A host whose tools are the test folder's, so a tool is missing until a test puts it there.
    private func makeHost() -> (host: PluginHost, kernel: Kernel) {
        let tools = ToolLocator(folders: [folder.path], developerTools: { false })
        let kernel = Kernel(vault: Vault(rootURL: FileManager.default.temporaryDirectory), tools: tools)
        return (PluginHost(kernel: kernel), kernel)
    }

    private func installTool(_ name: String) {
        FileManager.default.createFile(
            atPath: folder.appendingPathComponent(name).path, contents: Data("#!/bin/sh\n".utf8),
            attributes: [.posixPermissions: 0o755]
        )
    }

    func testPluginWaitsForItsRequiredToolThenStarts() throws {
        let (host, kernel) = makeHost()
        try host.register(Needy.self)

        let waiting = host.apply(enabled: ["needy"])
        XCTAssertEqual(waiting.skipped["needy"], "needs needy-tool, not installed")
        XCTAssertTrue(waiting.failed.isEmpty)
        XCTAssertFalse(host.isActive("needy"))
        XCTAssertEqual(host.missingTools(of: "needy"), ["needy-tool"])

        installTool("needy-tool")
        kernel.tools.refresh()
        let started = host.apply(enabled: ["needy"])
        XCTAssertEqual(started.activated, ["needy"])
        XCTAssertTrue(host.isActive("needy"))
        XCTAssertEqual(host.missingTools(of: "needy"), [])
        host.deactivateAll()
    }

    func testStrictActivationRefusesAPluginWithAMissingTool() throws {
        let (host, _) = makeHost()
        try host.register(Needy.self)
        XCTAssertThrowsError(try host.activateAll(enabled: ["needy"])) { error in
            XCTAssertEqual(error as? PluginError, .missingTools(plugin: "needy", tools: ["needy-tool"]))
        }
        XCTAssertFalse(host.isActive("needy"))
    }
}
