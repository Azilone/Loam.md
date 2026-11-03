import XCTest
import PluginKit
import PluginKitTesting
@testable import NoteGraphPlugin

final class NoteGraphMoveTests: XCTestCase {
    private var harness: PluginTestHarness!
    private var vault: TemporaryVault { harness.vault }

    override func setUpWithError() throws {
        harness = try PluginTestHarness([NoteGraphPlugin.self], files: [
            "index.md": "# Index\n[Plan](projects/plan.md) ![Chart](projects/img/chart.png) [Ideas](ideas.md)\n",
            "ideas.md": "# Ideas\n[Plan](projects/plan.md#goals)\n",
            "projects/plan.md": "# Plan\n[Back](../index.md) ![Chart](img/chart.png) [Notes](notes.md)\n",
            "projects/notes.md": "# Notes\n[Plan](plan.md)\n",
            "projects/img/chart.png": "png",
        ])
    }

    override func tearDown() {
        harness = nil
    }

    private func graph() throws -> NoteGraphService {
        try XCTUnwrap(harness.kernel.services.service(.noteGraph))
    }

    /// Records the move events in the order the kernel's event bus delivers them, with what was on
    /// disk and in the graph at that moment.
    private func recordEvents() throws -> () -> [String] {
        let graph = try graph()
        var log: [String] = []
        _ = harness.kernel.events.on(NotesWillMove.self) { [vault] event in
            let onDisk = event.moves.keys.allSatisfy { vault.exists($0) }
            log.append("will \(event.moves.count) files, sources on disk: \(onDisk)")
        }
        _ = harness.kernel.events.on(NotesMoved.self) { [vault] event in
            let onDisk = event.moves.values.allSatisfy { vault.exists($0) }
            let indexed = event.moves.values.filter { $0.hasSuffix(".md") }.allSatisfy { graph.note(at: $0) != nil }
            log.append("moved \(event.moves.count) files, on disk: \(onDisk), indexed: \(indexed)")
        }
        return { log }
    }

    func testMovingAFolderRewritesLinksFromOutsideAndKeepsRelativeLinksInside() throws {
        let result = try graph().move(["projects": "archive/2026"])

        XCTAssertEqual(result.moves, [
            "projects/plan.md": "archive/2026/plan.md",
            "projects/notes.md": "archive/2026/notes.md",
            "projects/img/chart.png": "archive/2026/img/chart.png",
        ])
        XCTAssertEqual(result.updated, ["archive/2026/plan.md", "ideas.md", "index.md"])
        XCTAssertEqual(
            try vault.read("index.md"),
            "# Index\n[Plan](archive/2026/plan.md) ![Chart](archive/2026/img/chart.png) [Ideas](ideas.md)\n"
        )
        XCTAssertEqual(try vault.read("ideas.md"), "# Ideas\n[Plan](archive/2026/plan.md#goals)\n")
        XCTAssertEqual(
            try vault.read("archive/2026/plan.md"),
            "# Plan\n[Back](../../index.md) ![Chart](img/chart.png) [Notes](notes.md)\n"
        )
        XCTAssertEqual(try vault.read("archive/2026/notes.md"), "# Notes\n[Plan](plan.md)\n")
        XCTAssertEqual(try vault.read("archive/2026/img/chart.png"), "png")
        XCTAssertFalse(vault.exists("projects"))
        XCTAssertEqual(
            try graph().backlinks(to: "archive/2026/plan.md"),
            ["archive/2026/notes.md", "ideas.md", "index.md"]
        )
    }

    func testMovingOneNoteAloneRewritesItsOwnRelativeLinks() throws {
        let result = try graph().move(["projects/plan.md": "plan.md"])
        XCTAssertEqual(result.moves, ["projects/plan.md": "plan.md"])
        XCTAssertEqual(
            try vault.read("plan.md"),
            "# Plan\n[Back](index.md) ![Chart](projects/img/chart.png) [Notes](projects/notes.md)\n"
        )
        XCTAssertEqual(try vault.read("projects/notes.md"), "# Notes\n[Plan](../plan.md)\n")
    }

    func testMovingAnAttachmentRewritesTheImageLinks() throws {
        let result = try graph().move(["projects/img/chart.png": "media/chart 1.png"])
        XCTAssertEqual(result.updated, ["index.md", "projects/plan.md"])
        XCTAssertTrue(try vault.read("index.md").contains("![Chart](media/chart%201.png)"))
        XCTAssertTrue(try vault.read("projects/plan.md").contains("![Chart](../media/chart%201.png)"))
    }

    func testEventsFireAroundTheDiskChangesWithExpandedMoves() throws {
        let events = try recordEvents()
        var received: [String: String] = [:]
        _ = harness.kernel.events.on(NotesMoved.self) { received = $0.moves }
        _ = try graph().move(["projects": "work"])
        XCTAssertEqual(events(), [
            "will 3 files, sources on disk: true",
            "moved 3 files, on disk: true, indexed: true",
        ])
        XCTAssertEqual(received, [
            "projects/plan.md": "work/plan.md",
            "projects/notes.md": "work/notes.md",
            "projects/img/chart.png": "work/img/chart.png",
        ])
    }

    func testAnInvalidMoveLeavesTheDiskUntouchedAndSendsNoEvent() throws {
        let events = try recordEvents()
        let before = try snapshot()
        let invalid: [([String: String], Error)] = [
            (["projects": "ideas.md"], VaultError.alreadyExists(path: "ideas.md")),
            (["projects/plan.md": "x.md", "missing.md": "y.md"], VaultError.notFound(path: "missing.md")),
            (["projects": "projects/inner"], NoteGraphError.moveIntoItself(path: "projects/inner")),
            (["ideas.md": "ideas.txt"], NoteGraphError.notMarkdown(path: "ideas.txt")),
            (
                ["projects": "p2", "projects/plan.md": "plan.md"],
                NoteGraphError.conflictingMoves(path: "projects/plan.md")
            ),
        ]
        for (moves, expected) in invalid {
            XCTAssertThrowsError(try graph().move(moves), "\(moves)") { error in
                XCTAssertEqual(String(describing: error), String(describing: expected))
            }
        }
        XCTAssertEqual(try snapshot(), before)
        XCTAssertEqual(events(), [])
    }

    func testRenameStillWorksAsAWrapper() async throws {
        let output = try await harness.run("notes.rename", ["from": "ideas.md", "to": "thoughts/Ideas.md"])
        let result = try JSONDecoder().decode(RenameResult.self, from: Data(output.utf8))
        XCTAssertEqual(result.from, "ideas.md")
        XCTAssertEqual(result.to, "thoughts/Ideas.md")
        XCTAssertEqual(result.updated, ["index.md", "thoughts/Ideas.md"])
        XCTAssertEqual(try vault.read("thoughts/Ideas.md"), "# Ideas\n[Plan](../projects/plan.md#goals)\n")
    }

    func testMoveCommandMovesAFolder() async throws {
        let output = try await harness.run("notes.move", ["from": "projects", "to": "work"])
        let result = try JSONDecoder().decode(MoveResult.self, from: Data(output.utf8))
        XCTAssertEqual(result.moves["projects/plan.md"], "work/plan.md")
        XCTAssertTrue(try vault.read("index.md").contains("[Plan](work/plan.md)"))
        XCTAssertTrue(vault.exists("work/img/chart.png"))
    }

    /// Every file of the vault with its contents.
    private func snapshot() throws -> [String: String] {
        var files: [String: String] = [:]
        func walk(_ folder: String) throws {
            for entry in try vault.list(folder) {
                if entry.isFolder { try walk(entry.path) } else { files[entry.path] = try vault.read(entry.path) }
            }
        }
        try walk("")
        return files
    }
}
