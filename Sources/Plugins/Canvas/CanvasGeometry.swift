import Foundation

/// A point on the board, in board units (pixels at 100 %). Foundation-only, so the geometry builds on Linux.
public struct CanvasPoint: Equatable, Sendable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }

    public static func + (a: CanvasPoint, b: CanvasPoint) -> CanvasPoint { CanvasPoint(x: a.x + b.x, y: a.y + b.y) }
    public static func - (a: CanvasPoint, b: CanvasPoint) -> CanvasPoint { CanvasPoint(x: a.x - b.x, y: a.y - b.y) }
    public static func * (a: CanvasPoint, k: Double) -> CanvasPoint { CanvasPoint(x: a.x * k, y: a.y * k) }

    public var length: Double { (x * x + y * y).squareRoot() }
}

public struct CanvasRect: Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    /// The smallest rectangle holding both points, whatever their order.
    public init(corner a: CanvasPoint, _ b: CanvasPoint) {
        self.init(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }

    public var minX: Double { x }
    public var minY: Double { y }
    public var maxX: Double { x + width }
    public var maxY: Double { y + height }
    public var center: CanvasPoint { CanvasPoint(x: x + width / 2, y: y + height / 2) }

    public func intersects(_ other: CanvasRect) -> Bool {
        minX < other.maxX && other.minX < maxX && minY < other.maxY && other.minY < maxY
    }

    public func contains(_ other: CanvasRect) -> Bool {
        other.minX >= minX && other.maxX <= maxX && other.minY >= minY && other.maxY <= maxY
    }

    public func contains(_ point: CanvasPoint) -> Bool {
        point.x >= minX && point.x <= maxX && point.y >= minY && point.y <= maxY
    }

    public func insetBy(_ amount: Double) -> CanvasRect {
        CanvasRect(x: x + amount, y: y + amount, width: width - 2 * amount, height: height - 2 * amount)
    }

    public func union(_ other: CanvasRect) -> CanvasRect {
        let left = min(minX, other.minX), top = min(minY, other.minY)
        return CanvasRect(x: left, y: top, width: max(maxX, other.maxX) - left, height: max(maxY, other.maxY) - top)
    }

    public func offsetBy(_ dx: Double, _ dy: Double) -> CanvasRect {
        CanvasRect(x: x + dx, y: y + dy, width: width, height: height)
    }

    /// The middle of one side: where an edge leaving that side starts.
    public func anchor(_ side: CanvasSide) -> CanvasPoint {
        switch side {
        case .top: return CanvasPoint(x: x + width / 2, y: minY)
        case .right: return CanvasPoint(x: maxX, y: y + height / 2)
        case .bottom: return CanvasPoint(x: x + width / 2, y: maxY)
        case .left: return CanvasPoint(x: minX, y: y + height / 2)
        }
    }

    public static func bounds(_ rects: [CanvasRect]) -> CanvasRect? {
        guard let first = rects.first else { return nil }
        return rects.dropFirst().reduce(first) { $0.union($1) }
    }
}

extension CanvasSide {
    /// The direction an edge leaves this side in.
    public var normal: CanvasPoint {
        switch self {
        case .top: return CanvasPoint(x: 0, y: -1)
        case .right: return CanvasPoint(x: 1, y: 0)
        case .bottom: return CanvasPoint(x: 0, y: 1)
        case .left: return CanvasPoint(x: -1, y: 0)
        }
    }

    public var opposite: CanvasSide {
        switch self {
        case .top: return .bottom
        case .right: return .left
        case .bottom: return .top
        case .left: return .right
        }
    }
}

/// The curve of one edge: a cubic Bézier from one side of a node to a side of another, leaving and entering
/// perpendicular to the sides as Obsidian draws it.
public struct CanvasCurve: Equatable, Sendable {
    public var start: CanvasPoint
    public var control1: CanvasPoint
    public var control2: CanvasPoint
    public var end: CanvasPoint

    public init(start: CanvasPoint, control1: CanvasPoint, control2: CanvasPoint, end: CanvasPoint) {
        self.start = start
        self.control1 = control1
        self.control2 = control2
        self.end = end
    }

    public func point(at t: Double) -> CanvasPoint {
        let u = 1 - t
        return start * (u * u * u) + control1 * (3 * u * u * t) + control2 * (3 * u * t * t) + end * (t * t * t)
    }

    /// Where the label sits.
    public var middle: CanvasPoint { point(at: 0.5) }

    /// Holds the whole curve (a Bézier stays inside its control points).
    public var bounds: CanvasRect {
        let xs = [start.x, control1.x, control2.x, end.x], ys = [start.y, control1.y, control2.y, end.y]
        return CanvasRect(corner: CanvasPoint(x: xs.min()!, y: ys.min()!), CanvasPoint(x: xs.max()!, y: ys.max()!))
    }

    /// The shortest distance from `point` to the curve, sampled: enough to click an edge.
    public func distance(to point: CanvasPoint, samples: Int = 32) -> Double {
        (0...samples).map { (self.point(at: Double($0) / Double(samples)) - point).length }.min() ?? .infinity
    }

    /// The two back corners of an arrow head at `end` (or at `start` when `atStart`), `size` long.
    public func arrowHead(atStart: Bool = false, size: Double = 12) -> (CanvasPoint, CanvasPoint) {
        let tip = atStart ? start : end
        var from = atStart ? control1 : control2
        if (from - tip).length < 0.001 { from = atStart ? end : start }
        let direction = (tip - from) * (1 / max((tip - from).length, 0.001))
        let back = tip - direction * size
        let normal = CanvasPoint(x: -direction.y, y: direction.x) * (size * 0.5)
        return (back + normal, back - normal)
    }
}

public enum CanvasGeometry {
    /// The sides an edge between two nodes uses when the file names none: the facing sides along the axis where
    /// the nodes are furthest apart.
    public static func sides(from a: CanvasRect, to b: CanvasRect) -> (CanvasSide, CanvasSide) {
        let dx = b.center.x - a.center.x, dy = b.center.y - a.center.y
        if abs(dx) >= abs(dy) {
            return dx >= 0 ? (.right, .left) : (.left, .right)
        }
        return dy >= 0 ? (.bottom, .top) : (.top, .bottom)
    }

    public static func curve(from a: CanvasRect, side fromSide: CanvasSide?, to b: CanvasRect,
                             side toSide: CanvasSide?, straight: Bool = false) -> CanvasCurve {
        let automatic = sides(from: a, to: b)
        let start = a.anchor(fromSide ?? automatic.0), end = b.anchor(toSide ?? automatic.1)
        // A Bézier whose control points are its ends is a straight line.
        if straight { return CanvasCurve(start: start, control1: start, control2: end, end: end) }
        let reach = min(max((end - start).length / 2, 40), 200)
        return CanvasCurve(
            start: start,
            control1: start + (fromSide ?? automatic.0).normal * reach,
            control2: end + (toSide ?? automatic.1).normal * reach,
            end: end
        )
    }

    /// The curve of an edge of `document`, or nil when one of its nodes is missing.
    public static func curve(of edge: CanvasEdge, in document: CanvasDocument) -> CanvasCurve? {
        guard let from = document.node(edge.fromNode), let to = document.node(edge.toNode) else { return nil }
        return curve(from: from.frame, side: edge.fromSide, to: to.frame, side: edge.toSide,
                     straight: edge.isStraight)
    }

    /// The nodes inside a group: those whose frame lies entirely within it, nested groups included. JSON Canvas
    /// has no membership field, so this is what moving a group carries along, as in Obsidian.
    public static func members(of group: CanvasNode, in document: CanvasDocument) -> [CanvasNode] {
        document.nodes.filter { $0.id != group.id && group.frame.contains($0.frame) }
    }

    /// The top-left corner where a `size` card goes without covering another card: `preferred` if it is free,
    /// else the next free slot in rows to its right and below. Groups do not count, so a card may land in one.
    public static func freeSpot(for size: (width: Double, height: Double), near preferred: CanvasPoint,
                                in document: CanvasDocument, gap: Double = 40) -> CanvasPoint {
        let obstacles = document.nodes.filter { $0.kind != .group }.map { $0.frame.insetBy(-gap / 2) }
        for row in 0..<200 {
            for column in 0..<8 {
                let point = CanvasPoint(x: preferred.x + Double(column) * (size.width + gap),
                                        y: preferred.y + Double(row) * (size.height + gap))
                let rect = CanvasRect(x: point.x, y: point.y, width: size.width, height: size.height)
                if !obstacles.contains(where: { $0.intersects(rect) }) { return point }
            }
        }
        return preferred
    }
}

/// Which nodes cover a region of the board, without testing them all: a grid of square cells, each listing the
/// nodes that touch it. The view draws only what is on screen, and finds the card under the pointer, through it.
public struct CanvasSpatialIndex: Sendable {
    public let cellSize: Double
    private var cells: [Cell: [Int]] = [:]
    private var frames: [CanvasRect] = []
    private var ids: [String] = []

    private struct Cell: Hashable, Sendable {
        let x: Int
        let y: Int
    }

    public init(nodes: [CanvasNode], cellSize: Double = 512) {
        self.cellSize = cellSize
        for (offset, node) in nodes.enumerated() {
            frames.append(node.frame)
            ids.append(node.id)
            for cell in cells(covering: node.frame) { cells[cell, default: []].append(offset) }
        }
    }

    private func cells(covering rect: CanvasRect) -> [Cell] {
        let x0 = Int((rect.minX / cellSize).rounded(.down)), x1 = Int((rect.maxX / cellSize).rounded(.down))
        let y0 = Int((rect.minY / cellSize).rounded(.down)), y1 = Int((rect.maxY / cellSize).rounded(.down))
        guard x1 - x0 < 4096, y1 - y0 < 4096 else { return [] }
        return (x0...x1).flatMap { x in (y0...y1).map { Cell(x: x, y: $0) } }
    }

    /// The ids of the nodes intersecting `rect`, bottom to top (the board's order).
    public func nodes(in rect: CanvasRect) -> [String] {
        var found = Set<Int>()
        let covering = cells(covering: rect)
        if covering.isEmpty { return ids.indices.filter { frames[$0].intersects(rect) }.map { ids[$0] } }
        for cell in covering {
            for offset in cells[cell] ?? [] where frames[offset].intersects(rect) { found.insert(offset) }
        }
        return found.sorted().map { ids[$0] }
    }

    /// The top-most node under `point`.
    public func node(at point: CanvasPoint) -> String? {
        let cell = Cell(x: Int((point.x / cellSize).rounded(.down)), y: Int((point.y / cellSize).rounded(.down)))
        return (cells[cell] ?? []).filter { frames[$0].contains(point) }.max().map { ids[$0] }
    }
}
