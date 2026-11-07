import XCTest
import PluginKit
@testable import CollectionsPlugin

/// Reading `.base` YAML as Obsidian writes it, and editing it without losing what Loam does not know.
final class BaseFileTests: XCTestCase {
    private let obsidian = """
    filters:
      and:
        - file.inFolder("Projects")
        - not:
            - file.hasTag("archived")
    formulas:
      cost: "(budget / hours).toFixed(2)"
    properties:
      status:
        displayName: Status
        type: select
        options:
          - To do
          - In progress
          - Done
      formula.cost:
        displayName: Cost/hr
    summaries:
      total: values.sum()
    views:
      - type: table
        name: Active projects
        limit: 10
        groupBy:
          property: note.status
          direction: DESC
        order:
          - file.name
          - status
          - formula.cost
        sort:
          - property: due
            direction: ASC
        columnSize:
          file.name: 240
        summaries:
          formula.cost: Average
      - type: cards
        name: Gallery
        image: cover

    """

    func testReadsObsidianSyntax() throws {
        let base = try BaseFile(yaml: obsidian)
        XCTAssertEqual(base.filters, .and([.expression(#"file.inFolder("Projects")"#), .not([.expression(#"file.hasTag("archived")"#)])]))
        XCTAssertEqual(base.properties.map(\.ref.description), ["status", "formula.cost"])
        XCTAssertEqual(base.properties[0], CollectionProperty(ref: PropertyRef("status"), displayName: "Status",
                                                             kind: .select, options: ["To do", "In progress", "Done"]))
        let views = base.views
        XCTAssertEqual(views.map(\.name), ["Active projects", "Gallery"])
        XCTAssertEqual(views[0].order, [.title, PropertyRef("status"), PropertyRef(.formula, "cost")])
        XCTAssertEqual(views[0].groupBy, CollectionSort(property: PropertyRef("status"), descending: true))
        XCTAssertEqual(views[0].sort, [CollectionSort(property: PropertyRef("due"))])
        XCTAssertEqual(views[0].limit, 10)
        XCTAssertEqual(views[0].options["columnSize"], .map(["file.name": .number(240)]))
        XCTAssertEqual(views[1].type, "cards")
        XCTAssertEqual(views[1].options["image"], .string("cover"))
    }

    func testAnEditKeepsEverythingElse() throws {
        var base = try BaseFile(yaml: obsidian)
        try base.apply(.addView(type: "kanban", name: "Gallery"))
        let edited = try BaseFile(yaml: try base.yaml())
        XCTAssertEqual(edited.views.map(\.name), ["Active projects", "Gallery", "Gallery 2"])
        XCTAssertEqual(edited.views[0], try BaseFile(yaml: obsidian).views[0])
        let yaml = try base.yaml()
        for kept in ["formulas:", #"cost: "(budget / hours).toFixed(2)""#, "summaries:", "total: values.sum()",
                     "formula.cost: Average", "columnSize:"] {
            XCTAssertTrue(yaml.contains(kept), "keeps \(kept)\n\(yaml)")
        }
        XCTAssertLessThan(yaml.range(of: "filters:")!.lowerBound, yaml.range(of: "formulas:")!.lowerBound, "key order")
    }

    func testEditsViewsAndFields() throws {
        var base = try BaseFile(yaml: "views:\n  - type: table\n    name: Table\n")
        try base.apply(.setOrder(view: "Table", order: [.title, PropertyRef("status")]))
        try base.apply(.setSort(view: "Table", sort: [CollectionSort(property: PropertyRef("due"), descending: true)]))
        try base.apply(.setGroupBy(view: "Table", groupBy: CollectionSort(property: PropertyRef("status"))))
        try base.apply(.setLimit(view: "Table", limit: 5))
        try base.apply(.setViewOption(view: "Table", key: "columnSize", value: .map(["status": .number(120)])))
        try base.apply(.setProperty(property: CollectionProperty(ref: PropertyRef("status"), kind: .select, options: ["Yes", "42"])))
        try base.apply(.renameView(name: "Table", to: "All"))
        let read = try BaseFile(yaml: try base.yaml())
        XCTAssertEqual(read.views, [CollectionViewConfig(
            type: "table", name: "All", order: [.title, PropertyRef("status")],
            sort: [CollectionSort(property: PropertyRef("due"), descending: true)],
            groupBy: CollectionSort(property: PropertyRef("status")), limit: 5,
            options: ["columnSize": .map(["status": .number(120)])]
        )])
        XCTAssertEqual(read.properties, [CollectionProperty(ref: PropertyRef("status"), kind: .select, options: ["Yes", "42"])],
                       "strings that look like other types stay strings")
        XCTAssertThrowsError(try base.apply(.renameView(name: "Nope", to: "x"))) {
            XCTAssertEqual($0 as? CollectionError, .unknownView("Nope"))
        }

        try base.apply(.addView(type: "kanban", name: "Board"))
        try base.apply(.moveView(name: "Board", to: 0))
        XCTAssertEqual(try BaseFile(yaml: try base.yaml()).views.map(\.name), ["Board", "All"])
        try base.apply(.removeView(name: "All"))
        try base.apply(.removeProperty(ref: PropertyRef("status")))
        let left = try BaseFile(yaml: try base.yaml())
        XCTAssertEqual(left.views.map(\.name), ["Board"])
        XCTAssertEqual(left.properties, [])
        XCTAssertFalse(try base.yaml().contains("properties"))
    }

    func testRemovingAFieldTakesItOutOfEveryView() throws {
        var base = try BaseFile(yaml: """
        properties:
          status:
            type: select
          note:
            type: text
        views:
          - type: kanban
            name: Board
            groupBy: {property: status, direction: ASC}
            order: [file.name, status, note]
            sort:
              - {property: status, direction: ASC}
          - type: table
            name: Table
            order: [file.name, status]
        """)
        try base.apply(.removeProperty(ref: PropertyRef("status")))
        let read = try BaseFile(yaml: try base.yaml())
        XCTAssertEqual(read.properties.map(\.ref), [PropertyRef("note")])
        XCTAssertEqual(read.views[0].order, [.title, PropertyRef("note")])
        XCTAssertEqual(read.views[0].sort, [])
        XCTAssertNil(read.views[0].groupBy)
        XCTAssertEqual(read.views[1].order, [.title])
    }

    func testFilters() throws {
        var base = try BaseFile(yaml: "")
        try base.apply(.addFilter(view: nil, expression: #"file.inFolder("A")"#))
        XCTAssertEqual(base.filters, .and([.expression(#"file.inFolder("A")"#)]))
        try base.apply(.addFilter(view: nil, expression: #"status != "done""#))
        XCTAssertEqual(try BaseFile(yaml: try base.yaml()).filters,
                       .and([.expression(#"file.inFolder("A")"#), .expression(#"status != "done""#)]))
        try base.apply(.removeFilter(view: nil, expression: #"file.inFolder("A")"#))
        try base.apply(.removeFilter(view: nil, expression: #"status != "done""#))
        XCTAssertNil(base.filters)

        var single = try BaseFile(yaml: "filters: file.hasTag(\"x\")\n")
        try single.apply(.addFilter(view: nil, expression: "a > 1"))
        XCTAssertEqual(single.filters, .and([.expression(#"file.hasTag("x")"#), .expression("a > 1")]))
    }

    func testInvalidYAMLIsReported() {
        XCTAssertThrowsError(try BaseFile(yaml: "views: [")) {
            guard case .invalidYAML? = $0 as? CollectionError else { return XCTFail("\($0)") }
        }
        XCTAssertThrowsError(try BaseFile(yaml: "- a\n- b\n"))
        XCTAssertEqual(try BaseFile(yaml: "\n").views, [])
    }

    func testPropertyRefs() {
        XCTAssertEqual(PropertyRef("note.status"), PropertyRef("status"))
        XCTAssertEqual(PropertyRef("status").description, "status")
        XCTAssertEqual(PropertyRef("file.mtime"), PropertyRef(.file, "mtime"))
        XCTAssertEqual(PropertyRef("formula.cost").description, "formula.cost")
        XCTAssertEqual(PropertyRef("due date").name, "due date")
    }
}
