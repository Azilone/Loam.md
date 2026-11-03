import Foundation
import PluginKitUI
import WorkspaceModel
import XCTest
@testable import NotebookApp

@MainActor
final class ShellSessionTests: ShellTestCase {
    func testHostServicesAreInPlaceForPlugins() throws {
        let session = try openSession()
        XCTAssertEqual(session.panels.panels(in: .leading).map(\.id), ["test.panel"])
        XCTAssertEqual(session.views.viewTypes(for: .virtual("test:a")).map(\.id), ["test.page"])
        XCTAssertNotNil(session.runtime.kernel.commands.command(id: "test.hello"))
        XCTAssertTrue(session.runtime.kernel.services.service(.workspace) === session.workspace)
        XCTAssertNotNil(session.runtime.kernel.services.service(.quickPick))
    }

    func testShellCommandsHaveSummariesAndDefaultShortcuts() throws {
        let session = try openSession()
        let commands = session.runtime.kernel.commands
        for id in ShellSession.commandIDs {
            let command = try XCTUnwrap(commands.command(id: id), id)
            XCTAssertGreaterThan(command.summary.count, 20, id)
        }
        XCTAssertEqual(commands.command(id: "workspace.close-tab")?.shortcut?.description, "cmd+w")
        XCTAssertEqual(commands.command(id: "workspace.next-tab")?.shortcut?.description, "ctrl+tab")
        XCTAssertEqual(commands.command(id: "workspace.previous-tab")?.shortcut?.description, "ctrl+shift+tab")
    }

    func testOpeningBesideCreatesASecondPane() throws {
        let session = try openSession()
        session.workspace.open(.virtual("test:a"), placement: .replace)
        session.workspace.open(.virtual("test:b"), placement: .beside)
        let panes = session.workspace.layout.panes
        XCTAssertEqual(panes.count, 2)
        XCTAssertEqual(panes.map { $0.tabs.map(\.resource) }, [[.virtual("test:a")], [.virtual("test:b")]])
        XCTAssertEqual(session.workspace.activeResource, .virtual("test:b"))
    }

    func testTheActiveResourceIsSentOnTheEventBus() throws {
        let session = try openSession()
        var received: [Resource?] = []
        let remove = session.runtime.kernel.events.on(ActiveResourceChanged.self) { received.append($0.resource) }
        defer { remove() }
        session.workspace.open(.virtual("test:a"), placement: .newTab)
        session.workspace.open(.virtual("test:a"), placement: .newTab)
        session.workspace.open(.virtual("test:b"), placement: .beside)
        _ = session.workspace.closeActiveTab()
        XCTAssertEqual(received, [.virtual("test:a"), .virtual("test:b"), .virtual("test:a")])
    }

    func testTheLayoutComesBackAfterReopening() throws {
        try write("Note.md", "# Note")
        try write("Gone.md", "# Gone")
        var session = try openSession()
        session.workspace.open(.file("Note.md"), placement: .replace)
        session.workspace.open(.file("Gone.md"), placement: .newTab)
        session.workspace.open(.virtual("test:b"), placement: .beside)
        guard case .split(let split, _, _, _) = session.workspace.layout.root else { return XCTFail("no split") }
        session.workspace.setFractions(split: split, [0.3, 0.7])
        session.workspace.toggleSidebar(.leading)
        session.workspace.selectPanel("test.panel", in: .trailing)
        let saved = session.workspace.snapshot
        session.close()
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: root.appendingPathComponent(".loam/cache/workspace/\(machineID).json").path
        ))

        try FileManager.default.removeItem(at: root.appendingPathComponent("Gone.md"))
        session = try openSession()
        var expected = saved.layout
        expected.closeAll { $0 == .file("Gone.md") }
        XCTAssertEqual(session.workspace.layout, expected)
        XCTAssertEqual(session.workspace.chrome, saved.chrome)
        XCTAssertFalse(session.workspace.chrome.showsLeading)
    }

    func testAnotherMachineStartsWithItsOwnLayout() throws {
        let session = try openSession()
        session.workspace.open(.virtual("test:a"), placement: .replace)
        session.close()
        let other = try ShellSession(
            rootURL: root,
            configuration: ShellConfiguration(logicPlugins: [], uiPlugins: [ShellTestPlugin.self]),
            machineID: "other-machine"
        )
        defer { other.close() }
        XCTAssertNil(other.workspace.activeResource)
    }

    func testTheLayoutIsSavedShortlyAfterAChange() async throws {
        let session = try openSession(saveDelay: .milliseconds(20))
        let file = root.appendingPathComponent(".loam/cache/workspace/\(machineID).json")
        session.workspace.open(.virtual("test:a"), placement: .replace)
        try await waitUntil { FileManager.default.fileExists(atPath: file.path) }
        let saved = try JSONDecoder().decode(WorkspaceSnapshot.self, from: Data(contentsOf: file))
        XCTAssertEqual(saved.layout.activeTab?.resource, .virtual("test:a"))
    }

    func testAnUnreadableLayoutStartsEmpty() throws {
        try write(".loam/cache/workspace/\(machineID).json", "{ not json")
        let session = try openSession()
        XCTAssertEqual(session.workspace.layout.panes.count, 1)
        XCTAssertNil(session.workspace.activeResource)
    }

    func testDisablingAPluginRemovesItsPanelAndKeepsItsTabs() async throws {
        let session = try openSession()
        session.workspace.open(.virtual("test:a"), placement: .replace)
        let tab = try XCTUnwrap(session.workspace.layout.activeTab)
        XCTAssertNotNil(WorkspaceController.viewType(for: tab, in: session.views))

        _ = try await session.run("plugins.disable", ["id": "test.shell"])
        XCTAssertTrue(session.panels.panels(in: .leading).isEmpty)
        XCTAssertNil(session.runtime.kernel.commands.command(id: "test.hello"))
        XCTAssertEqual(session.workspace.layout.activeTab, tab, "the tab stays")
        XCTAssertNil(WorkspaceController.viewType(for: tab, in: session.views), "and shows the placeholder")

        _ = try await session.run("plugins.enable", ["id": "test.shell"])
        XCTAssertEqual(session.panels.panels(in: .leading).map(\.id), ["test.panel"])
        XCTAssertEqual(WorkspaceController.viewType(for: tab, in: session.views)?.id, "test.page")
    }

    func testAConfigChangedOutsideTheAppIsApplied() throws {
        let session = try openSession()
        try write(".loam/config.json", #"{ "plugins": { "test.shell": { "enabled": false } } }"#)
        session.vaultDidChange()
        XCTAssertTrue(session.panels.panels(in: .leading).isEmpty)
    }

    func testMovedNotesAreFollowed() throws {
        try write("Old.md", "# Old")
        let session = try openSession()
        session.workspace.open(.file("Old.md"), placement: .replace)
        session.runtime.kernel.events.emit(NotesMoved(moves: ["Old.md": "Archive/New.md"]))
        XCTAssertEqual(session.workspace.activeResource, .file("Archive/New.md"))
    }

    func testMovedNotesAreFollowedWhenAnotherExecutorEmits() async throws {
        try write("Old.md", "# Old")
        let session = try openSession()
        session.workspace.open(.file("Old.md"), placement: .replace)
        nonisolated(unsafe) let events = session.runtime.kernel.events
        // A command run off the main actor (the shell, an agent) emits from there: it must not trap.
        await Task.detached { events.emit(NotesMoved(moves: ["Old.md": "Archive/New.md"])) }.value
        XCTAssertEqual(session.workspace.activeResource, .file("Archive/New.md"))
    }

    func testTabsOfDeletedFilesClose() throws {
        try write("Keep.md", "keep")
        try write("Delete.md", "delete")
        let session = try openSession()
        session.workspace.open(.file("Keep.md"), placement: .replace)
        session.workspace.open(.file("Delete.md"), placement: .beside)
        try FileManager.default.removeItem(at: root.appendingPathComponent("Delete.md"))
        session.vaultDidChange()
        XCTAssertEqual(session.workspace.layout.panes.flatMap(\.tabs).map(\.resource), [.file("Keep.md")])
    }

    func testViewContextsFollowTheirTab() throws {
        let session = try openSession()
        session.workspace.open(.virtual("test:a"), placement: .replace)
        let first = try XCTUnwrap(session.workspace.layout.activeTab)
        let context = session.workspace.context(for: first)
        XCTAssertTrue(context.isActive)
        XCTAssertTrue(session.workspace.context(for: first) === context, "one context per tab")

        context.setState(["caret": 3])
        XCTAssertNotNil(session.workspace.layout.activeTab?.state, "state is kept in the layout")

        session.workspace.open(.virtual("test:b"), placement: .beside)
        XCTAssertFalse(context.isActive)
    }
}
