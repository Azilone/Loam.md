import CoreGraphics
@testable import PluginKitUI
import XCTest

final class SVGPathTests: XCTestCase {
    func testLinesAbsoluteAndRelative() {
        let box = SVGPath.path("M2 3h4v5l-6 0Z").boundingBoxOfPath
        XCTAssertEqual(box, CGRect(x: 0, y: 3, width: 6, height: 5))
    }

    func testNumbersRunTogetherAsSVGWritesThem() {
        // "1.5.5" is 1.5 then .5; "2-3" is 2 then -3.
        let box = SVGPath.path("M1.5.5L2-3").boundingBoxOfPath
        XCTAssertEqual(box.minX, 1.5, accuracy: 0.001)
        XCTAssertEqual(box.minY, -3, accuracy: 0.001)
        XCTAssertEqual(box.maxY, 0.5, accuracy: 0.001)
    }

    func testAnArcIsAHalfCircle() {
        // From (0, 5) to (10, 5) over the top: a half circle of radius 5 centred on (5, 5).
        let box = SVGPath.path("M0 5a5 5 0 0 1 10 0").boundingBoxOfPath
        XCTAssertEqual(box.minX, 0, accuracy: 0.01)
        XCTAssertEqual(box.maxX, 10, accuracy: 0.01)
        XCTAssertEqual(box.minY, 0, accuracy: 0.05)
        XCTAssertEqual(box.maxY, 5, accuracy: 0.01)
    }

    func testSmoothCurveMirrorsTheLastControl() {
        let path = SVGPath.path("M0 0C0 4 4 4 4 0S8-4 8 0")
        XCTAssertEqual(path.boundingBoxOfPath.maxX, 8, accuracy: 0.001)
        XCTAssertLessThan(path.boundingBoxOfPath.minY, -2)
    }
}
