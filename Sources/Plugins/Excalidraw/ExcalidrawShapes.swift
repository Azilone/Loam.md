import Foundation

/// Drawing from a command: a labelled shape, an arrow between two shapes. Builds the elements Excalidraw writes itself
/// (text bound to its container, arrows bound to both ends), so the drawing opens and edits as one made by hand.
public extension ExcalidrawDocument {
    static let shapeTypes = ["rectangle", "ellipse", "diamond", "text"]

    /// Excalidraw's own light fills, by name; a `#RRGGBB` is kept as it is.
    static func fill(_ color: String?) -> String {
        guard let color, !color.isEmpty else { return "transparent" }
        if color.hasPrefix("#") { return color }
        let named = ["blue": "#a5d8ff", "green": "#b2f2bb", "yellow": "#ffec99", "red": "#ffc9c9",
                     "purple": "#d0bfff", "orange": "#ffd8a8", "gray": "#e9ecef", "grey": "#e9ecef"]
        return named[color.lowercased()] ?? "transparent"
    }

    private var drawnElements: [[String: Any]] {
        (scene["elements"] as? [[String: Any]] ?? []).filter { ($0["isDeleted"] as? Bool) != true }
    }

    /// The shapes and free texts, with the text shown in each: what `connect` takes as ends.
    var shapes: [(id: String, type: String, text: String)] {
        let all = drawnElements
        var bound: [String: String] = [:]
        for element in all where element["type"] as? String == "text" {
            if let container = element["containerId"] as? String { bound[container] = Self.rawText(of: element) }
        }
        return all.compactMap { element in
            guard let id = element["id"] as? String, let type = element["type"] as? String, type != "arrow",
                  element["containerId"] as? String == nil else { return nil }
            return (id, type, type == "text" ? Self.rawText(of: element) : bound[id] ?? "")
        }
    }

    /// Adds a shape with `text` centred in it, or a free text, and returns its id. Without `x`/`y` it goes right of
    /// the last shape, on the same line.
    mutating func addShape(type: String, text: String, x: Double?, y: Double?, width: Double?, height: Double?,
                           color: String?) throws -> String {
        guard Self.shapeTypes.contains(type) else {
            throw ExcalidrawError.invalid("type must be one of \(Self.shapeTypes.joined(separator: ", ")).")
        }
        let lines = text.components(separatedBy: "\n")
        let fontSize = 20.0
        let textWidth = Double(lines.map(\.count).max() ?? 0) * fontSize * 0.6
        let textHeight = Double(lines.count) * fontSize * 1.25
        let width = width ?? (type == "text" ? textWidth : max(160, textWidth + 40))
        let height = height ?? (type == "text" ? textHeight : max(80, textHeight + 40))
        let last = drawnElements.last { $0["type"] as? String != "arrow" && $0["containerId"] as? String == nil }
        let x = x ?? last.map { ($0["x"] as? Double ?? 0) + ($0["width"] as? Double ?? 0) + 100 } ?? 0
        let y = y ?? (last?["y"] as? Double ?? 0)
        let id = Self.newID()
        var elements = scene["elements"] as? [[String: Any]] ?? []
        if type == "text" {
            elements.append(Self.text(text, id: id, x: x, y: y, width: width, height: height, container: nil))
        } else {
            let textID = Self.newID()
            var shape = Self.base(type: type, id: id, x: x, y: y, width: width, height: height)
            shape["backgroundColor"] = Self.fill(color)
            shape["roundness"] = type == "rectangle" ? ["type": 3] : ["type": 2]
            shape["boundElements"] = text.isEmpty ? [] : [["type": "text", "id": textID]]
            elements.append(shape)
            if !text.isEmpty {
                elements.append(Self.text(text, id: textID, x: x + (width - textWidth) / 2, y: y + (height - textHeight) / 2,
                                          width: textWidth, height: textHeight, container: id))
            }
        }
        scene["elements"] = elements
        return id
    }

    /// Draws an arrow from one shape to another, bound to both, and returns its id.
    mutating func connect(from: String, to: String, label: String?) throws -> String {
        var elements = scene["elements"] as? [[String: Any]] ?? []
        guard let start = elements.firstIndex(where: { $0["id"] as? String == from && ($0["isDeleted"] as? Bool) != true }),
              let end = elements.firstIndex(where: { $0["id"] as? String == to && ($0["isDeleted"] as? Bool) != true })
        else { throw ExcalidrawError.invalid("from and to must be ids of shapes in the drawing (excalidraw.read lists texts).") }
        func box(_ e: [String: Any]) -> (x: Double, y: Double, w: Double, h: Double) {
            (e["x"] as? Double ?? 0, e["y"] as? Double ?? 0, e["width"] as? Double ?? 0, e["height"] as? Double ?? 0)
        }
        let a = box(elements[start]), b = box(elements[end])
        let horizontal = abs((b.x + b.w / 2) - (a.x + a.w / 2)) >= abs((b.y + b.h / 2) - (a.y + a.h / 2))
        let gap = 8.0
        let (sx, sy, ex, ey): (Double, Double, Double, Double) = horizontal
            ? (b.x > a.x ? (a.x + a.w + gap, a.y + a.h / 2, b.x - gap, b.y + b.h / 2)
                         : (a.x - gap, a.y + a.h / 2, b.x + b.w + gap, b.y + b.h / 2))
            : (b.y > a.y ? (a.x + a.w / 2, a.y + a.h + gap, b.x + b.w / 2, b.y - gap)
                         : (a.x + a.w / 2, a.y - gap, b.x + b.w / 2, b.y + b.h + gap))
        let id = Self.newID()
        var arrow = Self.base(type: "arrow", id: id, x: sx, y: sy, width: abs(ex - sx), height: abs(ey - sy))
        arrow["points"] = [[0.0, 0.0], [ex - sx, ey - sy]]
        arrow["roundness"] = ["type": 2]
        arrow["startBinding"] = ["elementId": from, "focus": 0, "gap": gap]
        arrow["endBinding"] = ["elementId": to, "focus": 0, "gap": gap]
        arrow["startArrowhead"] = NSNull()
        arrow["endArrowhead"] = "arrow"
        arrow["lastCommittedPoint"] = NSNull()
        var bound: [[String: Any]] = []
        if let label, !label.isEmpty {
            let textID = Self.newID()
            let w = Double(label.count) * 12, h = 25.0
            elements.append(Self.text(label, id: textID, x: (sx + ex) / 2 - w / 2, y: (sy + ey) / 2 - h / 2,
                                      width: w, height: h, container: id, fontSize: 16))
            bound.append(["type": "text", "id": textID])
        }
        arrow["boundElements"] = bound
        for index in [start, end] {
            var others = elements[index]["boundElements"] as? [[String: Any]] ?? []
            others.append(["type": "arrow", "id": id])
            elements[index]["boundElements"] = others
        }
        elements.append(arrow)
        scene["elements"] = elements
        return id
    }

    private static func base(type: String, id: String, x: Double, y: Double, width: Double, height: Double) -> [String: Any] {
        [
            "id": id, "type": type, "x": x, "y": y, "width": width, "height": height, "angle": 0,
            "strokeColor": "#1e1e1e", "backgroundColor": "transparent", "fillStyle": "solid", "strokeWidth": 2,
            "strokeStyle": "solid", "roughness": 1, "opacity": 100, "groupIds": [Any](), "frameId": NSNull(),
            "roundness": NSNull(), "seed": Int.random(in: 1...2_000_000_000), "version": 1,
            "versionNonce": Int.random(in: 1...2_000_000_000), "isDeleted": false, "boundElements": [Any](),
            "updated": Int(Date().timeIntervalSince1970 * 1000), "link": NSNull(), "locked": false,
        ]
    }

    private static func text(_ text: String, id: String, x: Double, y: Double, width: Double, height: Double,
                             container: String?, fontSize: Double = 20) -> [String: Any] {
        var element = base(type: "text", id: id, x: x, y: y, width: width, height: height)
        element["text"] = text
        element["originalText"] = text
        element["fontSize"] = fontSize
        element["fontFamily"] = 5
        element["textAlign"] = container == nil ? "left" : "center"
        element["verticalAlign"] = container == nil ? "top" : "middle"
        element["containerId"] = container.map { $0 as Any } ?? NSNull()
        element["lineHeight"] = 1.25
        element["autoResize"] = true
        return element
    }

    private static func newID() -> String {
        let letters = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        return String((0..<20).map { _ in letters.randomElement()! })
    }
}
