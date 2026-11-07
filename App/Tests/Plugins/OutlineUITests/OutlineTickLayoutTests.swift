import PluginKitUI
import XCTest
@testable import OutlineUI

/// The ticks at a long note's edge, without a view.
final class OutlineTickLayoutTests: XCTestCase {
    func testShownOnlyForLongNotesWithHeadings() {
        let long = PageScroll(offset: 0, visibleHeight: 800, contentHeight: 2400)
        XCTAssertTrue(OutlineTickLayout.isShown(headings: 3, scroll: long))
        XCTAssertFalse(OutlineTickLayout.isShown(headings: 1, scroll: long))
        XCTAssertFalse(OutlineTickLayout.isShown(headings: 5, scroll: PageScroll(offset: 0, visibleHeight: 800, contentHeight: 1200)))
        XCTAssertFalse(OutlineTickLayout.isShown(headings: 5, scroll: PageScroll()))
    }

    func testWidthShrinksWithLevelFromTheTopOne() {
        XCTAssertEqual(OutlineTickLayout.width(level: 2, top: 2), 16)
        XCTAssertEqual(OutlineTickLayout.width(level: 3, top: 2), 12)
        XCTAssertEqual(OutlineTickLayout.width(level: 6, top: 1), OutlineTickLayout.minWidth)
    }

    func testGapShrinksToFitButNotBelowTheMinimum() {
        XCTAssertEqual(OutlineTickLayout.gap(count: 10, available: 500), OutlineTickLayout.gap)
        XCTAssertEqual(OutlineTickLayout.gap(count: 11, available: 72), 5, accuracy: 0.001)
        XCTAssertEqual(OutlineTickLayout.gap(count: 200, available: 300), OutlineTickLayout.minGap)
    }

    func testCurrentIsTheLastHeadingPassedUnderTheToolbar() {
        let ys: [CGFloat?] = [0, 1000, 2000]
        func current(_ offset: CGFloat) -> Int? {
            OutlineTickLayout.current(ys: ys, scroll: PageScroll(offset: offset, visibleHeight: 800, contentHeight: 4000), topInset: 50)
        }
        XCTAssertEqual(current(0), 0)
        XCTAssertEqual(current(900), 0)
        XCTAssertEqual(current(930), 1)
        XCTAssertEqual(current(2500), 2)
        // Scrolled to the end: the last heading, even if it never reaches the top.
        XCTAssertEqual(
            OutlineTickLayout.current(ys: [0, 3900], scroll: PageScroll(offset: 3200, visibleHeight: 800, contentHeight: 4000), topInset: 50),
            1
        )
        XCTAssertNil(OutlineTickLayout.current(ys: [400], scroll: PageScroll(offset: 0, visibleHeight: 800, contentHeight: 4000), topInset: 0))
    }

    func testMagnetGrowsTicksNearThePointerOnly() {
        XCTAssertEqual(OutlineTickLayout.magnet(distance: 0), 1 + OutlineTickLayout.magnetGrowth)
        XCTAssertEqual(OutlineTickLayout.magnet(distance: OutlineTickLayout.magnetRadius), 1)
        XCTAssertEqual(OutlineTickLayout.magnet(distance: -100), 1)
        XCTAssertGreaterThan(OutlineTickLayout.magnet(distance: 10), OutlineTickLayout.magnet(distance: 20))
    }

    func testNearestTickUnderThePointer() {
        // Each tick takes 2 + 8 points.
        XCTAssertEqual(OutlineTickLayout.nearest(y: 0, count: 5, gap: 8), 0)
        XCTAssertEqual(OutlineTickLayout.nearest(y: 25, count: 5, gap: 8), 2)
        XCTAssertEqual(OutlineTickLayout.nearest(y: 400, count: 5, gap: 8), 4)
        XCTAssertNil(OutlineTickLayout.nearest(y: 10, count: 0, gap: 8))
        XCTAssertEqual(OutlineTickLayout.center(of: 2, gap: 8), 25)
    }
}
