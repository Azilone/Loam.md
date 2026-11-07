import BuiltinPlugins
import BuiltinUIPlugins
import PluginKitUI
import XCTest
@testable import NotebookApp

/// Settings > Sidebars: simple by default (no panel in the left column, whose sections are the sidebar), choices in `.loam/config.json`.
@MainActor
final class PanelVisibilityTests: ShellTestCase {
    private func config() throws -> [String: Any] {
        let data = try Data(contentsOf: root.appendingPathComponent(".loam/config.json"))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testByDefaultTheLeftColumnShowsNoPanel() throws {
        let session = try openSession(logic: builtinPlugins, ui: builtinUIPlugins)
        let visibility = session.panelVisibility
        let leading = session.panels.panels(in: .leading)
        XCTAssertGreaterThan(leading.count, 0)
        XCTAssertEqual(visibility.shown(leading).map(\.id), [], "the sections are the left sidebar")
        XCTAssertEqual(session.panels.panels(in: .trailing).map(\.id), [], "the right column is the inspector")
        XCTAssertFalse(session.inspector.all.isEmpty)
    }

    func testAChoiceIsSavedAndOnlyDifferencesAreKept() throws {
        let session = try openSession(logic: builtinPlugins, ui: builtinUIPlugins)
        let visibility = session.panelVisibility
        let leading = session.panels.panels(in: .leading)
        let search = try XCTUnwrap(leading.first { $0.id == "search.panel" })

        try visibility.set(search, shown: true, among: leading)
        XCTAssertEqual(try config()["panels"] as? [String: Bool], ["search.panel": true])
        XCTAssertEqual(visibility.shown(leading).map(\.id), ["search.panel"])

        try visibility.set(search, shown: false, among: leading)
        XCTAssertNil(try config()["panels"], "back to the default")
        try visibility.set(search, shown: true, among: leading)

        try visibility.reset()
        XCTAssertNil(try config()["panels"])
        XCTAssertEqual(visibility.shown(leading).map(\.id), [], "the sections are the left sidebar")
    }

    func testAConfigEditedOnDiskAppliesOnTheNextVaultChange() throws {
        let session = try openSession(logic: builtinPlugins, ui: builtinUIPlugins)
        try write(".loam/config.json", ##"{ "panels": { "search.panel": true } }"##)
        session.vaultDidChange()
        let leading = session.panels.panels(in: .leading)
        XCTAssertEqual(session.panelVisibility.shown(leading).map(\.id), ["search.panel"])
    }
}
