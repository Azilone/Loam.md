import PluginKitUI
import SwiftUI
import XCTest

/// The right sidebar's contract: sections by placement, resource and view, and the tabs a view publishes.
@MainActor
final class InspectorTests: XCTestCase {
    private func section(
        _ id: String, _ placement: InspectorSection.Placement = .info, order: Int = 0, viewTypes: Set<String>? = nil,
        applies: @escaping @MainActor @Sendable (Resource) -> Bool = { _ in true }
    ) -> InspectorSection {
        InspectorSection(id: id, placement: placement, order: order, viewTypes: viewTypes, appliesTo: applies) { _ in
            AnyView(EmptyView())
        }
    }

    func testSectionsAreFilteredByPlacementResourceAndViewThenSorted() {
        let store = InspectorStore()
        _ = store.register(section("b", order: 2))
        _ = store.register(section("a", order: 2))
        _ = store.register(section("first", order: -1))
        _ = store.register(section("notes", applies: { $0.pathExtension == "md" }))
        _ = store.register(section("outline", .primary, viewTypes: ["markdown.editor"]))
        let note = Resource.file("Plan.md")

        XCTAssertEqual(store.sections(for: note, viewType: "markdown.editor", in: .info).map(\.id), ["first", "notes", "a", "b"])
        XCTAssertEqual(store.sections(for: .virtual("graph:"), viewType: nil, in: .info).map(\.id), ["first", "a", "b"])
        XCTAssertEqual(store.sections(for: note, viewType: "markdown.editor", in: .primary).map(\.id), ["outline"])
        XCTAssertEqual(store.sections(for: note, viewType: "mindmap.file", in: .primary).map(\.id), [])
        XCTAssertEqual(store.sections(for: note, viewType: nil, in: .primary).map(\.id), [])
    }

    func testSectionsNamingOnePageMakeOneTabInOrder() {
        let store = InspectorStore()
        let links = InspectorPage(id: "links", title: "Links", order: 20)
        _ = store.register(section("mentions", .tab(links), order: 2))
        _ = store.register(section("backlinks", .tab(links), order: 1))
        _ = store.register(section("outline", .tab(InspectorPage(id: "outline", title: "Outline", order: 10))))
        _ = store.register(section("day", .tab(InspectorPage(id: "day", title: "Day", order: -10)),
                                   applies: { $0.path.hasPrefix("Daily/") }))
        _ = store.register(section("info"))

        let note = store.pages(for: .file("Plan.md"), viewType: nil)
        XCTAssertEqual(note.map(\.page.title), ["Outline", "Links"])
        XCTAssertEqual(note.last?.sections.map(\.id), ["backlinks", "mentions"])
        XCTAssertEqual(store.pages(for: .file("Daily/2026-10-21.md"), viewType: nil).map(\.page.title), ["Day", "Outline", "Links"])
        XCTAssertEqual(store.sections(for: .file("Plan.md"), viewType: nil, in: .tab(links)).map(\.id), ["backlinks", "mentions"])
    }

    func testRegisteringAnIdAgainReplacesItAndTheRemoverOnlyRemovesItsOwn() {
        let store = InspectorStore()
        let removeFirst = store.register(section("s", order: 1))
        let removeSecond = store.register(section("s", order: 5))
        XCTAssertEqual(store.all.map(\.order), [5])
        removeFirst()
        XCTAssertEqual(store.all.map(\.id), ["s"])
        removeSecond()
        XCTAssertTrue(store.all.isEmpty)
    }

    func testOnlyAPageGivesTheSidebarItsTabs() {
        let tab = InspectorTab(id: "t", title: "Style") { AnyView(EmptyView()) }
        let page = ViewContext(resource: .file("Map.md"))
        page.setInspector(viewType: "mindmap.file", tabs: [tab])
        XCTAssertEqual(page.inspector?.viewType, "mindmap.file")
        XCTAssertEqual(page.inspector?.tabs.map(\.title), ["Style"])

        let embedded = ViewContext(resource: .file("Map.md"), presentation: .embedded)
        embedded.setInspector(viewType: "mindmap.file", tabs: [tab])
        XCTAssertNil(embedded.inspector, "a card on a board has no sidebar of its own")
    }
}
