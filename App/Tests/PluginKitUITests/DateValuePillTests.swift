import PluginKitUI
import XCTest

final class DateValuePillTests: XCTestCase {
    func testADayReadsAsTheEditorWritesIt() {
        XCTAssertEqual(DateValuePill.label("2026-11-03", today: "2026-11-03"), "Today")
        XCTAssertEqual(DateValuePill.label("2026-11-04", today: "2026-11-03"), "Tomorrow")
        XCTAssertEqual(DateValuePill.label("2026-11-02", today: "2026-11-03"), "Yesterday")
        XCTAssertEqual(DateValuePill.label("2026-11-11", today: "2026-11-03"), "Wed, Nov 11")
        XCTAssertEqual(DateValuePill.label("2027-01-05", today: "2026-11-03"), "Jan 5, 2027")
        XCTAssertEqual(DateValuePill.label("2026-11-11T09:30", today: "2026-11-03"), "Wed, Nov 11")
        XCTAssertNil(DateValuePill.label("next week", today: "2026-11-03"))
    }
}
