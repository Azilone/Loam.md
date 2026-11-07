@testable import NotebookApp
import PluginKitUI
import WorkspaceModel
import XCTest

/// "Back" in the page toolbar: a tab remembers what it showed before a note replaced it.
@MainActor
final class BackHistoryTests: XCTestCase {
    private func activeID(_ workspace: WorkspaceController) throws -> TabID {
        try XCTUnwrap(workspace.layout.activeTab?.id)
    }

    func testReplacingRemembersThePreviousNoteAndBackRestoresIt() throws {
        let workspace = WorkspaceController()
        workspace.open(.file("a.md"), placement: .replace)
        let tab = try activeID(workspace)
        XCTAssertFalse(workspace.canGoBack(in: tab))
        workspace.open(.file("b.md"), placement: .replace)
        workspace.open(.file("c.md"), placement: .replace)
        XCTAssertTrue(workspace.canGoBack(in: tab))

        workspace.goBack(in: tab)
        XCTAssertEqual(workspace.activeResource, .file("b.md"))
        workspace.goBack(in: tab)
        XCTAssertEqual(workspace.activeResource, .file("a.md"))
        XCTAssertFalse(workspace.canGoBack(in: tab))
    }

    func testForwardShowsAgainWhatBackTookAway() throws {
        let workspace = WorkspaceController()
        workspace.open(.file("a.md"), placement: .replace)
        let tab = try activeID(workspace)
        workspace.open(.file("b.md"), placement: .replace)
        workspace.open(.file("c.md"), placement: .replace)
        XCTAssertFalse(workspace.canGoForward(in: tab))

        workspace.goBack(in: tab)
        workspace.goBack(in: tab)
        XCTAssertEqual(workspace.activeResource, .file("a.md"))
        workspace.goForward(in: tab)
        XCTAssertEqual(workspace.activeResource, .file("b.md"))
        workspace.goForward(in: tab)
        XCTAssertEqual(workspace.activeResource, .file("c.md"))
        XCTAssertFalse(workspace.canGoForward(in: tab))
        workspace.goBack(in: tab)
        XCTAssertEqual(workspace.activeResource, .file("b.md"))
    }

    func testBackClosesWhatTheViewShowsOverItsPageFirst() throws {
        let workspace = WorkspaceController()
        workspace.open(.file("a.md"), placement: .replace)
        workspace.open(.file("b.md"), placement: .replace)
        let tab = try XCTUnwrap(workspace.layout.activeTab)
        let context = workspace.context(for: tab)
        var closed = 0
        context.back = { closed += 1; context.back = nil }

        workspace.goBack(in: tab.id)
        XCTAssertEqual(closed, 1)
        XCTAssertEqual(workspace.activeResource, .file("b.md"))
        workspace.goBack(in: tab.id)
        XCTAssertEqual(workspace.activeResource, .file("a.md"))
    }

    func testOpeningANewPageEndsForward() throws {
        let workspace = WorkspaceController()
        workspace.open(.file("a.md"), placement: .replace)
        let tab = try activeID(workspace)
        workspace.open(.file("b.md"), placement: .replace)
        workspace.goBack(in: tab)
        XCTAssertTrue(workspace.canGoForward(in: tab))
        workspace.open(.file("c.md"), placement: .replace)
        XCTAssertFalse(workspace.canGoForward(in: tab))
    }

    func testAClosedTabReopensLastClosedFirst() throws {
        let workspace = WorkspaceController()
        workspace.open(.file("a.md"), placement: .replace)
        workspace.open(.file("b.md"), placement: .newTab)
        workspace.open(.file("c.md"), placement: .newTab)
        _ = workspace.closeActiveTab()
        _ = workspace.closeActiveTab()
        XCTAssertEqual(workspace.activeResource, .file("a.md"))

        workspace.reopenClosedTab()
        XCTAssertEqual(workspace.activeResource, .file("b.md"))
        workspace.reopenClosedTab()
        XCTAssertEqual(workspace.activeResource, .file("c.md"))
        workspace.reopenClosedTab()  // nothing left to reopen
        XCTAssertEqual(workspace.layout.panes.flatMap(\.tabs).count, 3)
    }

    func testANewTabStartsWithNoHistory() throws {
        let workspace = WorkspaceController()
        workspace.open(.file("a.md"), placement: .replace)
        workspace.open(.file("b.md"), placement: .newTab)
        XCTAssertFalse(workspace.canGoBack(in: try activeID(workspace)))
    }

    func testDeletedNotesLeaveTheHistory() throws {
        let workspace = WorkspaceController()
        workspace.open(.file("a.md"), placement: .replace)
        let tab = try activeID(workspace)
        workspace.open(.file("b.md"), placement: .replace)
        workspace.closeTabs { $0 == .file("a.md") }
        XCTAssertFalse(workspace.canGoBack(in: tab))
    }

    func testMovesForgetTheHistory() throws {
        let workspace = WorkspaceController()
        workspace.open(.file("a.md"), placement: .replace)
        let tab = try activeID(workspace)
        workspace.open(.file("b.md"), placement: .replace)
        workspace.retarget(["a.md": "z.md"])
        XCTAssertFalse(workspace.canGoBack(in: tab))
    }
}

final class VaultBadgeTests: XCTestCase {
    func testInitials() {
        XCTAssertEqual(VaultBadge.initials("TestVault"), "TV")
        XCTAssertEqual(VaultBadge.initials("my notes"), "MN")
        XCTAssertEqual(VaultBadge.initials("2nd Cerveau de Marie"), "2C")
        XCTAssertEqual(VaultBadge.initials("notes"), "NO")
    }
}
