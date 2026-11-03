import Foundation
import PluginKit
import PluginKitTesting
import XCTest
@testable import LoamCore

/// Keeps its context so a test can read and write through `context.vault`, as a plugin would.
private final class WriterPlugin: Plugin {
    static var manifest: PluginManifest { PluginManifest(id: "writer", name: "Writer", version: "1.0.0") }
    static var context: PluginContext?
    required init() {}
    func activate(context: PluginContext) throws { Self.context = context }
    func deactivate() { Self.context = nil }
}

/// `context.vault` announces a plugin's reads and writes (`NoteWillRead`, `NoteWillChange`, `NoteDidChange`).
final class NotifyingVaultTests: XCTestCase {
    private var harness: PluginTestHarness!
    private var log: [String] = []
    private var stops: [() -> Void] = []

    override func setUpWithError() throws {
        harness = try PluginTestHarness([WriterPlugin.self], files: ["Note.md": "# Note\n"])
        let events = harness.kernel.events
        stops = [
            events.on(NoteWillRead.self) { [unowned self] in log.append("read \($0.path) \($0.pluginID)") },
            events.on(NoteWillChange.self) { [unowned self] in log.append("will \($0.path) \($0.pluginID)") },
            events.on(NoteDidChange.self) { [unowned self] in log.append("did \($0.path) \($0.pluginID)") },
        ]
    }

    override func tearDown() {
        for stop in stops { stop() }
        harness = nil
    }

    private var vault: VaultAccess { WriterPlugin.context!.vault }

    func testAWriteIsAnnouncedBeforeAndAfterWithThePluginsID() throws {
        try vault.write("./Folder/../Note.md", "changed")
        XCTAssertEqual(log, ["will Note.md writer", "did Note.md writer"], "paths normalized, in order")
        XCTAssertEqual(try harness.vault.read("Note.md"), "changed")

        log = []
        try vault.writeData("photo.png", Data([1, 2]))
        XCTAssertEqual(log, ["will photo.png writer", "did photo.png writer"])
    }

    func testAFailedWriteIsAnnouncedBeforeButNotAfter() throws {
        XCTAssertThrowsError(try vault.write("../Outside.md", "x"))
        XCTAssertEqual(log, ["will ../Outside.md writer"])
        log = []
        XCTAssertThrowsError(try vault.move("Missing.md", to: "Other.md"))
        XCTAssertEqual(log, ["will Missing.md writer", "will Other.md writer"])
    }

    func testAMoveIsAnnouncedForTheSourceAndTheDestination() throws {
        try vault.move("Note.md", to: "Archive/Note.md")
        XCTAssertEqual(log, [
            "will Note.md writer", "will Archive/Note.md writer",
            "did Note.md writer", "did Archive/Note.md writer",
        ])
    }

    func testReadsAreAnnouncedAndListingsAreNot() throws {
        XCTAssertEqual(try vault.read("Note.md"), "# Note\n")
        XCTAssertEqual(log, ["read Note.md writer"])
        log = []
        _ = try vault.markdownPaths()
        _ = try vault.stamps()
        _ = try vault.list("")
        _ = vault.exists("Note.md")
        try vault.createFolder("Empty")
        XCTAssertEqual(log, [])
    }

    func testTheKernelsOwnVaultIsSilent() throws {
        _ = try harness.kernel.vault.read("Note.md")
        try harness.kernel.vault.write("Note.md", "quiet")
        XCTAssertEqual(log, [])
    }
}
