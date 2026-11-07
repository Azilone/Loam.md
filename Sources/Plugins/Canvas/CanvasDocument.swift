import Foundation

/// A board: a JSON Canvas 1.0 file (https://jsoncanvas.org/spec/1.0/), the open format Obsidian also writes.
/// Nodes are listed bottom to top (the array order is the z-order); a card showing a note is a `file` node whose
/// `file` is the note's vault path, so one note can sit on many boards.
///
/// Fields this model does not know (another app's extensions, Advanced Canvas's `styleAttributes`) are kept and
/// written back in their order. `text` writes the file the way Obsidian does: one node or edge per line, so a
/// change is a one-line diff.
public struct CanvasDocument: Equatable, Sendable {
    public var nodes: [CanvasNode]
    public var edges: [CanvasEdge]
    /// Top-level keys other than `nodes` and `edges`.
    public var extra: [(key: String, value: JSONValue)]

    public init(nodes: [CanvasNode] = [], edges: [CanvasEdge] = [], extra: [(key: String, value: JSONValue)] = []) {
        self.nodes = nodes
        self.edges = edges
        self.extra = extra
    }

    public static func == (lhs: CanvasDocument, rhs: CanvasDocument) -> Bool {
        lhs.nodes == rhs.nodes && lhs.edges == rhs.edges && JSONValue.object(lhs.extra) == JSONValue.object(rhs.extra)
    }

    public func node(_ id: String) -> CanvasNode? { nodes.first { $0.id == id } }
    public func edge(_ id: String) -> CanvasEdge? { edges.first { $0.id == id } }
}

public enum CanvasError: Error, Equatable, CustomStringConvertible {
    case notABoard(String)
    case unknownNode(String)
    case unknownEdge(String)
    case invalid(String)

    public var description: String {
        switch self {
        case let .notABoard(reason): return "Not a JSON Canvas board: \(reason)"
        case let .unknownNode(id): return "No node with id \(id) on this board."
        case let .unknownEdge(id): return "No edge with id \(id) on this board."
        case let .invalid(reason): return reason
        }
    }
}

/// The four kinds of node of the spec. Any other type is kept as `other` and drawn as an empty card.
public enum CanvasNodeKind: Equatable, Sendable {
    case text, file, link, group
    case other(String)

    public init(_ raw: String) {
        switch raw {
        case "text": self = .text
        case "file": self = .file
        case "link": self = .link
        case "group": self = .group
        default: self = .other(raw)
        }
    }

    public var rawValue: String {
        switch self {
        case .text: return "text"
        case .file: return "file"
        case .link: return "link"
        case .group: return "group"
        case let .other(raw): return raw
        }
    }
}

public enum CanvasSide: String, CaseIterable, Sendable {
    case top, right, bottom, left
}

public enum CanvasEnd: String, Sendable {
    case none, arrow
}

public struct CanvasNode: Equatable, Sendable {
    public var id: String
    public var kind: CanvasNodeKind
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double
    /// `"#RRGGBB"`, or a preset `"1"` to `"6"` (red, orange, yellow, green, cyan, purple).
    public var color: String?
    /// Markdown, for a text node.
    public var text: String?
    /// The vault path of the file a file node shows.
    public var file: String?
    /// A heading or block of that file, starting with `#`.
    public var subpath: String?
    /// The address a link node shows.
    public var url: String?
    /// A group's title.
    public var label: String?
    /// A group's background image, and how it fills the group (`cover`, `ratio`, `repeat`).
    public var background: String?
    public var backgroundStyle: String?
    /// The size of a text card's font, in board units. An extension of the spec (readers that don't know it keep
    /// it); `nil` is `CanvasNode.defaultFontSize`.
    public var fontSize: Double?
    public var extra: [(key: String, value: JSONValue)]

    public init(
        id: String, kind: CanvasNodeKind, x: Double, y: Double, width: Double, height: Double, color: String? = nil,
        text: String? = nil, file: String? = nil, subpath: String? = nil, url: String? = nil, label: String? = nil,
        background: String? = nil, backgroundStyle: String? = nil, fontSize: Double? = nil,
        extra: [(key: String, value: JSONValue)] = []
    ) {
        self.id = id
        self.kind = kind
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        self.color = color
        self.text = text
        self.file = file
        self.subpath = subpath
        self.url = url
        self.label = label
        self.background = background
        self.backgroundStyle = backgroundStyle
        self.fontSize = fontSize
        self.extra = extra
    }

    /// The font size of a text card that sets none.
    public static let defaultFontSize = 16.0
    /// The sizes the board offers, smallest to largest.
    public static let fontSizes: [Double] = [12, 14, 16, 20, 24, 32, 40, 56, 72]

    /// The size the card is drawn at.
    public var effectiveFontSize: Double { fontSize ?? Self.defaultFontSize }

    /// The next size up or down from the card's, staying within `fontSizes`.
    public func steppedFontSize(larger: Bool) -> Double {
        let current = effectiveFontSize
        if larger { return Self.fontSizes.first { $0 > current + 0.01 } ?? Self.fontSizes.last! }
        return Self.fontSizes.last { $0 < current - 0.01 } ?? Self.fontSizes.first!
    }

    public var frame: CanvasRect {
        get { CanvasRect(x: x, y: y, width: width, height: height) }
        set { x = newValue.x; y = newValue.y; width = newValue.width; height = newValue.height }
    }

    public static func == (lhs: CanvasNode, rhs: CanvasNode) -> Bool {
        lhs.id == rhs.id && lhs.kind == rhs.kind && lhs.frame == rhs.frame && lhs.color == rhs.color
            && lhs.text == rhs.text && lhs.file == rhs.file && lhs.subpath == rhs.subpath && lhs.url == rhs.url
            && lhs.label == rhs.label && lhs.background == rhs.background
            && lhs.backgroundStyle == rhs.backgroundStyle && lhs.fontSize == rhs.fontSize
            && JSONValue.object(lhs.extra) == JSONValue.object(rhs.extra)
    }
}

public enum CanvasEdgeShape: String, Sendable {
    case curve, straight
}

public struct CanvasEdge: Equatable, Sendable {
    public var id: String
    public var fromNode: String
    public var fromSide: CanvasSide?
    /// `none` when absent.
    public var fromEnd: CanvasEnd?
    public var toNode: String
    public var toSide: CanvasSide?
    /// `arrow` when absent.
    public var toEnd: CanvasEnd?
    public var color: String?
    public var label: String?
    /// How the edge is drawn: `curve` when absent. An extension of the spec, kept by readers that don't know it.
    public var shape: CanvasEdgeShape?
    /// Drawn as a dashed line. Also an extension.
    public var dashed: Bool?
    public var extra: [(key: String, value: JSONValue)]

    public init(
        id: String, fromNode: String, fromSide: CanvasSide? = nil, fromEnd: CanvasEnd? = nil, toNode: String,
        toSide: CanvasSide? = nil, toEnd: CanvasEnd? = nil, color: String? = nil, label: String? = nil,
        shape: CanvasEdgeShape? = nil, dashed: Bool? = nil, extra: [(key: String, value: JSONValue)] = []
    ) {
        self.id = id
        self.fromNode = fromNode
        self.fromSide = fromSide
        self.fromEnd = fromEnd
        self.toNode = toNode
        self.toSide = toSide
        self.toEnd = toEnd
        self.color = color
        self.label = label
        self.shape = shape
        self.dashed = dashed
        self.extra = extra
    }

    public var isStraight: Bool { shape == .straight }
    public var isDashed: Bool { dashed == true }
    public var startsWithArrow: Bool { (fromEnd ?? .none) == .arrow }
    public var endsWithArrow: Bool { (toEnd ?? .arrow) == .arrow }

    public static func == (lhs: CanvasEdge, rhs: CanvasEdge) -> Bool {
        lhs.id == rhs.id && lhs.fromNode == rhs.fromNode && lhs.fromSide == rhs.fromSide
            && lhs.fromEnd == rhs.fromEnd && lhs.toNode == rhs.toNode && lhs.toSide == rhs.toSide
            && lhs.toEnd == rhs.toEnd && lhs.color == rhs.color && lhs.label == rhs.label
            && lhs.shape == rhs.shape && lhs.dashed == rhs.dashed && JSONValue.object(lhs.extra) == JSONValue.object(rhs.extra)
    }
}

// MARK: - Reading and writing

extension CanvasDocument {
    /// Reads a board. An empty file is an empty board; a node or edge missing its required fields is an error, so
    /// a board is never silently emptied by a later save.
    public init(text: String) throws {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            self.init()
            return
        }
        let root: JSONValue
        do { root = try JSONValue.parse(text) } catch { throw CanvasError.notABoard("invalid JSON") }
        guard case let .object(pairs) = root else { throw CanvasError.notABoard("not a JSON object") }
        var nodes: [CanvasNode] = []
        var edges: [CanvasEdge] = []
        var extra: [(key: String, value: JSONValue)] = []
        for (key, value) in pairs {
            switch (key, value) {
            case let ("nodes", .array(items)): nodes = try items.map(CanvasNode.init(json:))
            case let ("edges", .array(items)): edges = try items.map(CanvasEdge.init(json:))
            case ("nodes", .null), ("edges", .null): continue
            case ("nodes", _), ("edges", _): throw CanvasError.notABoard("\(key) is not a list")
            default: extra.append((key, value))
            }
        }
        self.init(nodes: nodes, edges: edges, extra: extra)
    }

    /// The file, as Obsidian writes it: tabs, one node or edge per line, a final newline.
    public var text: String {
        var out = "{\n\t\"nodes\":["
        out += nodes.isEmpty ? "]" : "\n" + nodes.map { "\t\t" + $0.json.compact }.joined(separator: ",\n") + "\n\t]"
        out += ",\n\t\"edges\":["
        out += edges.isEmpty ? "]" : "\n" + edges.map { "\t\t" + $0.json.compact }.joined(separator: ",\n") + "\n\t]"
        for (key, value) in extra {
            out += ",\n\t"
            JSONValue.quote(key, into: &out)
            out += ":" + value.compact
        }
        return out + "\n}\n"
    }
}

private func required(_ value: JSONValue?, _ field: String, in what: String) throws -> String {
    guard let string = value?.string, !string.isEmpty else { throw CanvasError.notABoard("\(what) without \(field)") }
    return string
}

extension CanvasNode {
    static let knownKeys: Set<String> = [
        "id", "type", "x", "y", "width", "height", "color", "text", "file", "subpath", "url", "label", "background",
        "backgroundStyle", "fontSize",
    ]

    init(json: JSONValue) throws {
        guard case let .object(pairs) = json else { throw CanvasError.notABoard("a node is not an object") }
        let id = try required(json["id"], "id", in: "a node")
        func number(_ key: String) throws -> Double {
            guard let value = json[key]?.number else { throw CanvasError.notABoard("node \(id) without \(key)") }
            return value
        }
        self.init(
            id: id,
            kind: CanvasNodeKind(try required(json["type"], "type", in: "node \(id)")),
            x: try number("x"), y: try number("y"), width: try number("width"), height: try number("height"),
            color: json["color"]?.string, text: json["text"]?.string, file: json["file"]?.string,
            subpath: json["subpath"]?.string, url: json["url"]?.string, label: json["label"]?.string,
            background: json["background"]?.string, backgroundStyle: json["backgroundStyle"]?.string,
            fontSize: json["fontSize"]?.number,
            extra: pairs.filter { !Self.knownKeys.contains($0.key) }
        )
    }

    /// The spec's fields in the spec's order, then the unknown ones in theirs.
    public var json: JSONValue {
        var pairs: [(key: String, value: JSONValue)] = [
            ("id", .string(id)), ("type", .string(kind.rawValue)),
        ]
        for (key, value) in [("text", text), ("file", file), ("subpath", subpath), ("url", url), ("label", label),
                             ("background", background), ("backgroundStyle", backgroundStyle)] {
            if let value { pairs.append((key, .string(value))) }
        }
        pairs += [("x", .number(x)), ("y", .number(y)), ("width", .number(width)), ("height", .number(height))]
        if let color { pairs.append(("color", .string(color))) }
        if let fontSize { pairs.append(("fontSize", .number(fontSize))) }
        return .object(pairs + extra)
    }
}

extension CanvasEdge {
    static let knownKeys: Set<String> = [
        "id", "fromNode", "fromSide", "fromEnd", "toNode", "toSide", "toEnd", "color", "label", "shape", "dashed",
    ]

    init(json: JSONValue) throws {
        guard case let .object(pairs) = json else { throw CanvasError.notABoard("an edge is not an object") }
        let id = try required(json["id"], "id", in: "an edge")
        self.init(
            id: id,
            fromNode: try required(json["fromNode"], "fromNode", in: "edge \(id)"),
            fromSide: json["fromSide"]?.string.flatMap(CanvasSide.init(rawValue:)),
            fromEnd: json["fromEnd"]?.string.flatMap(CanvasEnd.init(rawValue:)),
            toNode: try required(json["toNode"], "toNode", in: "edge \(id)"),
            toSide: json["toSide"]?.string.flatMap(CanvasSide.init(rawValue:)),
            toEnd: json["toEnd"]?.string.flatMap(CanvasEnd.init(rawValue:)),
            color: json["color"]?.string,
            label: json["label"]?.string,
            shape: json["shape"]?.string.flatMap(CanvasEdgeShape.init(rawValue:)),
            dashed: json["dashed"]?.bool,
            extra: pairs.filter { !Self.knownKeys.contains($0.key) }
        )
    }

    public var json: JSONValue {
        var pairs: [(key: String, value: JSONValue)] = [("id", .string(id)), ("fromNode", .string(fromNode))]
        if let fromSide { pairs.append(("fromSide", .string(fromSide.rawValue))) }
        if let fromEnd { pairs.append(("fromEnd", .string(fromEnd.rawValue))) }
        pairs.append(("toNode", .string(toNode)))
        if let toSide { pairs.append(("toSide", .string(toSide.rawValue))) }
        if let toEnd { pairs.append(("toEnd", .string(toEnd.rawValue))) }
        if let color { pairs.append(("color", .string(color))) }
        if let label { pairs.append(("label", .string(label))) }
        if let shape { pairs.append(("shape", .string(shape.rawValue))) }
        if let dashed { pairs.append(("dashed", .bool(dashed))) }
        return .object(pairs + extra)
    }
}
