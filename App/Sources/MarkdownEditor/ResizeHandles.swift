import PluginKitUI
import AppKit

/// The handles of a selected picture: a bar inside the middle of each side, as in Craft. They change the width and
/// keep the ratio, which a dot on a corner would promise otherwise; the picture stays at the left of the column, so the
/// left one pulls the right edge in.
enum ResizeHandle: CaseIterable {
    case left, right

    static let all: [ResizeHandle] = allCases

    /// Which way a drag to the right changes the width.
    var sign: CGFloat { self == .left ? -1 : 1 }

    /// Where it is drawn on a picture at `frame`: inside the middle of the side.
    func rect(on frame: NSRect) -> NSRect {
        switch self {
        case .left: Self.bar(at: NSPoint(x: frame.minX + 8, y: frame.midY))
        case .right: Self.bar(at: NSPoint(x: frame.maxX - 8, y: frame.midY))
        }
    }

    private static func bar(at point: NSPoint) -> NSRect {
        NSRect(x: point.x - 3, y: point.y - 14, width: 6, height: 28)
    }

    /// The handle under `point` on a picture at `frame`, with a little room around it for the mouse.
    static func hit(_ point: NSPoint, on frame: NSRect) -> ResizeHandle? {
        all.first { $0.rect(on: frame).insetBy(dx: -4, dy: -4).contains(point) }
    }

    /// The width a picture `start` wide takes when the mouse moved `dx` points to the right, within the column.
    func width(from start: CGFloat, dragging dx: CGFloat, maxWidth: CGFloat) -> CGFloat {
        min(max(start + sign * dx, PictureMark.minWidth), max(maxWidth, PictureMark.minWidth))
    }
}

/// Draws the handles above the picture (and above its hosted view, which a text view's own drawing is under). Lets
/// every click through to the text view, which does the dragging.
final class ResizeHandlesView: NSView {
    /// How far the view reaches around the picture, for the handles' shadows.
    static let outset: CGFloat = 8
    var accent: NSColor = .controlAccentColor

    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        let picture = bounds.insetBy(dx: Self.outset, dy: Self.outset)
        for handle in ResizeHandle.all {
            let rect = handle.rect(on: picture)
            let path = NSBezierPath(continuousRoundedRect: rect, radius: Corners.r(rect.width / 2))
            NSGraphicsContext.saveGraphicsState()
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
            shadow.shadowBlurRadius = 2
            shadow.shadowOffset = NSSize(width: 0, height: -1)
            shadow.set()
            NSColor.white.setFill()
            path.fill()
            NSGraphicsContext.restoreGraphicsState()
            accent.setStroke()
            path.lineWidth = 1.5
            path.stroke()
        }
    }
}
