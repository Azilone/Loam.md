import BuiltinPlugins
import BuiltinUIPlugins
import Foundation
import MarkdownEditorUI
import XCTest
@testable import NotebookApp

/// The shell with the real first-party plugins: each essential plugin can be turned off and the shell keeps
/// working without it, and safe mode keeps the editor and the file explorer.
@MainActor
final class EssentialPluginsTests: ShellTestCase {
    /// The allowlist `Loam/main.swift` passes.
    private let safeModePlugins: Set<String> = ["markdown-editor", "file-explorer", "files"]
    private let filesPanel = "explorer.folders"
    private let searchPanel = "search.panel"

    override func setUp() async throws {
        try await super.setUp()
        try write("Note.md", "# Note\n\nText.")
    }

    private func openBuiltin() throws -> ShellSession {
        try openSession(logic: builtinPlugins, ui: builtinUIPlugins)
    }

    private func hasCommand(_ session: ShellSession, _ id: String) -> Bool {
        session.runtime.kernel.commands.command(id: id) != nil
    }

    func testEveryEssentialPluginStartsByDefault() throws {
        let session = try openBuiltin()
        for id in ["markdown-editor", "file-explorer", "quick-switcher", "files", "search-ui", "truffle-search"] {
            XCTAssertTrue(session.runtime.host.isActive(id), id)
        }
        XCTAssertTrue(session.panels.sections.map(\.id).contains(filesPanel))
        XCTAssertEqual(session.panels.panels(in: .leading).map(\.id).first, searchPanel)
        XCTAssertTrue(hasCommand(session, "explorer.new-note"))
        XCTAssertTrue(hasCommand(session, "switcher.open"))
    }

    func testWithoutTheEditorAMarkdownTabShowsThePlaceholder() async throws {
        let session = try openBuiltin()
        session.workspace.open(.file("Note.md"), placement: .replace)
        let tab = try XCTUnwrap(session.workspace.layout.activeTab)
        XCTAssertEqual(WorkspaceController.viewType(for: tab, in: session.views)?.id, MarkdownEditorPlugin.viewTypeID)

        _ = try await session.run("plugins.disable", ["id": "markdown-editor"])
        XCTAssertEqual(session.workspace.layout.activeTab, tab, "the tab stays")
        XCTAssertNil(WorkspaceController.viewType(for: tab, in: session.views), "and shows the placeholder")
        XCTAssertEqual(session.panels.sections.first { $0.id == filesPanel }?.id, filesPanel, "the explorer still works")
        let path = try await session.run("explorer.new-note")
        XCTAssertEqual(session.workspace.activeResource, .file(path))

        _ = try await session.run("plugins.enable", ["id": "markdown-editor"])
        XCTAssertEqual(WorkspaceController.viewType(for: tab, in: session.views)?.id, MarkdownEditorPlugin.viewTypeID)
    }

    func testWithoutTheFileExplorerThereIsNoFilesPanelNorNewNote() async throws {
        let session = try openBuiltin()
        _ = try await session.run("plugins.disable", ["id": "file-explorer"])
        XCTAssertFalse(session.panels.sections.map(\.id).contains(filesPanel))
        XCTAssertFalse(hasCommand(session, "explorer.new-note"))
        XCTAssertTrue(hasCommand(session, "switcher.open"))
        session.workspace.open(.file("Note.md"), placement: .replace)
        let tab = try XCTUnwrap(session.workspace.layout.activeTab)
        XCTAssertEqual(WorkspaceController.viewType(for: tab, in: session.views)?.id, MarkdownEditorPlugin.viewTypeID)
    }

    func testWithoutTheQuickSwitcherThereIsNoSwitcher() async throws {
        let session = try openBuiltin()
        _ = try await session.run("plugins.disable", ["id": "quick-switcher"])
        XCTAssertFalse(hasCommand(session, "switcher.open"))
        XCTAssertTrue(hasCommand(session, "palette.open"), "the command palette is the shell's")
        XCTAssertEqual(session.panels.sections.first { $0.id == filesPanel }?.id, filesPanel)
    }

    func testWithoutTheSearchPanelTheSearchCommandsStay() async throws {
        let session = try openBuiltin()
        _ = try await session.run("plugins.disable", ["id": "search-ui"])
        XCTAssertFalse(session.panels.panels(in: .leading).map(\.id).contains(searchPanel))
        XCTAssertFalse(hasCommand(session, "search.focus"))
        XCTAssertTrue(hasCommand(session, "search.content"), "the logic plugin's commands stay")
        XCTAssertEqual(session.panels.sections.first { $0.id == filesPanel }?.id, filesPanel)
    }

    func testSafeModeKeepsTheEditorAndTheExplorer() throws {
        let session = try ShellSession(
            rootURL: root,
            configuration: ShellConfiguration(
                logicPlugins: builtinPlugins,
                uiPlugins: builtinUIPlugins,
                safeModePlugins: safeModePlugins
            ),
            machineID: machineID,
            layoutSaveDelay: .seconds(60),
            safeMode: true
        )
        defer { session.close() }
        XCTAssertTrue(session.isSafeMode)
        for id in ["markdown-editor", "file-explorer", "files"] {
            XCTAssertTrue(session.runtime.host.isActive(id), id)
        }
        for id in ["quick-switcher", "habit-tracker", "daily-notes"] {
            XCTAssertFalse(session.runtime.host.isActive(id), id)
        }
        XCTAssertEqual(session.panels.sections.map(\.id), ["explorer.favorites", filesPanel, "explorer.recent"])
        session.workspace.open(.file("Note.md"), placement: .replace)
        let tab = try XCTUnwrap(session.workspace.layout.activeTab)
        XCTAssertEqual(WorkspaceController.viewType(for: tab, in: session.views)?.id, MarkdownEditorPlugin.viewTypeID)
    }

    func testNewNoteInTheMenuFollowsTheExplorerCommand() async throws {
        let model = AppModel(configuration: ShellConfiguration(logicPlugins: builtinPlugins, uiPlugins: builtinUIPlugins))
        XCTAssertFalse(model.canRun("explorer.new-note"), "no vault open")
        model.openVault(root)
        defer { model.closeVault() }
        let session = try XCTUnwrap(model.session)
        XCTAssertTrue(model.canRun("explorer.new-note"))
        _ = try await session.run("plugins.disable", ["id": "file-explorer"])
        XCTAssertFalse(model.canRun("explorer.new-note"))
    }
}
