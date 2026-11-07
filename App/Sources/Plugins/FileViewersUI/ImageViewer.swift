import AppKit
import Observation
import PluginKitUI
import SwiftUI

/// A picture of any format ImageIO reads (PNG, JPEG, HEIC, WebP, SVG, GIF…), centred on a quiet stage with a soft
/// shadow, fitted to the page and zoomable with a pinch, Command-scroll, the floating pill or a double click. An
/// animated GIF plays. A file ImageIO cannot read falls back to Quick Look.
struct ImageViewer: View {
    let view: ViewContext
    let file: FileLocation?
    @State private var zoom = ImageZoom()
    @State private var image: NSImage?
    @State private var failed = false

    var body: some View {
        ViewerFrame(view: view, file: file, detail: dimensions, showsMenu: true) { file in
            Group {
                if let image {
                    ZoomableImage(image: image, zoom: zoom)
                } else if failed {
                    QuickLookPreview(url: file.url)
                } else {
                    Color.clear
                }
            }
            .task(id: file.url) {
                zoom = ImageZoom()
                image = nil
                failed = false
                let loaded = await Task.detached { ImageViewer.load(file.url) }.value
                image = loaded?.value
                failed = loaded == nil
            }
        } bar: {
            if image != nil { ZoomControls(zoom: zoom) }
        }
    }

    private var dimensions: String? {
        guard let image, let rep = image.representations.first else { return nil }
        let width = rep.pixelsWide > 0 ? rep.pixelsWide : Int(image.size.width)
        let height = rep.pixelsHigh > 0 ? rep.pixelsHigh : Int(image.size.height)
        return "\(width) × \(height)"
    }

    /// `NSImage` is not `Sendable`; it is only read once it is back on the main actor.
    private struct Loaded: @unchecked Sendable { let value: NSImage }

    private nonisolated static func load(_ url: URL) -> Loaded? {
        guard let image = NSImage(contentsOf: url), image.size.width > 0, image.size.height > 0 else { return nil }
        return Loaded(value: image)
    }
}

/// The zoom of one picture: whether it follows the page ("fit") or the user's choice, and its factor.
@MainActor
@Observable
final class ImageZoom {
    enum Mode { case fit, actual, custom }

    var mode: Mode = .fit
    private(set) var factor: CGFloat = 1
    @ObservationIgnored fileprivate weak var scrollView: NSScrollView?
    @ObservationIgnored fileprivate var contentSize: CGSize = .zero
    @ObservationIgnored fileprivate var animates = true
    @ObservationIgnored private var observation: NSKeyValueObservation?

    var percent: Int { Int((factor * 100).rounded()) }

    fileprivate func attach(_ scrollView: NSScrollView, contentSize: CGSize) {
        self.scrollView = scrollView
        self.contentSize = contentSize
        observation = scrollView.observe(\.magnification, options: [.initial, .new]) { [weak self] view, _ in
            let value = view.magnification
            MainActor.assumeIsolated { self?.factor = value }
        }
        refit()
    }

    /// The factor that shows the whole picture, never above 100% (a small picture is not blown up).
    var fitFactor: CGFloat {
        guard let scrollView, contentSize.width > 0, contentSize.height > 0 else { return 1 }
        let room = scrollView.frame.size
        guard room.width > 0, room.height > 0 else { return 1 }
        return min(room.width / contentSize.width, room.height / contentSize.height, 1)
    }

    func fit() { mode = .fit; apply(fitFactor, animated: true) }
    func actualSize(at point: NSPoint? = nil) { mode = .actual; apply(1, animated: true, at: point) }
    func zoomIn() { step(1.25) }
    func zoomOut() { step(0.8) }

    /// The page resized: a fitted picture follows it, without animation.
    func refit() { if mode == .fit { apply(fitFactor, animated: false) } }

    /// The user pinched.
    func userMagnified() { mode = .custom }

    /// Double click: from fit to 100% where the click was, from anything else back to fit.
    func toggle(at point: NSPoint) { mode == .fit ? actualSize(at: point) : fit() }

    /// Command-scroll: zooms around the pointer.
    func scrollZoom(by delta: CGFloat, at point: NSPoint) {
        mode = .custom
        apply(factor * exp(delta * 0.012), animated: false, at: point)
    }

    private func step(_ ratio: CGFloat) {
        mode = .custom
        apply(factor * ratio, animated: true)
    }

    private func apply(_ value: CGFloat, animated: Bool, at point: NSPoint? = nil) {
        guard let scrollView else { return }
        let clamped = min(max(value, scrollView.minMagnification), scrollView.maxMagnification)
        let centre = point ?? scrollView.documentVisibleRect.center
        if animated, animates {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.2
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                scrollView.animator().magnification = clamped
            }
        } else {
            scrollView.setMagnification(clamped, centeredAt: centre)
        }
        factor = clamped
    }

    fileprivate func setReduceMotion(_ reduce: Bool) { animates = !reduce }
}

private extension NSRect {
    var center: NSPoint { NSPoint(x: midX, y: midY) }
}

private struct ZoomControls: View {
    let zoom: ImageZoom

    var body: some View {
        BarButton(symbol: "minus", help: "Zoom Out") { zoom.zoomOut() }
        Text("\(zoom.percent)%")
            .font(.ui(size: 12, weight: .medium).monospacedDigit())
            .foregroundStyle(.secondary)
            .frame(width: 44)
        BarButton(symbol: "plus", help: "Zoom In") { zoom.zoomIn() }
        BarDivider()
        BarButton(symbol: "arrow.down.right.and.arrow.up.left", help: "Fit to Page", isOn: zoom.mode == .fit) { zoom.fit() }
        BarButton(symbol: "1.square", help: "Actual Size", isOn: zoom.mode == .actual) { zoom.actualSize() }
        BarDivider()
    }
}

/// A scroll view that zooms around the pointer on Command-scroll, as Preview does, besides the pinch.
private final class ZoomScrollView: NSScrollView {
    var onScrollZoom: ((CGFloat, NSPoint) -> Void)?

    override func scrollWheel(with event: NSEvent) {
        guard event.modifierFlags.contains(.command) else { return super.scrollWheel(with: event) }
        let point = documentView?.convert(event.locationInWindow, from: nil) ?? .zero
        onScrollZoom?(event.scrollingDeltaY, point)
    }
}

/// Keeps a document smaller than the scroll view in its middle.
private final class CenteringClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var rect = super.constrainBoundsRect(proposedBounds)
        guard let document = documentView else { return rect }
        if rect.width > document.frame.width { rect.origin.x = (document.frame.width - rect.width) / 2 }
        if rect.height > document.frame.height { rect.origin.y = (document.frame.height - rect.height) / 2 }
        return rect
    }
}

/// The picture with room around it for its shadow: a rounded, clipped image over a soft shadow.
private final class PictureCanvas: NSView {
    static let margin: CGFloat = 36
    static let radius: CGFloat = 8
    let imageView = ClickableImageView()
    private let shadowView = NSView()

    init(image: NSImage) {
        let size = NSSize(width: image.size.width + 2 * Self.margin, height: image.size.height + 2 * Self.margin)
        super.init(frame: NSRect(origin: .zero, size: size))
        let box = NSRect(x: Self.margin, y: Self.margin, width: image.size.width, height: image.size.height)
        shadowView.frame = box
        shadowView.wantsLayer = true
        shadowView.layer?.shadowColor = NSColor.black.cgColor
        shadowView.layer?.shadowOpacity = 0.22
        shadowView.layer?.shadowRadius = 14
        shadowView.layer?.shadowOffset = CGSize(width: 0, height: -4)
        shadowView.layer?.shadowPath = CGPath(roundedRect: shadowView.bounds, cornerWidth: Self.radius, cornerHeight: Self.radius, transform: nil)
        addSubview(shadowView)
        imageView.frame = box
        imageView.image = image
        imageView.animates = true
        imageView.imageScaling = .scaleAxesIndependently
        imageView.wantsLayer = true
        imageView.layer?.cornerRadius = Self.radius
        imageView.layer?.cornerCurve = .continuous
        imageView.layer?.masksToBounds = true
        addSubview(imageView)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
}

private final class ClickableImageView: NSImageView {
    var onDoubleClick: ((NSPoint) -> Void)?

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            onDoubleClick?(superview.map { $0.convert(event.locationInWindow, from: nil) } ?? .zero)
        } else {
            super.mouseDown(with: event)
        }
    }
}

/// The scroll view that pans and magnifies the picture (a pinch, the trackpad's scroll).
private struct ZoomableImage: NSViewRepresentable {
    let image: NSImage
    let zoom: ImageZoom
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeNSView(context: Context) -> ZoomScrollView {
        let scrollView = ZoomScrollView()
        scrollView.contentView = CenteringClipView()
        scrollView.allowsMagnification = true
        scrollView.minMagnification = 0.02
        scrollView.maxMagnification = 32
        scrollView.hasHorizontalScroller = true
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.contentView.drawsBackground = false

        let canvas = PictureCanvas(image: image)
        canvas.imageView.onDoubleClick = { [zoom] point in zoom.toggle(at: point) }
        scrollView.documentView = canvas
        scrollView.onScrollZoom = { [zoom] delta, point in zoom.scrollZoom(by: delta, at: point) }

        context.coordinator.zoom = zoom
        context.coordinator.observe(scrollView)
        zoom.setReduceMotion(reduceMotion)
        zoom.attach(scrollView, contentSize: canvas.frame.size)
        return scrollView
    }

    func updateNSView(_ scrollView: ZoomScrollView, context: Context) { zoom.setReduceMotion(reduceMotion) }

    func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor
    final class Coordinator {
        var zoom: ImageZoom?
        private var tokens: [any NSObjectProtocol] = []

        func observe(_ scrollView: NSScrollView) {
            scrollView.postsFrameChangedNotifications = true
            let center = NotificationCenter.default
            tokens.append(center.addObserver(forName: NSView.frameDidChangeNotification, object: scrollView, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.zoom?.refit() }
            })
            tokens.append(center.addObserver(forName: NSScrollView.willStartLiveMagnifyNotification, object: scrollView, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.zoom?.userMagnified() }
            })
        }

        isolated deinit { tokens.forEach(NotificationCenter.default.removeObserver) }
    }
}
