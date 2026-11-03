import SwiftUI

extension View {
    /// Fades the view out over `length` points at `edges`, as Craft ends what a narrow column cuts: a line of text
    /// that runs past a card's edge thins out instead of stopping hard or wrapping letter by letter.
    public func fadingEdges(_ edges: Edge.Set, length: CGFloat = 20) -> some View {
        mask {
            EdgeFadeMask(axis: .horizontal, length: length, start: edges.contains(.leading), end: edges.contains(.trailing))
                .mask {
                    EdgeFadeMask(axis: .vertical, length: length, start: edges.contains(.top), end: edges.contains(.bottom))
                }
        }
    }

    /// Lays the view out as usual when it fits its width; otherwise keeps its natural width, cuts it at the edge
    /// and fades it out there, rather than truncating or wrapping it (a title in a narrow pane).
    public func fadingOverflow(length: CGFloat = 20) -> some View {
        ViewThatFits(in: .horizontal) {
            self
            fixedSize(horizontal: true, vertical: false)
                .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                .clipped()
                .fadingEdges(.trailing, length: length)
        }
    }

    /// For a scroll view: the glass at its edges (`Motion.EdgeGlass`). A vertical scroll view gets the macOS 26
    /// scroll edge effect (`scrollEdgeEffectStyle`, which the system draws wherever a bar sits over the scroll view)
    /// and its content fades out over the last `EdgeGlass.length` points at the top and bottom, as much as how far
    /// the content has gone beyond that edge: nothing at rest or at the end, full after `rampDistance` points. It
    /// is the content that fades, not a layer over it, so it fades into whatever is behind (a sidebar's grey, a
    /// page's white) and shows no band. A top edge that sits under the page's toolbar is left to the toolbar's own
    /// glass. A horizontal one fades out the edges that have more content beyond them, and only those (Craft's soft
    /// edges).
    /// Where the opaque colour behind is known (`scrollEdgeBackdrop`), the vertical fade is that colour drawn over the
    /// ends instead of a mask: a mask makes the render server draw everything under it off screen each frame the
    /// content moves, which held "All Notes" well under 120 fps while scrolling.
    public func softScrollEdges(_ axis: Axis = .vertical, length: CGFloat = 24) -> some View {
        modifier(SoftScrollEdges(axis: axis, length: length))
    }
}

extension EnvironmentValues {
    /// The opaque colour behind the scroll views here (a page's background, the window's canvas under a sidebar),
    /// for `softScrollEdges`; nil where it is not known or not opaque (glass).
    @Entry public var scrollEdgeBackdrop: Color?
}

extension Motion.EdgeGlass {
    /// How many blurs are stacked in a band. Each one blurs what the ones under it already blurred, so the blur grows
    /// towards the edge in steps too small to see, up to `maxBlur`.
    public static let layers = 3

    /// How much of layer `layer` (0 is the lightest and the tallest) shows at strength `progress`: the layers come in
    /// one after the other as the strength grows, so a stronger edge is also a blurrier one.
    public static func layerOpacity(layer: Int, progress: Double, layers: Int = Motion.EdgeGlass.layers) -> Double {
        guard layers > 0 else { return 0 }
        let t = min(max(progress, 0), 1) * Double(layers)
        return min(max(t - Double(layer), 0), 1)
    }

    /// The share of the band each layer covers from the edge: the first all of it, the last about a third.
    public static func layerReach(layer: Int, layers: Int = Motion.EdgeGlass.layers) -> Double {
        guard layers > 1 else { return 1 }
        return 1 - 0.65 * Double(layer) / Double(layers - 1)
    }

    /// The opacity of a band from its edge (0) to its far end (1): eased both ways, so it has no visible step where
    /// the band starts or stops.
    public static func rampOpacity(at fraction: Double) -> Double {
        let t = min(max(fraction, 0), 1)
        return 1 - t * t * (3 - 2 * t)
    }

    /// The distance in points of content beyond the top and bottom of a scroll view that shows `viewport` points
    /// of a `content` tall document from `offset`; negative while it is pulled past an end.
    public static func distances(offset: CGFloat, viewport: CGFloat, content: CGFloat) -> (top: CGFloat, bottom: CGFloat) {
        (offset, content - offset - viewport)
    }

    /// `progress(distance:)` in steps of 1/64, so a view that redraws with it does so at most 64 times over a ramp.
    public static func steppedProgress(distance: CGFloat) -> Double {
        (progress(distance: distance) * 64).rounded() / 64
    }
}

/// The glass at the top or bottom of something that scrolls, over a background of a known colour (the page): a
/// progressive blur over `length` points from the edge, strongest at the edge and gone at the other end, and a wash
/// of `tint`, that colour, over it so text coming up to the edge thins out instead of cutting. Over a background that
/// is not known (a sidebar), fade the content itself instead (`softScrollEdges`). `progress` is how far the effect has come in (0...1,
/// `Motion.EdgeGlass.progress`). With Reduce Transparency or Reduce Motion on it is the wash alone.
public struct EdgeGlassBand: View {
    public var edge: VerticalEdge
    public var progress: Double
    /// How much of the blur shows, 0...1, when it is not the wash's `progress`: a band on a bare page shows the wash
    /// alone (it is the page's own colour, so invisible) until there is something under it to blur.
    public var blur: Double
    public var length: CGFloat
    public var tint: Color?
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(edge: VerticalEdge, progress: Double, blur: Double? = nil, length: CGFloat = Motion.EdgeGlass.length, tint: Color? = nil) {
        self.edge = edge
        self.progress = progress
        self.blur = blur ?? progress
        self.length = length
        self.tint = tint
    }

    public var body: some View {
        let flat = reduceTransparency || reduceMotion
        ZStack {
            if !flat {
                ForEach(0..<Motion.EdgeGlass.layers, id: \.self) { layer in
                    Rectangle()
                        .fill(.ultraThinMaterial)
                        // Half strength: the material's own grey otherwise reads as a band across a white page.
                        .opacity(0.5 * Motion.EdgeGlass.layerOpacity(layer: layer, progress: blur))
                        .mask(ramp(reach: Motion.EdgeGlass.layerReach(layer: layer)))
                }
            }
            if let tint {
                Rectangle()
                    .fill(tint)
                    .opacity(progress * 0.95)
                    .mask(ramp(reach: 1))
            }
        }
        .frame(height: length)
        .frame(maxWidth: .infinity)
        .opacity(progress > 0 ? 1 : 0)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// Opaque at the edge, clear `reach` of the way to the far end, eased in between.
    private func ramp(reach: Double) -> some View {
        let steps = 10
        var stops = (0...steps).map { step -> Gradient.Stop in
            let fraction = Double(step) / Double(steps)
            return .init(color: .black.opacity(Motion.EdgeGlass.rampOpacity(at: fraction)), location: fraction * reach)
        }
        if reach < 1 { stops.append(.init(color: .clear, location: 1)) }
        return LinearGradient(
            stops: stops, startPoint: edge == .top ? .top : .bottom, endPoint: edge == .top ? .bottom : .top
        )
    }
}

private struct SoftScrollEdges: ViewModifier {
    let axis: Axis
    let length: CGFloat
    @State private var overflow = Overflow()
    @State private var glass = Glass()

    struct Overflow: Equatable {
        var start = false
        var end = false
    }

    /// How far the glass has come in at each end; 0 at a top end that sits under a bar (the page's toolbar).
    struct Glass: Equatable {
        var top = 0.0
        var bottom = 0.0
    }

    @Environment(\.scrollEdgeBackdrop) private var backdrop

    @ViewBuilder func body(content: Content) -> some View {
        if axis == .vertical {
            let measured = content
                .scrollEdgeEffectStyle(.soft, for: [.top, .bottom])
                .onScrollGeometryChange(for: Glass.self) { geometry in
                    let visible = geometry.visibleRect
                    let underBar = geometry.contentInsets.top > 1
                    return Glass(
                        top: underBar ? 0 : Motion.EdgeGlass.steppedProgress(distance: visible.minY),
                        bottom: Motion.EdgeGlass.steppedProgress(distance: geometry.contentSize.height - visible.maxY)
                    )
                } action: { _, new in
                    glass = new
                }
            if let backdrop {
                measured.overlay {
                    ProgressiveFade(top: glass.top, bottom: glass.bottom, backdrop: backdrop).allowsHitTesting(false)
                }
            } else {
                measured.mask { ProgressiveFade(top: glass.top, bottom: glass.bottom, backdrop: nil) }
            }
        } else {
            content
                .onScrollGeometryChange(for: Overflow.self) { geometry in
                    let visible = geometry.visibleRect
                    let size = geometry.contentSize
                    return Overflow(start: visible.minX > 1, end: visible.maxX < size.width - 1)
                } action: { _, new in
                    withAnimation(Motion.ambient) { overflow = new }
                }
                .mask { EdgeFadeMask(axis: axis, length: length, start: overflow.start, end: overflow.end) }
        }
    }
}

/// At each end a ramp over `Motion.EdgeGlass.length` that fades the content by up to 90% at the edge at full
/// strength, eased so it has no visible start; nothing at strength 0. Without a backdrop it is a mask (opaque in the
/// middle); with one, the backdrop's colour drawn over the content (clear in the middle), which looks the same.
private struct ProgressiveFade: View {
    let top: Double
    let bottom: Double
    let backdrop: Color?

    var body: some View {
        VStack(spacing: 0) {
            ramp(strength: top, towardsEdge: .top)
            backdrop == nil ? Color.black : Color.clear
            ramp(strength: bottom, towardsEdge: .bottom)
        }
    }

    private func ramp(strength: Double, towardsEdge edge: VerticalEdge) -> some View {
        let steps = 8
        let stops = (0...steps).map { step -> Gradient.Stop in
            let fraction = Double(step) / Double(steps)
            let fade = 0.9 * strength * Motion.EdgeGlass.rampOpacity(at: fraction)
            return .init(color: backdrop.map { $0.opacity(fade) } ?? .black.opacity(1 - fade), location: fraction)
        }
        return LinearGradient(stops: stops, startPoint: edge == .top ? .top : .bottom, endPoint: edge == .top ? .bottom : .top)
            .frame(height: Motion.EdgeGlass.length)
    }
}

/// Opaque in the middle, a gradient to clear at each faded end; an end that doesn't fade is opaque.
private struct EdgeFadeMask: View {
    let axis: Axis
    let length: CGFloat
    let start: Bool
    let end: Bool

    var body: some View {
        let layout = axis == .vertical ? AnyLayout(VStackLayout(spacing: 0)) : AnyLayout(HStackLayout(spacing: 0))
        layout {
            ramp(fades: start, from: axis == .vertical ? .top : .leading, to: axis == .vertical ? .bottom : .trailing)
            Color.black
            ramp(fades: end, from: axis == .vertical ? .bottom : .trailing, to: axis == .vertical ? .top : .leading)
        }
    }

    /// Clear at `from` to opaque at `to`; covered by black (an opacity, so it animates) when the end doesn't fade.
    private func ramp(fades: Bool, from: UnitPoint, to: UnitPoint) -> some View {
        ZStack {
            LinearGradient(colors: [.clear, .black], startPoint: from, endPoint: to)
            Color.black.opacity(fades ? 0 : 1)
        }
        .frame(width: axis == .horizontal ? length : nil, height: axis == .vertical ? length : nil)
    }
}
