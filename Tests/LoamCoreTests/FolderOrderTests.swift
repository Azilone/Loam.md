import PluginKit
import XCTest

final class FolderOrderTests: XCTestCase {
    func testAFolderInheritsTheOrderOfTheClosestFolderAboveIt() {
        let order = FolderOrder(orders: [
            "Journal": .nameDescending,
            "Journal/2026/11 November": .nameAscending,
        ])
        XCTAssertEqual(order.order(for: ""), .nameAscending)
        XCTAssertEqual(order.order(for: "Journal"), .nameDescending)
        XCTAssertEqual(order.order(for: "Journal/2026"), .nameDescending, "a folder below inherits")
        XCTAssertEqual(order.order(for: "Journal/2026/11 November"), .nameAscending, "until it says its own")
        XCTAssertEqual(order.order(for: "Journal/2026/11 November/2026-11-08.md"), .nameAscending)
        XCTAssertEqual(FolderOrder(orders: ["": .nameDescending]).order(for: "Anything"), .nameDescending)
    }
}
