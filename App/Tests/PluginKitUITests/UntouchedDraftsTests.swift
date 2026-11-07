import PluginKitUI
import XCTest

/// A new board or map left as its template goes away once the focus leaves it; one that changed stays.
@MainActor
final class UntouchedDraftsTests: XCTestCase {
    func testOnlyUntouchedDraftsAreDiscardedWhenTheFocusLeaves() {
        var files = ["Inbox/Board.canvas": "{}", "Inbox/Map.md": "# Map\n"]
        var discarded: [String] = []
        let drafts = UntouchedDrafts(read: { files[$0] }, discard: { discarded.append($0) })
        drafts.remember("Inbox/Board.canvas", template: "{}")
        drafts.remember("Inbox/Map.md", template: "# Map\n")
        files["Inbox/Map.md"] = "# Map\n- idea\n"
        drafts.focusMoved(to: .file("Inbox/Board.canvas"))
        XCTAssertEqual(discarded, [], "the open one stays; the changed one is forgotten")
        drafts.focusMoved(to: .file("Welcome.md"))
        XCTAssertEqual(discarded, ["Inbox/Board.canvas"])
        drafts.remember("Inbox/A.canvas", template: "{}")
        drafts.moved(["Inbox/A.canvas": "Inbox/B.canvas"])
        files["Inbox/B.canvas"] = "{}"
        drafts.focusMoved(to: nil)
        XCTAssertEqual(discarded, ["Inbox/Board.canvas", "Inbox/B.canvas"])
    }
}
