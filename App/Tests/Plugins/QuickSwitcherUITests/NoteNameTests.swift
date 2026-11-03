@testable import QuickSwitcherUI
import XCTest

final class NoteNameTests: XCTestCase {
    func testSanitize() {
        XCTAssertEqual(NoteName.sanitize("  Ideas "), "Ideas.md")
        XCTAssertEqual(NoteName.sanitize("a/b"), "a-b.md")
        XCTAssertEqual(NoteName.sanitize("Plan.md"), "Plan.md")
        XCTAssertEqual(NoteName.sanitize(".hidden"), "hidden.md")
        XCTAssertNil(NoteName.sanitize("   "))
        XCTAssertNil(NoteName.sanitize(".md"))
    }
}
