import AppKit
import SwiftUI

/// The sidebar's folder as Arc draws it: an outline that opens. Two shapes hinged at their bottom-left corner, the
/// back (with its tab) and the front panel, turn a little away in perspective; the front falls towards the reader and
/// the back leans away, each darkening under a soft gradient. Arc's own `FolderIconView` gave the measurements.
public struct AnimatedFolderIcon: NSViewRepresentable {
    public enum Pose: Equatable, Sendable {
        /// Flat, as a closed folder.
        case closed
        /// Half open: hovered, or a drag held over it.
        case peek
        /// Open, its children shown.
        case open
    }

    let pose: Pose
    /// The outline, and the tint of the fills.
    let color: Color
    /// What the icon sits on: the front panel is filled opaque from it, so the back's outline never shows through.
    let ground: Color
    let size: CGSize

    public init(pose: Pose, color: Color, ground: Color, size: CGSize = CGSize(width: 12.3 * SidebarStyle.iconScale, height: 10.4 * SidebarStyle.iconScale)) {
        self.pose = pose
        self.color = color
        self.ground = ground
        self.size = size
    }

    public func makeNSView(context: Context) -> FolderGlyphView {
        let view = FolderGlyphView()
        view.apply(pose: pose, color: NSColor(color), ground: NSColor(ground), animated: false)
        return view
    }

    public func updateNSView(_ view: FolderGlyphView, context: Context) {
        let animated = !context.transaction.disablesAnimations && !Motion.reduceMotion
        view.apply(pose: pose, color: NSColor(color), ground: NSColor(ground), animated: animated)
    }

    public func sizeThatFits(_ proposal: ProposedViewSize, nsView: FolderGlyphView, context: Context) -> CGSize? {
        size
    }
}

/// The layers behind `AnimatedFolderIcon`. Not flipped: y goes up, so the hinge is the layers' origin.
public final class FolderGlyphView: NSView {
    private let back = CAShapeLayer()
    private let backShading = CAGradientLayer()
    private let backShadingMask = CAShapeLayer()
    private let front = CALayer()
    private let frontPanel = CAShapeLayer()
    private let frontShading = CAGradientLayer()
    private var pose: AnimatedFolderIcon.Pose = .closed

    public override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = false
        // A faint shadow under the whole folder, the lift of the system's folder glyph.
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.14
        layer?.shadowRadius = 1.2
        layer?.shadowOffset = CGSize(width: 0, height: -0.6)
        for shape in [back, frontPanel] {
            shape.lineJoin = .round
        }
        backShading.colors = [NSColor.black.withAlphaComponent(0).cgColor, NSColor.black.withAlphaComponent(0.36).cgColor]
        backShading.startPoint = CGPoint(x: 0, y: 1)
        backShading.endPoint = CGPoint(x: 0.6, y: 0)
        backShading.mask = backShadingMask
        frontShading.colors = [NSColor.black.withAlphaComponent(0).cgColor, NSColor.black.withAlphaComponent(0.15).cgColor]
        frontShading.startPoint = CGPoint(x: 0.1, y: 1)
        frontShading.endPoint = CGPoint(x: 0.9, y: 0)
        frontShading.masksToBounds = true
        for hinged in [back, front] {
            hinged.anchorPoint = .zero
        }
        back.addSublayer(backShading)
        front.addSublayer(frontPanel)
        front.addSublayer(frontShading)
        layer?.addSublayer(back)
        layer?.addSublayer(front)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    public override var isFlipped: Bool { false }
    public override func hitTest(_ point: NSPoint) -> NSView? { nil }

    public override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let width = bounds.width, height = bounds.height
        let scale = window?.backingScaleFactor ?? 2
        let pixel = { (value: CGFloat) in (value * scale).rounded() / scale }
        // Rounder than Arc's width / 7, for a folder a little softer at sidebar size.
        let radius = pixel(width / 6.5)
        let frontHeight = height - pixel((height * 0.25).rounded())
        let tab = (pixel((height * 0.25).rounded()) / 1.5).rounded(.down)
        // The sidebar's drawn icons' weight (`SidebarGlyph`: 1.2 on their 18 point grid, drawn at 17).
        let lineWidth: CGFloat = 1.13

        // The back: the folder with its tab along the top left, the tab's edge slanting down to the body.
        let path = CGMutablePath()
        let top = height
        path.move(to: CGPoint(x: radius, y: top))
        path.addLine(to: CGPoint(x: pixel(0.42 * width), y: top))
        path.addLine(to: CGPoint(x: pixel(0.58 * width), y: top - tab))
        path.addArc(tangent1End: CGPoint(x: width, y: top - tab), tangent2End: CGPoint(x: width, y: 0), radius: radius)
        path.addArc(tangent1End: CGPoint(x: width, y: 0), tangent2End: CGPoint(x: 0, y: 0), radius: radius)
        path.addArc(tangent1End: .zero, tangent2End: CGPoint(x: 0, y: top), radius: radius)
        path.addArc(tangent1End: CGPoint(x: 0, y: top), tangent2End: CGPoint(x: width, y: top), radius: radius)
        path.closeSubpath()

        back.bounds = bounds
        back.position = .zero
        back.path = path
        back.lineWidth = lineWidth
        backShading.frame = bounds
        backShadingMask.frame = bounds
        backShadingMask.path = path

        let panel = CGRect(x: 0, y: 0, width: width, height: frontHeight)
        front.bounds = panel
        front.position = .zero
        frontPanel.frame = panel
        frontPanel.path = CGPath(roundedRect: panel, cornerWidth: radius, cornerHeight: radius, transform: nil)
        frontPanel.lineWidth = lineWidth
        frontShading.frame = panel
        frontShading.cornerRadius = radius
        applyPose()
        CATransaction.commit()
    }

    package func apply(pose: AnimatedFolderIcon.Pose, color: NSColor, ground: NSColor, animated: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let resolved = { (color: NSColor) in color.usingColorSpace(.sRGB) ?? color }
        let ink = resolved(color), base = resolved(ground)
        back.strokeColor = ink.cgColor
        frontPanel.strokeColor = ink.cgColor
        back.fillColor = (base.blended(withFraction: 0.16, of: ink) ?? base).cgColor
        frontPanel.fillColor = (base.blended(withFraction: 0.07, of: ink) ?? base).cgColor
        CATransaction.commit()

        guard pose != self.pose else { return }
        self.pose = pose
        CATransaction.begin()
        CATransaction.setDisableActions(!animated)
        CATransaction.setAnimationDuration(0.25)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .default))
        applyPose()
        CATransaction.commit()
    }

    /// Arc's angles: open turns the folder 32° away, the front falls 30° and the back leans 28°; half open is part of it.
    private func applyPose() {
        let amount: CGFloat = switch pose {
        case .closed: 0
        case .peek: SidebarGlyph.peek
        case .open: 1
        }
        back.transform = hinge(amount, tilt: -28)
        front.transform = hinge(amount, tilt: 30)
        backShading.opacity = amount > 0 ? 1 : 0.2
        frontShading.opacity = amount > 0 ? 1 : 0
    }

    private func hinge(_ amount: CGFloat, tilt: CGFloat) -> CATransform3D {
        var transform = CATransform3DIdentity
        transform.m34 = -1 / 350
        // Arc's 3 points for its 16 point folder, in proportion.
        transform = CATransform3DTranslate(transform, 3 * bounds.width / 16 * amount, 0, 0)
        transform = CATransform3DRotate(transform, 32 * amount * .pi / 180, 0, 1, 0)
        return CATransform3DRotate(transform, tilt * amount * .pi / 180, 1, 0, 0)
    }
}
