import XCTest
@testable import NotebookApp

final class SplitSnapTests: XCTestCase {
    /// Two pages sharing 1000 points: half is 0.5 and a point is 0.001.
    private func resolve(_ first: Double) -> (first: Double, isSnapped: Bool) {
        SplitSnap.resolve(first: first, pair: 1, pairLength: 1000, minimum: 0.12)
    }

    func testTheBoundaryStaysFreeFarFromEveryKeyPosition() {
        XCTAssertEqual(resolve(0.56).first, 0.56, accuracy: 1e-9)
        XCTAssertFalse(resolve(0.56).isSnapped)
        XCTAssertEqual(resolve(0.4).first, 0.4, accuracy: 1e-9)
    }

    func testTheBoundaryIsHeldOnTheMiddleNearIt() {
        for first in [0.497, 0.5, 0.503] {
            XCTAssertEqual(resolve(first).first, 0.5, accuracy: 1e-9)
            XCTAssertTrue(resolve(first).isSnapped)
        }
    }

    func testTheMagnetPullsLessAndLessThenLetsGoWithoutAJump() {
        // Between the grip and the reach the boundary lags behind the pointer…
        let pulled = resolve(0.515)
        XCTAssertFalse(pulled.isSnapped)
        XCTAssertGreaterThan(pulled.first, 0.5)
        XCTAssertLessThan(pulled.first, 0.515)
        // …on both sides alike…
        XCTAssertEqual(resolve(0.485).first, 1 - resolve(0.515).first, accuracy: 1e-9)
        // …never moves back as the pointer moves on…
        var last = 0.5
        for step in 0...60 {
            let first = resolve(0.5 + Double(step) * 0.001).first
            XCTAssertGreaterThanOrEqual(first, last)
            last = first
        }
        // …and is on the pointer again at the reach, with no step.
        XCTAssertEqual(resolve(0.5 + Double(SplitSnap.reach) / 1000 - 1e-6).first, 0.524, accuracy: 1e-4)
        XCTAssertEqual(resolve(0.5 + Double(SplitSnap.reach) / 1000 + 1e-6).first, 0.524, accuracy: 1e-4)
    }

    func testThirdsAndQuartersAreKeyPositionsToo() throws {
        XCTAssertEqual(resolve(0.335).first, 1.0 / 3, accuracy: 1e-9)
        XCTAssertTrue(resolve(0.745).isSnapped || abs(resolve(0.745).first - 0.75) < 0.005)
    }

    func testAKeyPositionBelowTheMinimumIsSkipped() {
        let result = SplitSnap.resolve(first: 0.26, pair: 1, pairLength: 1000, minimum: 0.3)
        XCTAssertEqual(result.first, 0.26, accuracy: 1e-9)
        XCTAssertFalse(result.isSnapped)
    }

    func testLettingGoNearAKeyPositionLandsOnIt() {
        XCTAssertEqual(SplitSnap.landing(first: 0.508, pair: 1, pairLength: 1000), 0.5)
        XCTAssertNil(SplitSnap.landing(first: 0.52, pair: 1, pairLength: 1000), "too far")
        XCTAssertNil(SplitSnap.landing(first: 0.5, pair: 1, pairLength: 1000), "already there")
    }
}
