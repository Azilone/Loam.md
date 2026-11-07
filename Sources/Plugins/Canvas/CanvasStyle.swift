import Foundation

/// The shape a text card is drawn as. Written as Advanced Canvas writes it (the "Advanced JSON Canvas" format of the
/// Obsidian plugin): `styleAttributes.shape` on the node, absent for the plain card (`rectangle`).
public enum CanvasNodeShape: String, CaseIterable, Sendable {
    case rectangle, pill, diamond, parallelogram, circle
    case predefinedProcess = "predefined-process"
    case document, database

    public var name: String {
        switch self {
        case .rectangle: return "Rectangle"
        case .pill: return "Pill"
        case .diamond: return "Diamond"
        case .parallelogram: return "Parallelogram"
        case .circle: return "Circle"
        case .predefinedProcess: return "Process"
        case .document: return "Document"
        case .database: return "Database"
        }
    }

    /// The size a new card of this shape gets.
    public var defaultSize: (width: Double, height: Double) {
        switch self {
        case .rectangle: return (240, 140)
        case .pill: return (240, 100)
        case .diamond: return (240, 180)
        case .parallelogram: return (260, 120)
        case .circle: return (180, 180)
        case .predefinedProcess: return (260, 120)
        case .document: return (240, 150)
        case .database: return (200, 200)
        }
    }

    /// The part of the frame text goes in, as fractions of the width and height from each edge: inside a diamond or
    /// a circle text needs the middle, not the corners.
    public var textInsets: (top: Double, left: Double, bottom: Double, right: Double) {
        switch self {
        case .rectangle: return (0, 0, 0, 0)
        case .pill: return (0, 0.12, 0, 0.12)
        case .diamond: return (0.25, 0.25, 0.25, 0.25)
        case .parallelogram: return (0, 0.16, 0, 0.16)
        case .circle: return (0.146, 0.146, 0.146, 0.146)
        case .predefinedProcess: return (0, 0.1, 0, 0.1)
        case .document: return (0, 0, 0.14, 0)
        case .database: return (0.2, 0, 0.1, 0)
        }
    }

    /// The frame text goes in, for a card of this shape at `frame`.
    public func textRect(in frame: CanvasRect) -> CanvasRect {
        let inset = textInsets
        return CanvasRect(x: frame.x + frame.width * inset.left, y: frame.y + frame.height * inset.top,
                          width: frame.width * (1 - inset.left - inset.right),
                          height: frame.height * (1 - inset.top - inset.bottom))
    }
}

/// How a card's outline is drawn (`styleAttributes.border`): `invisible` draws neither outline nor paper, for text
/// standing on the board by itself.
public enum CanvasBorder: String, CaseIterable, Sendable {
    case solid, dashed, dotted, invisible
}

/// Where a card's text lines up (`styleAttributes.textAlign`).
public enum CanvasTextAlign: String, CaseIterable, Sendable {
    case left, center, right
}

extension CanvasNode {
    /// One of Advanced Canvas's `styleAttributes`.
    public func styleAttribute(_ key: String) -> JSONValue? {
        extraValue("styleAttributes")?[key]
    }

    /// Sets or removes (nil) one style attribute; `styleAttributes` goes away when it holds nothing.
    public mutating func setStyleAttribute(_ key: String, _ value: JSONValue?) {
        var pairs: [(key: String, value: JSONValue)] = []
        if case let .object(existing) = extraValue("styleAttributes") { pairs = existing }
        if let value {
            if let index = pairs.firstIndex(where: { $0.key == key }) { pairs[index].value = value } else {
                pairs.append((key, value))
            }
        } else {
            pairs.removeAll { $0.key == key }
        }
        setExtra("styleAttributes", pairs.isEmpty ? nil : .object(pairs))
    }

    /// A field this model does not name (another app's), by key.
    public func extraValue(_ key: String) -> JSONValue? {
        extra.first { $0.key == key }?.value
    }

    /// Sets a field kept in `extra` where it was, or adds it at the end; nil removes it.
    public mutating func setExtra(_ key: String, _ value: JSONValue?) {
        if let value {
            if let index = extra.firstIndex(where: { $0.key == key }) { extra[index].value = value } else {
                extra.append((key, value))
            }
        } else {
            extra.removeAll { $0.key == key }
        }
    }

    /// The card's shape; nil is the plain card.
    public var shape: CanvasNodeShape? {
        get { styleAttribute("shape")?.string.flatMap(CanvasNodeShape.init(rawValue:)).flatMap { $0 == .rectangle ? nil : $0 } }
        set { setStyleAttribute("shape", newValue.flatMap { $0 == .rectangle ? nil : .string($0.rawValue) }) }
    }

    /// The card's outline; nil is solid.
    public var border: CanvasBorder? {
        get { styleAttribute("border")?.string.flatMap(CanvasBorder.init(rawValue:)).flatMap { $0 == .solid ? nil : $0 } }
        set { setStyleAttribute("border", newValue.flatMap { $0 == .solid ? nil : .string($0.rawValue) }) }
    }

    /// Where the card's text lines up; nil is left.
    public var textAlign: CanvasTextAlign? {
        get { styleAttribute("textAlign")?.string.flatMap(CanvasTextAlign.init(rawValue:)).flatMap { $0 == .left ? nil : $0 } }
        set { setStyleAttribute("textAlign", newValue.flatMap { $0 == .left ? nil : .string($0.rawValue) }) }
    }

    /// Text standing on the board by itself, with no card around it (an invisible border, no shape): it is as big
    /// as its text, and resizing it scales the text.
    public var isFreeText: Bool { kind == .text && border == .invisible && shape == nil && !CanvasInk.isDrawing(text)
        && !CanvasTable.isTable(text) }

    /// A sticky note: a square card of solid colour (`styleAttributes.sticky`, a Loam attribute other apps keep; they
    /// show a coloured card).
    public var isSticky: Bool {
        get { kind == .text && styleAttribute("sticky")?.bool == true }
        set { setStyleAttribute("sticky", newValue ? .bool(true) : nil) }
    }

    /// A text card drawn as a shape, or with centred text: its text sits in the middle, up and down too.
    public var centresText: Bool { shape != nil || textAlign == .center }

    /// The proportions (width / height) a card keeps when resized (`ratio`, Advanced Canvas's): a slide's.
    public var ratio: Double? {
        get { extraValue("ratio")?.number.flatMap { $0 > 0 && $0.isFinite ? $0 : nil } }
        set { setExtra("ratio", newValue.map { .number($0) }) }
    }
}

extension CanvasDocument {
    /// A field of the board's `metadata` object (Advanced Canvas's).
    public func metadata(_ key: String) -> JSONValue? {
        extra.first { $0.key == "metadata" }?.value[key]
    }

    /// Sets or removes a field of `metadata`, keeping the others; `metadata` goes away when it holds nothing.
    public mutating func setMetadata(_ key: String, _ value: JSONValue?) {
        var pairs: [(key: String, value: JSONValue)] = []
        let index = extra.firstIndex { $0.key == "metadata" }
        if let index, case let .object(existing) = extra[index].value { pairs = existing }
        if let value {
            if let at = pairs.firstIndex(where: { $0.key == key }) { pairs[at].value = value } else { pairs.append((key, value)) }
        } else {
            pairs.removeAll { $0.key == key }
        }
        if let index {
            if pairs.isEmpty { extra.remove(at: index) } else { extra[index].value = .object(pairs) }
        } else if !pairs.isEmpty {
            extra.append(("metadata", .object(pairs)))
        }
    }

    /// The node a presentation starts at (`metadata.startNode`).
    public var startNode: String? {
        get { metadata("startNode")?.string }
        set { setMetadata("startNode", newValue.map { .string($0) }) }
    }
}
