import CoreGraphics
import XCTest
@testable import GraphUI

/// The live force-directed layout, ticked by hand.
final class ForceSimulationTests: XCTestCase {
    /// Two rings of 8 nodes, joined by one link, plus 4 nodes with no link.
    private let nodeCount = 20
    private var edges: [(Int, Int)] {
        var result: [(Int, Int)] = []
        for ring in [0, 8] {
            for i in 0 ..< 8 { result.append((ring + i, ring + (i + 1) % 8)) }
        }
        result.append((0, 8))
        return result
    }

    private func settled(_ n: Int, _ edges: [(Int, Int)], initial: [Int: CGPoint] = [:]) -> ForceSimulation {
        let simulation = ForceSimulation(nodeCount: n, edges: edges, initial: initial)
        simulation.settle()
        return simulation
    }

    func testIsDeterministicAndSettles() {
        let a = settled(nodeCount, edges)
        let b = settled(nodeCount, edges)
        XCTAssertEqual(a.positions, b.positions)
        XCTAssertTrue(a.isSettled)

        // It settles in the 300 ticks of d3, then stops moving.
        let simulation = ForceSimulation(nodeCount: nodeCount, edges: edges)
        for _ in 0 ..< 310 { simulation.tick() }
        XCTAssertTrue(simulation.isSettled)
        let before = simulation.positions
        simulation.tick()
        XCTAssertEqual(simulation.positions, before)
    }

    func testHasNoNaN() {
        for n in [0, 1, 2, 3, 50] {
            let points = settled(n, n > 1 ? [(0, 1), (1, 1), (0, 99), (-1, 0)] : []).positions
            XCTAssertEqual(points.count, n)
            XCTAssertTrue(points.allSatisfy { $0.x.isFinite && $0.y.isFinite }, "\(n) nodes")
        }
        // Every node starting on the same spot still spreads out.
        let stacked = settled(5, [], initial: [0: .zero, 1: .zero, 2: .zero, 3: .zero, 4: .zero]).positions
        XCTAssertTrue(stacked.allSatisfy { $0.x.isFinite && $0.y.isFinite })
        XCTAssertEqual(Set(stacked.map { "\($0.x),\($0.y)" }).count, 5)
    }

    func testLinkedNodesEndUpCloserThanUnlinkedOnes() {
        let points = settled(nodeCount, edges).positions
        func distance(_ a: Int, _ b: Int) -> Double {
            Double(hypot(points[a].x - points[b].x, points[a].y - points[b].y))
        }
        let linked = Set(edges.map { "\(min($0.0, $0.1))-\(max($0.0, $0.1))" })
        var near: [Double] = []
        var far: [Double] = []
        for a in 0 ..< nodeCount {
            for b in (a + 1) ..< nodeCount {
                (linked.contains("\(a)-\(b)") ? { near.append(distance(a, b)) } : { far.append(distance(a, b)) })()
            }
        }
        let meanNear = near.reduce(0, +) / Double(near.count)
        let meanFar = far.reduce(0, +) / Double(far.count)
        XCTAssertLessThan(meanNear, meanFar)
        XCTAssertLessThan(meanNear, ForceSimulation.linkDistance * 2, "links settle near their length")
    }

    func testKnownPositionsAreAStart() {
        let points = settled(nodeCount, edges).positions
        let initial = Dictionary(uniqueKeysWithValues: points.enumerated().map { ($0, $1) })
        let again = ForceSimulation(nodeCount: nodeCount, edges: edges, initial: initial, alpha: 0.3)
        again.settle()
        let moved = zip(points, again.positions).map { Double(hypot($0.x - $1.x, $0.y - $1.y)) }
        XCTAssertLessThan(moved.reduce(0, +) / Double(moved.count), ForceSimulation.linkDistance / 2)
    }

    func testADraggedNodeStaysPutAndPullsItsNeighbours() {
        let simulation = settled(nodeCount, edges)
        let target = CGPoint(x: 600, y: 0)
        let neighbourBefore = simulation.position(1)
        simulation.pin(0, at: target)
        simulation.alphaTarget = 0.3
        simulation.reheat()
        for _ in 0 ..< 120 { simulation.tick() }
        XCTAssertEqual(simulation.position(0), target)
        XCTAssertFalse(simulation.isSettled, "it keeps moving while dragged")
        XCTAssertLessThan(
            hypot(simulation.position(1).x - target.x, simulation.position(1).y - target.y),
            hypot(neighbourBefore.x - target.x, neighbourBefore.y - target.y),
            "the neighbour follows"
        )

        simulation.unpin(0)
        simulation.alphaTarget = 0
        simulation.settle()
        XCTAssertTrue(simulation.isSettled)
    }

    func testBoundsOfPoints() {
        XCTAssertEqual(GraphLayout.bounds(of: []), .zero)
        XCTAssertEqual(
            GraphLayout.bounds(of: [CGPoint(x: -1, y: 2), CGPoint(x: 3, y: -4)]),
            CGRect(x: -1, y: -4, width: 4, height: 6)
        )
    }
}
