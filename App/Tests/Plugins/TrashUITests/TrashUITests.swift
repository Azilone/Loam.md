import BuiltinPlugins
import PluginKit
import PluginKitUI
import PluginKitUITesting
import SwiftUI
import XCTest
@testable import TrashUI

@MainActor
final class TrashUITests: XCTestCase {
    private let logic = builtinPlugins.filter { ["trash", "files"].contains($0.manifest.id) }

    private func harness(files: [String: String] = [:]) throws -> UIPluginHarness {
        try UIPluginHarness(logicPlugins: logic, uiPlugins: [TrashUIPlugin.self], files: files)
    }

    private func model(_ harness: UIPluginHarness) throws -> TrashModel {
        try XCTUnwrap(harness.kernel.services.service(TrashUIPlugin.modelKey))
    }

    func testRegistersViewLinkAndCommandAndUnloadsCleanly() throws {
        let harness = try harness()
        defer { harness.close() }
        XCTAssertTrue(harness.host.isActive("trash-ui"), "\(harness.report)")
        XCTAssertEqual(harness.views.viewTypes(for: .virtual("trash:Recently Deleted")).map(\.id), ["trash.list"])
        XCTAssertEqual(harness.views.viewTypes(for: .virtual("tasks:")).map(\.id), [])
        XCTAssertTrue(harness.panels.links.isEmpty, "the trash is in the sidebar's bottom bar, not a link")
        XCTAssertTrue(harness.kernel.commands.all.map(\.id).contains("trash.open"))
        harness.host.deactivateAll()
        XCTAssertEqual(harness.views.all.map(\.id), [])
        XCTAssertEqual(harness.panels.links.map(\.id), [])
    }

    func testListRestoreDeleteAndEmptyThroughTheModel() async throws {
        let harness = try harness(files: ["Notes/a.md": "A", "b.md": "B", "c.md": "C"])
        defer { harness.close() }
        let model = try model(harness)
        for path in ["Notes/a.md", "b.md", "c.md"] { _ = try await harness.run("files.trash", ["path": path]) }
        model.refresh()
        XCTAssertEqual(Set(model.items.map(\.originalPath)), ["Notes/a.md", "b.md", "c.md"])
        XCTAssertEqual(model.daysLeftText(model.items[0]), "30 days left")

        let a = try XCTUnwrap(model.items.first { $0.originalPath == "Notes/a.md" })
        model.restore(a)
        XCTAssertEqual(try harness.vault.read("Notes/a.md"), "A")
        XCTAssertEqual(model.items.count, 2)

        let b = try XCTUnwrap(model.items.first { $0.originalPath == "b.md" })
        model.pending = .delete(b)
        model.confirm()
        XCTAssertFalse(harness.vault.exists(".trash/b.md"))
        XCTAssertNil(model.pending)

        model.pending = .empty
        model.confirm()
        XCTAssertTrue(model.items.isEmpty)
        XCTAssertFalse(harness.vault.exists(".trash/c.md"))
        _ = harness.render(AnyView(TrashView(model: model)), size: CGSize(width: 600, height: 400))
    }

    func testTexts() {
        XCTAssertEqual(TrashModel.retentionLabel(0), "Never")
        XCTAssertEqual(TrashModel.retentionLabel(30), "30 days")
    }
}
