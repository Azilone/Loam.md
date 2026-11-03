import XCTest
import PluginKit
import LoamCore
@testable import NoteGraphPlugin

final class NoteGraphPluginTests: XCTestCase {
    private var root: URL!
    private var vault: Vault!
    private var kernel: Kernel!
    private var host: PluginHost!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("graph-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        vault = Vault(rootURL: root)
        try vault.write("inbox.md", "# Inbox\n[Plan](projects/plan.md) #todo\n")
        try vault.write("projects/plan.md", "---\ntags: [work]\n---\n# Plan\n[Back](../inbox.md) [Ideas](../ideas.md)\n")
        try vault.write("ideas.md", "# Ideas\n[Plan](projects/plan.md#goals)\n")
        kernel = Kernel(vault: vault)
        host = PluginHost(kernel: kernel)
        try host.register(NoteGraphPlugin.self)
        try host.activateAll()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func graph() throws -> NoteGraphService {
        try XCTUnwrap(kernel.services.service(.noteGraph))
    }

    private func run(_ id: String, _ arguments: [String: String] = [:]) async throws -> String {
        try await XCTUnwrap(kernel.commands.command(id: id)).handler(arguments)
    }

    func testBaseFilesAreNotNotes() throws {
        try vault.write("Projects/Projects.base", "views: []\n")
        try kernel.refreshVault()
        try kernel.refreshVault()
        XCTAssertNil(try graph().note(at: "Projects/Projects.base"))
        kernel.events.emit(VaultChanged(changes: [VaultChange(kind: .modified, path: "Projects/Projects.base")]))
        XCTAssertNil(try graph().note(at: "Projects/Projects.base"))
    }

    func testBacklinksAndTags() throws {
        let graph = try graph()
        XCTAssertEqual(graph.backlinks(to: "projects/plan.md"), ["ideas.md", "inbox.md"])
        XCTAssertEqual(graph.backlinks(to: "inbox.md"), ["projects/plan.md"])
        XCTAssertEqual(graph.notes(tagged: "WORK").map(\.path), ["projects/plan.md"])
        XCTAssertEqual(graph.notes(tagged: "#todo").map(\.path), ["inbox.md"])
    }

    func testChangesToOtherFilesAreNotNotes() throws {
        XCTAssertEqual(try kernel.refreshVault(), [])
        try vault.write("Boards/Plan.canvas", "{\"nodes\":[{\"file\":\"inbox.md\"}]}")
        try vault.write("todo.txt", "- [ ] not a note [Plan](projects/plan.md)")
        XCTAssertEqual(try kernel.refreshVault().map(\.path), ["Boards/Plan.canvas", "todo.txt"])
        let graph = try graph()
        XCTAssertNil(graph.note(at: "Boards/Plan.canvas"))
        XCTAssertNil(graph.note(at: "todo.txt"))
        XCTAssertEqual(Set(graph.notes.map(\.path)), ["ideas.md", "inbox.md", "projects/plan.md"])
        XCTAssertEqual(graph.backlinks(to: "projects/plan.md"), ["ideas.md", "inbox.md"])
    }

    func testRenameMovesTheNoteAndFixesLinksOnBothSides() async throws {
        let output = try await run("notes.rename", ["from": "projects/plan.md", "to": "archive/Old plan.md"])
        XCTAssertTrue(output.contains("archive/Old plan.md"))

        XCTAssertFalse(vault.exists("projects/plan.md"))
        XCTAssertEqual(try vault.read("inbox.md"), "# Inbox\n[Plan](archive/Old%20plan.md) #todo\n")
        XCTAssertEqual(try vault.read("ideas.md"), "# Ideas\n[Plan](archive/Old%20plan.md#goals)\n")
        XCTAssertEqual(
            try vault.read("archive/Old plan.md"),
            "---\ntags: [work]\n---\n# Plan\n[Back](../inbox.md) [Ideas](../ideas.md)\n"
        )
        XCTAssertEqual(try graph().backlinks(to: "archive/Old plan.md"), ["ideas.md", "inbox.md"])
    }

    func testRenameRefusesAnExistingDestinationAndLeavesTheVaultUntouched() async throws {
        let before = try vault.read("inbox.md")
        do {
            _ = try await run("notes.rename", ["from": "projects/plan.md", "to": "ideas.md"])
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? VaultError, .alreadyExists(path: "ideas.md"))
        }
        XCTAssertEqual(try vault.read("inbox.md"), before)
        XCTAssertTrue(vault.exists("projects/plan.md"))
    }

    func testMissingArgumentIsReported() async throws {
        do {
            _ = try await run("notes.backlinks")
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? CommandError, .missingArgument(name: "path"))
        }
    }

    func testListCommandReturnsJSON() async throws {
        let output = try await run("notes.list", ["tag": "work"])
        let decoded = try JSONDecoder().decode([NoteInfo].self, from: Data(output.utf8))
        XCTAssertEqual(decoded.map(\.path), ["projects/plan.md"])
    }

    func testDeactivationRemovesCommandsAndService() throws {
        host.deactivateAll()
        XCTAssertNil(kernel.commands.command(id: "notes.list"))
        XCTAssertNil(kernel.services.service(.noteGraph))
    }
}

final class NoteGraphWatchTests: XCTestCase {
    func testTheGraphFollowsChangesOnDisk() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("graphwatch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let vault = Vault(rootURL: root)
        try vault.write("a.md", "# A\n")
        let kernel = Kernel(vault: vault)
        let host = PluginHost(kernel: kernel)
        try host.register(NoteGraphPlugin.self)
        try host.activateAll()
        try kernel.refreshVault()

        let graph = try XCTUnwrap(kernel.services.service(.noteGraph))
        XCTAssertEqual(graph.backlinks(to: "a.md"), [])

        try vault.write("b.md", "# B #idea\n[A](a.md)\n")
        try kernel.refreshVault()
        XCTAssertEqual(graph.backlinks(to: "a.md"), ["b.md"])
        XCTAssertEqual(graph.notes(tagged: "idea").map(\.path), ["b.md"])

        try FileManager.default.removeItem(at: root.appendingPathComponent("b.md"))
        try kernel.refreshVault()
        XCTAssertEqual(graph.backlinks(to: "a.md"), [])
        XCTAssertNil(graph.note(at: "b.md"))
    }
}
