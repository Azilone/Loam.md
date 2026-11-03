import AppKit
import PluginKitUI
import SwiftUI

/// A mindmap tab: an infinite dotted canvas with the topics, coloured by branch and joined by curves. Everything
/// works from the keyboard (Tab, Return, arrows, Space…, `MindmapShortcuts` lists them), topics can be dragged
/// onto, before or after others and across to the other side, and every change animates.
struct MindmapView: View {
    let model: MindmapTabModel
    @Environment(\.themeTokens) private var theme
    @Environment(\.undoManager) private var undoManager
    @State private var scrollMonitor: Any?
    @State private var pointer = MindmapPointer()
    @State private var magnifyStart: CGFloat?

    var body: some View {
        Group {
            if model.root == nil {
                ContentUnavailableView {
                    Label("Note not found", symbol: LoamSymbol.mindmap)
                } description: {
                    Text(model.path)
                }
            } else {
                canvas
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(embedded ? .clear : theme.background)
        .onAppear { model.undoManager = undoManager }
        .onChange(of: undoManager) { model.undoManager = undoManager }
    }

    /// Shown in another view (a card on a board): no grid, toolbar or banner, and the keyboard only when asked.
    private var embedded: Bool { model.context.presentation == .embedded }

    private var canvas: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                MindmapGrid(offset: model.offset, scale: model.scale, color: embedded ? .clear : theme.secondaryText)
                    .contentShape(Rectangle())
                    .gesture(backgroundDrag)
                    .onTapGesture {
                        model.deselect()
                        model.requestKeyboard()
                    }
                MindmapEdges(model: model, scene: model.scene, offset: model.offset, scale: model.scale)
                    .allowsHitTesting(false)
                ForEach(model.scene) { item in
                    MindmapTopicView(model: model, item: item)
                }
                // The guides go over the dragged topic, so they stay in sight under it.
                dragGhost
                dropLink
                dropIndicator
                if let marquee = model.marquee {
                    Rectangle()
                        .fill(theme.accent.opacity(0.08))
                        .strokeBorder(theme.accent.opacity(0.6), lineWidth: 1)
                        .frame(width: marquee.width, height: marquee.height)
                        .offset(x: marquee.minX, y: marquee.minY)
                        .allowsHitTesting(false)
                }
            }
            .background {
                MindmapKeyCatcher(model: model, focusRequest: model.focusRequest) { event in handle(event) }
            }
            .coordinateSpace(.named(MindmapView.space))
            .clipped()
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                if case .active(let location) = phase { pointer.location = location } else { pointer.location = nil }
            }
            .simultaneousGesture(magnify, isEnabled: !embedded)
            .overlay(alignment: .bottom) {
                if !embedded { MindmapToolbar(model: model).padding(.bottom, 14) }
            }
            .overlay(alignment: .top) {
                if !model.isEditable, !embedded { readOnlyBanner.padding(.top, 12) }
            }
            .overlay {
                // An opaque card inside the map, never wider or taller than it (a popover was clipped by the window).
                if model.showsShortcuts {
                    ScrollView {
                        MindmapShortcuts(compact: proxy.size.width < 640)
                    }
                    .frame(maxWidth: min(800, max(proxy.size.width - 32, 200)),
                           maxHeight: max(proxy.size.height - 90, 120))
                    .fixedSize(horizontal: false, vertical: true)
                    .background(theme.background, in: RoundedRectangle(cornerRadius: Corners.r(14)))
                    .overlay(RoundedRectangle(cornerRadius: Corners.r(14)).strokeBorder(theme.secondaryText.opacity(0.25)))
                    .shadow(color: .black.opacity(0.2), radius: 16, y: 4)
                    .padding(.bottom, 50)
                    .transition(.opacity)
                }
            }
            .onAppear {
                model.viewResized(proxy.size)
                // Embedded, the map is as big as its card and the board scrolls it.
                if !embedded { installScrollMonitor() }
                if !embedded { model.requestKeyboard() }
            }
            .onDisappear { removeScrollMonitor() }
            .onChange(of: proxy.size) { model.viewResized(proxy.size) }
            // Entered on a board, the map takes the keyboard: Tab, Return and typing go to its topics.
            .onChange(of: model.context.isActive) { if embedded, model.context.isActive { model.requestKeyboard() } }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Mindmap of \(model.title)")
        }
    }

    static let space = "mindmap.canvas"

    private var readOnlyBanner: some View {
        Label("This note has sections: the map is read only. Use “New mindmap” to make an editable one.",
              symbol: "lock")
            .font(.ui(.label))
            .foregroundStyle(theme.secondaryText)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .glassEffect(.regular, in: ThemeCapsule())
    }

    // MARK: - Gestures

    /// Dragging the background draws a selection rectangle; scrolling pans (`installScrollMonitor`).
    private var backgroundDrag: some Gesture {
        DragGesture(minimumDistance: 3, coordinateSpace: .named(MindmapView.space))
            .onChanged { value in
                if model.marquee == nil {
                    model.beginMarquee(extend: NSEvent.modifierFlags.contains(.shift))
                }
                model.updateMarquee(CGRect(
                    x: min(value.startLocation.x, value.location.x),
                    y: min(value.startLocation.y, value.location.y),
                    width: abs(value.location.x - value.startLocation.x),
                    height: abs(value.location.y - value.startLocation.y)
                ))
            }
            .onEnded { _ in model.endMarquee() }
    }

    private var magnify: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                let start = magnifyStart ?? model.scale
                if magnifyStart == nil { magnifyStart = start }
                let target = start * value.magnification
                model.zoom(by: target / model.scale, around: pointer.location)
            }
            .onEnded { _ in magnifyStart = nil }
    }

    private func installScrollMonitor() {
        guard scrollMonitor == nil else { return }
        let model = model
        let pointer = pointer
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            let zooms = event.modifierFlags.contains(.command)
            let dx = event.scrollingDeltaX
            let dy = event.scrollingDeltaY
            let precise = event.hasPreciseScrollingDeltas
            let handled = MainActor.assumeIsolated { () -> Bool in
                guard let location = pointer.location else { return false }
                if zooms {
                    model.zoom(by: exp(dy * (precise ? 0.01 : 0.1)), around: location)
                } else {
                    model.pan(by: CGSize(width: dx * (precise ? 1 : 8), height: dy * (precise ? 1 : 8)))
                }
                return true
            }
            return handled ? nil : event
        }
    }

    private func removeScrollMonitor() {
        if let scrollMonitor { NSEvent.removeMonitor(scrollMonitor) }
        scrollMonitor = nil
    }

    // MARK: - Keyboard

    /// The map's keys, from its key view (`MindmapTabModel.handleKey`). True when the key was used.
    private func handle(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown, let key = MindmapKey(event) else { return false }
        return model.handleKey(key, modifiers: event.modifierFlags, isRepeat: event.isARepeat)
    }

    // MARK: - Drag feedback

    /// Where the dragged topics would land: a dashed ring around their new parent, or a bar where they would go
    /// among its children.
    @ViewBuilder private var dropIndicator: some View {
        if let target = model.dropTarget, let placement = model.placements[target.id] {
            let rect = model.screenRect(placement.frame)
            let color = MindmapStyle.color(branch: placement.branch, accent: theme.accent)
            switch target.mode {
            case .inside:
                RoundedRectangle(cornerRadius: Corners.r(12 * model.scale + 4), style: .continuous)
                    .strokeBorder(color, style: StrokeStyle(lineWidth: 2.5, dash: [6, 4]))
                    .frame(width: rect.width + 14, height: rect.height + 14)
                    .position(x: rect.midX, y: rect.midY)
                    .allowsHitTesting(false)
            case .before, .after:
                if model.mode == .timeline, placement.depth == 1 {
                    ThemeCapsule()
                        .fill(color)
                        .frame(width: 4, height: max(rect.height, 24))
                        .position(x: target.mode == .before ? rect.minX - 10 : rect.maxX + 10, y: rect.midY)
                        .allowsHitTesting(false)
                } else {
                    ThemeCapsule()
                        .fill(color)
                        .frame(width: max(rect.width, 48), height: 4)
                        .position(x: rect.midX, y: target.mode == .before ? rect.minY - 7 : rect.maxY + 7)
                        .shadow(color: color.opacity(0.4), radius: 3)
                        .allowsHitTesting(false)
                }
            }
        }
    }

    /// A dashed curve from the topic the dragged ones would hang from to the dragged topic, leaving that topic's
    /// side: it shows at once which side of the central topic a drop lands on.
    @ViewBuilder private var dropLink: some View {
        if let target = model.dropTarget, let link = dropLinkGeometry(target) {
            EdgeShape(from: link.from, c1: link.c1, c2: link.c2, to: link.to)
                .stroke(link.color, style: StrokeStyle(lineWidth: 2.5, lineCap: .round, dash: [5, 5]))
                .allowsHitTesting(false)
            Circle()
                .fill(link.color)
                .frame(width: 8, height: 8)
                .position(link.from)
                .allowsHitTesting(false)
        }
    }

    private struct DropLink {
        var from, c1, c2, to: CGPoint
        var color: Color
    }

    private func dropLinkGeometry(_ target: MindmapDropTarget) -> DropLink? {
        guard let location = model.dragLocation, let first = model.dragging.first,
              let dragged = model.placements[first] else { return nil }
        let parentID = target.mode == .inside ? target.id : model.parent(of: target.id)?.id
        guard let parentID, let parent = model.placements[parentID] else { return nil }
        let side: Int
        if parent.depth == 0 {
            side = target.side ?? (target.mode == .inside ? 1 : model.placements[target.id]?.direction ?? 1)
        } else {
            side = model.mode == .mindmap ? parent.direction : 1
        }
        let from = model.screenRect(parent.frame)
        let start = CGPoint(x: side == 1 ? from.maxX : from.minX, y: from.midY)
        let width = dragged.frame.width * model.scale
        let center = CGPoint(x: location.x - model.dragGrab.width, y: location.y - model.dragGrab.height)
        let end = CGPoint(x: center.x - CGFloat(side) * width / 2, y: center.y)
        let dx = abs(end.x - start.x) / 2
        let color = parent.depth == 0 ? theme.accent : MindmapStyle.color(branch: parent.branch, accent: theme.accent)
        return DropLink(
            from: start, c1: CGPoint(x: start.x + CGFloat(side) * dx, y: start.y),
            c2: CGPoint(x: end.x - CGFloat(side) * dx, y: end.y), to: end, color: color
        )
    }

    /// The dragged topic under the pointer, see-through so the guides under it show.
    @ViewBuilder private var dragGhost: some View {
        if let location = model.dragLocation, let first = model.dragging.first,
           let item = model.scene.first(where: { $0.id == first }) {
            let placement = item.placement
            MindmapTopicBody(
                text: item.text, depth: placement.depth, branchColor: MindmapStyle.color(
                    branch: placement.branch, accent: theme.accent),
                isSelected: true, isEditing: false
            )
            .overlay(alignment: .topTrailing) {
                if model.dragging.count > 1 {
                    Text("\(model.dragging.count)")
                        .font(.ui(.caption, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(ThemeCapsule().fill(theme.accent))
                        .offset(x: 8, y: -8)
                }
            }
            .frame(width: placement.frame.width, height: placement.frame.height)
            .scaleEffect(model.scale)
            .shadow(color: .black.opacity(0.12), radius: 10, y: 4)
            .opacity(0.45)
            .position(x: location.x - model.dragGrab.width, y: location.y - model.dragGrab.height)
            .allowsHitTesting(false)
        }
    }
}

/// Where the pointer is over the canvas, for scroll and pinch zoom. A reference so the scroll monitor sees it.
final class MindmapPointer {
    var location: CGPoint?
}

// MARK: - Background

/// The dot grid, moving and scaling with the camera.
private struct MindmapGrid: View {
    let offset: CGSize
    let scale: CGFloat
    let color: Color

    var body: some View {
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
                    dots.addEllipse(in: CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2))
                    x += step
                }
                y += step
            }
            context.fill(dots, with: .color(color.opacity(0.22)))
        }
    }
}

// MARK: - Edges

private struct MindmapEdges: View {
    let model: MindmapTabModel
    // The layout and the view, handed in by the canvas (not read from the model here), so a new layout always
    // redraws the edges together with the topics.
    let scene: [MindmapSceneTopic]
    let offset: CGSize
    let scale: CGFloat
    @Environment(\.themeTokens) private var theme

    var body: some View {
        let edges = scene.compactMap { topic in
            edge(for: topic).map { Edge(id: topic.id, faded: model.isDragged(topic.id), geometry: $0) }
        }
        ZStack {
            ForEach(edges) { edge in
                let curve = edge.geometry
                // Fading in from the parent: the branch's colour gathers toward its topic.
                EdgeShape(from: curve.from, c1: curve.c1, c2: curve.c2, to: curve.to)
                    .stroke(
                        LinearGradient(colors: [curve.color.opacity(0.35), curve.color],
                                       startPoint: UnitPoint(x: 0, y: 0), endPoint: UnitPoint(x: 1, y: 1)),
                        style: StrokeStyle(lineWidth: curve.width, lineCap: .round)
                    )
                    .opacity(edge.faded ? 0.25 : 1)
                    .transition(.opacity)
            }
        }
    }

    private struct Edge: Identifiable {
        let id: String
        let faded: Bool
        let geometry: Curve
    }

    private struct Curve {
        var from, c1, c2, to: CGPoint
        var color: Color
        var width: CGFloat
    }

    private func edge(for topic: MindmapSceneTopic) -> Curve? {
        guard let curve = MindmapEdgeCurve(topic) else { return nil }
        return Curve(
            from: screen(curve.from), c1: screen(curve.c1), c2: screen(curve.c2), to: screen(curve.to),
            color: MindmapStyle.color(branch: topic.placement.branch, accent: theme.accent),
            width: max(curve.width * scale, 0.75)
        )
    }

    private func screen(_ point: CGPoint) -> CGPoint {
        CGPoint(x: point.x * scale + offset.width, y: point.y * scale + offset.height)
    }
}

/// A cubic curve whose four points animate, so edges morph with the layout.
private struct EdgeShape: Shape {
    var from: CGPoint
    var c1: CGPoint
    var c2: CGPoint
    var to: CGPoint

    var animatableData: AnimatablePair<AnimatablePair<CGPoint.AnimatableData, CGPoint.AnimatableData>,
        AnimatablePair<CGPoint.AnimatableData, CGPoint.AnimatableData>> {
        get { AnimatablePair(AnimatablePair(from.animatableData, c1.animatableData),
                             AnimatablePair(c2.animatableData, to.animatableData)) }
        set {
            from.animatableData = newValue.first.first
            c1.animatableData = newValue.first.second
            c2.animatableData = newValue.second.first
            to.animatableData = newValue.second.second
        }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: from)
        path.addCurve(to: to, control1: c1, control2: c2)
        return path
    }
}

/// A fine grain over a topic: tiny dots at random places, the same on every draw, as the grain of printed paper.
private struct TopicGrain: View {
    let color: Color
    let opacity: Double
    let seed: Int

    var body: some View {
        Canvas { context, size in
            var dots = Path()
            let count = Int(size.width * size.height / 14)
            for i in 0..<count {
                let x = HalftoneNoise.hash(i &* 3 &+ seed, seed) * size.width
                let y = HalftoneNoise.hash(i &* 7 &+ seed, seed &+ 1) * size.height
                let r = 0.35 + 0.35 * HalftoneNoise.hash(i, seed &+ 2)
                dots.addEllipse(in: CGRect(x: x - r, y: y - r, width: 2 * r, height: 2 * r))
            }
            context.fill(dots, with: .color(color.opacity(opacity)))
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Topics

/// One topic on the canvas: placed by the layout, selectable, editable, draggable, foldable.
private struct MindmapTopicView: View {
    let model: MindmapTabModel
    let item: MindmapSceneTopic
    @Environment(\.themeTokens) private var theme
    @State private var hovered = false
    @State private var dragStarted = false

    var body: some View {
        let placement = item.placement
        let rect = model.screenRect(placement.frame)
            let color = MindmapStyle.color(branch: placement.branch, accent: theme.accent)
            let isEditing = model.editingID == item.id
            let parentDelta = parentOffset(placement)
            content(placement: placement, color: color, isEditing: isEditing)
                .frame(width: placement.frame.width, height: placement.frame.height)
                .overlay(alignment: placement.direction == 1 ? .trailing : .leading) {
                    foldToggle(placement: placement, color: color)
                }
                .scaleEffect(model.scale)
                .frame(width: rect.width, height: rect.height)
                .position(x: rect.midX, y: rect.midY)
                .opacity(model.isDragged(item.id) ? 0.3 : 1)
                .transition(.asymmetric(
                    insertion: .modifier(active: GrowFrom(offset: parentDelta, scale: 0.2, opacity: 0),
                                         identity: GrowFrom(offset: .zero, scale: 1, opacity: 1)),
                    removal: .modifier(active: GrowFrom(offset: parentDelta, scale: 0.2, opacity: 0),
                                       identity: GrowFrom(offset: .zero, scale: 1, opacity: 1))
                ))
                .zIndex(isEditing ? 2 : model.selection.contains(item.id) ? 1 : 0)
    }

    @ViewBuilder
    private func content(placement: MindmapPlacement, color: Color, isEditing: Bool) -> some View {
        let selected = model.selection.contains(item.id)
        MindmapTopicBody(
            text: item.text, depth: placement.depth, branchColor: color, isSelected: selected,
            isEditing: isEditing, isHovered: hovered,
            editor: isEditing ? AnyView(MindmapTopicEditor(model: model, depth: placement.depth)) : nil
        )
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .gesture(tap)
        .gesture(drag)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(item.text.isEmpty ? "Empty topic" : item.text)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { model.select(item.id) }
        .accessibilityAction(named: "Edit") { model.startEdit(item.id) }
    }

    /// A click selects (Shift adds to the selection); a double click edits.
    private var tap: some Gesture {
        SpatialTapGesture()
            .onEnded { _ in
                let event = NSApp.currentEvent
                if (event?.clickCount ?? 1) >= 2 {
                    model.startEdit(item.id)
                } else if model.editingID != item.id {
                    model.select(item.id, extend: event?.modifierFlags.contains(.shift) == true)
                    model.requestKeyboard()
                }
            }
    }

    private var drag: some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .named(MindmapView.space))
            .onChanged { value in
                guard model.editingID != item.id else { return }
                if !dragStarted {
                    dragStarted = true
                    let rect = model.screenRect(item.placement.frame)
                    model.beginDrag(item.id, grab: CGSize(width: value.startLocation.x - rect.midX,
                                                          height: value.startLocation.y - rect.midY))
                }
                model.updateDrag(to: value.location)
            }
            .onEnded { _ in
                guard dragStarted else { return }
                dragStarted = false
                model.endDrag()
            }
    }

    /// The small circle on a topic's outer side: shows the hidden count of a folded branch, folds or unfolds.
    @ViewBuilder
    private func foldToggle(placement: MindmapPlacement, color: Color) -> some View {
        let isFolded = model.folded.contains(item.id)
        let visible = placement.depth > 0 && item.childCount > 0
            && (isFolded || hovered || model.selection.contains(item.id))
        if visible {
            Group {
                if isFolded {
                    Text("\(item.descendantCount)")
                        .font(.ui(size: 10, weight: .semibold).monospacedDigit())
                        .padding(.horizontal, 5)
                } else {
                    ThemeCapsule().frame(width: 7, height: 1.5)
                }
            }
            .foregroundStyle(isFolded ? .white : theme.secondaryText)
            .frame(minWidth: 18, minHeight: 18)
            .background(ThemeCapsule().fill(isFolded ? color : theme.background))
            .overlay(ThemeCapsule().strokeBorder(color, lineWidth: 1.5))
            .contentShape(ThemeCapsule())
            .onTapGesture { model.toggleFold(item.id) }
            .offset(x: placement.direction == 1 ? 16 : -16, y: placement.depth >= 2 ? placement.frame.height / 2 - 1 : 0)
            .transition(.scale(scale: 0.5).combined(with: .opacity))
            .help(isFolded ? "\(item.descendantCount) hidden topics: click to unfold (⌥⌘→ or ⌘.)"
                : "Fold (⌥⌘← or ⌘.)")
            .accessibilityLabel(isFolded ? "Unfold, \(item.descendantCount) hidden topics" : "Fold")
        }
    }

    /// From this topic's centre to its parent's, on screen: where it grows from and folds back into.
    private func parentOffset(_ placement: MindmapPlacement) -> CGSize {
        guard let from = item.parentFrame else { return .zero }
        return CGSize(width: (from.midX - placement.frame.midX) * model.scale,
                      height: (from.midY - placement.frame.midY) * model.scale)
    }
}

/// How a topic looks: a filled pill for the central topic, a tinted box for main branches, text on a coloured
/// underline below them.
struct MindmapTopicBody: View {
    let text: String
    let depth: Int
    let branchColor: Color
    let isSelected: Bool
    let isEditing: Bool
    var isHovered = false
    var editor: AnyView?
    @Environment(\.themeTokens) private var theme
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let radius: CGFloat = depth == 0 ? 15 : depth == 1 ? 10 : 6
        ZStack {
            background(radius: radius)
            Group {
                if let editor {
                    editor
                } else {
                    Text(text.isEmpty ? AttributedString("Topic") : MindmapStyle.attributed(text))
                        .font(Font(MindmapStyle.font(depth: depth)))
                        .foregroundStyle(textColor.opacity(text.isEmpty ? 0.45 : 1))
                        // Boxed topics centre their text, as XMind and MindNode do; the underlined ones below them
                        // read from their branch's line.
                        .multilineTextAlignment(depth <= 1 ? .center : .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(MindmapStyle.padding(depth: depth))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: depth <= 1 ? .center : .leading)
        }
        .overlay {
            // The selection ring.
            RoundedRectangle(cornerRadius: Corners.r(radius + 5), style: .continuous)
                .strokeBorder(theme.accent, lineWidth: 2)
                .padding(-5)
                .opacity(isSelected || isEditing ? 1 : isHovered && depth > 0 ? 0.3 : 0)
                .scaleEffect(isSelected || isEditing ? 1 : 0.97)
                .animation(Motion.hover, value: isSelected)
        }
    }

    private var textColor: Color {
        depth == 0 ? .white : theme.text
    }

    @ViewBuilder
    private func background(radius: CGFloat) -> some View {
        let shape = RoundedRectangle(cornerRadius: Corners.r(radius), style: .continuous)
        switch depth {
        case 0:
            // Ink on paper: the accent, a shade lighter toward the top left, a fine grain of light, a lit top edge.
            shape.fill(LinearGradient(
                colors: [theme.accent.mix(with: .white, by: 0.14), theme.accent, theme.accent.mix(with: .black, by: 0.12)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            ))
            .overlay { TopicGrain(color: .white, opacity: 0.16, seed: 3).clipShape(shape) }
            .overlay {
                HalftoneCloud(corner: .bottomTrailing, step: 2, seed: 9, color: .white.opacity(0.22)).clipShape(shape)
            }
            .overlay {
                shape.strokeBorder(LinearGradient(colors: [.white.opacity(0.4), .white.opacity(0)], startPoint: .top, endPoint: .center), lineWidth: 1)
            }
            .shadow(color: theme.accent.opacity(0.18), radius: 1, y: 1)
            .shadow(color: theme.accent.opacity(0.22), radius: 14, y: 6)
        case 1:
            // A tint of the branch's colour, fading down, with a grain of it: a pastel print rather than a flat fill.
            shape.fill(LinearGradient(
                colors: [branchColor.opacity(colorScheme == .dark ? 0.26 : 0.15), branchColor.opacity(colorScheme == .dark ? 0.14 : 0.07)],
                startPoint: .top, endPoint: .bottom
            ))
            .background(shape.fill(theme.background))
            .overlay { TopicGrain(color: branchColor, opacity: 0.22, seed: depth + 11).clipShape(shape) }
            .overlay(shape.strokeBorder(branchColor.opacity(0.45), lineWidth: 1))
        default:
            UnevenRoundedRectangle(topLeadingRadius: 5, topTrailingRadius: 5, style: .continuous)
                .fill(isEditing ? theme.background : isHovered ? theme.text.opacity(0.05) : .clear)
                .overlay(alignment: .bottom) {
                    Rectangle().fill(branchColor).frame(height: 2)
                }
        }
    }
}

/// The topic being edited.
private struct MindmapTopicEditor: View {
    let model: MindmapTabModel
    let depth: Int
    @Environment(\.themeTokens) private var theme

    var body: some View {
        MindmapTextField(
            model: model, font: MindmapStyle.font(depth: depth),
            color: depth == 0 ? .white : NSColor(theme.text)
        )
    }
}

/// Grows from (and folds back into) the parent topic.
private struct GrowFrom: ViewModifier {
    let offset: CGSize
    let scale: CGFloat
    let opacity: Double

    func body(content: Content) -> some View {
        content
            .scaleEffect(scale)
            .offset(offset)
            .opacity(opacity)
    }
}

// MARK: - Toolbar

/// The floating bar under the map: zoom, fit, layout, folding and the shortcuts.
private struct MindmapToolbar: View {
    @Bindable var model: MindmapTabModel
    @Environment(\.themeTokens) private var theme

    var body: some View {
        HStack(spacing: 2) {
            button("minus", "Zoom out (⌘-)") { model.zoom(by: 0.8, animated: true) }
            Button { model.setScale(1) } label: {
                Text("\(Int((model.scale * 100).rounded())) %")
                    .font(.ui(.label).monospacedDigit())
                    .frame(minWidth: 52)
            }
            .buttonStyle(.plain)
            .help("Actual size")
            button("plus", "Zoom in (⌘+)") { model.zoom(by: 1.25, animated: true) }
            divider
            button("arrow.up.left.and.arrow.down.right", "Zoom to fit (⌘0)") { model.fit() }
            Menu {
                Picker("Layout", selection: Binding(get: { model.mode }, set: { model.setMode($0) })) {
                    ForEach(MindmapLayoutMode.allCases, id: \.self) { mode in
                        Label(mode.title, symbol: mode.systemImage).tag(mode)
                    }
                }
                .pickerStyle(.inline)
                Divider()
                Button("Fold all (⌥⇧⌘←)") { model.setAllFolded(true) }
                Button("Unfold all (⌥⇧⌘→)") { model.setAllFolded(false) }
                Divider()
                Button("Open the note") { model.openNote() }
            } label: {
                Image(symbol: model.mode.systemImage)
                    .frame(width: 30, height: 26)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Layout")
            divider
            button("keyboard", "Keyboard shortcuts (?)") { model.showsShortcuts.toggle() }
        }
        .foregroundStyle(theme.text)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .glassEffect(.regular, in: ThemeCapsule())
    }

    private var divider: some View {
        Divider().frame(height: 16).padding(.horizontal, 4)
    }

    private func button(_ image: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button { action() } label: {
            Image(symbol: image).frame(width: 30, height: 26).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

/// The list of shortcuts, from the toolbar's keyboard button, `?`, or the palette's "Mindmap: keyboard shortcuts".
/// The keys are the defaults; the palette shows a command's key after `.loam/config.json` changed it.
struct MindmapShortcuts: View {
    /// One column, for a map in a narrow pane.
    var compact = false

    static let sections: [(String, [(String, String)])] = [
        ("Add and edit", [
            ("⇥", "Add a child, also while typing"),
            ("↩", "Add a sibling, also while typing (twice: stop)"),
            ("⇧↩  ⌥↩", "Add a sibling above"), ("Space  F2", "Edit the topic, or type over it (Esc: undo that)"),
            ("Esc", "Stop editing (again: clear the selection)"), ("⌫", "Delete the topic"),
        ]),
        ("Move", [
            ("⌘↑  ⌘↓", "Move up or down among siblings"), ("⇧⇥", "Move up a level"),
            ("⌘←  ⌘→", "Move left or right, across to the other side"),
            ("Drag", "Move onto, beside, or across to the other side"),
        ]),
        ("Select and fold", [
            ("←  ↑  →  ↓", "Select the topic that way (outward: unfold)"), ("Home", "Select the central topic"),
            ("⌥⌘←  ⌥⌘→", "Fold or unfold the topic"), ("⌘.", "Fold or unfold the selected topics"),
            ("⌥⇧⌘←  ⌥⇧⌘→", "Fold all or unfold all"), ("⇧click  ⌘A", "Select several (or drag around them)"),
        ]),
        ("View", [
            ("⌘0  !", "Zoom to fit"), ("@", "Zoom to the selection"), ("⌘+  ⌘-", "Zoom (or pinch, ⌘ scroll)"),
            ("Scroll", "Pan"), ("⌘↩", "Open the note"), ("?", "These shortcuts"),
        ]),
        ("History", [("⌘Z  ⇧⌘Z", "Undo or redo"), ("⌘C  ⌘X  ⌘V", "Copy, cut, paste as a Markdown list")]),
    ]

    /// Two columns, so the list fits above the toolbar of a small window.
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Keyboard shortcuts").font(.ui(.emphasis))
                Text("? or Esc to close").font(.ui(.label)).foregroundStyle(.secondary)
            }
            if compact {
                column(Self.sections)
            } else {
                HStack(alignment: .top, spacing: 28) {
                    column(Self.sections.filter { ["Add and edit", "Move", "History"].contains($0.0) })
                    column(Self.sections.filter { !["Add and edit", "Move", "History"].contains($0.0) })
                }
            }
        }
        .padding(18)
        .frame(maxWidth: 800)
    }

    private func column(_ sections: [(String, [(String, String)])]) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 5) {
            ForEach(sections, id: \.0) { section in
                GridRow {
                    Text(section.0).font(.ui(.body, weight: .semibold)).padding(.top, 6)
                        .gridCellColumns(2)
                }
                ForEach(section.1, id: \.1) { row in
                    if compact {
                        GridRow {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(row.0).font(.ui(.label, weight: .medium)).foregroundStyle(.secondary)
                                Text(row.1).fixedSize(horizontal: false, vertical: true)
                            }
                            .gridCellColumns(2)
                        }
                    } else {
                        GridRow {
                            Text(row.1).fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Text(row.0).font(.ui(.label)).foregroundStyle(.secondary)
                                .fixedSize(horizontal: true, vertical: false)
                                .gridColumnAlignment(.trailing)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}
