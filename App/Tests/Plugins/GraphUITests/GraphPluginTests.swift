import BuiltinPlugins
import PluginKitUI
import PluginKitUITesting
import SwiftUI
import XCTest
@testable import GraphUI

/// The graph plugin in the UI harness, on the real `note-graph` logic plugin.
@MainActor
final class GraphPluginTests: XCTestCase {
    /// A → B, A → C, B → D, D → E; Orphan alone; A also links an image (not a note).
    private let files = [
        "A.md": "---\ntags: [project]\n---\n# A\n\nSee [B](B.md), [C](Ideas/C.md) and ![photo](photo.png).\n",
        "B.md": "# B\n\nNext: [D](D.md).\n",
        "Ideas/C.md": "# C\n\nAn #idea.\n",
        "D.md": "# D\n\n[E](E.md)\n",
        "E.md": "# E\n",
        "Orphan.md": "# Orphan\n\n#idea alone\n",
        "photo.png": "",
    ]
    private var harness: UIPluginHarness!

    override func setUp() async throws {
        harness = try UIPluginHarness(
            logicPlugins: builtinPlugins.filter { $0.manifest.id == "note-graph" },
            uiPlugins: [GraphPlugin.self],
            files: files
        )
        XCTAssertTrue(harness.host.isActive("graph"), "\(harness.report)")
    }

    override func tearDown() async throws {
        harness.close()
    }

    private var store: GraphStore {
        get throws { try XCTUnwrap(harness.kernel.services.service(GraphPlugin.storeKey)) }
    }

    private func tab(_ resource: Resource, state: Data? = nil) throws -> GraphTabModel {
        try store.makeTab(ViewContext(resource: resource, state: state))
    }

    private func titles(_ tab: GraphTabModel) -> [String] { tab.data.nodes.map(\.title) }

    func testTheWholeVault() throws {
        let tab = try tab(.virtual("graph:"))
        XCTAssertFalse(tab.isLocal)
        XCTAssertEqual(tab.data.nodes.map(\.path), ["A.md", "B.md", "D.md", "E.md", "Ideas/C.md", "Orphan.md"])
        XCTAssertEqual(tab.data.edges.count, 4, "the image is not a note")
        XCTAssertEqual(tab.data.nodes.map(\.degree), [2, 2, 2, 1, 1, 0])
        XCTAssertNil(tab.data.center)
        XCTAssertEqual(tab.positions.count, 6)
        XCTAssertEqual(tab.summary, "Graph of the vault: 6 notes, 4 links")
    }

    func testTheLocalGraphAtDepthOneAndTwo() throws {
        let tab = try tab(.virtual("graph:B.md"))
        XCTAssertTrue(tab.isLocal)
        XCTAssertEqual(titles(tab), ["A", "B", "D"], "its link and its backlink")
        XCTAssertEqual(tab.data.center.map { tab.data.nodes[$0].path }, "B.md")

        tab.filter.depth = 2
        XCTAssertEqual(titles(tab), ["A", "B", "D", "E", "C"])
        XCTAssertEqual(tab.positions.count, 5)

        let leaf = try self.tab(.virtual("graph:E.md"))
        XCTAssertEqual(titles(leaf), ["D", "E"], "backlinks count")
        let missing = try self.tab(.virtual("graph:Nope.md"))
        XCTAssertEqual(missing.data, GraphData())
    }

    func testTheTagFilterAndOrphans() throws {
        let tab = try tab(.virtual("graph:"))
        tab.filter.tag = "#IDE"
        XCTAssertEqual(titles(tab), ["C", "Orphan"], "case-insensitive, # optional, part of a tag")
        XCTAssertEqual(tab.data.edges, [])

        tab.filter.tag = ""
        tab.filter.showOrphans = false
        XCTAssertEqual(titles(tab), ["A", "B", "D", "E", "C"])

        tab.filter.tag = "idea"
        XCTAssertEqual(titles(tab), [], "with the filter, C has no link left")

        // A local graph keeps its centre whatever the filters.
        let local = try self.tab(.virtual("graph:B.md"))
        local.filter = GraphData.Filter(depth: 2, tag: "idea", showOrphans: false)
        XCTAssertEqual(titles(local), ["B"])
        local.filter.showOrphans = true
        XCTAssertEqual(titles(local), ["B", "C"])
    }

    func testFiltersAreSavedInTheTabState() throws {
        let view = ViewContext(resource: .virtual("graph:"))
        let tab = try store.makeTab(view)
        tab.filter.tag = "project"
        let saved = try XCTUnwrap(view.state(GraphTabState.self))
        XCTAssertEqual(saved.filter.tag, "project")

        let reopened = try self.tab(.virtual("graph:"), state: view.stateData)
        XCTAssertEqual(titles(reopened), ["A"])
    }

    func testAStateSavedWithTheOldListToggleStillOpens() throws {
        let old = Data(#"{"filter":{"depth":1,"tag":"project","showOrphans":true},"asList":true}"#.utf8)
        let tab = try self.tab(.virtual("graph:"), state: old)
        XCTAssertEqual(tab.filter.tag, "project")
        XCTAssertEqual(titles(tab), ["A"])
    }

    func testTagSuggestionsFollowWhatIsTyped() throws {
        let tab = try tab(.virtual("graph:"))
        let all = tab.tagSuggestions()
        XCTAssertFalse(all.isEmpty)
        XCTAssertEqual(all.map(\.count), all.map(\.count).sorted(by: >), "the most used first")
        let name = try XCTUnwrap(all.first?.name)
        tab.filter.tag = "#" + name.prefix(2).uppercased()
        XCTAssertTrue(tab.tagSuggestions().contains { $0.name == name })
        tab.filter.tag = name
        XCTAssertEqual(name, "idea")
        XCTAssertEqual(tab.tagSuggestions(), [], "nothing to pick once the tag is typed in full")
    }

    func testNewNotesGrowInAndTheHighlightEasesBothWays() throws {
        let tab = try tab(.virtual("graph:"))
        XCTAssertTrue(tab.motion.appear.allSatisfy { $0 == 0 })
        let size = CGSize(width: 600, height: 400)
        var date = Date()
        func run(_ frames: Int) {
            for _ in 0 ..< frames {
                date += 1.0 / 60
                tab.frame(at: date, in: size)
            }
        }
        run(120)
        XCTAssertTrue(tab.motion.appear.allSatisfy { $0 == 1 }, "every note has appeared")

        let b = try XCTUnwrap(tab.data.nodes.firstIndex { $0.path == "B.md" })
        tab.hovered = b
        XCTAssertTrue(tab.isAnimating, "a hover restarts the frames")
        run(2)
        XCTAssertGreaterThan(tab.motion.focus, 0)
        XCTAssertLessThan(tab.motion.focus, 1, "the highlight eases in rather than jumping")
        run(60)
        XCTAssertEqual(tab.motion.focus, 1)
        XCTAssertEqual(tab.motion.grow[b], 1)
        for n in tab.neighbours(of: b) { XCTAssertEqual(tab.motion.lit[n], 1) }

        tab.hovered = nil
        run(60)
        XCTAssertEqual(tab.motion.focus, 0)
        XCTAssertEqual(tab.motion.grow[b], 0)
    }

    func testAChangedFilterKeepsTheNotesThatStayInPlace() throws {
        let tab = try tab(.virtual("graph:"))
        let size = CGSize(width: 600, height: 400)
        var date = Date()
        for _ in 0 ..< 200 {
            date += 1.0 / 60
            tab.frame(at: date, in: size)
        }
        tab.filter.showOrphans = false
        XCTAssertTrue(tab.motion.appear.allSatisfy { $0 == 1 }, "the notes left were already there")
        XCTAssertTrue(tab.isAnimating, "the layout and the camera move to the new graph")
    }

    func testAClickOpensTheNoteBesideTheGraph() throws {
        let tab = try tab(.virtual("graph:"))
        let size = CGSize(width: 600, height: 400)
        tab.fit(in: size)
        let target = try XCTUnwrap(tab.data.nodes.firstIndex { $0.path == "D.md" })
        let location = tab.screenPoint(tab.positions[target], in: size)
        XCTAssertEqual(tab.node(at: location, in: size), target)
        XCTAssertNil(tab.node(at: CGPoint(x: -500, y: -500), in: size))

        tab.open(try XCTUnwrap(tab.node(at: location, in: size)))
        XCTAssertEqual(harness.workspace.opened.map(\.resource), [.file("D.md")])
        XCTAssertEqual(harness.workspace.opened.map(\.placement), [.beside])
    }

    func testHoverNeighboursAndZoom() throws {
        let tab = try tab(.virtual("graph:"))
        let b = try XCTUnwrap(tab.data.nodes.firstIndex { $0.path == "B.md" })
        XCTAssertEqual(Set(tab.neighbours(of: b).map { tab.data.nodes[$0].path }), ["A.md", "D.md"])

        let size = CGSize(width: 600, height: 400)
        tab.fit(in: size)
        let anchor = tab.screenPoint(tab.positions[b], in: size)
        tab.zoom(by: 2, around: anchor, in: size)
        let after = tab.screenPoint(tab.positions[b], in: size)
        XCTAssertEqual(after.x, anchor.x, accuracy: 0.001, "zooming keeps the point under the pointer")
        XCTAssertEqual(after.y, anchor.y, accuracy: 0.001)
        tab.zoom(by: 1000, around: anchor, in: size)
        XCTAssertEqual(tab.scale, 8)
    }

    func testRefreshesWhenTheVaultChanges() throws {
        let tab = try tab(.virtual("graph:"))
        try harness.vault.write("F.md", "# F\n\n[A](A.md)\n")
        harness.kernel.events.emit(VaultChanged(changes: [VaultChange(kind: .added, path: "F.md")]))
        XCTAssertTrue(titles(tab).contains("F"))
        XCTAssertEqual(tab.positions.count, tab.data.nodes.count)
    }

    func testViewTypeOpensOnlyGraphResources() throws {
        let type = try XCTUnwrap(harness.views.all.first { $0.id == "graph.vault" })
        XCTAssertTrue(type.canOpen(.virtual("graph:")))
        XCTAssertTrue(type.canOpen(.virtual("graph:Projects/Plan.md")))
        XCTAssertFalse(type.canOpen(.virtual("calendar:")))
        XCTAssertFalse(type.canOpen(.virtual("mindmap:A.md")))
        XCTAssertFalse(type.canOpen(.file("graph:A.md")))
        XCTAssertFalse(type.canOpen(.file("A.md")))
    }

    func testRendersOffscreenInEveryMode() throws {
        let type = try XCTUnwrap(harness.views.all.first { $0.id == "graph.vault" })
        let size = CGSize(width: 640, height: 420)
        for resource: Resource in [.virtual("graph:"), .virtual("graph:B.md"), .virtual("graph:Missing.md")] {
            XCTAssertEqual(harness.render(type.makeView(ViewContext(resource: resource)), size: size).frame.size, size)
        }
        let filtered = try JSONEncoder().encode(GraphTabState(filter: GraphData.Filter(tag: "project")))
        let view = ViewContext(resource: .virtual("graph:"), state: filtered)
        XCTAssertEqual(harness.render(type.makeView(view), size: size).frame.size, size)
    }

    func testCommands() async throws {
        let opened = try await harness.run("graph.open")
        XCTAssertEqual(opened, "Opened the graph of the vault.")
        XCTAssertEqual(harness.workspace.opened.last?.resource, .virtual("graph:"))
        XCTAssertEqual(harness.workspace.opened.last?.placement, .newTab)

        do {
            _ = try await harness.run("graph.open-local")
            XCTFail("the active tab is not a note")
        } catch let error as CommandError {
            XCTAssertEqual(error, .missingArgument(name: "path"))
        }

        harness.workspace.activeResource = .file("B.md")
        _ = try await harness.run("graph.open-local")
        XCTAssertEqual(harness.workspace.opened.last?.resource, .virtual("graph:B.md"))
        XCTAssertEqual(harness.workspace.opened.last?.placement, .beside)

        _ = try await harness.run("graph.open-local", ["path": "E.md"])
        XCTAssertEqual(harness.workspace.opened.last?.resource, .virtual("graph:E.md"))
    }

    func testDoesNotStartWithoutTheNoteGraphAndUnloadsCleanly() throws {
        let bare = try UIPluginHarness(uiPlugins: [GraphPlugin.self])
        defer { bare.close() }
        XCTAssertFalse(bare.host.isActive("graph"))

        harness.host.deactivate("graph")
        XCTAssertTrue(harness.views.all.isEmpty)
        XCTAssertNil(harness.kernel.commands.command(id: "graph.open"))
        XCTAssertNil(harness.kernel.commands.command(id: "graph.open-local"))
    }

    func testTheLayoutMovesUntilItSettles() throws {
        let tab = try tab(.virtual("graph:"))
        XCTAssertTrue(tab.isAnimating)
        let size = CGSize(width: 600, height: 400)
        let start = tab.positions
        var date = Date()
        for _ in 0 ..< 400 {
            date += 1.0 / 60
            tab.frame(at: date, in: size)
        }
        XCTAssertNotEqual(tab.positions, start)
        XCTAssertTrue(tab.simulation.isSettled)
        let bounds = GraphLayout.bounds(of: tab.positions.map { tab.screenPoint($0, in: size) })
        XCTAssertTrue(CGRect(origin: .zero, size: size).insetBy(dx: -1, dy: -1).contains(bounds),
                      "the camera follows the graph while it settles")
    }

    func testDraggingANodeMovesItWithoutOpeningIt() throws {
        let tab = try tab(.virtual("graph:"))
        let size = CGSize(width: 600, height: 400)
        tab.simulation.settle()
        tab.fit(in: size)
        let b = try XCTUnwrap(tab.data.nodes.firstIndex { $0.path == "B.md" })
        tab.beginDrag(b)
        tab.drag(to: CGPoint(x: 20, y: 20), in: size)
        var date = Date()
        for _ in 0 ..< 30 {
            date += 1.0 / 60
            tab.frame(at: date, in: size)
        }
        let point = tab.screenPoint(tab.simulation.position(b), in: size)
        XCTAssertEqual(point.x, 20, accuracy: 0.001)
        XCTAssertEqual(point.y, 20, accuracy: 0.001)
        XCTAssertFalse(tab.simulation.isSettled)
        tab.endDrag()
        XCTAssertNil(tab.dragged)
        XCTAssertEqual(tab.simulation.alphaTarget, 0)
        XCTAssertTrue(harness.workspace.opened.isEmpty)
    }

    func testTheSidebarLinkOpensTheVaultGraph() throws {
        let link = try XCTUnwrap(harness.panels.links.first { $0.id == "graph.vault-link" })
        XCTAssertEqual(link.title, "Graph view")
        XCTAssertEqual(link.resource, .virtual("graph:"))
        harness.host.deactivate("graph")
        XCTAssertFalse(harness.panels.links.contains { $0.id == "graph.vault-link" })
    }
}
