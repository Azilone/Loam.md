import AppKit
import BuiltinPlugins
import CollectionCardsUI
import CollectionKanbanUI
import CollectionTableUI
import TagsUI
import FileExplorerUI
import PluginKitUI
import PluginKitUITesting
import SwiftUI
import XCTest
@testable import CollectionsUI

@MainActor
final class CollectionsUITests: XCTestCase {
    private let logicPlugins = builtinPlugins.filter { ["note-graph", "note-query", "collections", "files"].contains($0.manifest.id) }

    private let base = """
    filters:
      and:
        - file.inFolder("Kanban test")
        - file.ext == "md"
    properties:
      status:
        type: select
        options: [To do, In progress, Done]
    views:
      - type: kanban
        name: Kanban
        groupBy: {property: status, direction: ASC}
        order: [file.name, status]
      - type: cards
        name: Gallery view
        order: [file.name, status]
      - type: table
        name: Table view
        order: [file.name, status]

    """

    private var files: [String: String] {
        [
            "Kanban test/Kanban test.base": base,
            "Kanban test/Kanban test.md": "---\nstatus: In progress\n---\nthis is also a note\n",
            "Kanban test/Test page in the kanban.md": "---\nstatus: To do\n---\n",
            "Plain/Note.md": "# Note\n\n#reading\n",
            "Plain/Other.md": "---\ntags: [reading]\n---\n# Other\n",
        ]
    }

    private func harness(_ ui: [Plugin.Type] = [CollectionsUIPlugin.self, CollectionTableUIPlugin.self, CollectionKanbanUIPlugin.self, CollectionCardsUIPlugin.self, TagsUIPlugin.self]) throws -> UIPluginHarness {
        try UIPluginHarness(logicPlugins: logicPlugins, uiPlugins: ui, files: files)
    }

    private func store(_ harness: UIPluginHarness) throws -> CollectionStore {
        try XCTUnwrap(harness.kernel.services.service(CollectionsUIPlugin.storeKey))
    }

    func testAFolderWithItsBaseOpensAsTheCollection() throws {
        let harness = try harness()
        defer { harness.close() }
        XCTAssertEqual(harness.report.failed, [:])
        XCTAssertEqual(harness.views.viewTypes(for: .folder("Kanban test")).first?.id, CollectionsUIPlugin.folderViewID)
        XCTAssertNil(harness.views.viewTypes(for: .folder("Plain")).first { $0.id == CollectionsUIPlugin.folderViewID })
        XCTAssertEqual(harness.views.viewTypes(for: .file("Kanban test/Kanban test.base")).first?.id, CollectionsUIPlugin.fileViewID)
        let registry = try XCTUnwrap(harness.kernel.services.service(.collectionViews))
        XCTAssertEqual(registry.types.map(\.id), ["table", "kanban", "cards"])
    }

    func testTurnIntoCollectionWritesTheBaseAndOpensIt() throws {
        let harness = try harness()
        defer { harness.close() }
        let actions = harness.resourceActions.actions(for: .folder("Plain"))
        XCTAssertEqual(actions.map(\.id), ["collection.turn-into"])
        XCTAssertEqual(harness.resourceActions.actions(for: .folder("Kanban test")).map(\.id), [], "already one")
        XCTAssertEqual(harness.resourceActions.actions(for: .file("Plain/Note.md")).map(\.id), [])
        actions[0].perform(.folder("Plain"))
        XCTAssertTrue(harness.vault.exists("Plain/Plain.base"))
        XCTAssertEqual(harness.workspace.opened.last?.resource, .folder("Plain"))
        XCTAssertEqual(harness.views.viewTypes(for: .folder("Plain")).first?.id, CollectionsUIPlugin.folderViewID)
    }

    func testABaseApartFromItsFolderMovesIntoIt() throws {
        var files = files
        files["Bases/Plain notes.base"] = "filters:\n  and:\n    - file.inFolder(\"Plain\")\nviews:\n  - type: table\n    name: Table\n"
        files["Bases/Kanban copy.base"] = base
        let harness = try UIPluginHarness(logicPlugins: logicPlugins, uiPlugins: [CollectionsUIPlugin.self], files: files)
        defer { harness.close() }
        XCTAssertEqual(harness.resourceActions.actions(for: .file("Kanban test/Kanban test.base")).map(\.id), [], "already its folder's")
        XCTAssertEqual(harness.resourceActions.actions(for: .file("Bases/Kanban copy.base")).map(\.id), [], "the folder has its own")
        let actions = harness.resourceActions.actions(for: .file("Bases/Plain notes.base"))
        XCTAssertEqual(actions.map(\.id), ["collection.adopt"])
        actions[0].perform(.file("Bases/Plain notes.base"))
        XCTAssertFalse(harness.vault.exists("Bases/Plain notes.base"))
        XCTAssertTrue(harness.vault.exists("Plain/Plain.base"))
        XCTAssertEqual(harness.workspace.opened.last?.resource, .folder("Plain"))
        XCTAssertEqual(harness.views.viewTypes(for: .folder("Plain")).first?.id, CollectionsUIPlugin.folderViewID)
    }

    func testSlashShowsEachCollectionAsAnEmbed() throws {
        let editor = RecordingEditor()
        let harness = try UIPluginHarness(logicPlugins: logicPlugins, uiPlugins: [CollectionsUIPlugin.self, CollectionTableUIPlugin.self],
                                          files: files, editor: editor)
        defer { harness.close() }
        XCTAssertEqual(editor.slashItems.map(\.title), ["Collection: Kanban test"])
        let text = "# Note\n/coll"
        let inserted = editor.slashItems[0].makeChange(text, NSRange(location: 7, length: 5)).applied(to: text)
        XCTAssertEqual(inserted, "# Note\n![](Kanban%20test/Kanban%20test.base)\n")
        XCTAssertEqual(editor.embedRenderers.map(\.extensions), [["base"]])
        let model = try store(harness).embedModel(for: "Kanban test/Kanban test.base")
        XCTAssertEqual(model.entries.count, 2)
    }

    func testNewCollectionIsANamedFolderAtTheRoot() throws {
        let harness = try harness()
        defer { harness.close() }
        XCTAssertTrue(harness.panels.newItems.contains { $0.id == "collection.new" })
        let collections = try XCTUnwrap(harness.kernel.services.service(.collections))
        let created = NewCollection.create(named: "Plain", in: "Inbox", collections: collections, workspace: harness.workspace,
                                           exists: { harness.vault.exists($0) })
        XCTAssertEqual(created, "Plain 2")
        XCTAssertTrue(harness.vault.exists("Plain 2/Plain 2.base"))
        XCTAssertEqual(harness.workspace.opened.last?.resource, .folder("Plain 2"))
        XCTAssertEqual(NewCollection.uniqueFolder(named: " a/b ", in: "Work", exists: { _ in false }), "Work/a-b")
        XCTAssertEqual(NewCollection.uniqueFolder(named: "", in: "", exists: { _ in false }), "Collection")
    }

    func testThePageModelRunsTheSelectedView() throws {
        let harness = try harness()
        defer { harness.close() }
        let context = ViewContext(resource: .folder("Kanban test"), state: try JSONEncoder().encode(PageState(view: "Table view")))
        let model = try store(harness).model(for: context)
        XCTAssertTrue(try store(harness).model(for: context) === model, "one model per tab")
        XCTAssertEqual(model.view?.name, "Table view")
        XCTAssertEqual(model.entries.map(\.title), ["Kanban test", "Test page in the kanban"])
        XCTAssertEqual(model.fields, [PropertyRef("status")])
        XCTAssertEqual(model.kind(PropertyRef("status")), .select)

        model.searchText = "page"
        XCTAssertEqual(model.entries.map(\.title), ["Test page in the kanban"])
        model.searchText = ""

        model.set(PropertyRef("status"), to: .string("Done"), on: "Kanban test/Kanban test.md")
        XCTAssertEqual(try harness.vault.read("Kanban test/Kanban test.md"), "---\nstatus: Done\n---\nthis is also a note\n")

        let path = try XCTUnwrap(model.newEntry(title: "Third"))
        XCTAssertEqual(path, "Kanban test/Third.md")
        XCTAssertEqual(model.entries.map(\.title), ["Kanban test", "Test page in the kanban", "Third"])

        model.addOption("Blocked", to: PropertyRef("status"))
        XCTAssertEqual(model.property(PropertyRef("status")).options, ["To do", "In progress", "Done", "Blocked"])
        model.viewName = "Kanban"
        XCTAssertEqual(model.groups?.map { $0.entries.map(\.title) }, [["Test page in the kanban"], [], ["Kanban test"], [], ["Third"]])
    }

    func testDeletingAFieldTakesItOutOfTheViewsAndUndoPutsItBack() throws {
        let harness = try harness()
        defer { harness.close() }
        let model = try store(harness).model(for: ViewContext(resource: .folder("Kanban test")))
        let status = PropertyRef("status")
        XCTAssertEqual(model.valueCount(of: status), 2)

        model.deleteField(status, removingValues: false)
        XCTAssertEqual(model.definition?.properties, [])
        XCTAssertEqual(model.definition?.views.map(\.order), [[.title], [.title], [.title]])
        XCTAssertNil(model.definition?.views[0].groupBy)
        XCTAssertEqual(try harness.vault.read("Kanban test/Kanban test.md"), "---\nstatus: In progress\n---\nthis is also a note\n",
                       "the notes keep their value")
        XCTAssertEqual(model.deletedField?.title, "Status")

        model.undoDelete()
        XCTAssertNil(model.deletedField)
        XCTAssertEqual(model.definition?.properties.map(\.ref), [status])
        XCTAssertEqual(model.definition?.views.map(\.order), [[.title, status], [.title, status], [.title, status]])
        XCTAssertEqual(model.definition?.views[0].groupBy?.property, status)

        model.deleteField(status, removingValues: true)
        XCTAssertFalse(try harness.vault.read("Kanban test/Kanban test.md").contains("status"))
        XCTAssertFalse(try harness.vault.read("Kanban test/Test page in the kanban.md").contains("status"))
        model.undoDelete()
        XCTAssertEqual(try harness.vault.read("Kanban test/Kanban test.md"), "---\nstatus: In progress\n---\nthis is also a note\n")
        XCTAssertTrue(try harness.vault.read("Kanban test/Test page in the kanban.md").contains("status: To do"))
    }

    func testCommandOpensACollection() async throws {
        let harness = try harness()
        defer { harness.close() }
        _ = try await harness.run("collection.open", ["folder": "Kanban test"])
        XCTAssertEqual(harness.workspace.opened.last?.resource, .folder("Kanban test"))
        do {
            _ = try await harness.run("collection.open", ["folder": "Plain"])
            XCTFail("not a collection")
        } catch {}
    }

    func testUnloadingLeavesNothingBehind() throws {
        let harness = try harness()
        harness.host.deactivateAll()
        XCTAssertEqual(harness.views.viewTypes(for: .folder("Kanban test")).count, 0)
        XCTAssertEqual(harness.resourceActions.actions(for: .folder("Plain")).count, 0)
        XCTAssertNil(harness.kernel.services.service(.collectionViews))
        harness.close()
    }

    func testANewBoardGroupsByStatusWithCraftsColumns() throws {
        let harness = try harness()
        defer { harness.close() }
        _ = try XCTUnwrap(harness.kernel.services.service(.collections)).create(folder: "Plain")
        let model = try store(harness).model(for: ViewContext(resource: .folder("Plain")))
        let registry = try XCTUnwrap(harness.kernel.services.service(.collectionViews))
        model.edit([.addView(type: "kanban", name: "Board")])
        model.edit(try XCTUnwrap(registry.type("kanban")).defaults(try XCTUnwrap(model.definition), "Board"))
        model.viewName = "Board"
        XCTAssertEqual(model.view?.groupBy?.property, PropertyRef("status"))
        XCTAssertEqual(model.property(PropertyRef("status")).options, ["To do", "In progress", "Done"])
        XCTAssertEqual(model.groups?.map(\.value), [.string("To do"), .string("In progress"), .string("Done"), nil])
    }

    func testTagPagesShowTheTagsNotes() throws {
        let harness = try harness()
        defer { harness.close() }
        let model = try store(harness).model(for: ViewContext(resource: .virtual("collection:#reading")))
        XCTAssertEqual(model.view?.type, "cards")
        XCTAssertEqual(model.entries.map(\.title), ["Note", "Other"])
        let tags = try XCTUnwrap(harness.kernel.services.service(TagsUIPlugin.modelKeyForTests))
        XCTAssertEqual(tags.tags.map(\.tag), ["reading"])
    }

    /// Draws the page for each view, and saves PNGs to compare with Craft when LOAM_SNAPSHOTS names a folder.
    func testThePageRenders() throws {
        let harness = try harness()
        defer { harness.close() }
        for view in ["Table view", "Kanban", "Gallery view"] {
            let context = ViewContext(resource: .folder("Kanban test"), state: try JSONEncoder().encode(PageState(view: view)))
            let type = try XCTUnwrap(harness.views.viewTypes(for: context.resource).first)
            let page = type.makeView(context).environment(\.themeTokens, .standard)
            let hosting = harness.render(AnyView(page.frame(width: 1100, height: 640).background(Color.white)),
                                         size: CGSize(width: 1100, height: 640))
            hosting.window?.appearance = NSAppearance(named: .aqua)
            hosting.layoutSubtreeIfNeeded()
            XCTAssertGreaterThan(hosting.fittingSize.width, 0)
            Snapshot.save(hosting, name: "collection-\(view)")
        }
    }
}

@MainActor
enum Snapshot {
    static func save(_ view: NSView, name: String) {
        guard let folder = ProcessInfo.processInfo.environment["LOAM_SNAPSHOTS"] else { return }
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        let url = URL(fileURLWithPath: folder).appendingPathComponent(name.replacingOccurrences(of: " ", with: "-") + ".png")
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}

@MainActor
final class CollectionBlockTests: XCTestCase {
    func testABaseBlockShowsTheNotesThatNameItAndWritesEditsBack() throws {
        let files = [
            "Inbox/Trip.md": "# Trip\n",
            "Inbox/Hotel.md": "---\ncollection: Trip\nstatus: To do\n---\n",
            "Inbox/Train.md": "---\ncollection: Trip\nstatus: Done\n---\n",
            "Inbox/Other.md": "# Other\n",
        ]
        let logic = builtinPlugins.filter { ["note-graph", "note-query", "collections"].contains($0.manifest.id) }
        let editor = RecordingEditor()
        let harness = try UIPluginHarness(logicPlugins: logic, uiPlugins: [CollectionsUIPlugin.self, CollectionKanbanUIPlugin.self],
                                          files: files, editor: editor)
        defer { harness.close() }
        XCTAssertEqual(harness.report.failed, [:])
        XCTAssertEqual(editor.slashItems.map(\.id), [], "no collection in the vault, nothing to show; / writes no block")
        let view = try XCTUnwrap(editor.codeBlockViews.first)
        XCTAssertEqual(view.languages, ["base"])

        let code = CollectionBlocks.yaml("kanban")

        var replaced: [String] = []
        let block = CodeBlockContext(notePath: "Inbox/Trip.md", language: "base", code: code,
                                     replaceCode: { replaced.append($0) }, editCode: {})
        let store = try XCTUnwrap(harness.kernel.services.service(CollectionsUIPlugin.storeKey))
        let model = store.model(for: block)
        XCTAssertNil(model.definition?.home)
        XCTAssertEqual(model.groups?.map { $0.entries.map(\.title) }, [["Hotel"], [], ["Train"]])
        XCTAssertEqual(model.newEntry(title: "Plane", values: ["status": .string("In progress")]), "Inbox/Plane.md", "next to the note, no folder")

        model.edit([.renameView(name: "Kanban", to: "Board")])
        XCTAssertEqual(replaced.count, 1)
        XCTAssertTrue(replaced[0].contains("name: Board"))
        XCTAssertNotNil(harness.render(view.makeView(block), size: CGSize(width: 700, height: 500)))
    }
}
