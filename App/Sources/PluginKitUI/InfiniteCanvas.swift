import AppKit
import Observation
import SwiftUI

/// The camera of an infinite canvas (a board, a mindmap, a graph): world point (0, 0) is drawn at `offset`, at
/// `scale`. A view keeps one per tab, lays its content out in world units and converts with `screenRect` and
/// `worldPoint`; `infiniteCanvasNavigation(_:)` moves it with the trackpad, the scroll wheel and pinches.
@MainActor
@Observable
public final class CanvasCamera {
    /// Set from outside, either stops an animated move (`move(to:scale:animated:)`) where it is.
    public var offset: CGSize = .zero { didSet { if !isStepping { stopFlight() } } }
    public var scale: CGFloat = 1 { didSet { if !isStepping { stopFlight() } } }
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
        // From where an animation in flight is going, so steps made quickly add up.
        let base: (offset: CGSize, scale: CGFloat) = animated ? flight?.target ?? (offset, scale) : (offset, scale)
        let newScale = min(max(base.scale * factor, minScale), maxScale)
        let world = CGPoint(x: (anchor.x - base.offset.width) / base.scale, y: (anchor.y - base.offset.height) / base.scale)
        move(to: CGSize(width: anchor.x - world.x * newScale, height: anchor.y - world.y * newScale), scale: newScale,
             animated: animated)
    }

    public func setScale(_ value: CGFloat, animated: Bool = true) { zoom(by: value / scale, animated: animated) }

    public func pan(by delta: CGSize) {
        stopFlight()
        offset.width += delta.width
        offset.height += delta.height
    }

    /// Frames a world rectangle in the middle of the view, never zooming in past `maxScale`.
    public func show(_ world: CGRect, maxScale: CGFloat = 1, margin: CGFloat = 60, animated: Bool = true) {
        guard !world.isNull, !world.isInfinite, viewSize.width > 0, viewSize.height > 0 else { return }
        let fitScale = min((viewSize.width - margin * 2) / max(world.width, 1),
                           (viewSize.height - margin * 2) / max(world.height, 1))
        let newScale = min(max(fitScale, minScale), min(maxScale, self.maxScale))
        move(to: CGSize(width: viewSize.width / 2 - world.midX * newScale, height: viewSize.height / 2 - world.midY * newScale),
             scale: newScale, animated: animated)
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
        move(to: CGSize(width: offset.width + dx, height: offset.height + dy), scale: scale, animated: animated)
    }

    /// Goes to `offset` and `scale`; animated, along `Motion.Spring.smooth` (a short fade's ease under Reduce
    /// Motion), one step per frame of the display, so an AppKit view and a SwiftUI one follow it alike. The point
    /// that stays in place on screen during the move does: a zoom grows around its anchor.
    public func move(to offset: CGSize, scale: CGFloat, animated: Bool) {
        stopFlight()
        guard animated, offset != self.offset || scale != self.scale else {
            step(offset: offset, scale: scale)
            return
        }
        flight = CanvasCameraFlight(camera: self, from: (self.offset, self.scale), to: (offset, scale))
    }

    /// Where the camera is going: the end of an animated move, else where it is.
    public var destination: (offset: CGSize, scale: CGFloat) { flight?.target ?? (offset, scale) }

    /// Whether the camera is moving by itself (`move(to:scale:animated:)`): a view keeps its cheap drawing until it rests.
    public var isFlying: Bool { flight != nil }

    @ObservationIgnored private var flight: CanvasCameraFlight?
    /// An animated move is setting the values: they do not stop it.
    @ObservationIgnored private var isStepping = false

    fileprivate func step(offset: CGSize, scale: CGFloat) {
        isStepping = true
        self.offset = offset
        self.scale = scale
        isStepping = false
    }

    private func stopFlight() {
        flight?.stop()
        flight = nil
    }

    fileprivate func flightEnded(_ ended: CanvasCameraFlight) {
        if flight === ended { flight = nil }
    }
}

/// A camera's animated move: a spring's progress each frame of the display, the scale eased in its logarithm and
/// the point that stays still kept in place.
@MainActor
private final class CanvasCameraFlight: NSObject {
    typealias Pose = (offset: CGSize, scale: CGFloat)
    private weak var camera: CanvasCamera?
    private let from: Pose
    let target: Pose
    private var link: CADisplayLink?
    private var start: CFTimeInterval?
    private let spring: Motion.Spring
    private let reduced: Bool

    init(camera: CanvasCamera, from: Pose, to: Pose) {
        self.camera = camera
        self.from = from
        target = to
        reduced = Motion.reduceMotion
        spring = Motion.Spring.smooth
        super.init()
        guard let screen = NSScreen.main ?? NSScreen.screens.first else {
            finish()
            return
        }
        let link = screen.displayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
        // A display that gives no frames (asleep, locked, a test) still sees the camera arrive.
        let length = reduced ? 0.12 : spring.duration * 1.6
        DispatchQueue.main.asyncAfter(deadline: .now() + length + 0.1) { [weak self] in
            guard let self, self.link != nil else { return }
            self.finish()
        }
    }

    func stop() {
        link?.invalidate()
        link = nil
    }

    @objc private func tick(_ link: CADisplayLink) {
        let now = link.targetTimestamp
        if start == nil { start = link.timestamp }
        let elapsed = now - (start ?? now)
        let progress: Double
        if reduced {
            let t = min(1, elapsed / 0.12)
            progress = 1 - (1 - t) * (1 - t)
        } else {
            progress = spring.progress(at: elapsed)
        }
        guard elapsed < (reduced ? 0.12 : spring.duration * 1.6) else {
            finish()
            return
        }
        apply(CGFloat(progress))
    }

    private func finish() {
        stop()
        camera?.step(offset: target.offset, scale: target.scale)
        camera?.flightEnded(self)
    }

    private func apply(_ progress: CGFloat) {
        guard let camera else { return stop() }
        let scale = abs(target.scale - from.scale) < 0.0001 ? target.scale
            : exp(log(from.scale) + (log(target.scale) - log(from.scale)) * progress)
        let offset: CGSize
        if abs(target.scale - from.scale) < 0.0001 {
            offset = CGSize(width: from.offset.width + (target.offset.width - from.offset.width) * progress,
                            height: from.offset.height + (target.offset.height - from.offset.height) * progress)
        } else {
            // The world point the move keeps in place (the fixed point of the two poses), and where it is on screen.
            let world = CGPoint(x: (from.offset.width - target.offset.width) / (target.scale - from.scale),
                                y: (from.offset.height - target.offset.height) / (target.scale - from.scale))
            let screen = CGPoint(x: from.offset.width + world.x * from.scale, y: from.offset.height + world.y * from.scale)
            offset = CGSize(width: screen.x - world.x * scale, height: screen.y - world.y * scale)
        }
        camera.step(offset: offset, scale: scale)
    }
}

public extension Motion.Spring {
    /// How far the spring has gone at `time` seconds, from 0 to 1 (past it while it overshoots): the curve
    /// `animation` follows, for code that steps a value itself each frame.
    func progress(at time: Double) -> Double {
        guard time > 0 else { return 0 }
        let omega = 2 * Double.pi / max(duration, 0.01)
        let damping = max(0, min(1, 1 - bounce))
        if damping >= 0.999 {
            return 1 - (1 + omega * time) * exp(-omega * time)
        }
        let damped = omega * (1 - damping * damping).squareRoot()
        let envelope = exp(-damping * omega * time)
        return 1 - envelope * (cos(damped * time) + damping * omega / damped * sin(damped * time))
    }
}

public extension CanvasCamera {
    /// Moves the camera for a scroll event over an AppKit canvas at `location` (a view point): scrolling pans,
    /// Command-scrolling zooms around the pointer; with `wheelZooms`, a mouse's wheel zooms too and the trackpad pans.
    func scroll(with event: NSEvent, at location: CGPoint, wheelZooms: Bool = false) {
        let precise = event.hasPreciseScrollingDeltas
        if event.modifierFlags.contains(.command) || (wheelZooms && !precise) {
            zoom(by: exp(event.scrollingDeltaY * (precise ? 0.01 : 0.04)), around: location)
        } else {
            pan(by: CGSize(width: event.scrollingDeltaX * (precise ? 1 : 8), height: event.scrollingDeltaY * (precise ? 1 : 8)))
        }
    }

    /// Whether a scroll event zooms rather than pans (`scroll(with:at:wheelZooms:)`).
    static func scrollZooms(_ event: NSEvent, wheelZooms: Bool = false) -> Bool {
        event.modifierFlags.contains(.command) || (wheelZooms && !event.hasPreciseScrollingDeltas)
    }

    /// Zooms for a pinch over an AppKit canvas, around `location` (a view point).
    func magnify(with event: NSEvent, at location: CGPoint) {
        zoom(by: 1 + event.magnification, around: location)
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
            let zooms = CanvasCamera.scrollZooms(event, wheelZooms: wheelZooms)
            let handled = MainActor.assumeIsolated { () -> Bool in
                guard let location = pointer.location, !scrolls(location) || zooms else { return false }
                camera.scroll(with: event, at: location, wheelZooms: wheelZooms)
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

/// The dot grid behind a canvas, moving and scaling with its camera, in AppKit: two replicator layers of one dot,
/// so a pan or a zoom only sets a position and a step, and the render server draws the dots. The owner sets its
/// frame to the canvas's bounds and calls `update` as the camera moves.
public final class CanvasDotGridLayer: CALayer {
    private let rows = CAReplicatorLayer()
    private let columns = CAReplicatorLayer()
    private let dot = CALayer()
    private var shown: (step: CGFloat, radius: CGFloat, size: CGSize, color: CGColor?) = (0, 0, .zero, nil)

    public override init() {
        super.init()
        masksToBounds = true
        rows.addSublayer(dot)
        columns.addSublayer(rows)
        addSublayer(columns)
    }

    public override init(layer: Any) { super.init(layer: layer) }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public override func action(forKey event: String) -> (any CAAction)? { nil }

    /// The step between dots for a scale: 22 points at 100 %, doubled while it would be under 12.
    public static func step(for scale: CGFloat) -> CGFloat {
        var step = 22 * scale
        while step < 12 { step *= 2 }
        return step
    }

    /// Shows the dots for a camera at `offset` and `scale`, in `color` (drawn at 22 %).
    public func update(offset: CGSize, scale: CGFloat, color: NSColor) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        let step = Self.step(for: scale)
        // Squares, not circles: at this size the eye cannot tell.
        let radius = max(0.7, min(1.2, scale))
        let cgColor = color.withAlphaComponent(0.22 * color.alphaComponent).cgColor
        if shown.step != step || shown.size != bounds.size {
            rows.instanceTransform = CATransform3DMakeTranslation(step, 0, 0)
            columns.instanceTransform = CATransform3DMakeTranslation(0, step, 0)
            rows.instanceCount = Int((bounds.width / step).rounded(.up)) + 2
            columns.instanceCount = Int((bounds.height / step).rounded(.up)) + 2
        }
        if shown.radius != radius { dot.frame = CGRect(x: -radius, y: -radius, width: radius * 2, height: radius * 2) }
        if shown.color != cgColor { dot.backgroundColor = cgColor }
        shown = (step, radius, bounds.size, cgColor)
        func start(_ value: CGFloat) -> CGFloat {
            let rest = value.truncatingRemainder(dividingBy: step)
            return (rest < 0 ? rest + step : rest) - step
        }
        columns.frame = CGRect(x: start(offset.width), y: start(offset.height), width: 1, height: 1)
    }
}

/// An AppKit view of `CanvasDotGridLayer`, for `CanvasDotGrid`.
final class CanvasDotGridView: NSView {
    let grid = CanvasDotGridLayer()
    var values: (offset: CGSize, scale: CGFloat, color: NSColor) = (.zero, 1, .gray)

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.addSublayer(grid)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        grid.frame = bounds
        CATransaction.commit()
        grid.update(offset: values.offset, scale: values.scale, color: values.color)
    }
}

/// The dot grid behind a canvas, moving and scaling with its camera: `CanvasDotGridLayer` in SwiftUI.
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
        DotGridRepresentable(offset: offset, scale: scale, color: color)
    }
}

private struct DotGridRepresentable: NSViewRepresentable {
    let offset: CGSize
    let scale: CGFloat
    let color: Color

    func makeNSView(context: Context) -> CanvasDotGridView { CanvasDotGridView() }

    func updateNSView(_ view: CanvasDotGridView, context: Context) {
        view.values = (offset, scale, NSColor(color))
        view.grid.update(offset: offset, scale: scale, color: NSColor(color))
    }
}

/// The zoom buttons of a canvas in AppKit, in a Liquid Glass capsule: out, the scale (a click returns to 100 %), in,
/// and "zoom to fit", then the canvas's own buttons (`extra`) after a divider. The scale follows the camera. Placed
/// by hand (no Auto Layout): a canvas opening makes it in its first frame.
public final class CanvasZoomControlsView: NSView {
    private let camera: CanvasCamera
    private let fit: () -> Void
    private let glass = NSGlassEffectView()
    private let content = NSView()
    private let label = NSButton(title: "100 %", target: nil, action: nil)
    private var symbolButtons: [(button: NSButton, symbol: String)] = []
    private var items: [NSView] = []
    private let divider = NSView()
    private var following: Follow<CGFloat>?
    public var theme: ThemeTokens = .standard { didSet { if theme != oldValue { applyTheme() } } }

    private static let height: CGFloat = 34
    private static let inset: CGFloat = 8

    public init(camera: CanvasCamera, fit: @escaping () -> Void, extra: [NSView] = []) {
        self.camera = camera
        self.fit = fit
        super.init(frame: .zero)
        glass.contentView = content
        addSubview(glass)
        label.isBordered = false
        label.target = self
        label.action = #selector(actualSize)
        label.toolTip = "Actual size".uiLocalized
        label.frame.size = CGSize(width: 52, height: 26)
        divider.wantsLayer = true
        divider.frame.size = CGSize(width: 1, height: 16)
        items = [
            symbolButton("minus", "Zoom out (⌘-)") { [weak self] in self?.camera.zoom(by: 0.8, animated: true) },
            label,
            symbolButton("plus", "Zoom in (⌘+)") { [weak self] in self?.camera.zoom(by: 1.25, animated: true) },
            divider,
            symbolButton("arrow.up.left.and.arrow.down.right", "Zoom to fit (⇧1)") { [weak self] in self?.fit() },
        ] + extra
        for item in items { content.addSubview(item) }
        following = Follow({ [weak camera] in ((camera?.scale ?? 1) * 100).rounded() }) { [weak self] percent in
            self?.label.attributedTitle = self?.labelTitle(percent / 100) ?? NSAttributedString()
        }
        applyTheme()
        placeItems()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public override var intrinsicContentSize: NSSize {
        let width = items.reduce(Self.inset * 2) { total, item in total + itemWidth(item) + 2 } - 2
        return NSSize(width: width, height: Self.height)
    }

    public override var isFlipped: Bool { true }
    public override var mouseDownCanMoveWindow: Bool { false }

    private func itemWidth(_ item: NSView) -> CGFloat {
        item === divider ? 9 : max(item.frame.width, item.fittingSize.width)
    }

    private func placeItems() {
        var x = Self.inset
        for item in items {
            let width = itemWidth(item)
            let height = item === divider ? 16 : max(26, item.frame.height)
            item.frame = CGRect(x: x + (item === divider ? 4 : 0), y: (Self.height - height) / 2, width: item === divider ? 1 : width,
                                height: height)
            x += width + 2
        }
    }

    public override func layout() {
        super.layout()
        glass.frame = bounds
        content.frame = bounds
        glass.cornerRadius = Corners.cap.map { min($0, bounds.height / 2) } ?? bounds.height / 2
        placeItems()
    }

    /// A plain symbol button of the capsule's look, for `extra`.
    public func symbolButton(_ symbol: String, _ help: String, action: @escaping () -> Void) -> NSButton {
        let button = CanvasControlButton(action: action)
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.toolTip = help.uiLocalized
        button.setAccessibilityLabel(help.uiLocalized)
        button.frame.size = CGSize(width: 30, height: 26)
        symbolButtons.append((button, symbol))
        button.image = tintedSymbol(symbol, size: 13, color: NSColor(theme.text))
        return button
    }

    /// Adds a view after the others (a canvas's own button, made by `symbolButton`).
    public func addExtra(_ view: NSView) {
        items.append(view)
        content.addSubview(view)
        placeItems()
        invalidateIntrinsicContentSize()
    }

    /// Recolours a button made by `symbolButton` (one that shows a state, as the minimap's).
    public func setSymbol(_ button: NSButton, color: NSColor? = nil) {
        guard let symbol = symbolButtons.first(where: { $0.button === button })?.symbol else { return }
        button.image = tintedSymbol(symbol, size: 13, color: color ?? NSColor(theme.text))
    }

    private func applyTheme() {
        labelColor = nil
        for (button, symbol) in symbolButtons { button.image = tintedSymbol(symbol, size: 13, color: NSColor(theme.text)) }
        divider.layer?.backgroundColor = NSColor(theme.separator).cgColor
        label.attributedTitle = labelTitle(camera.scale)
    }

    private lazy var labelFont = NSFont.ui(size: 12).monospacedDigitFont
    private var labelColor: NSColor?

    private func labelTitle(_ scale: CGFloat) -> NSAttributedString {
        let color = labelColor ?? NSColor(theme.text)
        labelColor = color
        return NSAttributedString(string: "\(Int((scale * 100).rounded())) %", attributes: [.font: labelFont, .foregroundColor: color])
    }

    @objc private func actualSize() { camera.setScale(1) }
}

/// A borderless button running a closure.
private final class CanvasControlButton: NSButton {
    private let run: () -> Void

    init(action: @escaping () -> Void) {
        run = action
        super.init(frame: .zero)
        target = self
        self.action = #selector(pressed)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc private func pressed() { run() }
}

private extension NSFont {
    var monospacedDigitFont: NSFont {
        NSFont(descriptor: fontDescriptor.addingAttributes([.featureSettings: [[
            NSFontDescriptor.FeatureKey.typeIdentifier: kNumberSpacingType,
            NSFontDescriptor.FeatureKey.selectorIdentifier: kMonospacedNumbersSelector,
        ]]]), size: pointSize) ?? self
    }
}

/// The zoom buttons of a canvas, in a Liquid Glass capsule: `CanvasZoomControlsView` in SwiftUI. `extra` adds the
/// canvas's own buttons after a divider.
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
        ZoomControlsRepresentable(camera: camera, fit: fit,
                                  extra: Extra.self == EmptyView.self ? nil : AnyView(extra.environment(\.themeTokens, theme)),
                                  theme: theme)
            .fixedSize()
    }
}

private struct ZoomControlsRepresentable: NSViewRepresentable {
    let camera: CanvasCamera
    let fit: () -> Void
    let extra: AnyView?
    let theme: ThemeTokens

    final class Coordinator {
        var host: NSHostingView<AnyView>?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> CanvasZoomControlsView {
        var views: [NSView] = []
        if let extra {
            let host = NSHostingView(rootView: extra)
            host.sizingOptions = [.intrinsicContentSize]
            context.coordinator.host = host
            views.append(host)
        }
        let view = CanvasZoomControlsView(camera: camera, fit: fit, extra: views)
        view.theme = theme
        return view
    }

    func updateNSView(_ view: CanvasZoomControlsView, context: Context) {
        view.theme = theme
        if let extra { context.coordinator.host?.rootView = extra }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: CanvasZoomControlsView, context: Context) -> CGSize? {
        nsView.intrinsicContentSize
    }
}

public extension CanvasZoomControls where Extra == EmptyView {
    init(camera: CanvasCamera, fit: @escaping () -> Void) {
        self.init(camera: camera, fit: fit) { EmptyView() }
    }
}
