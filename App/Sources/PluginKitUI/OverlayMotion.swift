import SwiftUI

/// The distances and durations of the overlays (palette, toasts, `/` menu, format bar). They extend `Motion.Metrics`
/// from their own file and are listed in `docs/design/MOTION.md`, "Token cheat sheet".
extension Motion.Metrics {
    /// The palette drops in this far from above its rest while it grows.
    public static let paletteDrop: CGFloat = 10
    /// The palette shrinks to this while it leaves (it started at `overlayScale`).
    public static let paletteExitScale: CGFloat = 0.98
    /// The `/` menu starts this much smaller, anchored at the corner nearer the caret.
    public static let menuScale: CGFloat = 0.97
    /// The `/` menu starts this far below its rest.
    public static let menuRise: CGFloat = 4
    /// The format bar starts this far from its rest, toward the selection.
    public static let barRise: CGFloat = 6
    /// A toast sinks this far while it fades out.
    public static let toastSink: CGFloat = 8
    /// How long the `/` menu takes to fade out. Shorter than `Motion.exit`: it closes as you type on.
    public static let menuExit: TimeInterval = 0.08
    /// The length of `Motion.exit`, for AppKit animations (a window fading out).
    public static let exitDuration: TimeInterval = 0.12
    /// How long the dimmed scrim of a palette takes to arrive.
    public static let scrimIn: TimeInterval = 0.18
}

extension Motion {
    /// Which side of its anchor a floating panel opens on, and so which of its corners it grows from.
    public enum Opening: Equatable, Sendable {
        /// Hangs under the anchor (the `/` menu under the caret; the format bar under a selection).
        case below
        /// Stands above the anchor.
        case above

        /// The `/` menu grows from the corner nearest the caret: top-left below it, bottom-left above it.
        public var menuAnchor: UnitPoint { self == .below ? .topLeading : .bottomLeading }
        /// The format bar grows from the middle of the edge nearest the selection.
        public var barAnchor: UnitPoint { self == .above ? .bottom : .top }
        /// The sign of the `y` offset a format bar starts from: it comes from the side of its selection.
        public var barRiseSign: CGFloat { self == .above ? 1 : -1 }
    }
}
