import AppKit
import XCTest
@testable import MarkdownEditor

/// The marker highlight: its shape stays put for the same words, and its stroke is drawn left to right in time.
final class HighlighterStrokeTests: XCTestCase {
    func testTheSameWordsDrawTheSameStroke() {
        let box = NSRect(x: 10, y: 20, width: 180, height: 22)
        let seed = HighlighterStroke.seed(of: "felt marker")
        XCTAssertEqual(HighlighterStroke.seed(of: "felt marker"), seed)
        XCTAssertNotEqual(HighlighterStroke.seed(of: "felt markers"), seed)
        XCTAssertEqual(HighlighterStroke.path(for: box, seed: seed).bounds, HighlighterStroke.path(for: box, seed: seed).bounds)
    }

    func testTheStrokeStaysOnItsLine() {
        let box = NSRect(x: 10, y: 20, width: 180, height: 22)
        let bounds = HighlighterStroke.path(for: box, seed: 42).bounds
        // Thinner than the letters, wobbling by less than a point, a little past each end.
        XCTAssertGreaterThan(bounds.minY, box.minY)
        XCTAssertLessThan(bounds.maxY, box.maxY)
        XCTAssertEqual(bounds.minX, box.minX - 1.5, accuracy: 0.01)
        XCTAssertEqual(bounds.maxX, box.maxX + 1.5, accuracy: 0.01)
    }

    func testTheRevealGoesFromNothingToAllFastThenSlowing() {
        let reveal = HighlightReveal(range: NSRange(location: 0, length: 5), start: 100, duration: 0.4)
        XCTAssertEqual(reveal.revealed(of: 300, at: 100), 0)
        XCTAssertEqual(reveal.revealed(of: 300, at: 100.4), 300, accuracy: 0.001)
        // Past half of its length in the first third of its time.
        XCTAssertGreaterThan(reveal.revealed(of: 300, at: 100 + 0.4 / 3), 150)
        XCTAssertFalse(reveal.isDone(at: 100.2))
        XCTAssertTrue(reveal.isDone(at: 100.4))
    }

    func testALongerHighlightTakesLongerWithinBounds() {
        XCTAssertEqual(HighlightReveal.duration(width: 10), 0.32)
        XCTAssertLessThan(HighlightReveal.duration(width: 200), HighlightReveal.duration(width: 500))
        XCTAssertEqual(HighlightReveal.duration(width: 5000), 0.6)
    }
}
