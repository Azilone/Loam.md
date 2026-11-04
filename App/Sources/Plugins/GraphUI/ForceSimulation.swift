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

        repel()

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

    // MARK: Repulsion

    /// How far a group of nodes must be, relative to its width, to push as one body at its centre (d3's theta).
    static let theta: Double = 0.9

    /// The quadtree of the nodes, rebuilt each tick in these buffers: cell `c` covers a square of `cellSize[c]`,
    /// holds `cellMass[c]` nodes centred on `cellX[c], cellY[c]`, and either has four children from
    /// `cellChild[c]` on, or is a leaf whose nodes are `order[cellStart[c] ..< cellEnd[c]]`.
    private var order: [Int] = []
    private var scratch: [Int] = []
    private var cellSize: [Double] = []
    private var cellMass: [Double] = []
    private var cellX: [Double] = []
    private var cellY: [Double] = []
    private var cellChild: [Int] = []
    private var cellStart: [Int] = []
    private var cellEnd: [Int] = []
    private var stack: [Int] = []

    /// Every node pushes the others away, as Barnes-Hut does in d3: near nodes one by one, far groups as a single
    /// body. Some n log n steps a tick instead of n², which keeps a vault of thousands of notes moving at full speed.
    private func repel() {
        let n = nodeCount
        var minX = Double.infinity, minY = Double.infinity, maxX = -Double.infinity, maxY = -Double.infinity
        for i in 0 ..< n {
            minX = min(minX, x[i]); maxX = max(maxX, x[i])
            minY = min(minY, y[i]); maxY = max(maxY, y[i])
        }
        let side = max(maxX - minX, maxY - minY, 1)
        order = Array(0 ..< n)
        scratch = order
        cellSize.removeAll(keepingCapacity: true)
        cellMass.removeAll(keepingCapacity: true)
        cellX.removeAll(keepingCapacity: true)
        cellY.removeAll(keepingCapacity: true)
        cellChild.removeAll(keepingCapacity: true)
        cellStart.removeAll(keepingCapacity: true)
        cellEnd.removeAll(keepingCapacity: true)
        fill(addCell(size: side), start: 0, end: n, x0: minX, y0: minY, size: side)

        let minDistance2 = Self.minDistance * Self.minDistance
        let theta2 = Self.theta * Self.theta
        let strength = Self.charge * alpha
        for i in 0 ..< n {
            stack.removeAll(keepingCapacity: true)
            stack.append(0)
            while let c = stack.popLast() {
                if cellChild[c] < 0 {
                    for k in cellStart[c] ..< cellEnd[c] {
                        let j = order[k]
                        guard j != i else { continue }
                        var dx = x[j] - x[i]
                        var dy = y[j] - y[i]
                        if dx == 0 { dx = jiggle() }
                        if dy == 0 { dy = jiggle() }
                        var l2 = dx * dx + dy * dy
                        if l2 < minDistance2 { l2 = (minDistance2 * l2).squareRoot() }
                        vx[i] += dx * strength / l2
                        vy[i] += dy * strength / l2
                    }
                    continue
                }
                let dx = cellX[c] - x[i], dy = cellY[c] - y[i]
                var l2 = dx * dx + dy * dy
                if cellSize[c] * cellSize[c] < theta2 * l2 {
                    if l2 < minDistance2 { l2 = (minDistance2 * l2).squareRoot() }
                    vx[i] += dx * strength * cellMass[c] / l2
                    vy[i] += dy * strength * cellMass[c] / l2
                } else {
                    for child in cellChild[c] ..< cellChild[c] + 4 where cellMass[child] > 0 { stack.append(child) }
                }
            }
        }
    }

    /// Adds an empty cell at the end of the buffers and returns its index.
    private func addCell(size: Double) -> Int {
        cellSize.append(size)
        cellMass.append(0)
        cellX.append(0)
        cellY.append(0)
        cellChild.append(-1)
        cellStart.append(0)
        cellEnd.append(0)
        return cellSize.count - 1
    }

    /// Fills cell `c` with the nodes `order[start ..< end]`, in the square at `x0, y0`, and unless it is small
    /// enough to be a leaf, splits it into four quarters that take the next four indices.
    private func fill(_ c: Int, start: Int, end: Int, x0: Double, y0: Double, size: Double) {
        var sx = 0.0, sy = 0.0
        for k in start ..< end {
            sx += x[order[k]]
            sy += y[order[k]]
        }
        let mass = Double(end - start)
        cellMass[c] = mass
        cellX[c] = mass > 0 ? sx / mass : 0
        cellY[c] = mass > 0 ? sy / mass : 0
        cellStart[c] = start
        cellEnd[c] = end
        // A leaf holds one node, or several on the same spot (nothing more to split).
        guard end - start > 1, size > 1e-3 else { return }

        // The nodes sorted by quarter: top left, top right, bottom left, bottom right.
        let half = size / 2, midX = x0 + half, midY = y0 + half
        func quarter(_ i: Int) -> Int { (x[i] < midX ? 0 : 1) + (y[i] < midY ? 0 : 2) }
        var counts = [0, 0, 0, 0]
        for k in start ..< end { counts[quarter(order[k])] += 1 }
        var bounds = [start, 0, 0, 0, 0]
        for q in 0 ..< 4 { bounds[q + 1] = bounds[q] + counts[q] }
        var next = Array(bounds[0 ..< 4])
        for k in start ..< end {
            let i = order[k]
            scratch[next[quarter(i)]] = i
            next[quarter(i)] += 1
        }
        for k in start ..< end { order[k] = scratch[k] }

        let first = addCell(size: half)
        for _ in 1 ..< 4 { _ = addCell(size: half) }
        cellChild[c] = first
        for q in 0 ..< 4 {
            fill(first + q, start: bounds[q], end: bounds[q + 1], x0: q % 2 == 0 ? x0 : midX, y0: q < 2 ? y0 : midY, size: half)
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
