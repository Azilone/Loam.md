import PluginKitUI
import PluginKitUITesting
import AppKit
import SwiftUI
import XCTest
@testable import MindmapUI

/// The mindmap plugin in the UI harness: editing a map writes its note, with undo, and the views open the right
/// notes.
@MainActor
final class MindmapPluginTests: XCTestCase {
    private let files = [
        "Map.md": "---\nmindmap-plugin: basic\n---\n\n# Project\n\n- Ideas\n\t- One\n\t- Two\n- Tasks\n",
        "Plan.md": "# Plan\n\n## Goals\n\n- Ship\n\n## Risks\n",
        "Plain.md": "Just text.\n",
    ]
    private var editor: RecordingEditor!
    private var harness: UIPluginHarness!
    private var undo: UndoManager!

    override func setUp() async throws {
        editor = RecordingEditor()
        harness = try UIPluginHarness(uiPlugins: [MindmapPlugin.self], files: files, editor: editor)
        XCTAssertTrue(harness.host.isActive("mindmap"), "\(harness.report)")
        undo = UndoManager()
        undo.groupsByEvent = false
    }

    override func tearDown() async throws {
        harness.close()
    }

    private func tab(_ path: String, state: Data? = nil) throws -> (MindmapTabModel, ViewContext) {
        let store = try XCTUnwrap(harness.kernel.services.service(MindmapPlugin.storeKey))
        let view = ViewContext(resource: .virtual("mindmap:" + path), state: state)
        let tab = store.makeTab(view)
        tab.undoManager = undo
        tab.viewResized(CGSize(width: 800, height: 600))
        return (tab, view)
    }

    private func id(_ tab: MindmapTabModel, _ text: String) throws -> String {
        try XCTUnwrap(tab.root?.all.first { $0.text == text }?.id, text)
    }

    private func file(_ path: String) throws -> String { try harness.vault.read(path) }

    private func step(_ body: () throws -> Void) rethrows {
        undo.beginUndoGrouping()
        defer { undo.endUndoGrouping() }
        try body()
    }

    func testShowsAMapAndPlacesEveryTopic() throws {
        let (tab, _) = try tab("Map.md")
        XCTAssertTrue(tab.isEditable)
        XCTAssertEqual(tab.root?.all.map(\.text), ["Project", "Ideas", "One", "Two", "Tasks"])
        XCTAssertEqual(tab.placements.count, 5)
        XCTAssertLessThanOrEqual(tab.scale, 1)
    }

    func testTabAddsAChildThatIsWrittenWhenTyped() throws {
        let (tab, _) = try tab("Map.md")
        tab.select(try id(tab, "Tasks"))
        step { tab.addChild() }
        XCTAssertNotNil(tab.editingID)
        XCTAssertEqual(try file("Map.md"), files["Map.md"], "nothing written before the text")
        tab.draft = "Write tests"
        step { tab.commitEdit() }
        XCTAssertTrue(try file("Map.md").hasSuffix("- Tasks\n\t- Write tests\n"))

        // Return adds a sibling; an empty one vanishes.
        step { tab.addSibling() }
        tab.draft = "  "
        step { tab.commitEdit() }
        XCTAssertEqual(tab.root?.all.count, 6)
        XCTAssertEqual(tab.focusID, try id(tab, "Write tests"))
    }

    func testTheSceneShowsANewTopicAtOnceWithItsPlace() throws {
        let (tab, view) = try tab("Map.md")
        tab.select(try id(tab, "Tasks"))
        tab.addChild()
        let editing = try XCTUnwrap(tab.editingID)
        let item = try XCTUnwrap(tab.scene.first { $0.id == editing }, "the views draw the new topic")
        XCTAssertEqual(item.placement, tab.placements[editing])
        XCTAssertEqual(item.parentID, try id(tab, "Tasks"))
        tab.draft = "Typed"
        XCTAssertEqual(tab.scene.first { $0.id == editing }?.text, "Typed", "the topic grows while typing")

        let store = try XCTUnwrap(harness.kernel.services.service(MindmapPlugin.storeKey))
        XCTAssertTrue(store.makeTab(view) === tab, "one model per tab, however often SwiftUI rebuilds it")
    }

    /// The map is AppKit: one layer per topic, a pan moves the camera and lays nothing out again, a new topic shows on
    /// the view's next turn.
    func testTheCanvasShowsEveryTopicAndPansWithoutLayingOut() throws {
        let (tab, view) = try tab("Map.md")
        let canvas = MindmapCanvasView(model: tab)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 800, height: 600), styleMask: .borderless,
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        canvas.frame = CGRect(x: 0, y: 0, width: 800, height: 600)
        window.contentView = canvas
        canvas.hostEnvironmentChanged(NativeViewEnvironment(theme: .standard))
        canvas.layoutSubtreeIfNeeded()
        func spin() { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        spin()
        XCTAssertEqual(canvas.accessibilityChildren()?.count, 5, "a topic for each of the map's five")
        XCTAssertEqual(canvas.accessibilityLabel(), "Mindmap of Map")

        let revision = tab.sceneRevision
        let offset = tab.offset
        tab.pan(by: CGSize(width: 40, height: -20))
        spin()
        XCTAssertEqual(tab.offset.width, offset.width + 40)
        XCTAssertEqual(tab.sceneRevision, revision, "a pan moves the camera, not the topics")

        tab.select(try id(tab, "Tasks"))
        step { tab.addChild() }
        tab.draft = "Canvas"
        step { tab.commitEdit() }
        spin()
        XCTAssertEqual(canvas.accessibilityChildren()?.count, 6)
        _ = view
    }

    func testEditingRenamesAndUndoRestores() throws {
        let (tab, _) = try tab("Map.md")
        let one = try id(tab, "One")
        tab.startEdit(one)
        tab.draft = "First"
        step { tab.commitEdit() }
        XCTAssertTrue(try file("Map.md").contains("\t- First\n"))
        undo.undo()
        XCTAssertEqual(try file("Map.md"), files["Map.md"])
        XCTAssertEqual(tab.root?.children[0].children[0].id, one, "ids survive the undo")
        undo.redo()
        XCTAssertTrue(try file("Map.md").contains("\t- First\n"))
    }

    func testDeleteOutdentAndReorder() throws {
        let (tab, _) = try tab("Map.md")
        tab.select(try id(tab, "Two"))
        step { tab.moveSibling(by: -1) }
        XCTAssertTrue(try file("Map.md").contains("\t- Two\n\t- One\n"))
        step { tab.outdent() }
        XCTAssertTrue(try file("Map.md").contains("- Ideas\n\t- One\n- Two\n- Tasks\n"))
        step { tab.deleteSelection() }
        XCTAssertTrue(try file("Map.md").contains("- Ideas\n\t- One\n- Tasks\n"))
        XCTAssertEqual(tab.focusID, try id(tab, "Ideas"), "the previous sibling is selected")

        tab.select(try XCTUnwrap(tab.root?.id))
        step { tab.deleteSelection() }
        XCTAssertNotNil(tab.root, "the central topic stays")
    }

    func testDraggingMovesBranchesOntoBeforeOrAfter() throws {
        let (tab, _) = try tab("Map.md")
        let ideas = try id(tab, "Ideas")
        let tasks = try id(tab, "Tasks")
        step { tab.move([ideas], to: MindmapDropTarget(id: tasks, mode: .inside)) }
        XCTAssertTrue(try file("Map.md").contains("- Tasks\n\t- Ideas\n\t\t- One\n\t\t- Two\n"))
        try step { tab.move([try id(tab, "Two")], to: MindmapDropTarget(id: tasks, mode: .before)) }
        XCTAssertTrue(try file("Map.md").contains("- Two\n- Tasks\n"))
        // A topic never goes inside its own branch.
        let before = try file("Map.md")
        try step { tab.move([tasks], to: MindmapDropTarget(id: try id(tab, "One"), mode: .inside)) }
        XCTAssertEqual(try file("Map.md"), before)
    }

    func testCopyAndPasteAsMarkdownLists() throws {
        let (tab, _) = try tab("Map.md")
        tab.select(try id(tab, "Ideas"))
        XCTAssertEqual(tab.copySelection(), "- Ideas\n\t- One\n\t- Two")
        tab.select(try id(tab, "Tasks"))
        step { tab.paste("- A\n  - A.1\n- B") }
        XCTAssertTrue(try file("Map.md").hasSuffix("- Tasks\n\t- A\n\t\t- A.1\n\t- B\n"))
    }

    func testFoldingIsSavedWithTheTab() throws {
        let (tab, view) = try tab("Map.md")
        tab.toggleFold(try id(tab, "Ideas"))
        XCTAssertEqual(tab.placements.count, 3)
        XCTAssertEqual(view.state(MindmapTabState.self)?.folded, ["Project/Ideas"])
        let (reopened, _) = try self.tab("Map.md", state: view.stateData)
        XCTAssertEqual(reopened.placements.count, 3)
    }

    func testNavigationWithArrows() throws {
        let (tab, _) = try tab("Map.md")
        XCTAssertEqual(tab.focusID, tab.root?.id, "an opened map has its central topic selected")
        tab.deselect()
        tab.navigate(.right)
        XCTAssertEqual(tab.focusID, tab.root?.id, "with nothing selected, the first arrow selects it")
        tab.select(try id(tab, "Ideas"))
        let side = try XCTUnwrap(tab.placements[try id(tab, "Ideas")]).direction
        tab.navigate(side == 1 ? .right : .left)
        XCTAssertEqual(tab.focusID, try id(tab, "One"))
        tab.navigate(.bottom)
        XCTAssertEqual(tab.focusID, try id(tab, "Two"))
        tab.navigate(side == 1 ? .left : .right)
        XCTAssertEqual(tab.focusID, try id(tab, "Ideas"))
    }

    func testFollowsTheEditorAndKeepsIDs() throws {
        let (tab, _) = try tab("Map.md")
        let ideas = try id(tab, "Ideas")
        editor.texts["Map.md"] = files["Map.md"]! + "- Typed\n"
        harness.kernel.events.emit(DocumentTextChanged(path: "Map.md"))
        XCTAssertEqual(tab.root?.children.map(\.text), ["Ideas", "Tasks", "Typed"])
        XCTAssertEqual(tab.root?.children[0].id, ideas)
    }

    func testANoteWithSectionsIsReadOnly() throws {
        let (tab, _) = try tab("Plan.md")
        XCTAssertFalse(tab.isEditable)
        XCTAssertEqual(tab.root?.all.map(\.text), ["Plan", "Goals", "Ship", "Risks"])
        tab.select(try id(tab, "Goals"))
        step { tab.addChild() }
        step { tab.deleteSelection() }
        XCTAssertEqual(try file("Plan.md"), files["Plan.md"])
        let (missing, _) = try self.tab("Missing.md")
        XCTAssertNil(missing.root)
    }

    func testChangingTheLayoutIsSavedInTheNote() throws {
        let (tab, _) = try tab("Map.md")
        step { tab.setMode(.timeline) }
        XCTAssertTrue(try file("Map.md").hasPrefix("---\nmindmap-plugin: basic\nmindmap-layout: timeline\n---\n"))
    }

    func testViewTypesOpenMapsAndRender() throws {
        let virtual = try XCTUnwrap(harness.views.all.first { $0.id == "mindmap.note" })
        XCTAssertTrue(virtual.canOpen(.virtual("mindmap:Plan.md")))
        XCTAssertFalse(virtual.canOpen(.virtual("mindmap:")))
        XCTAssertFalse(virtual.canOpen(.file("Plan.md")))
        let file = try XCTUnwrap(harness.views.all.first { $0.id == "mindmap.file" })
        XCTAssertTrue(file.canOpen(.file("Map.md")))
        XCTAssertTrue(file.prefers(.file("Map.md")), "a flagged note opens as a map")
        try harness.vault.write("List.md", "# Ideas\n\n- One\n")
        XCTAssertTrue(file.canOpen(.file("List.md")), "a note in the format can be shown as a map")
        XCTAssertFalse(file.prefers(.file("List.md")), "but opens in the editor")
        XCTAssertFalse(file.canOpen(.file("Plan.md")), "not a note with sections")
        XCTAssertFalse(file.canOpen(.file("Plain.md")), "nor one without a list")
        XCTAssertNotNil(file.symbol)
        XCTAssertEqual(harness.views.symbol(for: .file("Map.md")), file.symbol, "a map's icon is the map's")

        // The format follows the note.
        try harness.vault.write("List.md", "---\nmindmap-plugin: basic\n---\n# Ideas\n")
        harness.kernel.events.emit(VaultChanged(changes: [VaultChange(kind: .modified, path: "List.md")]))
        XCTAssertTrue(file.prefers(.file("List.md")))

        let size = CGSize(width: 600, height: 400)
        for resource in [Resource.file("Map.md"), .virtual("mindmap:Plan.md"), .virtual("mindmap:Missing.md")] {
            let view = ViewContext(resource: resource)
            XCTAssertEqual(harness.render(virtual.makeView(view), size: size).frame.size, size, resource.path)
        }
    }

    func testCommands() async throws {
        do {
            _ = try await harness.run("mindmap.open")
            XCTFail("no active note")
        } catch let error as CommandError {
            XCTAssertEqual(error, .missingArgument(name: "path"))
        }
        harness.workspace.activeResource = .file("Plan.md")
        _ = try await harness.run("mindmap.open")
        XCTAssertEqual(harness.workspace.opened.last?.resource, .virtual("mindmap:Plan.md"))

        harness.workspace.activeResource = .file("Projects/Note.md")
        let created = try await harness.run("mindmap.new", ["title": "Ideas"])
        XCTAssertEqual(created, "Created Projects/Ideas.md.")
        XCTAssertEqual(try file("Projects/Ideas.md"), "---\nmindmap-plugin: basic\n---\n\n# Ideas\n")
        _ = try await harness.run("mindmap.new", ["title": "Ideas"])
        XCTAssertTrue(harness.vault.exists("Projects/Ideas 2.md"))
        XCTAssertEqual(harness.workspace.opened.last?.resource, .file("Projects/Ideas 2.md"))
    }

    func testNewMindmapFromTheSidebarEditsItsCentralTopic() throws {
        let item = try XCTUnwrap(harness.panels.newItems.first { $0.id == "mindmap.new" })
        item.create("Maps")
        XCTAssertEqual(try file("Maps/Mindmap.md"), "---\nmindmap-plugin: basic\n---\n\n# Mindmap\n")
        XCTAssertEqual(harness.workspace.opened.last?.resource, .file("Maps/Mindmap.md"))
        let store = try XCTUnwrap(harness.kernel.services.service(MindmapPlugin.storeKey))
        let tab = store.makeTab(ViewContext(resource: .file("Maps/Mindmap.md")))
        XCTAssertEqual(tab.editingID, tab.root?.id, "ready to name the map")
        XCTAssertEqual(tab.draft, "Mindmap")
    }

    /// A board's card shows a picture of its map, kept by revision: a model made again for a changed note must not
    /// land on the picture of the map as it was (a map grown on a board showed only its central topic once left).
    func testAModelMadeAgainNeverReusesAnOlderPictureRevision() throws {
        try harness.vault.write("Maps/Pic.md", "---\nmindmap-plugin: basic\n---\n\n# Central idea\n")
        let store = try XCTUnwrap(harness.kernel.services.service(MindmapPlugin.storeKey))
        let first = store.makeTab(ViewContext(resource: .file("Maps/Pic.md"), presentation: .embedded))
        first.viewResized(CGSize(width: 800, height: 600))
        let before = first.sceneRevision
        try harness.vault.write("Maps/Pic.md", "---\nmindmap-plugin: basic\n---\n\n# Central idea\n\n- One\n- Two\n")
        let again = store.makeTab(ViewContext(resource: .file("Maps/Pic.md"), presentation: .embedded))
        again.viewResized(CGSize(width: 800, height: 600))
        XCTAssertEqual(again.scene.count, 3)
        XCTAssertNotEqual(again.sceneRevision, before)
    }

    func testUnloadsCleanly() throws {
        harness.host.deactivate("mindmap")
        XCTAssertTrue(harness.views.all.isEmpty)
        XCTAssertNil(harness.kernel.commands.command(id: "mindmap.open"))
        XCTAssertNil(harness.kernel.commands.command(id: "mindmap.new"))
        XCTAssertTrue(harness.panels.newItems.isEmpty)
    }
}
