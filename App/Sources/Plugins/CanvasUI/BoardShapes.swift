import PluginKitUI
import CanvasPlugin
import SwiftUI

/// The outline of a card: the board's rounded card, or one of Advanced Canvas's shapes (a pill, a diamond, a circle,
/// a parallelogram, a process box, a document, a database). Drawn at the size it is given, so the same shape clips the
/// card, carries its glass and rings it when selected.
struct BoardShape: InsettableShape {
    var shape: CanvasNodeShape?
    /// The plain card's corner radius, in the points the shape is drawn in.
    var radius: CGFloat
    var inset: CGFloat = 0

    init(_ shape: CanvasNodeShape?, radius: CGFloat) {
        self.shape = shape
        self.radius = radius
    }

    func inset(by amount: CGFloat) -> BoardShape {
        var copy = self
        copy.inset += amount
        return copy
    }

    func path(in frame: CGRect) -> Path {
        let rect = frame.insetBy(dx: inset, dy: inset)
        guard rect.width > 0, rect.height > 0 else { return Path() }
        switch shape {
        case nil, .rectangle?:
            return RoundedRectangle(cornerRadius: Corners.r(max(0, radius - inset)), style: .continuous).path(in: rect)
        case .pill?:
            return ThemeCapsule(style: .circular).path(in: rect)
        case .circle?:
            return Ellipse().path(in: rect)
        case .diamond?:
            return Self.rounded([
                CGPoint(x: rect.midX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.midY),
                CGPoint(x: rect.midX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.midY),
            ], corner: min(rect.width, rect.height) * 0.06)
        case .parallelogram?:
            let skew = rect.width * 0.16
            return Self.rounded([
                CGPoint(x: rect.minX + skew, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
                CGPoint(x: rect.maxX - skew, y: rect.maxY), CGPoint(x: rect.minX, y: rect.maxY),
            ], corner: min(rect.width, rect.height) * 0.06)
        case .predefinedProcess?:
            return RoundedRectangle(cornerRadius: Corners.r(max(0, radius * 0.5 - inset)), style: .continuous).path(in: rect)
        case .document?:
            var path = Path()
            let wave = rect.height * 0.1
            let corner = min(radius * 0.5, rect.width / 4)
            path.move(to: CGPoint(x: rect.minX, y: rect.maxY - wave))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + corner))
            path.addQuadCurve(to: CGPoint(x: rect.minX + corner, y: rect.minY), control: CGPoint(x: rect.minX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX - corner, y: rect.minY))
            path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY + corner), control: CGPoint(x: rect.maxX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - wave))
            path.addCurve(to: CGPoint(x: rect.minX, y: rect.maxY - wave),
                          control1: CGPoint(x: rect.maxX - rect.width * 0.3, y: rect.maxY - wave * 3),
                          control2: CGPoint(x: rect.minX + rect.width * 0.3, y: rect.maxY + wave))
            path.closeSubpath()
            return path
        case .database?:
            var path = Path()
            let cap = min(rect.height * 0.12, rect.width * 0.25)
            path.move(to: CGPoint(x: rect.minX, y: rect.minY + cap))
            path.addCurve(to: CGPoint(x: rect.maxX, y: rect.minY + cap),
                          control1: CGPoint(x: rect.minX, y: rect.minY - cap / 3),
                          control2: CGPoint(x: rect.maxX, y: rect.minY - cap / 3))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - cap))
            path.addCurve(to: CGPoint(x: rect.minX, y: rect.maxY - cap),
                          control1: CGPoint(x: rect.maxX, y: rect.maxY + cap / 3),
                          control2: CGPoint(x: rect.minX, y: rect.maxY + cap / 3))
            path.closeSubpath()
            return path
        }
    }

    /// The lines drawn inside a shape on top of its outline: a process box's two inner sides, a database's rim.
    func details(in frame: CGRect) -> Path {
        let rect = frame.insetBy(dx: inset, dy: inset)
        var path = Path()
        switch shape {
        case .predefinedProcess?:
            let side = rect.width * 0.1
            path.move(to: CGPoint(x: rect.minX + side, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.minX + side, y: rect.maxY))
            path.move(to: CGPoint(x: rect.maxX - side, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX - side, y: rect.maxY))
        case .database?:
            let cap = min(rect.height * 0.12, rect.width * 0.25)
            path.move(to: CGPoint(x: rect.minX, y: rect.minY + cap))
            path.addCurve(to: CGPoint(x: rect.maxX, y: rect.minY + cap),
                          control1: CGPoint(x: rect.minX, y: rect.minY + cap * 5 / 3),
                          control2: CGPoint(x: rect.maxX, y: rect.minY + cap * 5 / 3))
        default:
            break
        }
        return path
    }

    var hasDetails: Bool { shape == .predefinedProcess || shape == .database }

    /// A closed polygon with its corners rounded by `corner`.
    private static func rounded(_ points: [CGPoint], corner: CGFloat) -> Path {
        var path = Path()
        let count = points.count
        for index in 0..<count {
            let previous = points[(index + count - 1) % count], point = points[index], next = points[(index + 1) % count]
            func toward(_ other: CGPoint) -> CGPoint {
                let dx = other.x - point.x, dy = other.y - point.y
                let length = max(hypot(dx, dy), 0.001)
                let reach = min(corner, length / 2)
                return CGPoint(x: point.x + dx / length * reach, y: point.y + dy / length * reach)
            }
            let start = toward(previous), end = toward(next)
            if index == 0 { path.move(to: start) } else { path.addLine(to: start) }
            path.addQuadCurve(to: end, control: point)
        }
        path.closeSubpath()
        return path
    }
}

/// The inner lines of a shape, as a shape of their own to stroke.
struct BoardShapeDetails: Shape {
    let shape: BoardShape

    func path(in rect: CGRect) -> Path { shape.details(in: rect) }
}

extension CanvasBorder {
    /// The dashes of the outline, for a line `width` wide.
    func dash(_ width: CGFloat) -> [CGFloat] {
        switch self {
        case .dashed: return [width * 4, width * 3]
        case .dotted: return [0.01, width * 2.6]
        case .solid, .invisible: return []
        }
    }
}

extension CanvasNodeShape {
    var symbol: String {
        switch self {
        case .rectangle: return "rectangle"
        case .pill: return "capsule"
        case .diamond: return "diamond"
        case .parallelogram: return "parallelogram"
        case .circle: return "circle"
        case .predefinedProcess: return "rectangle.split.3x1"
        case .document: return "doc"
        case .database: return "cylinder"
        }
    }

    /// The key that adds this shape on the board, if it has one (Excalidraw's).
    var key: String? {
        switch self {
        case .rectangle: return "R"
        case .diamond: return "D"
        case .circle: return "O"
        default: return nil
        }
    }
}

extension CanvasTextAlign {
    var swiftUI: TextAlignment {
        switch self {
        case .left: return .leading
        case .center: return .center
        case .right: return .trailing
        }
    }

    var horizontal: HorizontalAlignment {
        switch self {
        case .left: return .leading
        case .center: return .center
        case .right: return .trailing
        }
    }

    var symbol: String {
        switch self {
        case .left: return "text.alignleft"
        case .center: return "text.aligncenter"
        case .right: return "text.alignright"
        }
    }
}

extension CanvasNode {
    /// How the card's text lines up: as set, else centred in a shape.
    var effectiveTextAlign: CanvasTextAlign { textAlign ?? (shape != nil ? .center : .left) }
}
