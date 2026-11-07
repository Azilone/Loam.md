import Foundation
import PluginKitUI
import WorkspaceModel
import XCTest
@testable import NotebookApp

@MainActor
final class ShellCommandTests: ShellTestCase {
    func testSplitRightAndDownOpenTheActiveTabAgain() async throws {
        let session = try openSession()
        session.workspace.open(.virtual("test:a"), placement: .replace)
        _ = try await session.run("workspace.split-right")
        guard case .split(_, .horizontal, let children, _) = session.workspace.layout.root else {
            return XCTFail("expected a horizontal split")
        }
        XCTAssertEqual(children.count, 2)
        _ = try await session.run("workspace.split-down")
        XCTAssertEqual(session.workspace.layout.panes.count, 3)
        XCTAssertEqual(Set(session.workspace.layout.panes.flatMap(\.tabs).map(\.resource)), [.virtual("test:a")])
        XCTAssertNoThrow(try session.workspace.layout.validate())
    }

    func testCloseTabClosesTheActiveTab() async throws {
        let session = try openSession()
        session.workspace.open(.virtual("test:a"), placement: .replace)
        session.workspace.open(.virtual("test:b"), placement: .beside)
        _ = try await session.run("workspace.close-tab")
        XCTAssertEqual(session.workspace.layout.panes.count, 1)
        XCTAssertEqual(session.workspace.activeResource, .virtual("test:a"))
        _ = try await session.run("workspace.close-tab")
        XCTAssertNil(session.workspace.activeResource)
        _ = try await session.run("workspace.close-tab")  // nothing left: no error
    }

    func testNewTabOpensHomeAfterTheSelectedTabAndIsNotDuplicated() async throws {
        let session = try openSession()
        let home = Resource.virtual("test:home")
        session.workspace.newTabResource = { home }
        XCTAssertEqual(session.runtime.kernel.commands.command(id: "workspace.new-tab")?.shortcut?.description, "cmd+t")
        session.workspace.open(home, placement: .newTab)  // the home tab itself
        session.workspace.open(.virtual("test:a"), placement: .newTab)
        session.workspace.select(session.workspace.layout.focused.tabs[0].id)
        var quickOpens = 0
        session.workspace.onNewTab = { quickOpens += 1 }
        _ = try await session.run("workspace.new-tab")
        let tabs = session.workspace.layout.focused.tabs
        XCTAssertEqual(tabs.map(\.resource), [home, home, .virtual("test:a")])
        XCTAssertEqual(session.workspace.layout.activeTab?.id, tabs[1].id)
        _ = try await session.run("workspace.new-tab")  // already on an untouched new tab
        XCTAssertEqual(session.workspace.layout.focused.tabs.count, 3)
        XCTAssertEqual(quickOpens, 2)  // the second Cmd+T brings Quick Open back
    }

    func testLeavingAnUntouchedNewTabTellsTheShellSoQuickOpenCloses() async throws {
        let session = try openSession()
        session.workspace.newTabResource = { .virtual("test:home") }
        session.workspace.open(.virtual("test:a"), placement: .newTab)
        var left = 0
        session.workspace.onNewTabLeft = { left += 1 }
        _ = try await session.run("workspace.new-tab")
        _ = try await session.run("workspace.new-tab")  // stays on it: nothing left
        XCTAssertEqual(left, 0)
        _ = try await session.run("workspace.close-tab")
        XCTAssertEqual(left, 1)
        _ = try await session.run("workspace.close-tab")  // a plain tab: not a new tab
        XCTAssertEqual(left, 1)
    }

    func testAnUntouchedNewTabIsDiscardedWhenYouLeaveIt() async throws {
        let session = try openSession()
        session.workspace.newTabResource = { .virtual("test:home") }
        session.workspace.open(.virtual("test:a"), placement: .newTab)
        _ = try await session.run("workspace.new-tab")
        session.workspace.selectAdjacentTab(-1)
        XCTAssertEqual(session.workspace.layout.focused.tabs.map(\.resource), [.virtual("test:a")])
        // A new tab that was used (it now shows a note) stays.
        _ = try await session.run("workspace.new-tab")
        session.workspace.open(.virtual("test:b"), placement: .replace)
        session.workspace.selectAdjacentTab(-1)
        XCTAssertEqual(session.workspace.layout.focused.tabs.count, 2)
        _ = try await session.run("workspace.new-tab")  // a used tab does not block the next new tab
        XCTAssertEqual(session.workspace.layout.focused.tabs.count, 3)
    }

    func testAnUntouchedNewTabIsDiscardedWhenAnOpenNoteIsOpenedAgain() async throws {
        let session = try openSession()
        session.workspace.newTabResource = { .virtual("test:home") }
        session.workspace.open(.virtual("test:a"), placement: .newTab)
        _ = try await session.run("workspace.new-tab")
        XCTAssertTrue(session.workspace.isNewTab(session.workspace.layout.activeTab!.id))
        session.workspace.open(.virtual("test:a"), placement: .replace)  // already open: only selects it
        let tabs = session.workspace.layout.focused.tabs
        XCTAssertEqual(tabs.map(\.resource), [.virtual("test:a")])
        XCTAssertEqual(session.workspace.layout.activeTab?.resource, .virtual("test:a"))
    }

    func testANewTabIsNoLongerNewOnceItShowsSomethingElse() async throws {
        let session = try openSession()
        session.workspace.newTabResource = { .virtual("test:home") }
        session.workspace.open(.virtual("test:a"), placement: .newTab)
        _ = try await session.run("workspace.new-tab")
        let id = session.workspace.layout.activeTab!.id
        session.workspace.open(.virtual("test:b"), placement: .replace)
        XCTAssertFalse(session.workspace.isNewTab(id))
        session.workspace.goBack(in: id)  // back on the home page: still an ordinary tab
        XCTAssertFalse(session.workspace.isNewTab(id))
    }

    func testNewTabDoesNothingWithoutAHomePage() async throws {
        let session = try openSession()
        _ = try await session.run("workspace.new-tab")
        XCTAssertTrue(session.workspace.layout.focused.tabs.isEmpty)
    }

    func testNextAndPreviousTabWrapAround() async throws {
        let session = try openSession()
        for name in ["a", "b", "c"] { session.workspace.open(.virtual("test:\(name)"), placement: .newTab) }
        _ = try await session.run("workspace.next-tab")
        XCTAssertEqual(session.workspace.activeResource, .virtual("test:a"))
        _ = try await session.run("workspace.previous-tab")
        XCTAssertEqual(session.workspace.activeResource, .virtual("test:c"))
    }

    func testSidebarsToggle() async throws {
        let session = try openSession()
        _ = try await session.run("sidebar.toggle-leading")
        _ = try await session.run("sidebar.toggle-trailing")
        XCTAssertFalse(session.workspace.chrome.showsLeading)
        XCTAssertFalse(session.workspace.chrome.showsTrailing)
        _ = try await session.run("sidebar.toggle-leading")
        XCTAssertTrue(session.workspace.chrome.showsLeading)
    }

    func testClosingTheSessionRemovesTheShellCommands() throws {
        let session = try openSession()
        let commands = session.runtime.kernel.commands
        session.close()
        XCTAssertTrue(commands.all.isEmpty, "left: \(commands.all.map(\.id))")
    }
}
