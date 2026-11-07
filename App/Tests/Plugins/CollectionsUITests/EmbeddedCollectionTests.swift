import AppKit
import BuiltinPlugins
@testable import CollectionCardsUI
@testable import CollectionTableUI
import PluginKitUI
import PluginKitUITesting
import SwiftUI
import XCTest
@testable import CollectionsUI

/// A gallery and a table are the same AppKit views in a page and in a note (a `base` block): no SwiftUI twin. In a
/// note they are as tall as their content, up to the block's limit.
@MainActor
final class EmbeddedCollectionTests: XCTestCase {
    private var harness: UIPluginHarness?

    override func tearDown() async throws {
        harness?.close()
        harness = nil
        try await super.tearDown()
    }

    private func block(_ type: String, entries: Int) throws -> (CollectionViewModel, NSView) {
        var files = ["Inbox/Trip.md": "# Trip\n"]
        for index in 0..<entries {
            files["Inbox/Stop \(index).md"] = "---\ncollection: Trip\n---\nA stop on the way.\n"
        }
        let logic = builtinPlugins.filter { ["note-graph", "note-query", "collections"].contains($0.manifest.id) }
        let editor = RecordingEditor()
        let harness = try UIPluginHarness(
            logicPlugins: logic, uiPlugins: [CollectionsUIPlugin.self, CollectionTableUIPlugin.self, CollectionCardsUIPlugin.self],
            files: files, editor: editor
        )
        self.harness = harness
        let view = try XCTUnwrap(editor.codeBlockViews.first)
        let block = CodeBlockContext(notePath: "Inbox/Trip.md", language: "base", code: CollectionBlocks.yaml(type),
                                     replaceCode: { _ in }, editCode: {})
        let model = try XCTUnwrap(harness.kernel.services.service(CollectionsUIPlugin.storeKey)).model(for: block)
        let rendered = harness.render(AnyView(view.makeView(block).environment(\.themeTokens, .standard)), size: CGSize(width: 700, height: 600))
        rendered.layoutSubtreeIfNeeded()
        return (model, rendered)
    }

    func testTheBuiltInGalleryGivesItsAppKitView() throws {
        let harness = try UIPluginHarness(
            logicPlugins: builtinPlugins.filter { ["note-graph", "note-query", "collections"].contains($0.manifest.id) },
            uiPlugins: [CollectionsUIPlugin.self, CollectionCardsUIPlugin.self], files: [:]
        )
        self.harness = harness
        let views = try XCTUnwrap(harness.kernel.services.service(.collectionViews))
        XCTAssertNotNil(views.type("cards")?.makeNSView)
    }

    func testAGalleryInANoteIsTheAppKitGridAsTallAsItsCards() throws {
        let (model, view) = try block("cards", entries: 3)
        XCTAssertEqual(model.entries.count, 3)
        let gallery = try XCTUnwrap(view.firstSubview(of: GalleryScrollView.self))
        XCTAssertTrue(gallery.document.live.values.allSatisfy { $0.superview === gallery.document }, "AppKit cards")
        let one = try XCTUnwrap(gallery.fittingSize(width: 900, maxHeight: nil)).height
        XCTAssertEqual(one, gallery.document.contentHeight(width: 900))
        XCTAssertLessThan(one, 400, "one row of cards, not the block's whole height")
        XCTAssertGreaterThan(one, GalleryCardCell.coverHeight)
        // Narrower: one card a row, three rows; the block's limit then caps it, and it scrolls.
        let narrow = try XCTUnwrap(gallery.fittingSize(width: 240, maxHeight: nil)).height
        XCTAssertGreaterThan(narrow, 2.5 * one - 40)
        XCTAssertEqual(gallery.fittingSize(width: 240, maxHeight: 300)?.height, 300)
    }

    func testAnEmptyGalleryInANoteShowsTheEmptyState() throws {
        let (_, view) = try block("cards", entries: 0)
        let gallery = try XCTUnwrap(view.firstSubview(of: GalleryScrollView.self))
        XCTAssertTrue(gallery.document.isHidden)
        XCTAssertGreaterThan(try XCTUnwrap(gallery.fittingSize(width: 640, maxHeight: nil)).height, 40)
    }

    func testATableInANoteHasTheAppKitRows() throws {
        let (_, view) = try block("table", entries: 4)
        let rows = try XCTUnwrap(view.firstSubview(of: TableScrollView.self))
        XCTAssertEqual(rows.document.frame.height, 4 * TableRowView.height, accuracy: 0.5, "as tall as its rows")
    }
}

extension NSView {
    /// The first view of `type` under this one, depth first.
    func firstSubview<T: NSView>(of type: T.Type) -> T? {
        for subview in subviews {
            if let match = subview as? T ?? subview.firstSubview(of: type) { return match }
        }
        return nil
    }
}
