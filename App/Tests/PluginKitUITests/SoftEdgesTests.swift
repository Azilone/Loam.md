import XCTest
@testable import PluginKitUI

final class SoftEdgesTests: XCTestCase {
    func testDistancesAtRestInTheMiddleAndAtTheEnd() {
        var d = Motion.EdgeGlass.distances(offset: 0, viewport: 600, content: 2000)
        XCTAssertEqual(d.top, 0)
        XCTAssertEqual(d.bottom, 1400)
        d = Motion.EdgeGlass.distances(offset: 500, viewport: 600, content: 2000)
        XCTAssertEqual(d.top, 500)
        XCTAssertEqual(d.bottom, 900)
        d = Motion.EdgeGlass.distances(offset: 1400, viewport: 600, content: 2000)
        XCTAssertEqual(d.bottom, 0)
    }

    func testAShortDocumentHasNoGlassAtEitherEdge() {
        let d = Motion.EdgeGlass.distances(offset: 0, viewport: 600, content: 300)
        XCTAssertEqual(Motion.EdgeGlass.progress(distance: d.top), 0)
        XCTAssertEqual(Motion.EdgeGlass.progress(distance: d.bottom), 0)
    }

    func testPullingPastAnEndKeepsTheGlassOff() {
        let d = Motion.EdgeGlass.distances(offset: -30, viewport: 600, content: 2000)
        XCTAssertEqual(Motion.EdgeGlass.steppedProgress(distance: d.top), 0)
        let end = Motion.EdgeGlass.distances(offset: 1440, viewport: 600, content: 2000)
        XCTAssertEqual(Motion.EdgeGlass.steppedProgress(distance: end.bottom), 0)
    }

    func testSteppedProgressStaysOnItsGrid() {
        for distance in stride(from: CGFloat(-5), through: 80, by: 0.7) {
            let value = Motion.EdgeGlass.steppedProgress(distance: distance)
            XCTAssertEqual(value * 64, (value * 64).rounded(), accuracy: 1e-9)
            XCTAssertEqual(value, Motion.EdgeGlass.progress(distance: distance), accuracy: 1 / 128 + 1e-9)
        }
        XCTAssertEqual(Motion.EdgeGlass.steppedProgress(distance: Motion.EdgeGlass.rampDistance), 1)
    }

    func testLayersComeInOneAfterTheOtherAndAllAtFullStrength() {
        let layers = Motion.EdgeGlass.layers
        for layer in 0..<layers {
            XCTAssertEqual(Motion.EdgeGlass.layerOpacity(layer: layer, progress: 0), 0)
            XCTAssertEqual(Motion.EdgeGlass.layerOpacity(layer: layer, progress: 1), 1)
        }
        // At a third of the way, only the first is in, and fully.
        XCTAssertEqual(Motion.EdgeGlass.layerOpacity(layer: 0, progress: 1.0 / Double(layers)), 1, accuracy: 1e-9)
        XCTAssertEqual(Motion.EdgeGlass.layerOpacity(layer: 1, progress: 1.0 / Double(layers)), 0, accuracy: 1e-9)
        // A layer never shows before the lighter one under it.
        for step in 0...100 {
            let progress = Double(step) / 100
            for layer in 1..<layers {
                XCTAssertLessThanOrEqual(
                    Motion.EdgeGlass.layerOpacity(layer: layer, progress: progress),
                    Motion.EdgeGlass.layerOpacity(layer: layer - 1, progress: progress)
                )
            }
        }
    }

    func testHeavierLayersReachLess() {
        XCTAssertEqual(Motion.EdgeGlass.layerReach(layer: 0), 1)
        var previous = 1.0
        for layer in 1..<Motion.EdgeGlass.layers {
            let reach = Motion.EdgeGlass.layerReach(layer: layer)
            XCTAssertLessThan(reach, previous)
            XCTAssertGreaterThan(reach, 0)
            previous = reach
        }
    }

    func testRampIsOpaqueAtTheEdgeClearAtTheEndAndNeverRises() {
        XCTAssertEqual(Motion.EdgeGlass.rampOpacity(at: 0), 1)
        XCTAssertEqual(Motion.EdgeGlass.rampOpacity(at: 1), 0)
        XCTAssertEqual(Motion.EdgeGlass.rampOpacity(at: 0.5), 0.5, accuracy: 1e-9)
        var previous = 1.0
        for step in 0...100 {
            let value = Motion.EdgeGlass.rampOpacity(at: Double(step) / 100)
            XCTAssertLessThanOrEqual(value, previous + 1e-12)
            previous = value
        }
    }
}
