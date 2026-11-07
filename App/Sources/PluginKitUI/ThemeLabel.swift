import SwiftUI

public extension View {
    /// A small label (a section title, a date, a count) as Loam sets them in every theme: in capitals in the theme's
    /// mono font, a little smaller than `size` and spaced out, as on a print.
    func themeLabel(size: CGFloat, weight: Font.Weight = .regular) -> some View {
        modifier(ThemeLabelModifier(size: size, weight: weight))
    }
}

private struct ThemeLabelModifier: ViewModifier {
    let size: CGFloat
    let weight: Font.Weight
    @Environment(\.themeTokens) private var theme

    func body(content: Content) -> some View {
        let mono = (size * 0.78).rounded()
        content
            .font(.theme(theme.monoFamily, size: mono))
            .textCase(.uppercase)
            .tracking(mono * 0.09)
    }
}

/// The corners of the window's theme (`shape.corners`): rounded as each view draws them, or held to a largest
/// radius (`soft`: a slight rounding, `square`: a hairline's softening). Set by the shell before the views read it,
/// as `InterfaceFont`; views pass their radius through `Corners.r` and draw pills as `ThemeCapsule`.
public enum Corners {
    /// The largest radius any corner takes, in points; nil keeps each view's own.
    nonisolated(unsafe) public static var cap: CGFloat?
    /// `pill` corners: the sidebar's rows and fields as capsules, rounder pages.
    nonisolated(unsafe) public static var pill = false

    /// The largest radius of `soft` and `square` corners.
    public static func cap(for value: String) -> CGFloat? {
        switch value {
        case "soft": 6
        case "square": 2
        default: nil
        }
    }

    /// `radius`, held to the theme's largest.
    public static func r(_ radius: CGFloat) -> CGFloat {
        cap.map { min(radius, $0) } ?? radius
    }
}

public extension NSBezierPath {
    /// A rounded rectangle with continuous corners, the curve SwiftUI's `RoundedRectangle` and the system draw, so
    /// AppKit drawing matches the views beside it (`roundedRect:xRadius:yRadius:` draws circular arcs).
    convenience init(continuousRoundedRect rect: NSRect, radius: CGFloat) {
        self.init()
        Path(roundedRect: rect, cornerRadius: max(0, min(radius, rect.width / 2, rect.height / 2)), style: .continuous)
            .cgPath.applyWithBlock { element in
                let points = element.pointee.points
                switch element.pointee.type {
                case .moveToPoint: move(to: points[0])
                case .addLineToPoint: line(to: points[0])
                case .addQuadCurveToPoint:
                    let start = currentPoint
                    curve(to: points[1],
                          controlPoint1: NSPoint(x: start.x + 2 / 3 * (points[0].x - start.x), y: start.y + 2 / 3 * (points[0].y - start.y)),
                          controlPoint2: NSPoint(x: points[1].x + 2 / 3 * (points[0].x - points[1].x), y: points[1].y + 2 / 3 * (points[0].y - points[1].y)))
                case .addCurveToPoint: curve(to: points[2], controlPoint1: points[0], controlPoint2: points[1])
                case .closeSubpath: close()
                @unknown default: break
                }
            }
    }
}

/// A capsule, or a rectangle with the square theme's corners.
public struct ThemeCapsule: InsettableShape {
    private var inset: CGFloat = 0

    public init() {}
    public init(style: RoundedCornerStyle) {}

    public func path(in rect: CGRect) -> Path {
        let rect = rect.insetBy(dx: inset, dy: inset)
        if let cap = Corners.cap {
            return Path(roundedRect: rect, cornerRadius: min(cap, rect.height / 2), style: .continuous)
        }
        return Capsule().path(in: rect)
    }

    public func inset(by amount: CGFloat) -> ThemeCapsule {
        var shape = self
        shape.inset += amount
        return shape
    }
}
