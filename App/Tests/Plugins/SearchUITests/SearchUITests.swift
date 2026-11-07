import Foundation
import PluginKitUI
import PluginKitUITesting
@testable import SearchUI
import SwiftUI
import TruffleSearchPlugin
import XCTest

/// A Truffle that is never running, so the built-in search answers names and content whatever runs on this Mac.
private struct NoTruffle: TruffleTransport {
    func request(_ request: [String: Any]) throws -> [String: Any] {
        throw TruffleError.daemonNotRunning(socket: "/nowhere.sock")
    }
}

/// A Truffle that runs: its status says so, and meaning search finds the plan.
private struct RunningTruffle: TruffleTransport {
    let root: String
    func request(_ request: [String: Any]) throws -> [String: Any] {
        switch request["op"] as? String {
        case "status": return ["ok": true, "entries": 3]
        case "meaning.search": return ["ok": true, "hits": [["path": root + "/Projects/Plan.md", "excerpt": "Ship it"]]]
        default: throw TruffleError.daemon("not in this test")
        }
    }
}

/// The `search` service on the temporary vault, with no Truffle: the fallback.
private final class FallbackSearchPlugin: Plugin {
    static var manifest: PluginManifest { PluginManifest(id: "test.search", name: "Search", version: "1", provides: ["search"]) }
    init() {}
    func activate(context: PluginContext) throws {
        try context.provide(.search, VaultSearchService(vault: context.vault, truffle: NoTruffle()))
    }
}

/// The same service, with a Truffle that runs.
private final class TruffleSearchStub: Plugin {
    static var manifest: PluginManifest { PluginManifest(id: "test.search", name: "Search", version: "1", provides: ["search"]) }
    init() {}
    func activate(context: PluginContext) throws {
        let root = context.vault.rootURL.standardizedFileURL.path
        try context.provide(.search, VaultSearchService(vault: context.vault, truffle: RunningTruffle(root: root)))
    }
}

@MainActor
final class SearchUITests: XCTestCase {
    private let files = [
        "Welcome.md": "# Welcome\n\nStart with the plan.\n",
        "Projects/Plan.md": "# Plan\n\nShip the search panel.\nThen the PLAN for backlinks.\n",
        "Ideas/Spark.md": "# A spark\n\nNothing to see.\n",
    ]

    private func harness(truffle: Bool = false) throws -> UIPluginHarness {
        try UIPluginHarness(
            logicPlugins: [truffle ? TruffleSearchStub.self : FallbackSearchPlugin.self],
            uiPlugins: [SearchUIPlugin.self],
            files: files
        )
    }

    private func model(_ harness: UIPluginHarness) throws -> SearchModel {
        try XCTUnwrap(harness.kernel.services.service(SearchUIPlugin.modelKey), "\(harness.report)")
    }

    func testPanelSitsAfterFilesInTheLeadingSlotAndRenders() throws {
        let harness = try harness()
        defer { harness.close() }
        XCTAssertTrue(harness.host.isActive("search-ui"), "\(harness.report)")
        let panel = try XCTUnwrap(harness.panels.panels(in: .leading).first)
        XCTAssertEqual(panel.id, "search.panel")
        XCTAssertEqual(panel.title, "Search")
        XCTAssertEqual(panel.symbol, "magnifyingglass")
        XCTAssertEqual(panel.order, 1)
        let size = CGSize(width: 260, height: 500)
        XCTAssertEqual(harness.render(panel.makeView(), size: size).frame.size, size)
    }

    func testTypingReturnsHitsGroupedByNote() async throws {
        let harness = try harness()
        defer { harness.close() }
        let model = try model(harness)
        XCTAssertEqual(model.kind, .content)
        model.setQuery("plan")
        await model.pending?.value
        XCTAssertEqual(model.groups.map(\.path), ["Projects/Plan.md", "Welcome.md"])
        XCTAssertEqual(model.groups.map(\.title), ["Plan", "Welcome"])
        XCTAssertEqual(model.groups.map(\.folder), ["Projects", ""])
        XCTAssertEqual(model.groups[0].rows.map(\.hit.line), [1, 4])
        XCTAssertEqual(model.groups[0].rows.map(\.hit.snippet), ["# Plan", "Then the PLAN for backlinks."])
        // Groups and rows share one list: no two may have the same id.
        let ids = model.groups.map(\.id) + model.groups.flatMap { $0.rows.map(\.id) }
        XCTAssertEqual(Set(ids).count, ids.count)

        // The panel renders with results too.
        let panel = try XCTUnwrap(harness.panels.panels(in: .leading).first)
        let size = CGSize(width: 260, height: 500)
        XCTAssertEqual(harness.render(panel.makeView(), size: size).frame.size, size)

        model.setKind(.names)
        await model.pending?.value
        XCTAssertEqual(model.groups.map(\.path), ["Projects/Plan.md"])

        model.setQuery("")
        XCTAssertEqual(model.groups, [])
    }

    func testOnlyTheLastQueryCounts() async throws {
        let harness = try harness()
        defer { harness.close() }
        let model = try model(harness)
        model.setQuery("spark")
        model.setQuery("ship")
        await model.pending?.value
        XCTAssertEqual(model.groups.map(\.path), ["Projects/Plan.md"])
    }

    func testClickOpensTheNoteAndCommandClickBesideIt() throws {
        let harness = try harness()
        defer { harness.close() }
        let model = try model(harness)
        model.open("Projects/Plan.md", beside: false)
        model.open("Welcome.md", beside: true)
        XCTAssertEqual(harness.workspace.opened.map(\.resource), [.file("Projects/Plan.md"), .file("Welcome.md")])
        XCTAssertEqual(harness.workspace.opened.map(\.placement), [.replace, .beside])
    }

    func testMeaningIsDisabledWhileTruffleIsNotRunning() async throws {
        let harness = try harness()
        defer { harness.close() }
        let model = try model(harness)
        await model.refreshStatus().value
        XCTAssertEqual(model.status?.truffleRunning, false)
        XCTAssertFalse(model.meaningAvailable)
        model.setKind(.meaning)
        XCTAssertEqual(model.kind, .content, "meaning cannot be picked")
    }

    func testMeaningWorksWhenTruffleRuns() async throws {
        let harness = try harness(truffle: true)
        defer { harness.close() }
        let model = try model(harness)
        await model.refreshStatus().value
        XCTAssertTrue(model.meaningAvailable)
        model.setQuery("shipping software")
        model.setKind(.meaning)
        XCTAssertEqual(model.kind, .meaning)
        await model.pending?.value
        XCTAssertEqual(model.groups.map(\.path), ["Projects/Plan.md"])
        XCTAssertEqual(model.groups.first?.rows.first?.hit.snippet, "Ship it")
    }

    func testSearchFocusShowsAQuickPickOfContentHitsThatOpensTheNote() async throws {
        let harness = try harness()
        defer { harness.close() }
        let command = try XCTUnwrap(harness.kernel.commands.command(id: "search.focus"))
        XCTAssertEqual(command.shortcut, KeyShortcut("f", [.command, .shift]))
        _ = try await harness.run("search.focus")
        XCTAssertEqual(harness.quickPick.shownCount, 1)
        XCTAssertEqual(harness.quickPick.placeholder, "Search in notes…")

        let empty = await harness.quickPick.search("")
        XCTAssertEqual(empty, [])
        let plan = await harness.quickPick.search("plan")
        XCTAssertEqual(plan.count, 3)
        XCTAssertEqual(plan.first?.title, "Plan")
        XCTAssertEqual(plan.first?.subtitle, "Plan — Projects")
        XCTAssertEqual(plan.first?.detail, "line 1")
        XCTAssertEqual(Set(plan.map(\.id)).count, plan.count)

        let ship = await harness.quickPick.search("ship")
        XCTAssertEqual(ship.map(\.title), ["Ship the search panel."])
        XCTAssertTrue(harness.quickPick.choose(id: ship[0].id))
        XCTAssertEqual(harness.workspace.opened.map(\.resource), [.file("Projects/Plan.md")])
        XCTAssertEqual(harness.workspace.opened.map(\.placement), [.replace])
    }

    func testSnippetsShowTextWithoutMarkdownMarks() {
        XCTAssertEqual(SearchModel.plainSnippet("### 🎙 19:04 · Test de la note"), "🎙 19:04 · Test de la note")
        XCTAssertEqual(SearchModel.plainSnippet("*Je <mark>teste</mark> la note.*"), "Je teste la note.")
        XCTAssertEqual(SearchModel.plainSnippet("- [ ] Ship **it** with [the plan](Plan.md)"), "Ship it with the plan")
        XCTAssertEqual(SearchModel.plainSnippet("…in `code` here"), "…in code here")
        XCTAssertEqual(SearchModel.plainSnippet("2. snake_case stays"), "snake_case stays")
    }

    func testMatchesAreEmphasised() {
        let text = emphasised("Plan the plan", "PLAN")
        let bold = text.runs.filter { $0.inlinePresentationIntent == .stronglyEmphasized }.map { String(text[$0.range].characters) }
        XCTAssertEqual(bold, ["Plan", "plan"])
        XCTAssertTrue(emphasised("Plan", "").runs.allSatisfy { $0.inlinePresentationIntent == nil })
    }

    func testUnloadingRemovesThePanelAndTheCommand() throws {
        let harness = try harness()
        defer { harness.close() }
        harness.host.deactivateAll()
        XCTAssertEqual(harness.panels.all.map(\.id), [])
        XCTAssertNil(harness.kernel.commands.command(id: "search.focus"))
    }
}
