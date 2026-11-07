import PluginKitUI
import PluginKitUITesting
import SwiftUI
import XCTest
@testable import MindmapUI

/// The map from the keyboard alone (Return, Tab, Shift-Tab and Escape while typing, arrows, folding, ⌘ arrows), its
/// commands, and dragging a topic across the central topic to the other side.
@MainActor
final class MindmapKeyboardTests: XCTestCase {
    private let files = [
        "Map.md": "---\nmindmap-plugin: basic\n---\n\n# Project\n\n- Ideas\n\t- One\n\t- Two\n- Tasks\n",
        // Paris and Rome on the right of the central topic, Berlin and Munich on its left.
        "Trip.md": "---\nmindmap-plugin: basic\nmindmap-right: 2\n---\n\n# Trip\n\n"
            + "- Paris\n\t- Louvre\n\t- Eiffel Tower\n- Rome\n\t- Colosseum\n- Berlin\n- Munich\n",
        // No `mindmap-right:`: the map balances the sides.
        "Review.md": "---\nmindmap-plugin: basic\n---\n\n# Review\n\n"
            + "- One\n\t- One A\n\t- One B\n- Two\n- Three\n- Four\n",
        "Time.md": "---\nmindmap-plugin: basic\nmindmap-layout: timeline\n---\n\n# Year\n\n"
            + "- Jan\n\t- a\n- Feb\n\t- b\n- Mar\n- Apr\n",
    ]
    private var harness: UIPluginHarness!
    private var undo: UndoManager!

    override func setUp() async throws {
        harness = try UIPluginHarness(uiPlugins: [MindmapPlugin.self], files: files, editor: RecordingEditor())
        undo = UndoManager()
        undo.groupsByEvent = false
    }

    override func tearDown() async throws {
        harness.close()
    }

    private func tab(_ path: String, active: Bool = false) throws -> MindmapTabModel {
        let store = try XCTUnwrap(harness.kernel.services.service(MindmapPlugin.storeKey))
        let tab = store.makeTab(ViewContext(resource: .virtual("mindmap:" + path), isActive: active))
        tab.undoManager = undo
        tab.viewResized(CGSize(width: 1000, height: 700))
        return tab
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

    // MARK: - Typing

    func testReturnAndTabWhileTypingChainTopics() throws {
        let tab = try tab("Map.md")
        tab.select(try id(tab, "Tasks"))
        step { tab.addChild() }
        tab.draft = "A"
        step { tab.tabWhileEditing() }
        let child = try XCTUnwrap(tab.editingID, "Tab saved A and opened its child for typing")
        XCTAssertEqual(tab.parent(of: child)?.text, "A")
        XCTAssertEqual(tab.draft, "")
        tab.draft = "A1"
        step { tab.returnWhileEditing() }
        let sibling = try XCTUnwrap(tab.editingID, "Return saved A1 and opened a sibling for typing")
        XCTAssertNotEqual(sibling, child)
        XCTAssertEqual(tab.parent(of: sibling)?.text, "A")
        tab.draft = "A2"
        step { tab.returnWhileEditing() }
        XCTAssertNotNil(tab.editingID)

        // Return on the new empty topic ends the run, as a second Return ends a list (nothing to undo).
        tab.returnWhileEditing()
        XCTAssertNil(tab.editingID)
        XCTAssertEqual(tab.focusID, try id(tab, "A2"))
        XCTAssertEqual(tab.root?.all.count, 8)
        XCTAssertTrue(try file("Map.md").hasSuffix("- Tasks\n\t- A\n\t\t- A1\n\t\t- A2\n"))

        undo.undo()
        let undone = try file("Map.md")
        XCTAssertTrue(undone.hasSuffix("- Tasks\n\t- A\n\t\t- A1\n"), "each topic is one undo step: \(undone)")
    }

    func testReturnOnASelectedTopicOpensASiblingOnItsSide() throws {
        let tab = try tab("Trip.md")
        tab.select(try id(tab, "Berlin"))
        step { tab.addSibling() }
        let new = try XCTUnwrap(tab.editingID, "ready for typing")
        XCTAssertEqual(tab.side(of: new), -1, "on Berlin's side")
        tab.draft = "Hamburg"
        step { tab.commitEdit() }
        XCTAssertTrue(try file("Trip.md").contains("- Berlin\n- Hamburg\n- Munich\n"))

        tab.select(try id(tab, "Paris"))
        step { tab.addSibling(above: true) }
        XCTAssertEqual(tab.side(of: try XCTUnwrap(tab.editingID)), 1, "Shift-Return: above Paris, on the right")
        tab.draft = "Lyon"
        step { tab.commitEdit() }
        XCTAssertEqual(tab.root?.children.map(\.text), ["Lyon", "Paris", "Rome", "Berlin", "Hamburg", "Munich"])
        XCTAssertEqual(try ["Lyon", "Paris", "Rome", "Berlin"].map { tab.side(of: try id(tab, $0)) }, [1, 1, 1, -1])
    }

    func testAnOutsideChangeDuringEditingDoesNotLeaveTheMapStuckInEditing() throws {
        let tab = try tab("Map.md")
        tab.select(try id(tab, "Tasks"))
        step { tab.addChild() }
        XCTAssertNotNil(tab.editingID)
        try harness.vault.write("Map.md", "---\nmindmap-plugin: basic\n---\n\n# Project\n\n- Ideas\n- Other\n")
        tab.refresh()
        XCTAssertNil(tab.editingID, "the unsaved topic is gone, so is the editing state")
        XCTAssertFalse(tab.commitEdit())
        tab.select(try id(tab, "Other"))
        step { tab.addSibling() }
        XCTAssertNotNil(tab.editingID, "keys work again")
    }

    func testTabOnTheCentralTopicAddsOnTheLighterSide() throws {
        let tab = try tab("Trip.md")
        tab.select(try XCTUnwrap(tab.root?.id))
        step { tab.addChild() }
        XCTAssertEqual(tab.side(of: try XCTUnwrap(tab.editingID)), -1, "the left side has fewer topics")
    }

    func testShiftTabWhileTypingMovesTheTopicUpALevel() throws {
        let tab = try tab("Map.md")
        tab.select(try id(tab, "Two"))
        step { tab.addSibling() }
        let new = try XCTUnwrap(tab.editingID)
        step { tab.backtabWhileEditing() }
        XCTAssertEqual(tab.editingID, new, "still typing")
        XCTAssertTrue(tab.parent(of: new) === tab.root)
        tab.draft = "New"
        step { tab.commitEdit() }
        XCTAssertTrue(try file("Map.md").hasSuffix("- Ideas\n\t- One\n\t- Two\n- New\n- Tasks\n"))

        // A topic already written moves too, its typing kept.
        let one = try id(tab, "One")
        tab.startEdit(one)
        tab.draft = "One, edited"
        step { tab.backtabWhileEditing() }
        XCTAssertEqual(tab.editingID, one)
        XCTAssertEqual(tab.draft, "One, edited")
        step { tab.commitEdit() }
        XCTAssertTrue(try file("Map.md").hasSuffix("- Ideas\n\t- Two\n- One, edited\n- New\n- Tasks\n"))
    }

    func testTabOnAnEmptyNewTopicPutsItUnderTheTopicAbove() throws {
        let tab = try tab("Map.md")
        tab.select(try id(tab, "One"))
        step { tab.addSibling() }
        let new = try XCTUnwrap(tab.editingID)
        step { tab.tabWhileEditing() }
        XCTAssertEqual(tab.editingID, new)
        XCTAssertEqual(tab.parent(of: new)?.text, "One")
        tab.draft = "Detail"
        step { tab.commitEdit() }
        XCTAssertTrue(try file("Map.md").contains("\t- One\n\t\t- Detail\n\t- Two\n"))
    }

    func testEscapeEndsTypingAndKeepsTheTopicSelected() throws {
        let tab = try tab("Map.md")
        let tasks = try id(tab, "Tasks")
        tab.startEdit(tasks)
        tab.draft = "Todo"
        step { tab.commitEdit() }
        XCTAssertNil(tab.editingID)
        XCTAssertEqual(tab.selection, [tasks])
        XCTAssertEqual(tab.focusID, tasks)
        XCTAssertTrue(try file("Map.md").hasSuffix("- Todo\n"))
        // The second Escape clears the selection.
        tab.deselect()
        XCTAssertTrue(tab.selection.isEmpty)
        XCTAssertNil(tab.focusID)

        // Typing on a selected topic replaces its text.
        tab.startEdit(tasks, replacingWith: "D")
        XCTAssertEqual(tab.draft, "D")
    }

    // MARK: - Keys

    private func press(_ tab: MindmapTabModel, _ key: MindmapKey, _ modifiers: NSEvent.ModifierFlags = []) {
        step { _ = tab.handleKey(key, modifiers: modifiers) }
    }

    private func type(_ tab: MindmapTabModel, _ text: String) {
        for character in text { press(tab, .character(String(character))) }
    }

    func testKeysTypedBeforeTheFieldIsUpAreKept() throws {
        let tab = try tab("Map.md")
        tab.select(try id(tab, "Tasks"))
        // No text field in the tests: the keys reach the map, as they do in the app until the field is up.
        press(tab, .tab)
        let first = try XCTUnwrap(tab.editingID, "Tab opens a child for typing")
        type(tab, "Bee")
        press(tab, .delete)
        XCTAssertEqual(tab.draft, "Be")
        press(tab, .returnKey)
        XCTAssertNotEqual(tab.editingID, first, "Return saved Be and opened a sibling")
        type(tab, "Sea")
        press(tab, .escape)
        XCTAssertNil(tab.editingID)
        XCTAssertEqual(tab.selection, [try id(tab, "Sea")], "Escape keeps the new topic selected")
        XCTAssertTrue(try file("Map.md").hasSuffix("- Tasks\n\t- Be\n\t- Sea\n"))

        // Tab while typing, before the field: a child of the topic being typed.
        press(tab, .tab)
        type(tab, "Deep")
        press(tab, .tab, [.shift])
        XCTAssertNotNil(tab.editingID, "Shift-Tab keeps typing, a level up")
        press(tab, .escape)
        XCTAssertTrue(try file("Map.md").hasSuffix("- Tasks\n\t- Be\n\t- Sea\n\t- Deep\n"))
        press(tab, .escape)
        XCTAssertTrue(tab.selection.isEmpty, "a second Escape clears the selection")
    }

    func testWithNothingSelectedTheKeysActOnTheCentralTopic() throws {
        let tab = try tab("Map.md")
        let root = try XCTUnwrap(tab.root?.id)
        XCTAssertEqual(tab.focusID, root, "an opened map has its central topic selected")

        tab.deselect()
        press(tab, .tab)
        let child = try XCTUnwrap(tab.editingID, "Tab with nothing selected: a main topic")
        XCTAssertTrue(tab.parent(of: child) === tab.root)
        type(tab, "Via Tab")
        press(tab, .escape)
        tab.deselect()
        press(tab, .returnKey)
        XCTAssertTrue(tab.parent(of: try XCTUnwrap(tab.editingID)) === tab.root, "Return too")
        type(tab, "Via Return")
        press(tab, .escape)
        XCTAssertEqual(tab.root?.children.map(\.text).filter { $0.hasPrefix("Via") }.sorted(),
                       ["Via Return", "Via Tab"])

        tab.deselect()
        press(tab, .space)
        XCTAssertEqual(tab.editingID, root, "Space edits the central topic")
        press(tab, .escape)
        tab.deselect()
        press(tab, .character("Z"))
        XCTAssertEqual(tab.editingID, root, "and typing types over it")
        XCTAssertEqual(tab.draft, "Z")
    }

    func testEscapeAfterTypingOverATopicPutsItsTextBack() throws {
        let tab = try tab("Trip.md")
        let before = try file("Trip.md")
        let paris = try id(tab, "Paris")
        tab.select(paris)
        press(tab, .character("f"))
        XCTAssertEqual(tab.editingID, paris)
        XCTAssertEqual(tab.draft, "f", "a letter on a selected topic types over its text")
        press(tab, .escape)
        XCTAssertNil(tab.editingID)
        XCTAssertEqual(tab.topic(paris)?.text, "Paris", "Escape put the text back")
        XCTAssertEqual(try file("Trip.md"), before)
        XCTAssertEqual(tab.selection, [paris])

        // Return keeps the typing, as does Escape after Space (or F2), which edit the text in place.
        press(tab, .character("L"))
        type(tab, "yon")
        press(tab, .returnKey)
        press(tab, .escape)
        XCTAssertEqual(tab.topic(paris)?.text, "Lyon")
        tab.select(paris)
        press(tab, .space)
        XCTAssertEqual(tab.draft, "Lyon")
        type(tab, "!")
        press(tab, .escape)
        XCTAssertEqual(tab.topic(paris)?.text, "Lyon!")
        XCTAssertTrue(try file("Trip.md").contains("- Lyon!\n\t- Louvre\n"))
    }

    func testTheTextFieldsKeysAddTopicsAndHandTheKeyboardToTheMap() throws {
        let tab = try tab("Map.md")
        tab.select(try id(tab, "Tasks"))
        step { tab.addChild() }
        tab.draft = "Field"
        let coordinator = MindmapTextField.Coordinator(model: tab)
        let field = NSTextField()
        let requests = tab.focusRequest
        step {
            XCTAssertTrue(coordinator.control(field, textView: NSTextView(),
                                              doCommandBy: #selector(NSResponder.insertTab(_:))))
        }
        let child = try XCTUnwrap(tab.editingID, "Tab in the field: a child, ready for typing")
        XCTAssertEqual(tab.parent(of: child)?.text, "Field")
        XCTAssertGreaterThan(tab.focusRequest, requests,
                             "the map takes the keyboard until the child's field is up, so no key is lost")
        // Escape on the new empty topic: it goes away, and Field stays selected.
        XCTAssertTrue(coordinator.control(field, textView: NSTextView(),
                                          doCommandBy: #selector(NSResponder.cancelOperation(_:))))
        XCTAssertNil(tab.editingID)
        XCTAssertEqual(tab.focusID, try id(tab, "Field"))
        XCTAssertTrue(try file("Map.md").hasSuffix("- Tasks\n\t- Field\n"))
    }

    func testTheKeysThatType() {
        XCTAssertEqual(MindmapKey.character("é").typedText, "é")
        XCTAssertEqual(MindmapKey.space.typedText, " ")
        XCTAssertNil(MindmapKey.character("\u{F700}").typedText, "an arrow's function-key character")
        XCTAssertNil(MindmapKey.character("\u{1B}").typedText)
        XCTAssertNil(MindmapKey.returnKey.typedText)
    }

    // MARK: - Moving around

    func testArrowsFollowTheSidesOfTheMap() throws {
        let tab = try tab("Trip.md")
        let root = try XCTUnwrap(tab.root?.id)
        tab.select(root)
        tab.navigate(.left)
        let left = try XCTUnwrap(tab.focusID)
        XCTAssertEqual(tab.side(of: left), -1, "left goes to a topic on the left")
        tab.navigate(.right)
        XCTAssertEqual(tab.focusID, root, "and right comes back to the central topic")
        tab.navigate(.right)
        XCTAssertEqual(tab.side(of: try XCTUnwrap(tab.focusID)), 1)

        tab.select(try id(tab, "Berlin"))
        tab.navigate(.bottom)
        XCTAssertEqual(tab.focusID, try id(tab, "Munich"), "down: the next topic on the same side")
        tab.navigate(.top)
        XCTAssertEqual(tab.focusID, try id(tab, "Berlin"))

        tab.select(try id(tab, "Paris"))
        tab.navigate(.right)
        XCTAssertEqual(tab.focusID, try id(tab, "Louvre"), "outward: the nearest child")
        tab.navigate(.bottom)
        XCTAssertEqual(tab.focusID, try id(tab, "Eiffel Tower"))
        tab.navigate(.left)
        XCTAssertEqual(tab.focusID, try id(tab, "Paris"), "inward: the parent")
    }

    func testFoldingFromTheKeyboard() throws {
        let tab = try tab("Trip.md")
        let paris = try id(tab, "Paris")
        tab.select(paris)
        tab.foldFocused()
        XCTAssertEqual(tab.folded, [paris])
        XCTAssertNil(tab.placements[try id(tab, "Louvre")], "the branch is hidden")
        XCTAssertEqual(tab.scene.first { $0.id == paris }?.descendantCount, 2, "the badge's hidden count")
        tab.unfoldFocused()
        XCTAssertTrue(tab.folded.isEmpty)

        // On a topic without children, folding folds the branch it is in, and selects its head.
        tab.select(try id(tab, "Louvre"))
        tab.foldFocused()
        XCTAssertEqual(tab.folded, [paris])
        XCTAssertEqual(tab.focusID, paris)
        XCTAssertEqual(tab.selection, [paris])

        // Right on a folded topic, outward, unfolds it.
        tab.navigate(.right)
        XCTAssertTrue(tab.folded.isEmpty)

        tab.setAllFolded(true)
        XCTAssertEqual(tab.folded, [paris, try id(tab, "Rome")])
        tab.setAllFolded(false)
        XCTAssertTrue(tab.folded.isEmpty)

        // ⌘. on the central topic does nothing: it never folds.
        tab.select(try XCTUnwrap(tab.root?.id))
        tab.foldSelection()
        XCTAssertTrue(tab.folded.isEmpty)
    }

    func testCommandArrowsReorderAndCrossSides() throws {
        let tab = try tab("Trip.md")
        let rome = try id(tab, "Rome")
        tab.select(rome)
        step { tab.moveSibling(by: 1) }
        XCTAssertEqual(tab.root?.children.map(\.text), ["Paris", "Rome", "Berlin", "Munich"],
                       "the last topic on the right does not slip to the left side")
        step { tab.moveSibling(by: -1) }
        XCTAssertEqual(tab.root?.children.map(\.text), ["Rome", "Paris", "Berlin", "Munich"])

        // ⌘← on a topic on the right, toward the central topic: it crosses to the left side.
        step { tab.moveHorizontally(-1) }
        XCTAssertEqual(tab.side(of: rome), -1)
        XCTAssertEqual(tab.focusID, rome)
        XCTAssertEqual(tab.root?.children.first?.text, "Paris")
        let reopened = try self.tab("Trip.md")
        XCTAssertFalse(reopened === tab)
        XCTAssertEqual(reopened.side(of: try id(reopened, "Rome")), -1, "the side is in the note")

        // ⌘→ brings it back; away from the central topic, a topic goes under the one above it.
        step { tab.moveHorizontally(1) }
        XCTAssertEqual(tab.side(of: rome), 1)
        let munich = try id(tab, "Munich")
        tab.select(munich)
        step { tab.moveHorizontally(-1) }
        XCTAssertEqual(tab.parent(of: munich)?.text, "Berlin")

        // A main topic moves to the other side from the palette too.
        tab.select(try id(tab, "Berlin"))
        step { tab.moveToOtherSide() }
        XCTAssertEqual(tab.side(of: try id(tab, "Berlin")), 1)
        XCTAssertTrue(try file("Trip.md").contains("- Berlin\n\t- Munich\n"))

        undo.undo()
        XCTAssertEqual(tab.side(of: try id(tab, "Berlin")), -1, "undo puts it back on its side")
    }

    // MARK: - Drag and drop

    func testDraggingAcrossTheCentreLineChangesSides() throws {
        let tab = try tab("Trip.md")
        let paris = try id(tab, "Paris")
        let center = try XCTUnwrap(tab.placements[try XCTUnwrap(tab.root?.id)]).frame
        let munich = try XCTUnwrap(tab.placements[try id(tab, "Munich")]).frame
        tab.beginDrag(paris)
        XCTAssertTrue(tab.isDragged(try id(tab, "Louvre")), "the branch moves with its topic")
        XCTAssertFalse(tab.isDragged(try id(tab, "Rome")))

        // Over the central topic, one point either side of its centre line decides the side.
        let justRight = tab.dropTarget(at: CGPoint(x: center.midX + 1, y: center.midY + 4))
        let justLeft = tab.dropTarget(at: CGPoint(x: center.midX - 1, y: center.midY + 4))
        XCTAssertEqual(justRight?.side, 1)
        XCTAssertEqual(justLeft?.side, -1)
        XCTAssertEqual(justLeft.flatMap { tab.side(of: $0.id) }, -1, "next to a topic of the left side")

        // Below Munich, far from the topics: the nearest slot, after Munich.
        let below = try XCTUnwrap(tab.dropTarget(at: CGPoint(x: munich.midX, y: munich.maxY + 60)))
        XCTAssertEqual(below, MindmapDropTarget(id: try id(tab, "Munich"), mode: .after, side: -1))
        step { tab.move([paris], to: below) }
        XCTAssertEqual(tab.side(of: paris), -1)
        XCTAssertEqual(tab.root?.children.map(\.text), ["Rome", "Berlin", "Munich", "Paris"])
        XCTAssertTrue(try file("Trip.md").contains("mindmap-right: 1\n"))
        XCTAssertTrue(try file("Trip.md").hasSuffix("- Munich\n- Paris\n\t- Louvre\n\t- Eiffel Tower\n"))

        // A side with no topic left still takes one, through the view's drag: the first topic there.
        tab.select(try id(tab, "Rome"))
        step { tab.moveToOtherSide() }
        XCTAssertTrue(try ["Rome", "Berlin", "Munich", "Paris"].allSatisfy { tab.side(of: try id(tab, $0)) == -1 })
        let berlin = try id(tab, "Berlin")
        let world = CGPoint(x: center.maxX + 200, y: center.midY)
        tab.beginDrag(berlin)
        let rect = tab.screenRect(CGRect(origin: world, size: .zero))
        tab.updateDrag(to: rect.origin)
        XCTAssertEqual(tab.dropTarget, MindmapDropTarget(id: try XCTUnwrap(tab.root?.id), mode: .inside, side: 1))
        step { tab.endDrag() }
        XCTAssertEqual(tab.side(of: berlin), 1)
        XCTAssertTrue(tab.dragging.isEmpty)
        XCTAssertEqual(tab.root?.children.first?.text, "Berlin", "the right side's topics come first in the note")
    }

    func testDropsOnATimelineGoBetweenEvents() throws {
        let tab = try tab("Time.md")
        XCTAssertEqual(tab.mode, .timeline)
        let jan = try XCTUnwrap(tab.placements[try id(tab, "Jan")]).frame
        let feb = try XCTUnwrap(tab.placements[try id(tab, "Feb")]).frame
        let center = try XCTUnwrap(tab.placements[try XCTUnwrap(tab.root?.id)]).frame
        let apr = try id(tab, "Apr")
        tab.beginDrag(apr)

        // In the gap between two events on the line, or just past one: between them, never into a detail.
        let gap = try XCTUnwrap(tab.dropTarget(at: CGPoint(x: (jan.maxX + feb.minX) / 2, y: jan.midY)))
        XCTAssertNotEqual(gap.mode, .inside)
        XCTAssertTrue([try id(tab, "Jan"), try id(tab, "Feb")].contains(gap.id))
        XCTAssertEqual(tab.dropTarget(at: CGPoint(x: jan.maxX + 10, y: jan.midY)),
                       MindmapDropTarget(id: try id(tab, "Jan"), mode: .after))
        XCTAssertEqual(tab.dropTarget(at: CGPoint(x: jan.midX, y: jan.midY)),
                       MindmapDropTarget(id: try id(tab, "Jan"), mode: .inside), "over its middle: a detail")
        XCTAssertEqual(tab.dropTarget(at: CGPoint(x: center.midX, y: center.midY)),
                       MindmapDropTarget(id: try id(tab, "Jan"), mode: .before), "the central topic: first")

        let afterJan = MindmapDropTarget(id: try id(tab, "Jan"), mode: .after)
        step { tab.move([apr], to: afterJan) }
        XCTAssertEqual(tab.root?.children.map(\.text), ["Jan", "Apr", "Feb", "Mar"])
    }

    // MARK: - Sides in the note

    func testOrdinaryEditsLeaveTheFrontmatterAlone() throws {
        let tab = try tab("Review.md")
        let frontmatter = "---\nmindmap-plugin: basic\n---\n\n# Review\n"
        let sides = try ["One", "Two", "Three", "Four"].map { tab.side(of: try id(tab, $0)) }

        tab.select(try id(tab, "One B"))
        step { tab.deleteSelection() }
        for text in ["a", "b", "c", "d", "e", "f"] {
            tab.select(try id(tab, "One"))
            step { tab.addChild(text: text) }
        }
        tab.select(try id(tab, "a"))
        step { tab.outdent() }
        tab.select(try id(tab, "Two"))
        step { tab.addSibling(text: "Two and a half") }
        let file = try file("Review.md")
        XCTAssertTrue(file.hasPrefix(frontmatter), "no `mindmap-right:` was written: \(file)")
        XCTAssertEqual(try ["One", "Two", "Three", "Four"].map { tab.side(of: try id(tab, $0)) }, sides,
                       "and no topic jumped to the other side meanwhile")

        // Undo puts back the sides the map showed, not the balanced ones.
        undo.undo()
        XCTAssertNil(tab.root?.all.first { $0.text == "Two and a half" })
        XCTAssertEqual(try ["One", "Two", "Three", "Four"].map { tab.side(of: try id(tab, $0)) }, sides)

        // Moving a topic to the other side on purpose writes the sides.
        tab.select(try id(tab, "Four"))
        step { tab.moveToOtherSide() }
        XCTAssertTrue(try self.file("Review.md").contains("mindmap-right: "))
        let reopened = try self.tab("Review.md")
        XCTAssertEqual(reopened.side(of: try id(reopened, "Four")), tab.side(of: try id(tab, "Four")))
    }

    func testANoteWithItsSidesKeepsThemInStep() throws {
        let tab = try tab("Trip.md")
        tab.select(try id(tab, "Paris"))
        step { tab.addSibling(text: "Lyon") }
        XCTAssertTrue(try file("Trip.md").contains("mindmap-right: 3\n"), "a third topic on the right")
        tab.select(try id(tab, "Munich"))
        step { tab.deleteSelection() }
        XCTAssertTrue(try file("Trip.md").contains("mindmap-right: 3\n"), "one less on the left")
        tab.select(try id(tab, "Rome"))
        step { tab.deleteSelection() }
        XCTAssertTrue(try file("Trip.md").contains("mindmap-right: 2\n"))
    }

    func testTypingMainTopicsWithReturnKeepsTheMapBalanced() throws {
        let tab = try tab("Map.md")
        tab.select(try XCTUnwrap(tab.root?.id))
        step { tab.addChild(text: "A") }
        for text in ["B", "C", "D", "E", "F"] {
            tab.select(try id(tab, String(UnicodeScalar(UInt8(ascii: "A") + UInt8(["B", "C", "D", "E", "F"].firstIndex(of: text) ?? 0)))))
            step { tab.addSibling(text: text) }
        }
        let sides = try ["Ideas", "Tasks", "A", "B", "C", "D", "E", "F"].map { tab.side(of: try id(tab, $0)) }
        let right = sides.filter { $0 == 1 }.count
        XCTAssertTrue((3...5).contains(right), "sides are not lopsided: \(sides)")
        XCTAssertFalse(try file("Map.md").contains("mindmap-right"))
    }

    func testReorderingInAnotherLayoutNeverSendsTopicsAcross() throws {
        let tab = try tab("Trip.md")
        step { tab.setMode(.logic) }
        tab.select(try id(tab, "Munich"))
        for _ in 0 ..< 3 { step { tab.moveSibling(by: -1) } }
        step { tab.setMode(.mindmap) }
        XCTAssertEqual(tab.root?.children.map(\.text).first, "Munich")
        let right = tab.root?.children.filter { tab.side(of: $0.id) == 1 }.map(\.text) ?? []
        let note = try file("Trip.md")
        // Either the sides are still those of the note, or the stale count is gone and the map balances.
        XCTAssertTrue(!note.contains("mindmap-right: 2") || Set(right) == ["Munich", "Paris"], note)
        XCTAssertFalse(note.contains("mindmap-right: 2"), "the count no longer matches the order: \(note)")
    }

    func testMovingATopicKeepsItInView() throws {
        let tab = try tab("Trip.md")
        let center = try XCTUnwrap(tab.placements[try XCTUnwrap(tab.root?.id)]).frame
        // The central topic at the view's left edge: the left side is out of sight.
        tab.offset = CGSize(width: 40 - center.minX * tab.scale, height: tab.offset.height)
        let rome = try id(tab, "Rome")
        tab.select(rome)
        step { tab.moveToOtherSide() }
        XCTAssertEqual(tab.side(of: rome), -1)
        let rect = tab.screenRect(try XCTUnwrap(tab.placements[rome]).frame)
        XCTAssertGreaterThanOrEqual(rect.minX, 0, "the view followed Rome to the left")
        XCTAssertLessThanOrEqual(rect.maxX, tab.viewSize.width)
    }

    // MARK: - Commands

    func testCommandsListTheirKeys() throws {
        let add = try XCTUnwrap(harness.kernel.commands.command(id: "mindmap.add-child"))
        XCTAssertNil(add.shortcut, "Tab is the map's own key: no setting can rebind it")
        XCTAssertEqual(add.viewKey?.description, "tab", "the palette still shows it")
        XCTAssertEqual(harness.kernel.commands.command(id: "mindmap.outdent")?.viewKey?.description, "shift+tab")
        XCTAssertEqual(harness.kernel.commands.command(id: "mindmap.move-up")?.shortcut?.description, "cmd+up")
        XCTAssertEqual(harness.kernel.commands.command(id: "mindmap.toggle-fold")?.shortcut?.description, "cmd+.")
        XCTAssertEqual(harness.kernel.commands.command(id: "mindmap.unfold-all")?.shortcut?.description,
                       "opt+shift+cmd+right")
        XCTAssertEqual(add.isShortcutEnabled?(), false, "no map has the keyboard: ⌘↑ stays the editor's")

        harness.host.deactivate("mindmap")
        XCTAssertTrue(MindmapCommands.actions.allSatisfy { harness.kernel.commands.command(id: $0.id) == nil })
    }

    func testCommandsNeedAMap() async throws {
        do {
            _ = try await harness.run("mindmap.fold-all")
            XCTFail("no map open")
        } catch let error as MindmapCommandError {
            XCTAssertEqual(error.errorDescription, "Open a mindmap first.")
        }
    }

    func testCommandsActOnTheFocusedMap() async throws {
        let tab = try tab("Map.md", active: true)
        tab.select(try id(tab, "Tasks"))
        undo.beginUndoGrouping()
        _ = try await harness.run("mindmap.add-child", ["text": "From an agent"])
        undo.endUndoGrouping()
        XCTAssertTrue(try file("Map.md").hasSuffix("- Tasks\n\t- From an agent\n"))
        XCTAssertNil(tab.editingID, "with a text, the topic is written at once")
        _ = try await harness.run("mindmap.fold-all")
        XCTAssertEqual(tab.folded.count, 2)
    }
}
