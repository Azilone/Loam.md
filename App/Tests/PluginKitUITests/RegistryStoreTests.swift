import PluginKitUI
import SwiftUI
import XCTest

@MainActor
final class RegistryStoreTests: XCTestCase {
    private func viewType(_ id: String, priority: Int = 0, opens: @escaping @MainActor (Resource) -> Bool = { _ in true }) -> ViewType {
        ViewType(id: id, title: id, priority: priority, canOpen: opens) { _ in AnyView(EmptyView()) }
    }

    private func panel(_ id: String, _ slot: Slot, order: Int = 0) -> Panel {
        Panel(id: id, title: id, symbol: "star", slot: slot, order: order) { AnyView(EmptyView()) }
    }

    func testViewTypesComeByPriorityThenID() {
        let store = ViewRegistryStore()
        _ = store.register(viewType("b.text", priority: 0))
        _ = store.register(viewType("c.board", priority: 10))
        _ = store.register(viewType("a.raw", priority: 0))
        _ = store.register(viewType("d.image", priority: 50, opens: { $0.pathExtension == "png" }))
        XCTAssertEqual(store.viewTypes(for: .file("note.md")).map(\.id), ["c.board", "a.raw", "b.text"])
        XCTAssertEqual(store.viewTypes(for: .file("photo.png")).map(\.id), ["d.image", "c.board", "a.raw", "b.text"])
    }

    func testRegisteringAnIDAgainReplacesItAndOnlyTheNewRemoverRemovesIt() {
        let store = ViewRegistryStore()
        let removeOld = store.register(viewType("x.view", priority: 1))
        let removeNew = store.register(viewType("x.view", priority: 2))
        XCTAssertEqual(store.all.map(\.priority), [2])

        removeOld()
        XCTAssertEqual(store.all.map(\.priority), [2], "a replaced registration must not remove its replacement")
        removeNew()
        XCTAssertTrue(store.all.isEmpty)
        removeNew()
        XCTAssertTrue(store.all.isEmpty)
    }

    func testPanelsComeBySlotThenOrderThenID() {
        let store = PanelRegistryStore()
        _ = store.register(panel("files", .leading, order: 0))
        _ = store.register(panel("search", .leading, order: 1))
        _ = store.register(panel("bookmarks", .leading, order: 1))
        _ = store.register(panel("words", .statusBar))
        XCTAssertEqual(store.panels(in: .leading).map(\.id), ["files", "bookmarks", "search"])
        XCTAssertEqual(store.panels(in: .statusBar).map(\.id), ["words"])
        XCTAssertEqual(store.panels(in: .trailing).map(\.id), [])
    }

    func testPanelDuplicatesFollowTheSameRule() {
        let store = PanelRegistryStore()
        let removeOld = store.register(panel("p", .leading))
        _ = store.register(panel("p", .trailing))
        removeOld()
        XCTAssertEqual(store.panels(in: .trailing).map(\.id), ["p"])
        XCTAssertEqual(store.panels(in: .leading).map(\.id), [])
    }

    func testSidebarLinksComeByOrderThenIDAndLeaveWithTheirRemover() {
        let store = PanelRegistryStore()
        let removeB = store.register(SidebarLink(id: "b", title: "B", symbol: "b", resource: .virtual("b:"), order: 1))
        _ = store.register(SidebarLink(id: "c", title: "C", symbol: "c", resource: .virtual("c:"), order: 0))
        _ = store.register(SidebarLink(id: "a", title: "A", symbol: "a", resource: .virtual("a:"), order: 1))
        XCTAssertEqual(store.links.map(\.id), ["c", "a", "b"])
        removeB()
        XCTAssertEqual(store.links.map(\.id), ["c", "a"])
    }

    func testAPreferringTypeComesFirstAndGivesItsSymbol() {
        let store = ViewRegistryStore()
        _ = store.register(ViewType(id: "editor", title: "Markdown", priority: 5, symbol: "doc.text", canOpen: { _ in true }) { _ in
            AnyView(EmptyView())
        })
        _ = store.register(ViewType(
            id: "map", title: "Map", symbol: "map", canOpen: { _ in true }, prefers: { $0.path == "flagged.md" }
        ) { _ in AnyView(EmptyView()) })
        XCTAssertEqual(store.viewTypes(for: .file("plain.md")).map(\.id), ["editor", "map"])
        XCTAssertEqual(store.viewTypes(for: .file("flagged.md")).map(\.id), ["map", "editor"])
        XCTAssertEqual(store.symbol(for: .file("plain.md")), "doc.text")
        XCTAssertEqual(store.symbol(for: .file("flagged.md")), "map")
    }

    func testNewItemsComeByOrderAndLeaveWithTheirRemover() {
        let store = PanelRegistryStore()
        let removeMap = store.register(NewItem(id: "map", title: "New Map", symbol: "map", order: 2) { _ in })
        _ = store.register(NewItem(id: "board", title: "New Board", symbol: "board", order: 1) { _ in })
        XCTAssertEqual(store.newItems.map(\.id), ["board", "map"])
        removeMap()
        XCTAssertEqual(store.newItems.map(\.id), ["board"])
    }

    func testNoteHeadersApplyByResourceAndComeByOrderThenID() {
        let store = NoteHeaderStore()
        func header(_ id: String, order: Int, applies: @escaping @MainActor (Resource) -> Bool = { _ in true }) -> NoteHeader {
            NoteHeader(id: id, order: order, appliesTo: applies) { _ in AnyView(EmptyView()) }
        }
        _ = store.register(header("b.second", order: 20))
        _ = store.register(header("a.second", order: 20))
        _ = store.register(header("c.first", order: 10))
        let removeDaily = store.register(header("d.daily", order: 0, applies: { $0.path.hasPrefix("Daily/") }))
        XCTAssertEqual(store.headers(for: .file("Daily/2026-10-19.md")).map(\.id), ["d.daily", "c.first", "a.second", "b.second"])
        XCTAssertEqual(store.headers(for: .file("Notes/a.md")).map(\.id), ["c.first", "a.second", "b.second"])
        removeDaily()
        XCTAssertEqual(store.headers(for: .file("Daily/2026-10-19.md")).map(\.id), ["c.first", "a.second", "b.second"])
    }
}
