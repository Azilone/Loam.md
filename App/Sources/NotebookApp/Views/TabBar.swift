import AppKit
import PluginKitUI
import SwiftUI
import WorkspaceModel

/// The tab bars' metrics; the bar and its tabs are AppKit (`TabBarView`, `TabStripView`).
enum TabBar {
    static let height: CGFloat = 40
}

/// The selected tab's bead of glass as an image, by appearance: frosted white over the sidebar, a rim lit from the top
/// and a shade at its foot, lifted by a soft shadow; the capsule `height` tall with `margin` around it for its shadow,
/// as narrow as its rounded ends allow, stretched across a tab by its middle (`contentsCenter`). Drawn once: as SwiftUI
/// shapes its gradients were painted again by the CPU on every frame of its slide from tab to tab.
@MainActor
enum TabGlassImage {
    static let height: CGFloat = TabBar.height - 10
    static let margin: CGFloat = 10
    private static var cache: [String: NSImage] = [:]

    /// The capsule's corner radius: the theme's corners, a full capsule at most.
    static var radius: CGFloat { min(Corners.cap ?? height / 2, height / 2) }

    static func image(isDark: Bool) -> NSImage {
        let radius = self.radius
        let key = "\(isDark)|\(radius)"
        if let known = cache[key] { return known }
        let capsuleWidth = 2 * radius + 2
        let size = NSSize(width: capsuleWidth + 2 * margin, height: height + 2 * margin)
        let image = NSImage(size: size, flipped: true) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            let rect = CGRect(x: margin, y: margin, width: capsuleWidth, height: height)
            let path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
            let space = CGColorSpace(name: CGColorSpace.sRGB)!
            func gradient(_ colors: [NSColor]) -> CGGradient {
                CGGradient(colorsSpace: space, colors: colors.map(\.cgColor) as CFArray, locations: nil)!
            }
            // The two shadows, under an opaque fill that the glass then covers: the shadow's own shape.
            context.saveGState()
            context.setShadow(offset: CGSize(width: 0, height: 3), blur: 12, color: NSColor.black.withAlphaComponent(isDark ? 0.25 : 0.06).cgColor)
            context.addPath(path)
            context.setFillColor(NSColor.black.cgColor)
            context.fillPath()
            context.restoreGState()
            context.saveGState()
            context.setShadow(offset: CGSize(width: 0, height: 0.5), blur: 1, color: NSColor.black.withAlphaComponent(isDark ? 0.3 : 0.07).cgColor)
            context.addPath(path)
            context.setFillColor(NSColor.black.cgColor)
            context.fillPath()
            context.restoreGState()
            // The capsule itself is clear (the material shows through it), then the frosted fill and the lit rim.
            context.saveGState()
            context.addPath(path)
            context.clip()
            context.setBlendMode(.clear)
            context.fill(rect)
            context.setBlendMode(.normal)
            let fill = isDark
                ? [NSColor.white.withAlphaComponent(0.16), NSColor.white.withAlphaComponent(0.08)]
                : [NSColor.white.withAlphaComponent(0.95), NSColor.white.withAlphaComponent(0.72)]
            context.drawLinearGradient(gradient(fill), start: CGPoint(x: 0, y: rect.minY), end: CGPoint(x: 0, y: rect.maxY), options: [])
            // The rim: the gradient through a one-point ring inside the edge.
            let inner = CGPath(roundedRect: rect.insetBy(dx: 1, dy: 1), cornerWidth: max(0, radius - 1), cornerHeight: max(0, radius - 1), transform: nil)
            context.addPath(path)
            context.addPath(inner)
            context.clip(using: .evenOdd)
            let rim = [NSColor.white.withAlphaComponent(isDark ? 0.35 : 1), NSColor.white.withAlphaComponent(0),
                       NSColor.black.withAlphaComponent(isDark ? 0.3 : 0.07)]
            context.drawLinearGradient(gradient(rim), start: CGPoint(x: 0, y: rect.minY), end: CGPoint(x: 0, y: rect.maxY), options: [])
            context.restoreGState()
            return true
        }
        cache[key] = image
        return image
    }
}


extension EnvironmentValues {
    /// How far the last pane's tab bar keeps clear of the right sidebar button.
    @Entry var tabBarTrailingInset: CGFloat = 0
}
