import CoreGraphics
import Foundation

/// A live force-directed layout in the manner of d3-force, the engine behind Obsidian's graph: links pull their ends
/// together like springs, every node pushes the others away, and a weak pull keeps the graph around the origin.
/// Each `tick()` moves the nodes one frame; the simulation cools down (`alpha`) until it stops, and warms up again
/// when a node is dragged or the graph changes. Deterministic: the same inputs always give the same frames.
public final class ForceSimulation {
    /// The length a link settles at, in points.
    public static let linkDistance: Double = 50
    /// How hard nodes push each other away (d3's many-body strength, negative to repel).
    static let charge: Double = -180
    /// The pull of every node towards the origin, which keeps unlinked notes near the rest.
    static let gravity: Double = 0.05
    /// Below this, repulsion is computed as if the nodes were this far apart, so close nodes do not fly off.
    static let minDistance: Double = 20
    static let alphaMin: Double = 0.001
    /// Reaches `alphaMin` from 1 in 300 ticks, as in d3.
    static let alphaDecay: Double = 1 - pow(alphaMin, 1.0 / 300)
    /// The share of its speed a node keeps from one tick to the next.
    static let friction: Double = 0.6

    public let nodeCount: Int
    /// How warm the simulation is: 1 when it starts, 0 at rest. The forces are scaled by it.
    public private(set) var alpha: Double
    /// The temperature the simulation heads for: 0 to come to rest, 0.3 while a node is dragged.
    public var alphaTarget: Double = 0

    private var x: [Double]
    private var y: [Double]
    private var vx: [Double]
    private var vy: [Double]
    /// Where pinned (dragged) nodes are held; nil for free nodes.
    private var pinned: [Int: CGPoint] = [:]
    private let links: [(source: Int, target: Int, strength: Double, bias: Double)]
    private var random: SplitMix64

    /// - Parameters:
    ///   - initial: known positions (a previous layout), so a small change to the graph keeps the picture in
    ///     place; the others start on a spiral around the origin. Indices out of range are ignored.
    ///   - alpha: the starting temperature, lower when most positions are known.
    public init(
        nodeCount n: Int,
        edges: [(Int, Int)],
        initial: [Int: CGPoint] = [:],
        alpha: Double = 1,
        seed: UInt64 = 0x5EED
    ) {
        nodeCount = n
        self.alpha = alpha
        random = SplitMix64(seed: seed)
        x = [Double](repeating: 0, count: n)
        y = [Double](repeating: 0, count: n)
        vx = [Double](repeating: 0, count: n)
        vy = [Double](repeating: 0, count: n)

        // d3's phyllotaxis: evenly spread starting points, the first ones near the centre.
        let angle = Double.pi * (3 - 5.0.squareRoot())
        for i in 0 ..< n {
            if let p = initial[i], p.x.isFinite, p.y.isFinite {
                x[i] = Double(p.x)
                y[i] = Double(p.y)
            } else {
                let r = 10 * (0.5 + Double(i)).squareRoot()
                x[i] = r * cos(Double(i) * angle)
                y[i] = r * sin(Double(i) * angle)
            }
        }

        // Links between two distinct nodes, once each. A link pulls harder on the end with fewer links.
        var seen = Set<[Int]>()
        var pairs: [(Int, Int)] = []
        for (a, b) in edges where a != b && a >= 0 && b >= 0 && a < n && b < n {
            if seen.insert([min(a, b), max(a, b)]).inserted { pairs.append((a, b)) }
        }
        var degree = [Int](repeating: 0, count: n)
        for (a, b) in pairs {
            degree[a] += 1
            degree[b] += 1
        }
        links = pairs.map { a, b in
            let da = Double(degree[a]), db = Double(degree[b])
            return (a, b, 1 / min(da, db), da / (da + db))
        }
    }

    /// True once the simulation has cooled down and nothing is dragged: ticking further moves nothing.
    public var isSettled: Bool { alpha < Self.alphaMin && alphaTarget == 0 }

    public var positions: [CGPoint] {
        (0 ..< nodeCount).map { CGPoint(x: x[$0], y: y[$0]) }
    }

    public func position(_ i: Int) -> CGPoint {
        CGPoint(x: x[i], y: y[i])
    }

    /// Warms the simulation up to at least `alpha`, so it moves again.
    public func reheat(_ alpha: Double = 0.3) {
        self.alpha = max(self.alpha, alpha)
    }

    /// Holds node `i` at `point` (a drag) until `unpin`.
    public func pin(_ i: Int, at point: CGPoint) {
        guard i >= 0, i < nodeCount else { return }
        pinned[i] = point
    }

    public func unpin(_ i: Int) {
        pinned[i] = nil
    }

    /// Moves every node one step.
    public func tick() {
        let n = nodeCount
        guard n > 0, alpha >= Self.alphaMin || alphaTarget > 0 else { return }
        alpha += (alphaTarget - alpha) * Self.alphaDecay

        // Links: each pulls (or pushes) its ends towards the link distance, using where they are heading.
        for link in links {
            let s = link.source, t = link.target
            var dx = x[t] + vx[t] - x[s] - vx[s]
            var dy = y[t] + vy[t] - y[s] - vy[s]
            if dx == 0 { dx = jiggle() }
            if dy == 0 { dy = jiggle() }
            var l = (dx * dx + dy * dy).squareRoot()
            l = (l - Self.linkDistance) / l * alpha * link.strength
            dx *= l
            dy *= l
            vx[t] -= dx * link.bias
            vy[t] -= dy * link.bias
            vx[s] += dx * (1 - link.bias)
            vy[s] += dy * (1 - link.bias)
        }

        // Repulsion between every pair. Quadratic, fine for the few thousand notes of a personal vault.
        let minDistance2 = Self.minDistance * Self.minDistance
        for i in 0 ..< n {
            for j in (i + 1) ..< n {
                var dx = x[j] - x[i]
                var dy = y[j] - y[i]
                if dx == 0 { dx = jiggle() }
                if dy == 0 { dy = jiggle() }
                var l2 = dx * dx + dy * dy
                if l2 < minDistance2 { l2 = (minDistance2 * l2).squareRoot() }
                let w = Self.charge * alpha / l2
                vx[i] += dx * w
                vy[i] += dy * w
                vx[j] -= dx * w
                vy[j] -= dy * w
            }
        }

        for i in 0 ..< n {
            vx[i] -= x[i] * Self.gravity * alpha
            vy[i] -= y[i] * Self.gravity * alpha
            if let p = pinned[i] {
                x[i] = Double(p.x)
                y[i] = Double(p.y)
                vx[i] = 0
                vy[i] = 0
            } else {
                vx[i] *= Self.friction
                vy[i] *= Self.friction
                x[i] += vx[i]
                y[i] += vy[i]
            }
        }
    }

    /// Ticks until the simulation is settled, at most `maxTicks` times (the tests, and layouts nobody watches).
    public func settle(maxTicks: Int = 1000) {
        for _ in 0 ..< maxTicks where !isSettled { tick() }
    }

    /// A tiny deterministic nudge that separates two nodes on the same spot.
    private func jiggle() -> Double {
        (random.nextUnit() - 0.5) * 1e-6
    }
}
