import AppKit
import Observation
import SwiftUI

/// The camera of an infinite canvas (a board, a mindmap, a graph): world point (0, 0) is drawn at `offset`, at
/// `scale`. A view keeps one per tab, lays its content out in world units and converts with `screenRect` and
/// `worldPoint`; `infiniteCanvasNavigation(_:)` moves it with the trackpad, the scroll wheel and pinches.
@MainActor
@Observable
public final class CanvasCamera {
    public var offset: CGSize = .zero
    public var scale: CGFloat = 1
    public private(set) var viewSize: CGSize = .zero
    public let minScale: CGFloat
    public let maxScale: CGFloat

    public init(minScale: CGFloat = 0.1, maxScale: CGFloat = 4) {
        self.minScale = minScale
        self.maxScale = maxScale
    }

    public func screenPoint(_ world: CGPoint) -> CGPoint {
        CGPoint(x: world.x * scale + offset.width, y: world.y * scale + offset.height)
    }

    public func screenRect(_ world: CGRect) -> CGRect {
        CGRect(x: world.minX * scale + offset.width, y: world.minY * scale + offset.height,
               width: world.width * scale, height: world.height * scale)
    }

    public func worldPoint(_ screen: CGPoint) -> CGPoint {
        CGPoint(x: (screen.x - offset.width) / scale, y: (screen.y - offset.height) / scale)
    }

    /// The part of the world the view shows.
    public var visibleWorldRect: CGRect {
        let origin = worldPoint(.zero)
        return CGRect(x: origin.x, y: origin.y, width: viewSize.width / scale, height: viewSize.height / scale)
    }

    /// Records the view's size; a resize keeps the centre still. True the first time the size is known, when the
    /// view usually frames its content.
    @discardableResult
    public func viewResized(_ size: CGSize) -> Bool {
        let old = viewSize
        viewSize = size
        if old.width > 0, old.height > 0 {
            offset.width += (size.width - old.width) / 2
            offset.height += (size.height - old.height) / 2
            return false
        }
        return size.width > 0 && size.height > 0
    }

    /// Zooms by `factor`, keeping the world point under `anchor` (a view point; the centre when nil) in place.
    public func zoom(by factor: CGFloat, around anchor: CGPoint? = nil, animated: Bool = false) {
        let anchor = anchor ?? CGPoint(x: viewSize.width / 2, y: viewSize.height / 2)
        let newScale = min(max(scale * factor, minScale), maxScale)
        let world = worldPoint(anchor)
        let apply = {
            self.scale = newScale
            self.offset = CGSize(width: anchor.x - world.x * newScale, height: anchor.y - world.y * newScale)
        }
        if animated { Motion.with(Motion.Spring.smooth.animation) { apply() } } else { apply() }
    }

    public func setScale(_ value: CGFloat, animated: Bool = true) { zoom(by: value / scale, animated: animated) }

    public func pan(by delta: CGSize) {
        offset.width += delta.width
        offset.height += delta.height
    }

    /// Frames a world rectangle in the middle of the view, never zooming in past `maxScale`.
    public func show(_ world: CGRect, maxScale: CGFloat = 1, margin: CGFloat = 60, animated: Bool = true) {
        guard !world.isNull, !world.isInfinite, viewSize.width > 0, viewSize.height > 0 else { return }
        let fitScale = min((viewSize.width - margin * 2) / max(world.width, 1),
                           (viewSize.height - margin * 2) / max(world.height, 1))
        let newScale = min(max(fitScale, minScale), min(maxScale, self.maxScale))
        let apply = {
            self.scale = newScale
            self.offset = CGSize(width: self.viewSize.width / 2 - world.midX * newScale,
                                 height: self.viewSize.height / 2 - world.midY * newScale)
        }
        if animated { Motion.with(Motion.Spring.smooth.animation) { apply() } } else { apply() }
    }

    /// Pans just enough to show a world rectangle, `margin` points from the view's edges.
    public func reveal(_ world: CGRect, margin: CGFloat = 56, animated: Bool = true) {
        guard viewSize.width > 0 else { return }
        let rect = screenRect(world)
        var dx: CGFloat = 0
        var dy: CGFloat = 0
        if rect.minX < margin { dx = margin - rect.minX } else if rect.maxX > viewSize.width - margin {
            dx = viewSize.width - margin - rect.maxX
        }
        if rect.minY < margin { dy = margin - rect.minY } else if rect.maxY > viewSize.height - margin {
            dy = viewSize.height - margin - rect.maxY
        }
        guard dx != 0 || dy != 0 else { return }
        if animated {
            Motion.with(Motion.Spring.smooth.animation) { pan(by: CGSize(width: dx, height: dy)) }
        } else {
            pan(by: CGSize(width: dx, height: dy))
        }
    }
}

/// Where the pointer is over a canvas, in view coordinates; nil when it is elsewhere. A reference, so the scroll
/// monitor reads the current value without a view update.
@MainActor
public final class CanvasPointer {
    public var location: CGPoint?
    public init() {}
}

private struct InfiniteCanvasNavigation: ViewModifier {
    let camera: CanvasCamera
    let pointer: CanvasPointer
    let wheelZooms: Bool
    let scrolls: (CGPoint) -> Bool
    @State private var monitors: [Any] = []
    @State private var magnifyStart: CGFloat?

    func body(content: Content) -> some View {
        content
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                if case .active(let location) = phase { pointer.location = location } else { pointer.location = nil }
            }
            .simultaneousGesture(
                MagnifyGesture()
                    .onChanged { value in
                        let start = magnifyStart ?? camera.scale
                        if magnifyStart == nil { magnifyStart = start }
                        camera.zoom(by: start * value.magnification / camera.scale, around: pointer.location)
                    }
                    .onEnded { _ in magnifyStart = nil }
            )
            .onAppear { install() }
            .onDisappear { remove() }
    }

    /// Scrolling pans and Command-scrolling zooms, while the pointer is over the canvas and not over something
    /// that scrolls by itself (`scrolls`); with `wheelZooms`, the wheel of a mouse zooms too and the trackpad
    /// pans. A middle-button drag pans. Local monitors, because SwiftUI has neither a scroll-wheel gesture nor
    /// other buttons.
    private func install() {
        guard monitors.isEmpty else { return }
        let camera = camera, pointer = pointer, scrolls = scrolls, wheelZooms = wheelZooms
        let wheel = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            let precise = event.hasPreciseScrollingDeltas
            let zooms = event.modifierFlags.contains(.command) || (wheelZooms && !precise)
            let dx = event.scrollingDeltaX, dy = event.scrollingDeltaY
            let handled = MainActor.assumeIsolated { () -> Bool in
                guard let location = pointer.location, !scrolls(location) || zooms else { return false }
                if zooms {
                    camera.zoom(by: exp(dy * (precise ? 0.01 : 0.04)), around: location)
                } else {
                    camera.pan(by: CGSize(width: dx * (precise ? 1 : 8), height: dy * (precise ? 1 : 8)))
                }
                return true
            }
            return handled ? nil : event
        }
        let middle = NSEvent.addLocalMonitorForEvents(matching: .otherMouseDragged) { event in
            let dx = event.deltaX, dy = event.deltaY
            let handled = MainActor.assumeIsolated { () -> Bool in
                guard pointer.location != nil else { return false }
                camera.pan(by: CGSize(width: dx, height: dy))
                return true
            }
            return handled ? nil : event
        }
        monitors = [wheel, middle].compactMap { $0 }
    }

    private func remove() {
        for monitor in monitors { NSEvent.removeMonitor(monitor) }
        monitors = []
    }
}

public extension View {
    /// Moves `camera` with two-finger scrolling (pan), Command-scrolling and pinches (zoom around the pointer), and
    /// a drag of the middle button (pan). `wheelZooms` makes the wheel of a mouse zoom instead of pan.
    /// `scrolls` says whether the content under a view point scrolls by itself (an embedded editor): plain scrolling
    /// is left to it there.
    func infiniteCanvasNavigation(_ camera: CanvasCamera, pointer: CanvasPointer, wheelZooms: Bool = false,
                                  scrolls: @escaping (CGPoint) -> Bool = { _ in false }) -> some View {
        modifier(InfiniteCanvasNavigation(camera: camera, pointer: pointer, wheelZooms: wheelZooms, scrolls: scrolls))
    }
}

/// The dot grid behind a canvas, moving and scaling with its camera.
public struct CanvasDotGrid: View {
    let offset: CGSize
    let scale: CGFloat
    let color: Color

    public init(offset: CGSize, scale: CGFloat, color: Color) {
        self.offset = offset
        self.scale = scale
        self.color = color
    }

    public var body: some View {
        Canvas { context, size in
            var step = 22 * scale
            while step < 12 { step *= 2 }
            let radius = max(0.7, min(1.2, scale))
            let startX = offset.width.truncatingRemainder(dividingBy: step) - step
            let startY = offset.height.truncatingRemainder(dividingBy: step) - step
            var dots = Path()
            var y = startY
            while y < size.height + step {
                var x = startX
                while x < size.width + step {
                    // Squares, not circles: at this size the eye cannot tell, and a thousand of them cost far less.
                    dots.addRect(CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2))
                    x += step
                }
                y += step
            }
            context.fill(dots, with: .color(color.opacity(0.22)))
        }
        .allowsHitTesting(false)
    }
}

/// The zoom buttons of a canvas, in a Liquid Glass capsule: out, the scale (a click returns to 100 %), in, and
/// "zoom to fit". `extra` adds the canvas's own buttons after a divider.
public struct CanvasZoomControls<Extra: View>: View {
    let camera: CanvasCamera
    let fit: () -> Void
    let extra: Extra
    @Environment(\.themeTokens) private var theme

    public init(camera: CanvasCamera, fit: @escaping () -> Void, @ViewBuilder extra: () -> Extra) {
        self.camera = camera
        self.fit = fit
        self.extra = extra()
    }

    public var body: some View {
        HStack(spacing: 2) {
            button("minus", "Zoom out (⌘-)") { camera.zoom(by: 0.8, animated: true) }
            Button { camera.setScale(1) } label: {
                Text("\(Int((camera.scale * 100).rounded())) %")
                    .font(.ui(.label).monospacedDigit())
                    .frame(minWidth: 52)
            }
            .buttonStyle(.plain)
            .help("Actual size")
            button("plus", "Zoom in (⌘+)") { camera.zoom(by: 1.25, animated: true) }
            Divider().frame(height: 16).padding(.horizontal, 4)
            button("arrow.up.left.and.arrow.down.right", "Zoom to fit (⇧1)") { fit() }
            extra
        }
        .foregroundStyle(theme.text)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .glassEffect(.regular, in: ThemeCapsule())
    }

    private func button(_ image: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button { action() } label: {
            Image(symbol: image).frame(width: 30, height: 26).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

public extension CanvasZoomControls where Extra == EmptyView {
    init(camera: CanvasCamera, fit: @escaping () -> Void) {
        self.init(camera: camera, fit: fit) { EmptyView() }
    }
}
