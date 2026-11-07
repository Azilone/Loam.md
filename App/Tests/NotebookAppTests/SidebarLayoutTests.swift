import BuiltinPlugins
import BuiltinUIPlugins
import AppKit
import PluginKitUI
import SwiftUI
import XCTest
@testable import NotebookApp

/// The left sidebar's Customize mode: order, visibility, folds and added sections, in `.loam/config.json`.
@MainActor
final class SidebarLayoutTests: ShellTestCase {
    private func sidebar() throws -> [String: Any] {
        let data = try Data(contentsOf: root.appendingPathComponent(".loam/config.json"))
        let config = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        return config["sidebar"] as? [String: Any] ?? [:]
    }

    func testDefaultsComeFromThePlugins() throws {
        let session = try openSession(logic: builtinPlugins, ui: builtinUIPlugins)
        let layout = session.sidebarLayout
        let shown = layout.arranged(session.panels.sections).map(\.id)
        XCTAssertEqual(shown, ["explorer.favorites", "explorer.folders", "tags.section"], "Recent starts hidden")
        let tags = try XCTUnwrap(session.panels.sections.first { $0.id == "tags.section" })
        XCTAssertTrue(layout.isCollapsed(tags))
        XCTAssertFalse(session.panels.links.contains { $0.id == "trash.link" })
    }

    func testOrderVisibilityAndFoldsAreSavedAsDifferences() throws {
        let session = try openSession(logic: builtinPlugins, ui: builtinUIPlugins)
        let layout = session.sidebarLayout
        let sections = session.panels.sections
        let recent = try XCTUnwrap(sections.first { $0.id == "explorer.recent" })
        let folders = try XCTUnwrap(sections.first { $0.id == "explorer.folders" })
        try layout.set(recent, shown: true)
        try layout.set(folders, shown: false)
        try layout.reorderSections(["tags.section", "explorer.recent"])
        try layout.setCollapsed(folders, true)
        XCTAssertEqual(layout.arranged(sections).map(\.id), ["tags.section", "explorer.recent", "explorer.favorites"])
        let saved = try sidebar()["sections"] as? [String: Any]
        XCTAssertEqual(saved?["shown"] as? [String], ["explorer.recent"])
        XCTAssertEqual(saved?["hidden"] as? [String], ["explorer.folders"])
        XCTAssertEqual(try sidebar()["collapsed"] as? [String], ["explorer.folders"])
        try layout.set(recent, shown: false)
        XCTAssertNil((try sidebar()["sections"] as? [String: Any])?["shown"], "back to the default")
    }

    func testASectionFromAFolderOrATagIsAddedAndRemoved() throws {
        let session = try openSession(logic: builtinPlugins, ui: builtinUIPlugins)
        let layout = session.sidebarLayout
        let folder = SidebarLayout.Pin(kind: .folder, value: "Projects/Loam")
        let tag = SidebarLayout.Pin(kind: .tag, value: "decision")
        try layout.add(folder)
        try layout.add(tag)
        try layout.add(tag)
        XCTAssertEqual(try sidebar()["pinned"] as? [String], ["folder:Projects/Loam", "tag:decision"])
        let sections = session.sidebarSections(workspace: session.workspace)
        XCTAssertEqual(layout.arranged(sections).suffix(2).map(\.title), ["Loam", "#decision"])
        try layout.remove(folder)
        XCTAssertEqual(layout.pinned, [tag])
    }
}

/// Draws the sidebar in both modes, on a vault with folders, tags and tasks. Set `LOAM_SIDEBAR_SNAPSHOTS` to a
/// folder to get the pictures, to compare with Craft and the mockup.
@MainActor
final class LeftSidebarRenderTests: ShellTestCase {
    func testTheSidebarDrawsInBothModes() throws {
        for folder in ["Areas", "Daily", "Inbox", "Reading", "Projects", "Boards", "Notes", "Archive"] {
            try write("\(folder)/Note.md", "# Note\n\n- [ ] a task #decision\n")
        }
        try write("Status quo bias.md", "# Status quo bias\n")
        let session = try openSession(logic: builtinPlugins, ui: builtinUIPlugins)
        session.workspace.open(.virtual("notes:"), placement: .replace)
        let directory = ProcessInfo.processInfo.environment["LOAM_SIDEBAR_SNAPSHOTS"].map { URL(fileURLWithPath: $0) }
        for customizing in [false, true] {
            let view = LeftSidebar(
                session: session, workspace: session.workspace, panels: [], openSettings: {}, isCustomizing: customizing
            )
            .frame(width: 280, height: 760)
            .background(Color(white: 0.949))
            .environment(\.colorScheme, .light)
            let host = NSHostingView(rootView: view)
            host.frame = NSRect(x: 0, y: 0, width: 280, height: 760)
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.3))
            let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: rep)
            XCTAssertEqual(rep.pixelsWide > 0, true)
            if let directory, let png = rep.representation(using: .png, properties: [:]) {
                try png.write(to: directory.appendingPathComponent(customizing ? "sidebar-customize.png" : "sidebar-default.png"))
            }
        }
    }
}

