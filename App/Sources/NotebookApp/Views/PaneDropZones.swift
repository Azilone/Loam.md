import AppKit
import Observation
import PluginKitUI
import SwiftUI
import WorkspaceModel

/// Where a drag over a pane's page is, for its drop zones: the zone the pointer is on and the pointer itself, in the
/// page (top left origin). Written by the pane's AppKit drop target (`PaneHostView`), read by the zones over the page
/// (`PaneDropZones`), which move with `SplitZones.settle` as it changes.
@MainActor
@Observable
final class PaneDropState {
    var edge: DropEdge?
    var pointer: CGPoint?
    var isDragging = false

    init(edge: DropEdge? = nil, isDragging: Bool = false) {
        self.edge = edge
        self.isDragging = isDragging
    }
}

/// The drop zones over a page during a drag. As soon as a drag starts anywhere in the window, the page recedes a
/// little (`PageChromeView.setReceded`); as the pointer nears an edge of it, that edge's zone alone comes in, "Add
/// left / right / top / bottom split", drawn towards the pointer like a magnet, and lights up once over it
/// (`SplitZones`, laid out by `SplitZoneLayout`). The middle of the page outlines the whole pane: the tab lands in
/// it. In a hosting view of their own over the page, made when a drag starts and gone after it: they cost nothing the
/// rest of the time, and they do not step back with the page.
struct PaneDropZones: View {
    let state: PaneDropState

    var body: some View {
        SplitZones(edge: state.edge, pointer: state.pointer, isDragging: state.isDragging)
            .allowsHitTesting(false)
    }
}

/// Where the drop zones of a pane go, as one layout: pure, so that it can be tested at any size.
///
/// Four zones, "left", "right", "top" and "bottom", are laid out around the middle of the page without ever touching
/// one another or leaving the pane: the top and bottom ones are strips across it, the left and right ones fill the
/// room between those strips, and what stays in the middle is where a drop becomes a tab. The zone the pointer is on
/// grows towards it, and the others make way (their room is worked out again with the grown zone in it). A pane too
/// small for a pair of zones to leave a usable middle gets none of that pair.
enum SplitZoneLayout {
    /// The room kept around the zones and between them.
    static let inset: CGFloat = 10
    static let gap: CGFloat = 8
    /// What a pane's middle needs to stay: a tab can still be dropped on it.
    static let minimumMiddle = CGSize(width: 80, height: 70)
    /// An active zone grows by at most this share of its own thickness.
    static let growth: CGFloat = 0.45

    /// The thickness of the side zones and of the top and bottom ones in a pane of `size`.
    private static func thicknesses(in size: CGSize) -> (side: CGFloat, band: CGFloat) {
        (min(max(size.width * 0.215, 64), 220), min(max(size.height * 0.2, 44), 160))
    }

    /// The zones that fit in a pane of `size`: with `active` grown towards `pointer`, and the others around it.
    static func zones(in size: CGSize, active: DropEdge? = nil, pointer: CGPoint? = nil) -> [DropEdge: CGRect] {
        guard size.width > 0, size.height > 0 else { return [:] }
        let (side, band) = thicknesses(in: size)
        let fitsSides = size.width - 2 * (inset + side + gap) >= minimumMiddle.width
        let fitsBands = size.height - 2 * (inset + band + gap) >= minimumMiddle.height
        guard fitsSides || fitsBands else { return [:] }

        var leftWidth = fitsSides ? side : 0, rightWidth = leftWidth
        var topHeight = fitsBands ? band : 0, bottomHeight = topHeight
        // The grown zone takes the room towards the pointer, up to a share of its thickness, and never so much that the
        // middle goes under its minimum.
        func grown(_ base: CGFloat, reach: CGFloat?, room: CGFloat) -> CGFloat {
            let wanted = min(max(reach ?? 0, 0), base * growth)
            return base + min(wanted, max(room, 0))
        }
        let middleWidth = size.width - 2 * inset - leftWidth - rightWidth - (fitsSides ? 2 * gap : 0)
        let middleHeight = size.height - 2 * inset - topHeight - bottomHeight - (fitsBands ? 2 * gap : 0)
        switch active {
        case .leading? where fitsSides:
            leftWidth = grown(side, reach: pointer.map { $0.x - (inset + side) }, room: middleWidth - minimumMiddle.width)
        case .trailing? where fitsSides:
            rightWidth = grown(side, reach: pointer.map { (size.width - inset - side) - $0.x }, room: middleWidth - minimumMiddle.width)
        case .top? where fitsBands:
            topHeight = grown(band, reach: pointer.map { $0.y - (inset + band) }, room: middleHeight - minimumMiddle.height)
        case .bottom? where fitsBands:
            bottomHeight = grown(band, reach: pointer.map { (size.height - inset - band) - $0.y }, room: middleHeight - minimumMiddle.height)
        default: break
        }

        var zones: [DropEdge: CGRect] = [:]
        let full = CGRect(origin: .zero, size: size).insetBy(dx: inset, dy: inset)
        if fitsBands {
            zones[.top] = CGRect(x: full.minX, y: full.minY, width: full.width, height: topHeight)
            zones[.bottom] = CGRect(x: full.minX, y: full.maxY - bottomHeight, width: full.width, height: bottomHeight)
        }
        if fitsSides {
            let top = fitsBands ? full.minY + topHeight + gap : full.minY
            let bottom = fitsBands ? full.maxY - bottomHeight - gap : full.maxY
            zones[.leading] = CGRect(x: full.minX, y: top, width: leftWidth, height: bottom - top)
            zones[.trailing] = CGRect(x: full.maxX - rightWidth, y: top, width: rightWidth, height: bottom - top)
        }
        return zones
    }

    /// How far from a zone the pointer starts to bring it in, in points.
    static let approach: CGFloat = 110
    /// How far a zone leans towards the pointer at most, in points: the magnet.
    static let pull: CGFloat = 10

    /// How much of `side`'s zone shows with the pointer at `pointer`: 1 over it, falling to 0 at `approach` points
    /// away; 0 for every zone but the nearest, so the page shows one zone at a time, and for all of them with no
    /// pointer over the pane.
    static func presence(of side: DropEdge, in zones: [DropEdge: CGRect], pointer: CGPoint?) -> CGFloat {
        guard let pointer, let rect = zones[side] else { return 0 }
        let distances = zones.mapValues { distance(from: pointer, to: $0) }
        guard let nearest = distances.min(by: { $0.value < $1.value }), nearest.key == side else { return 0 }
        return max(0, 1 - nearest.value / approach)
    }

    /// Where `side`'s zone leans with the pointer at `pointer`: towards it, by up to `pull` points as it nears.
    static func lean(of side: DropEdge, rect: CGRect, pointer: CGPoint?, presence: CGFloat) -> CGSize {
        guard let pointer, presence > 0, presence < 1 else { return .zero }
        let dx = pointer.x - rect.midX, dy = pointer.y - rect.midY
        let length = max(hypot(dx, dy), 1)
        let strength = pull * presence
        return CGSize(width: dx / length * strength, height: dy / length * strength)
    }

    private static func distance(from point: CGPoint, to rect: CGRect) -> CGFloat {
        hypot(max(rect.minX - point.x, 0, point.x - rect.maxX), max(rect.minY - point.y, 0, point.y - rect.maxY))
    }

    /// The edge a drop at `point` goes to: the zone under it, the nearest one when it is in the gap or the margin around
    /// the zones, else the middle of the page. `current` is the zone lit now, whose grown size counts, so that the
    /// pointer does not flicker at its border.
    static func edge(at point: CGPoint, in size: CGSize, current: DropEdge?) -> DropEdge {
        let zones = zones(in: size, active: current, pointer: point)
        let reach = gap + inset / 2
        var nearest: (edge: DropEdge, distance: CGFloat)?
        for (edge, rect) in zones {
            let dx = max(rect.minX - point.x, 0, point.x - rect.maxX)
            let dy = max(rect.minY - point.y, 0, point.y - rect.maxY)
            let distance = hypot(dx, dy)
            if distance < (nearest?.distance ?? .infinity) { nearest = (edge, distance) }
        }
        if let nearest, nearest.distance <= reach { return nearest.edge }
        return .center
    }
}

/// The drop zones over a page during a drag ("Add left split" and "Add right split", and the same above and
/// below), laid out by `SplitZoneLayout`.
///
/// Each is a rounded, dashed region with its icon and label centred in it and clipped to it. Only the zone nearest the
/// pointer shows, more of it the closer the pointer comes, leaning towards it (`SplitZoneLayout.presence`, `lean`);
/// over it, it turns green and grows towards the pointer through a spring. The middle of the page, where a drop
/// becomes a tab, is outlined as a whole.
struct SplitZones: View {
    let edge: DropEdge?
    let pointer: CGPoint?
    let isDragging: Bool
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// How the zones move and light up.
    static let settle = Motion.Spring.settle.animation

    /// The page behind the zones: how much smaller and how much fainter it gets while a drag is under way.
    static let recede: CGFloat = 0.96
    static let recededOpacity: Double = 0.55
    static let green = Color(red: 0.19, green: 0.78, blue: 0.47)

    private static let sides: [DropEdge] = [.leading, .trailing, .top, .bottom]

    var body: some View {
        GeometryReader { proxy in
            let zones = SplitZoneLayout.zones(in: proxy.size, active: edge, pointer: pointer)
            ZStack(alignment: .topLeading) {
                ForEach(Self.sides, id: \.self) { side in
                    let presence = isDragging || edge != nil
                        ? (edge == side ? 1 : SplitZoneLayout.presence(of: side, in: zones, pointer: pointer)) : 0
                    zone(side, rect: zones[side], presence: presence)
                }
                // Always there, so that it can fade in and out with its ring.
                DropOverlay(edge: edge == .center ? .center : nil)
            }
        }
    }

    private func zone(_ side: DropEdge, rect: CGRect?, presence: CGFloat) -> some View {
        let shown = presence > 0 && rect != nil
        let rect = rect ?? .zero
        let active = edge == side
        let lean = reduceMotion ? .zero : SplitZoneLayout.lean(of: side, rect: rect, pointer: pointer, presence: presence)
        let dark = colorScheme == .dark
        let name = side == .leading ? "left" : side == .trailing ? "right" : side == .top ? "top" : "bottom"
        let symbol = side == .leading
            ? "rectangle.lefthalf.inset.filled" : side == .trailing
            ? "rectangle.righthalf.inset.filled" : side == .top
            ? "rectangle.tophalf.inset.filled" : "rectangle.bottomhalf.inset.filled"
        let tint = active ? Self.green : (dark ? Color.white.opacity(0.55) : Color.black.opacity(0.45))
        let shape = RoundedRectangle(cornerRadius: Corners.r(min(18, min(rect.width, rect.height) / 3)), style: .continuous)
        let fill = active
            ? Self.green.opacity(dark ? 0.16 : 0.12)
            : (dark ? Color.white.opacity(0.05) : Color.black.opacity(0.035))
        let border = active ? Self.green : (dark ? Color.white.opacity(0.16) : Color.black.opacity(0.16))
        // The label needs room for its words; with less, the icon stays alone, and with less still, nothing.
        let showsLabel = rect.width >= 104 && rect.height >= 64
        let showsIcon = rect.width >= 30 && rect.height >= 30
        return shape
            .fill(fill)
            .shadow(color: .black.opacity(active ? 0.28 : 0.1), radius: active ? 20 : 8, y: 3)
            .overlay { shape.strokeBorder(border, style: StrokeStyle(lineWidth: active ? 2 : 1.2, dash: [7, 6])) }
            .overlay {
                VStack(spacing: 6) {
                    Image(symbol: symbol).font(.ui(size: 17))
                    if showsLabel {
                        Text("Add \(name) split")
                            .font(.ui(size: 13, weight: .semibold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                    }
                }
                .foregroundStyle(tint)
                .padding(8)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .opacity(showsIcon ? 1 : 0)
                // Nothing of the label goes past its own zone.
                .clipShape(shape)
            }
            .frame(width: rect.width, height: rect.height)
            // A zone comes in from its own side of the page as the pointer nears it, and goes as the pointer leaves.
            .scaleEffect(reduceMotion ? 1 : 0.9 + 0.1 * presence, anchor: Self.anchor(of: side))
            .opacity(shown ? Double(min(1, presence * 1.6)) : 0)
            .offset(x: rect.minX + lean.width, y: rect.minY + lean.height)
            // Only while a drag offers the zones: hidden, they still follow the pane's size, and a spring on each
            // change animated eight frames for a third of a second after every step of a window resize.
            .animation(reduceMotion || !isDragging ? nil : Self.settle, value: rect)
            .animation(reduceMotion ? nil : Self.settle, value: active)
            .animation(reduceMotion ? nil : Self.settle, value: presence)
    }

    private static func anchor(of side: DropEdge) -> UnitPoint {
        switch side {
        case .leading: .leading
        case .trailing: .trailing
        case .top: .top
        default: .bottom
        }
    }
}

/// The highlight of a drop on the top or bottom edge or the center: the half of the pane or all of it, outlined.
///
/// A half grows from the pane's edge toward the center when the pointer reaches the edge, and shrinks back to it when
/// the pointer leaves (`Motion.Spring.standard`); the center fades in as a whole page with its ring. Under Reduce
/// Motion every one of them only fades.
struct DropOverlay: View {
    let edge: DropEdge?
    /// Whether the highlight has grown: set one step after the edge, so that it starts from the collapsed rect.
    @State private var grown: Bool
    /// The edge shown last, which the highlight shrinks back to once the pointer leaves.
    @State private var last: DropEdge
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(edge: DropEdge?) {
        self.edge = edge
        _grown = State(initialValue: edge != nil)
        _last = State(initialValue: edge ?? .center)
    }

    var body: some View {
        GeometryReader { proxy in
            let current = edge ?? last
            let rect = grown || reduceMotion
                ? Self.rect(for: current, in: proxy.size)
                : Self.collapsedRect(for: current, in: proxy.size)
            let visible = reduceMotion ? edge != nil : grown
            RoundedRectangle(cornerRadius: Corners.r(12), style: .continuous)
                .fill(SplitZones.green.opacity(current == .center ? 0.06 : 0.14))
                .overlay {
                    RoundedRectangle(cornerRadius: Corners.r(12), style: .continuous)
                        .strokeBorder(SplitZones.green.opacity(0.85), style: StrokeStyle(lineWidth: 2, dash: [7, 6]))
                }
                .frame(width: rect.width, height: rect.height)
                .offset(x: rect.minX, y: rect.minY)
                .opacity(visible ? 1 : 0)
                .animation(Motion.resolved(Motion.Spring.standard.animation, reduceMotion: reduceMotion), value: grown)
                .animation(Motion.resolved(Motion.Spring.standard.animation, reduceMotion: reduceMotion), value: current)
        }
        .onChange(of: edge) { _, new in
            if let new { last = new }
            grown = new != nil
        }
    }

    /// The sliver a highlight grows from: the pane's edge it belongs to, as thin as the inset. The center has no
    /// edge to grow from; it stays whole and only fades.
    static func collapsedRect(for edge: DropEdge, in size: CGSize) -> CGRect {
        let full = rect(for: edge, in: size)
        switch edge {
        case .center: return full
        case .leading: return CGRect(x: full.minX, y: full.minY, width: 0, height: full.height)
        case .trailing: return CGRect(x: full.maxX, y: full.minY, width: 0, height: full.height)
        case .top: return CGRect(x: full.minX, y: full.minY, width: full.width, height: 0)
        case .bottom: return CGRect(x: full.minX, y: full.maxY, width: full.width, height: 0)
        }
    }

    /// The part of a pane of `size` a drop on `edge` covers.
    static func rect(for edge: DropEdge, in size: CGSize) -> CGRect {
        let inset: CGFloat = 4
        let full = CGRect(origin: .zero, size: size).insetBy(dx: inset, dy: inset)
        guard full.width > 0, full.height > 0 else { return .zero }
        switch edge {
        case .center: return full
        case .leading: return CGRect(x: full.minX, y: full.minY, width: full.width / 2, height: full.height)
        case .trailing: return CGRect(x: full.midX, y: full.minY, width: full.width / 2, height: full.height)
        case .top: return CGRect(x: full.minX, y: full.minY, width: full.width, height: full.height / 2)
        case .bottom: return CGRect(x: full.minX, y: full.midY, width: full.width, height: full.height / 2)
        }
    }
}

/// A value a view measures but reads only when an event comes, such as a drop, held outside SwiftUI's state:
/// setting it draws nothing again. A size or a frame that changes on every frame of an animation would otherwise
/// re-render its view on each one.
final class Measured<Value> {
    var value: Value

    init(_ value: Value) {
        self.value = value
    }
}
