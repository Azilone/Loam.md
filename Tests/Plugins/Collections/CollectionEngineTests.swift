import XCTest
import LoamCore
import NoteGraphPlugin
import NoteQueryPlugin
import PluginKit
import PluginKitTesting
@testable import CollectionsPlugin

/// Running views over notes, writing entries and `.base` files, and following folder moves.
final class CollectionEngineTests: XCTestCase {
    private let base = """
    filters:
      and:
        - file.inFolder("Projects")
        - file.ext == "md"
    properties:
      status:
        type: select
        options:
          - To do
          - In progress
          - Done
    views:
      - type: kanban
        name: Board
        groupBy:
          property: status
          direction: ASC
        order:
          - file.name
          - status
          - priority
      - type: table
        name: Urgent
        filters: priority > 1
        sort:
          - property: priority
            direction: DESC
        limit: 2

    """

    private var files: [String: String] {
        [
            "Projects/Projects.base": base,
            "Projects/alpha.md": "---\nstatus: To do\npriority: 3\n---\n# Alpha\n",
            "Projects/beta.md": "---\nstatus: done\npriority: 2\n---\n# Beta\n",
            "Projects/Sub/gamma.md": "---\nstatus: Blocked\npriority: 1\n---\n# Gamma\n",
            "Projects/delta.md": "# Delta\n",
            "Other/epsilon.md": "---\nstatus: To do\n---\n# Epsilon\n",
        ]
    }

    private var harness: PluginTestHarness?

    private func service() throws -> (PluginTestHarness, CollectionService) {
        let harness = try PluginTestHarness([NoteGraphPlugin.self, NoteQueryPlugin.self, CollectionsPlugin.self], files: files)
        self.harness = harness
        return (harness, try XCTUnwrap(harness.kernel.services.service(.collections)))
    }

    private let source = CollectionSource.file("Projects/Projects.base")

    func testDefinition() throws {
        let (_, collections) = try service()
        XCTAssertEqual(collections.collections(), ["Projects/Projects.base"])
        let definition = try collections.definition(source)
        XCTAssertEqual(definition.name, "Projects")
        XCTAssertEqual(definition.home, "Projects")
        XCTAssertEqual(definition.views.map(\.name), ["Board", "Urgent"])
        XCTAssertEqual(definition.property(PropertyRef("status")).options, ["To do", "In progress", "Done"])
        XCTAssertThrowsError(try collections.definition(.file("Projects/alpha.md")))
    }

    func testCollectionsContainingANote() throws {
        let (_, collections) = try service()
        XCTAssertEqual(collections.collections(containing: "Projects/alpha.md"), ["Projects/Projects.base"])
        XCTAssertEqual(collections.collections(containing: "Projects/Sub/gamma.md"), ["Projects/Projects.base"])
        XCTAssertEqual(collections.collections(containing: "Other/epsilon.md"), [])
        XCTAssertEqual(collections.collections(containing: "Projects/Projects.base"), [])
        XCTAssertEqual(collections.collections(containing: "Projects/missing.md"), [])
    }

    func testBoardGroupsInOptionOrder() throws {
        let (_, collections) = try service()
        let result = try collections.entries(source, view: nil)
        XCTAssertEqual(result.entries.map(\.title), ["alpha", "beta", "delta", "gamma"], "sorted by title, subfolders included")
        let groups = try XCTUnwrap(result.groups)
        XCTAssertEqual(groups.map(\.value), [.string("To do"), .string("In progress"), .string("Done"), .string("Blocked"), nil])
        XCTAssertEqual(groups.map { $0.entries.map(\.title) }, [["alpha"], [], ["beta"], ["gamma"], ["delta"]])
        XCTAssertEqual(result.kinds, ["file.name": .text, "status": .select, "priority": .number])
    }

    func testViewFiltersSortAndLimit() throws {
        let (_, collections) = try service()
        let result = try collections.entries(source, view: "Urgent")
        XCTAssertEqual(result.entries.map(\.title), ["alpha", "beta"])
        XCTAssertNil(result.groups)
        XCTAssertThrowsError(try collections.entries(source, view: "Nope"))
    }

    func testABlockIsNamedByItsNameKey() throws {
        let (_, collections) = try service()
        XCTAssertEqual(try collections.definition(.inline(yaml: "name: Tasks\nviews: []\n", host: nil)).name, "Tasks")
        XCTAssertEqual(try collections.definition(.inline(yaml: "views: []\n", host: nil)).name, "Collection")
    }

    func testInlineBlockUsesItsNote() throws {
        let (_, collections) = try service()
        let yaml = """
        filters:
          and:
            - file.inFolder(this.file.folder)
            - file.path != this.file.path
        views:
          - type: table
            name: Table
        """
        let inline = CollectionSource.inline(yaml: yaml, host: "Projects/alpha.md")
        XCTAssertEqual(try collections.definition(inline).home, "Projects")
        XCTAssertEqual(try collections.entries(inline, view: nil).entries.map(\.title), ["beta", "delta", "gamma"])
        let edited = try collections.apply([.addView(type: "cards", name: "Gallery")], to: inline)
        guard case .inline(let newYAML, "Projects/alpha.md") = edited else { return XCTFail("\(edited)") }
        XCTAssertEqual(try collections.definition(edited).views.map(\.name), ["Table", "Gallery"])
        XCTAssertTrue(newYAML.contains("this.file.folder"))
    }

    func testNewEntryMatchesTheFilter() throws {
        let (harness, collections) = try service()
        let tagged = """
        filters:
          and:
            - file.inFolder("Tasks")
            - file.hasTag("work")
            - status == "To do"
        """
        try harness.vault.write("Tasks/Tasks.base", tagged)
        let path = try collections.newEntry(in: .file("Tasks/Tasks.base"), title: "Call: Ann", values: ["priority": .number(1)])
        XCTAssertEqual(path, "Tasks/Call- Ann.md")
        XCTAssertEqual(try harness.vault.read(path), "---\nstatus: To do\npriority: 1\ntags:\n  - work\n---\n")
        XCTAssertEqual(try collections.entries(.file("Tasks/Tasks.base"), view: nil).entries.map(\.path), [path],
                       "the graph knows the note at once")
        XCTAssertEqual(try collections.newEntry(in: .file("Tasks/Tasks.base"), title: "Call: Ann", values: [:]), "Tasks/Call- Ann 2.md")
        XCTAssertEqual(try collections.newEntry(in: .inline(yaml: "views: []", host: nil), title: nil, values: [:]), "Inbox/Untitled.md")
    }

    func testNewEntryReturnsWhereAPluginFiledIt() throws {
        let (harness, collections) = try service()
        try harness.vault.write("Tasks/Tasks.base", "filters:\n  and:\n    - file.inFolder(\"Tasks\")\n")
        let events = harness.kernel.events
        let stop = events.on(VaultChanged.self) { event in
            guard let added = event.changes.first(where: { $0.kind == .added && $0.path == "Tasks/Fresh.md" }) else { return }
            try? harness.vault.move(added.path, to: "Tasks/Fresh/Fresh.md")
            events.emit(NotesMoved(moves: [added.path: "Tasks/Fresh/Fresh.md"]))
        }
        defer { stop() }
        XCTAssertEqual(try collections.newEntry(in: .file("Tasks/Tasks.base"), title: "Fresh", values: [:]), "Tasks/Fresh/Fresh.md")
        XCTAssertEqual(try collections.newEntry(in: .file("Tasks/Tasks.base"), title: "Other", values: [:]), "Tasks/Other.md")
    }

    func testCreateIsIdempotent() throws {
        let (harness, collections) = try service()
        XCTAssertEqual(try collections.create(folder: "Other"), "Other/Other.base")
        let written = try harness.vault.read("Other/Other.base")
        XCTAssertTrue(written.contains(#"- file.inFolder("Other")"#), written)
        XCTAssertEqual(try collections.create(folder: "Other/"), "Other/Other.base")
        XCTAssertEqual(try harness.vault.read("Other/Other.base"), written)
        XCTAssertEqual(collections.collections(), ["Other/Other.base", "Projects/Projects.base"])
        XCTAssertEqual(try collections.entries(.file("Other/Other.base"), view: nil).entries.map(\.title), ["epsilon"])
        XCTAssertThrowsError(try collections.create(folder: ""))
    }

    func testApplyWritesOnlyWhenSomethingChanged() throws {
        let (harness, collections) = try service()
        _ = try collections.apply([], to: source)
        XCTAssertEqual(try harness.vault.read("Projects/Projects.base"), base, "no edit, no write")
        _ = try collections.apply([.setLimit(view: "Board", limit: 1)], to: source)
        XCTAssertEqual(try collections.definition(source).views[0].limit, 1)
    }

    func testFollowsARenamedFolder() throws {
        let (harness, collections) = try service()
        let engine = try XCTUnwrap(collections as? CollectionEngine)
        try harness.vault.move("Projects", to: "Work/Plans")
        engine.follow(["Projects/alpha.md": "Work/Plans/alpha.md", "Projects/Sub/gamma.md": "Work/Plans/Sub/gamma.md"])
        XCTAssertEqual(collections.collections(), ["Work/Plans/Plans.base"])
        let text = try harness.vault.read("Work/Plans/Plans.base")
        XCTAssertTrue(text.contains(#"file.inFolder("Work/Plans")"#), text)
        XCTAssertEqual(try collections.definition(.file("Work/Plans/Plans.base")).home, "Work/Plans")
    }

    func testABlockOwnsTheNotesThatNameIt() throws {
        let (harness, collections) = try service()
        let yaml = """
        filters:
          and:
            - collection == this.file.basename
            - file.ext == "md"
        views:
          - type: table
            name: Table
        """
        let inline = CollectionSource.inline(yaml: yaml, host: "Welcome.md")
        XCTAssertNil(try collections.definition(inline).home)
        let path = try collections.newEntry(in: inline, title: "Idea", values: [:])
        XCTAssertEqual(path, "Idea.md", "next to the note, no folder")
        XCTAssertEqual(try harness.vault.read(path), "---\ncollection: Welcome\n---\n")
        XCTAssertEqual(try collections.entries(inline, view: nil).entries.map(\.path), [path])
        let nested = CollectionSource.inline(yaml: yaml, host: "Projects/alpha.md")
        XCTAssertEqual(try collections.newEntry(in: nested, title: "Step", values: [:]), "Projects/Step.md")

        let engine = try XCTUnwrap(collections as? CollectionEngine)
        engine.follow(["Welcome.md": "Home.md"])
        XCTAssertEqual(try harness.vault.read(path), "---\ncollection: Home\n---\n", "the entries follow a renamed note")
    }

    func testRewritingFolders() {
        let folders = ["A": "B", "A/C": "Z"]
        XCTAssertEqual(CollectionEngine.rewritingFolders(in: #"file.inFolder("A/C/D") || file.inFolder('A') || file.inFolder("AB")"#, folders),
                       #"file.inFolder("Z/D") || file.inFolder('B') || file.inFolder("AB")"#)
    }

    func testInferKinds() {
        XCTAssertEqual(CollectionEngine.inferKind([.bool(true)]), .checkbox)
        XCTAssertEqual(CollectionEngine.inferKind([.number(1), .number(2)]), .number)
        XCTAssertEqual(CollectionEngine.inferKind([.string("2026-10-20"), .string("2026-10-20T10:00:00Z")]), .date)
        XCTAssertEqual(CollectionEngine.inferKind([.string("https://craft.do")]), .url)
        XCTAssertEqual(CollectionEngine.inferKind([.list([.string("a")]), .string("b")]), .multiselect)
        XCTAssertEqual(CollectionEngine.inferKind([.string("x"), .number(1)]), .text)
        XCTAssertEqual(CollectionEngine.inferKind([]), .text)
    }

    func testCommands() async throws {
        let (harness, _) = try service()
        let list = try await harness.run("collection.list")
        XCTAssertEqual(try JSONDecoder().decode([String].self, from: Data(list.utf8)), ["Projects/Projects.base"])
        _ = try await harness.run("collection.create", ["folder": "Other"])
        _ = try await harness.run("collection.add-view", ["path": "Other/Other.base", "type": "kanban"])
        let shown = try JSONDecoder().decode(CollectionDefinition.self,
                                             from: Data(try await harness.run("collection.show", ["path": "Other/Other.base"]).utf8))
        XCTAssertEqual(shown.views.map(\.name), ["Table", "Kanban"])
        XCTAssertEqual(shown.views[1].groupBy?.property, PropertyRef("status"))
        XCTAssertEqual(shown.property(PropertyRef("status")).options, ["To do", "In progress", "Done"])

        _ = try await harness.run("collection.set-property", ["path": "Other/Other.base", "property": "status",
                                                               "options": "Later, Now", "display-name": "State"])
        let edited = try JSONDecoder().decode(CollectionDefinition.self, from: Data(try await harness.run("collection.edit", [
            "path": "Other/Other.base",
            "edits": #"[{"renameView":{"name":"Kanban","to":"Board"}}]"#,
        ]).utf8))
        XCTAssertEqual(edited.views.map(\.name), ["Table", "Board"])
        XCTAssertEqual(edited.property(PropertyRef("status")), CollectionProperty(ref: PropertyRef("status"), displayName: "State",
                                                                                  kind: .select, options: ["Later", "Now"]))

        let path = try await harness.run("collection.new-entry", ["path": "Other/Other.base", "title": "Zeta",
                                                                   "values": #"{"status":"Now"}"#])
        XCTAssertEqual(path, "Other/Zeta.md")
        let entries = try JSONDecoder().decode(CollectionResult.self, from: Data(try await harness.run("collection.entries", [
            "path": "Other/Other.base", "view": "Board",
        ]).utf8))
        XCTAssertEqual(entries.groups?.map { $0.entries.map(\.title) }, [[], ["Zeta"], ["epsilon"]])
        do {
            _ = try await harness.run("collection.edit", ["path": "Other/Other.base", "edits": "nope"])
            XCTFail("bad JSON")
        } catch {
            XCTAssertEqual(error as? CollectionError, .invalidArgument("edits"))
        }
    }
}
