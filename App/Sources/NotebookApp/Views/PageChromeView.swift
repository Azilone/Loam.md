import AppKit
import PluginKitUI
import SwiftUI

/// A pane's page as AppKit draws it (docs/DESIGN.md, "Look"): the theme's background, rounded, a hairline ring and a
/// soft layered shadow, its content cut at its rounded edge. All of it in Core Animation layers: a window resize only
/// sets their frames, and the render server draws them.
///
/// The last page follows a sidebar's slide with its trailing edge (`followSlide`): past its place while the column
/// comes in (or while the workspace is left of its place, the left sidebar opening), short of it while the inspector
/// goes. The page is laid out once at its new width; only the edge moves, on the render server.
///
/// While a tab or a note is dragged, the page steps back (`isReceded`): a little smaller and fainter, so the drop
/// zones over it read as offered rather than covering it.
final class PageChromeView: ShellView {
    /// What the page shows, cut at the page's rounded edge.
    let content: NSView
    private let clip = ShellView()
    private let wideShadow = CALayer()
    private let tightShadow = CALayer()
    private let background = CALayer()
    private let ring = CALayer()

    var theme: ThemeTokens = .standard { didSet { if theme != oldValue { updateColors() } } }

    init(content: NSView) {
        self.content = content
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = false
        for shadow in [wideShadow, tightShadow] {
            shadow.shadowColor = NSColor.black.cgColor
            shadow.shadowOpacity = 1
            layer?.addSublayer(shadow)
        }
        layer?.addSublayer(background)
        clip.wantsLayer = true
        clip.layer?.masksToBounds = true
        clip.addSubview(content)
        addSubview(clip)
        // Over the content, as SwiftUI's overlay was.
        ring.borderWidth = 1
        layer?.addSublayer(ring)
        for corner in [wideShadow, tightShadow, background, ring] { corner.cornerCurve = .continuous }
        clip.layer?.cornerCurve = .continuous
        updateColors()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }

    private var radius: CGFloat { Corners.r(Glass.pageRadius) }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for shape in [wideShadow, tightShadow, background] {
            shape.frame = bounds
            shape.cornerRadius = radius
        }
        // A stroke centred on the page's edge, half in and half out, as SwiftUI strokes a shape.
        ring.frame = bounds.insetBy(dx: -0.5, dy: -0.5)
        ring.cornerRadius = radius + 0.5
        CATransaction.commit()
        if clip.frame != bounds { clip.frame = bounds }
        clip.layer?.cornerRadius = radius
        if content.frame != clip.bounds { content.frame = clip.bounds }
        // The ring stays over the content's layers, which AppKit may have put in front as subviews came.
        if layer?.sublayers?.last !== ring { layer?.addSublayer(ring) }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColors()
    }

    private var isDark: Bool { effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua }

    /// The page's colours: the theme's background, the shadows and the ring of `PageChrome` (light and dark).
    private func updateColors() {
        let dark = isDark
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let page = NSColor(theme.background).cgColor
            background.backgroundColor = page
            // The shadows are cast by shapes of the page's colour under it, never by its content.
            for shadow in [wideShadow, tightShadow] { shadow.backgroundColor = page }
            ring.borderColor = NSColor(Color.primary.opacity(dark ? 0.1 : 0.06)).cgColor
        }
        // Down the page: its layers are flipped, as the view is.
        tightShadow.shadowColor = NSColor.black.withAlphaComponent(dark ? 0.3 : 0.05).cgColor
        tightShadow.shadowRadius = 1
        tightShadow.shadowOffset = CGSize(width: 0, height: 1)
        wideShadow.shadowColor = NSColor.black.withAlphaComponent(dark ? 0.3 : 0.05).cgColor
        wideShadow.shadowRadius = 6
        wideShadow.shadowOffset = CGSize(width: 0, height: 3)
        CATransaction.commit()
    }

    // MARK: Sidebar slides

    /// Plays a sidebar's slide on the page's trailing edge: it starts `bleed` points past its place (short of it when
    /// negative) and comes back to it with the slide's spring. Past its place, only the page's colour reaches out; short
    /// of it, the content is cut there too.
    func followSlide(bleed: CGFloat, reduceMotion: Bool) {
        let bleed = bleed.rounded()
        guard bleed != 0, !reduceMotion, window != nil else { return }
        var layers = [wideShadow, tightShadow, background, ring]
        if bleed < 0, let clipLayer = clip.layer { layers.append(clipLayer) }
        CATransaction.begin()
        for layer in layers {
            let width = SplitTreeView.spring(.slide, keyPath: "bounds.size.width")
            width.isAdditive = true
            width.fromValue = bleed
            width.toValue = 0
            layer.add(width, forKey: "slide.width")
            // Its leading edge stays where it is: the layer grows from its anchor, the centre of a plain layer but the
            // leading edge of a view's (the clip), whose content moved with it by half the bleed.
            guard layer.anchorPoint.x != 0 else { continue }
            let position = SplitTreeView.spring(.slide, keyPath: "position.x")
            position.isAdditive = true
            position.fromValue = bleed * layer.anchorPoint.x
            position.toValue = 0
            layer.add(position, forKey: "slide.position")
        }
        CATransaction.commit()
    }

    // MARK: Drags

    private(set) var isReceded = false

    /// Steps the page back while a drag offers the drop zones, and forward again once it ends, with
    /// `Motion.Spring.smooth`: a whole page never overshoots (with `settle` it swelled past its size on the drop).
    /// Under Reduce Motion it only fades.
    func setReceded(_ receded: Bool, reduceMotion: Bool) {
        guard receded != isReceded, let layer else { return }
        isReceded = receded
        let presentation = layer.presentation()
        let opacity: Float = receded ? Float(SplitZones.recededOpacity) : 1
        let scale = receded && !reduceMotion ? SplitZones.recede : 1
        // Scaled about the page's centre: a sublayer transform applies about the layer's anchor point.
        let dx = bounds.width * (0.5 - layer.anchorPoint.x), dy = bounds.height * (0.5 - layer.anchorPoint.y)
        let transform = CATransform3DConcat(
            CATransform3DConcat(CATransform3DMakeTranslation(-dx, -dy, 0), CATransform3DMakeScale(scale, scale, 1)),
            CATransform3DMakeTranslation(dx, dy, 0)
        )
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let fade = reduceMotion ? CABasicAnimation(keyPath: "opacity") : SplitTreeView.spring(.smooth, keyPath: "opacity")
        if reduceMotion { fade.duration = 0.12 }
        fade.fromValue = presentation?.opacity ?? layer.opacity
        fade.toValue = opacity
        layer.opacity = opacity
        layer.add(fade, forKey: "recede.fade")
        if !reduceMotion {
            let size = SplitTreeView.spring(.smooth, keyPath: "sublayerTransform")
            size.fromValue = NSValue(caTransform3D: presentation?.sublayerTransform ?? layer.sublayerTransform)
            size.toValue = NSValue(caTransform3D: transform)
            layer.add(size, forKey: "recede.scale")
        }
        layer.sublayerTransform = transform
        CATransaction.commit()
    }
}
