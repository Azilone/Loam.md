import AppKit
import PluginKitUI
import SwiftUI

/// A side column that slides in from the window's edge and back out on the render server, off the main thread.
///
/// The column's SwiftUI content lives in its own hosting view, which stays at a fixed place in the window's layout:
/// showing or hiding sets its final frame at once and plays one additive spring from where it was. Nothing is laid
/// out or drawn again on the frames of the slide, so it stays smooth while the main thread is busy with the pages
/// that follow its edge. Moving the column through SwiftUI animated its frame instead, which moved the file tree's
/// scroll view on every frame (tracking areas, drag regions) and cost half of each frame.
struct SlidingColumn<Content: View>: NSViewRepresentable {
    let isShown: Bool
    let edge: HorizontalEdge
    /// With Reduce Motion the column does not slide: it cross-fades in place.
    let reduceMotion: Bool
    /// False when the change is not the user's (the page they went to has nothing for this column): it then jumps,
    /// in the same frame as the pages, instead of sliding out of step with them.
    let animated: Bool
    let content: Content

    init(isShown: Bool, edge: HorizontalEdge, reduceMotion: Bool, animated: Bool = true, @ViewBuilder content: () -> Content) {
        self.isShown = isShown
        self.edge = edge
        self.reduceMotion = reduceMotion
        self.animated = animated
        self.content = content()
    }

    func makeNSView(context: Context) -> SlidingColumnView<Content> {
        SlidingColumnView(rootView: content, edge: edge, isShown: isShown)
    }

    func updateNSView(_ view: SlidingColumnView<Content>, context: Context) {
        view.host.rootView = content
        view.setShown(isShown, reduceMotion: reduceMotion, animated: animated)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: SlidingColumnView<Content>, context: Context) -> CGSize? {
        proposal.replacingUnspecifiedDimensions(by: .zero)
    }
}

/// A sidebar column, for what needs to know whether a point is over one (the picture of a drag, `DragGhost`).
protocol SidebarColumn: NSView {}

extension SlidingColumnView: SidebarColumn {}

@MainActor
enum SidebarHitTest {
    /// Installs `DragGhost.region`: a point is over a sidebar when the view under it, in the window under the
    /// picture, sits in a sidebar column.
    static func install() {
        guard DragGhost.region == nil else { return }
        DragGhost.region = { point, below in
            let number = NSWindow.windowNumber(at: point, belowWindowWithWindowNumber: below)
            guard let window = NSApp.window(withWindowNumber: number), let content = window.contentView else { return .page }
            var view = content.hitTest(content.convert(window.convertPoint(fromScreen: point), from: nil))
            while let current = view {
                if current is SidebarColumn { return .sidebar }
                view = current.superview
            }
            return .page
        }
    }
}

final class SlidingColumnView<Content: View>: NSView {
    let host: ColumnHostingView<Content>
    private let edge: HorizontalEdge
    private(set) var isShown: Bool

    init(rootView: Content, edge: HorizontalEdge, isShown: Bool) {
        SidebarHitTest.install()
        host = ColumnHostingView(rootView: rootView)
        self.edge = edge
        self.isShown = isShown
        super.init(frame: .zero)
        wantsLayer = true
        // The column runs under the title bar, which its content leaves room for itself.
        host.safeAreaRegions = []
        host.isHidden = !isShown
        addSubview(host)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// True while the column fades out in place (Reduce Motion): it stays over its bounds until the fade is done.
    private var isFadingOut = false

    /// Where the hosting view rests: over this view's bounds while shown, one width out of the window once hidden.
    private var restFrame: NSRect {
        guard !isShown, !isFadingOut else { return bounds }
        return bounds.offsetBy(dx: edge == .leading ? -bounds.width : bounds.width, dy: 0)
    }

    override func layout() {
        super.layout()
        if host.frame != restFrame { host.frame = restFrame }
    }

    /// A hidden column takes no clicks: it is out of the window, but this view still lies behind the pages.
    override func hitTest(_ point: NSPoint) -> NSView? {
        isShown ? super.hitTest(point) : nil
    }

    func setShown(_ shown: Bool, reduceMotion: Bool, animated: Bool) {
        guard shown != isShown else { return }
        // Where the column is on screen now, which a slide in progress has not yet finished.
        let current = host.layer?.presentation()?.frame.origin.x ?? host.frame.origin.x
        let opacity = host.layer?.presentation()?.opacity ?? 1
        isShown = shown
        host.isHidden = false
        isFadingOut = reduceMotion && !shown
        host.frame = restFrame
        guard animated, window != nil, bounds.width > 0, let layer = host.layer else {
            isFadingOut = false
            host.frame = restFrame
            host.isHidden = !shown
            return
        }
        layer.removeAnimation(forKey: "slide")
        layer.removeAnimation(forKey: "fade")
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            guard let self, !self.isShown else { return }
            self.isFadingOut = false
            self.host.isHidden = true
            self.needsLayout = true
        }
        if reduceMotion {
            // Opacity is what is left of the slide: the column fades where it is.
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = shown ? opacity : 1
            fade.toValue = shown ? 1 : 0
            fade.duration = Motion.appKitDuration(SidebarMotion.duration)
            fade.timingFunction = CAMediaTimingFunction(name: shown ? .easeOut : .easeIn)
            layer.opacity = shown ? 1 : 0
            layer.add(fade, forKey: "fade")
        } else {
            layer.opacity = 1
            let slide = CASpringAnimation(perceptualDuration: SidebarMotion.duration, bounce: 0)
            slide.keyPath = "position.x"
            slide.isAdditive = true
            slide.fromValue = current - host.frame.origin.x
            slide.toValue = 0
            slide.duration = slide.settlingDuration
            layer.add(slide, forKey: "slide")
        }
        CATransaction.commit()
    }
}

/// The hosting view of a column. AppKit asks every hosting view in the window whether it accepts first responder each
/// time views move (to find the regions of the title bar that drag the window), and SwiftUI answers by walking the
/// whole focus tree: about a quarter of each frame of a page's slide. A column has nothing to focus as a whole (its
/// rows and fields take the focus themselves), so it answers at once.
final class ColumnHostingView<Content: View>: NSHostingView<Content> {
    override var acceptsFirstResponder: Bool { false }
}
