import Foundation

/// A drawing on the board: pen strokes, or one free line or arrow, kept as a text node whose text is an inline SVG
/// (HTML a Markdown reader shows as the drawing; Obsidian does) with an invisible border. `data-loam` on the `svg`
/// says which: `ink` (strokes) or `line`. Coordinates are relative to the node, in board units, and the `viewBox` is
/// the node's size, so the picture fills its card wherever it is drawn.
///
/// A stroke is written as quadratic curves through the middles of its points, with the points as control points:
/// smooth for any SVG reader, and read back to the exact points.
public struct CanvasInk: Equatable, Sendable {
    public enum Kind: String, Sendable {
        case ink, line
    }

    public var kind: Kind
    public var strokes: [CanvasInkStroke]
    /// For a line: heads at its start and end.
    public var startArrow: Bool
    public var endArrow: Bool

    public init(kind: Kind = .ink, strokes: [CanvasInkStroke], startArrow: Bool = false, endArrow: Bool = false) {
        self.kind = kind
        self.strokes = strokes
        self.startArrow = startArrow
        self.endArrow = endArrow
    }

    /// The color presets as SVG writes them: the six of JSON Canvas, as the board draws them.
    public static let presets: [String: String] = [
        "1": "#E84A4A", "2": "#F08C33", "3": "#EBBF21", "4": "#45B066", "5": "#33ABC9", "6": "#9966D9",
    ]

    /// The smallest box holding every stroke, its width included.
    public var bounds: CanvasRect? {
        CanvasRect.bounds(strokes.compactMap { stroke in
            CanvasRect.bounds(stroke.points.map { CanvasRect(x: $0.x, y: $0.y, width: 0, height: 0) })?
                .insetBy(-stroke.width / 2 - 1)
        })
    }

    public func offsetBy(_ dx: Double, _ dy: Double) -> CanvasInk {
        var copy = self
        copy.strokes = strokes.map { stroke in
            var moved = stroke
            moved.points = stroke.points.map { CanvasPoint(x: $0.x + dx, y: $0.y + dy) }
            return moved
        }
        return copy
    }

    /// Scaled about the origin by `sx`, `sy` (a resized node).
    public func scaledBy(_ sx: Double, _ sy: Double) -> CanvasInk {
        var copy = self
        copy.strokes = strokes.map { stroke in
            var scaled = stroke
            scaled.points = stroke.points.map { CanvasPoint(x: $0.x * sx, y: $0.y * sy) }
            return scaled
        }
        return copy
    }

    /// The two ends of a line.
    public var ends: (CanvasPoint, CanvasPoint)? {
        guard kind == .line, let stroke = strokes.first, let first = stroke.points.first, let last = stroke.points.last
        else { return nil }
        return (first, last)
    }

    /// The strokes that pass within `radius` of `point`: what an eraser there takes away.
    public func strokes(near point: CanvasPoint, radius: Double) -> IndexSet {
        IndexSet(strokes.indices.filter { strokes[$0].distance(to: point) <= radius + strokes[$0].width / 2 })
    }

    // MARK: SVG

    /// Whether a text node's text is a drawing, without reading it all.
    public static func isDrawing(_ text: String?) -> Bool {
        guard let text, text.hasPrefix("<svg") else { return false }
        return text.prefix(200).contains("data-loam=\"")
    }

    /// The drawing a text node holds; nil when it is not one of Loam's drawings.
    public init?(svg text: String) {
        guard Self.isDrawing(text), let open = text.range(of: ">") else { return nil }
        let root = Self.attributes(String(text[text.startIndex..<open.lowerBound]))
        guard let kind = root["data-loam"].flatMap(Kind.init(rawValue:)) else { return nil }
        var strokes: [CanvasInkStroke] = []
        var rest = text[open.upperBound...]
        while let start = rest.range(of: "<path") {
            guard let end = rest[start.upperBound...].range(of: ">") else { break }
            let attributes = Self.attributes(String(rest[start.upperBound..<end.lowerBound]))
            rest = rest[end.upperBound...]
            // A line's heads are drawn from its ends, not read.
            guard attributes["data-head"] == nil, let d = attributes["d"] else { continue }
            let points = Self.points(d)
            guard !points.isEmpty else { continue }
            strokes.append(CanvasInkStroke(
                points: points,
                color: attributes["data-color"] ?? attributes["stroke"].flatMap { $0 == "currentColor" ? nil : $0 },
                width: attributes["stroke-width"].flatMap(Double.init) ?? 3,
                opacity: attributes["stroke-opacity"].flatMap(Double.init) ?? 1,
                dashed: attributes["stroke-dasharray"] != nil
            ))
        }
        self.init(kind: kind, strokes: strokes, startArrow: root["data-start"] == "arrow",
                  endArrow: root["data-end"] == "arrow")
    }

    /// The SVG of the drawing for a node `width` by `height`.
    public func svg(width: Double, height: Double) -> String {
        var out = "<svg xmlns=\"http://www.w3.org/2000/svg\" data-loam=\"\(kind.rawValue)\""
        if startArrow { out += " data-start=\"arrow\"" }
        if endArrow { out += " data-end=\"arrow\"" }
        out += " viewBox=\"0 0 \(Self.number(width)) \(Self.number(height))\" width=\"100%\" height=\"100%\""
        out += " preserveAspectRatio=\"none\" fill=\"none\" stroke-linecap=\"round\" stroke-linejoin=\"round\">"
        for stroke in strokes {
            out += "<path d=\"\(stroke.pathData)\"" + stroke.paint + "/>"
        }
        if kind == .line, let stroke = strokes.first, let (start, end) = ends {
            if startArrow { out += head(at: start, from: stroke.points.dropFirst().first ?? end, stroke: stroke) }
            if endArrow { out += head(at: end, from: stroke.points.dropLast().last ?? start, stroke: stroke) }
        }
        return out + "</svg>"
    }

    private func head(at tip: CanvasPoint, from: CanvasPoint, stroke: CanvasInkStroke) -> String {
        let (left, right) = Self.arrowHead(tip: tip, from: from, size: Self.headSize(stroke.width))
        var plain = stroke
        plain.dashed = false
        return "<path data-head=\"1\" d=\"M\(Self.number(left.x)) \(Self.number(left.y))L\(Self.number(tip.x)) "
            + "\(Self.number(tip.y))L\(Self.number(right.x)) \(Self.number(right.y))\"" + plain.paint + "/>"
    }

    /// How long an arrow head is for a line `width` wide.
    public static func headSize(_ width: Double) -> Double { max(12, width * 4) }

    /// The two back corners of an arrow head at `tip`, coming from `from`.
    public static func arrowHead(tip: CanvasPoint, from: CanvasPoint, size: Double) -> (CanvasPoint, CanvasPoint) {
        var direction = tip - from
        let length = max(direction.length, 0.001)
        direction = direction * (1 / length)
        let back = tip - direction * size
        let normal = CanvasPoint(x: -direction.y, y: direction.x) * (size * 0.55)
        return (back + normal, back - normal)
    }

    static func number(_ value: Double) -> String {
        let rounded = (value * 10).rounded() / 10
        return rounded == rounded.rounded() ? String(Int(rounded)) : String(rounded)
    }

    /// `key="value"` pairs of a tag.
    static func attributes(_ tag: String) -> [String: String] {
        var result: [String: String] = [:]
        var rest = Substring(tag)
        while let equals = rest.range(of: "=\"") {
            let key = rest[rest.startIndex..<equals.lowerBound].split(whereSeparator: { $0 == " " || $0 == "\n" }).last
            guard let close = rest[equals.upperBound...].range(of: "\"") else { break }
            if let key { result[String(key)] = String(rest[equals.upperBound..<close.lowerBound]) }
            rest = rest[close.upperBound...]
        }
        return result
    }

    /// The points of a path written by `pathData`: `M`, then `Q` (whose control points are the points) or `L`.
    static func points(_ d: String) -> [CanvasPoint] {
        var numbers: [Double] = []
        var commands: [(Character, Int)] = []
        var token = ""
        func flush() {
            if let value = Double(token) { numbers.append(value) }
            token = ""
        }
        for character in d {
            if "MLQmlq".contains(character) {
                flush()
                commands.append((character, numbers.count))
            } else if character == " " || character == "," {
                flush()
            } else if character == "-", !token.isEmpty, token.last != "e" {
                flush()
                token.append(character)
            } else {
                token.append(character)
            }
        }
        flush()
        var points: [CanvasPoint] = []
        for (index, (command, start)) in commands.enumerated() {
            let end = index + 1 < commands.count ? commands[index + 1].1 : numbers.count
            let values = Array(numbers[start..<end])
            switch command {
            case "M", "L":
                stride(from: 0, to: values.count - 1, by: 2).forEach { points.append(CanvasPoint(x: values[$0], y: values[$0 + 1])) }
            case "Q":
                // The control point is the stroke's point; the end, the middle to the next one, is not.
                if values.count >= 2 { points.append(CanvasPoint(x: values[0], y: values[1])) }
            default:
                continue
            }
        }
        return points
    }
}

public struct CanvasInkStroke: Equatable, Sendable {
    public var points: [CanvasPoint]
    /// A preset (`"1"`…`"6"`) or `#RRGGBB`; nil is the text colour, which follows the theme.
    public var color: String?
    public var width: Double
    /// 1 for a pen, less for a highlighter.
    public var opacity: Double
    public var dashed: Bool

    public init(points: [CanvasPoint], color: String? = nil, width: Double = 3, opacity: Double = 1, dashed: Bool = false) {
        self.points = points
        self.color = color
        self.width = width
        self.opacity = opacity
        self.dashed = dashed
    }

    /// `M`, `Q` through the middles, `L` to the last point.
    public var pathData: String {
        let n = CanvasInk.number
        guard let first = points.first else { return "" }
        var out = "M\(n(first.x)) \(n(first.y))"
        if points.count == 1 { return out + "L\(n(first.x)) \(n(first.y))" }
        for index in 1..<points.count - 1 {
            let point = points[index], next = points[index + 1]
            out += "Q\(n(point.x)) \(n(point.y)) \(n((point.x + next.x) / 2)) \(n((point.y + next.y) / 2))"
        }
        let last = points[points.count - 1]
        return out + "L\(n(last.x)) \(n(last.y))"
    }

    /// The stroke's paint attributes: a preset's colour (named in `data-color` too, so it reads back as the preset).
    var paint: String {
        var out = ""
        if let color, let hex = CanvasInk.presets[color] {
            out += " stroke=\"\(hex)\" data-color=\"\(color)\""
        } else {
            out += " stroke=\"\(color ?? "currentColor")\""
        }
        out += " stroke-width=\"\(CanvasInk.number(width))\""
        if opacity < 1 { out += " stroke-opacity=\"\(String(format: "%.2f", opacity))\"" }
        if dashed { out += " stroke-dasharray=\"\(CanvasInk.number(width * 3)) \(CanvasInk.number(width * 2.5))\"" }
        return out
    }

    /// The shortest distance from `point` to the stroke's segments.
    public func distance(to point: CanvasPoint) -> Double {
        guard let first = points.first else { return .infinity }
        guard points.count > 1 else { return (first - point).length }
        var best = Double.infinity
        for index in 1..<points.count {
            let a = points[index - 1], b = points[index]
            let ab = b - a
            let t = max(0, min(1, ((point.x - a.x) * ab.x + (point.y - a.y) * ab.y) / max(ab.x * ab.x + ab.y * ab.y, 1e-9)))
            best = min(best, (a + ab * t - point).length)
        }
        return best
    }

    /// Fewer points along the same line (Ramer–Douglas–Peucker): what a fast hand leaves is mostly redundant.
    public static func simplify(_ points: [CanvasPoint], tolerance: Double) -> [CanvasPoint] {
        guard points.count > 2 else { return points }
        var keep = [Bool](repeating: false, count: points.count)
        keep[0] = true
        keep[points.count - 1] = true
        var stack = [(0, points.count - 1)]
        while let (start, end) = stack.popLast() {
            let segment = CanvasInkStroke(points: [points[start], points[end]])
            var farthest = (index: -1, distance: tolerance)
            for index in (start + 1)..<end {
                let distance = segment.distance(to: points[index])
                if distance > farthest.distance { farthest = (index, distance) }
            }
            if farthest.index >= 0 {
                keep[farthest.index] = true
                stack.append((start, farthest.index))
                stack.append((farthest.index, end))
            }
        }
        return points.indices.filter { keep[$0] }.map { points[$0] }
    }
}

extension CanvasNode {
    /// A drawing (strokes or a free line), kept as an inline SVG in a text node.
    public var isDrawing: Bool { kind == .text && CanvasInk.isDrawing(text) }

    /// The node holding `ink`, placed so its strokes keep their place on the board: `ink` is in board units, the
    /// node's frame becomes its bounds and its strokes relative to it.
    public static func drawing(id: String, _ ink: CanvasInk) -> CanvasNode? {
        guard let bounds = ink.bounds else { return nil }
        var node = CanvasNode(id: id, kind: .text, x: bounds.x.rounded(.down), y: bounds.y.rounded(.down),
                              width: max(1, bounds.width.rounded(.up) + 1), height: max(1, bounds.height.rounded(.up) + 1))
        node.text = ink.offsetBy(-node.x, -node.y).svg(width: node.width, height: node.height)
        node.border = .invisible
        return node
    }

    /// The drawing in board units; nil when the node is not one.
    public var drawing: CanvasInk? {
        guard kind == .text, let text, let ink = CanvasInk(svg: text) else { return nil }
        return ink.offsetBy(x, y)
    }
}
