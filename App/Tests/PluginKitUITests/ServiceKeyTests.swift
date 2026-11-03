import PluginKitUI
import PluginKitUITesting
import LoamCore
import XCTest

/// The service registry stores `Any` and casts back with `as? S`; these check the cast works when `S` is an
/// existential such as `any ViewRegistry`, which is how every UI service key is declared.
@MainActor
final class ServiceKeyTests: XCTestCase {
    func testExistentialServicesComeBackAsTheSameObject() throws {
        let registry = ServiceRegistry()
        let views = ViewRegistryStore()
        let panels = PanelRegistryStore()
        let workspace = RecordingWorkspace()
        let quickPick = RecordingQuickPick()
        let editor = RecordingEditor()
        _ = try registry.provide(.views, views)
        _ = try registry.provide(.panels, panels)
        _ = try registry.provide(.workspace, workspace)
        _ = try registry.provide(.quickPick, quickPick)
        _ = try registry.provide(.editor, editor)

        XCTAssertTrue(registry.service(.views) === views)
        XCTAssertTrue(registry.service(.panels) === panels)
        XCTAssertTrue(registry.service(.workspace) === workspace)
        XCTAssertTrue(registry.service(.quickPick) === quickPick)
        XCTAssertTrue(registry.service(.editor) === editor)
    }

    func testTheIDsAreTheOnesManifestsUse() {
        XCTAssertEqual(ServiceKey<any ViewRegistry>.views.id, "ui.views")
        XCTAssertEqual(ServiceKey<any PanelRegistry>.panels.id, "ui.panels")
        XCTAssertEqual(ServiceKey<any Workspace>.workspace.id, "ui.workspace")
        XCTAssertEqual(ServiceKey<any QuickPick>.quickPick.id, "ui.quick-pick")
        XCTAssertEqual(ServiceKey<any EditorService>.editor.id, "editor")
    }

    func testAnotherTypeUnderTheSameIDIsNotReturned() throws {
        let registry = ServiceRegistry()
        _ = try registry.provide(ServiceKey<String>("ui.views"), "not a registry")
        XCTAssertNil(registry.service(.views))
    }
}
