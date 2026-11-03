import AppKit
import PluginKitUI
import SwiftUI

/// A graph tab: the canvas fills the page, with its title and tools floating on top, as in Craft's pages.
struct GraphView: View {
    @Bindable var model: GraphTabModel
    @Environment(\.themeTokens) private var theme
    @FocusState private var filtering: Bool

    var body: some View {
        ZStack(alignment: .top) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .simultaneousGesture(TapGesture().onEnded { filtering = false })
            GraphHeader(model: model, filtering: $filtering)
        }
        .background(theme.background)
    }

    @ViewBuilder private var content: some View {
        if model.data.nodes.isEmpty {
            if model.isLocal, model.data.center == nil, model.filter.tag.isEmpty {
                EmptyState("Note not found", symbol: "point.3.connected.trianglepath.dotted", message: model.center ?? "")
                    .frame(maxHeight: .infinity)
            } else {
                EmptyState("No notes", symbol: "point.3.connected.trianglepath.dotted", message: "No note matches the filter.")
                    .frame(maxHeight: .infinity)
            }
        } else {
            GraphCanvas(model: model)
        }
    }
}

/// The page's title on the left, its tools on the right: one bar to filter by tag, one button for the options.
private struct GraphHeader: View {
    @Bindable var model: GraphTabModel
    var filtering: FocusState<Bool>.Binding
    @Environment(\.themeTokens) private var theme
    @State private var showsOptions = false

    var body: some View {
        PageHeader(model.isLocal ? "Local graph" : "Graph", subtitle: model.centerTitle) { tools }
            .pageColumn(.full)
            .padding(.horizontal, PageMetrics.edge)
            .padding(.bottom, Space.s)
        .zIndex(1)
    }

    private var tools: some View {
        HStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(symbol: "number")
                    .font(.ui(size: 12, weight: .medium))
                    .foregroundStyle(theme.secondaryText)
                TextField("Filter by tag", text: $model.filter.tag)
                    .textFieldStyle(.plain)
                    .font(.ui(size: 13))
                    .focused(filtering)
                    .onExitCommand {
                        if model.filter.tag.isEmpty { filtering.wrappedValue = false } else { model.filter.tag = "" }
                    }
                    .onSubmit { filtering.wrappedValue = false }
                if !model.filter.tag.isEmpty {
                    Button { model.filter.tag = "" } label: {
                        Image(symbol: "xmark.circle.fill").foregroundStyle(theme.secondaryText.opacity(0.7))
                    }
                    .buttonStyle(.plain)
                    .help("Clear the filter")
                }
            }
            .padding(.leading, 12)
            .padding(.trailing, 8)
            .frame(width: 190)

            Rectangle().fill(theme.separator.opacity(0.6)).frame(width: 1, height: 16)

            Button { showsOptions.toggle() } label: {
                Image(symbol: "slider.horizontal.3")
                    .font(.ui(size: 13, weight: .medium))
                    .foregroundStyle(theme.text.opacity(0.8))
                    .frame(width: 38, height: 30)
                    .overlay(alignment: .topTrailing) {
                        Circle().fill(theme.accent).frame(width: 6, height: 6)
                            .padding(.top, 5).padding(.trailing, 9)
                            .opacity(model.hasCustomOptions ? 1 : 0)
                    }
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Graph options")
            .popover(isPresented: $showsOptions, arrowEdge: .bottom) { GraphOptions(model: model) }
        }
        .frame(height: 32)
        .background(ThemeCapsule().fill(theme.background))
        .overlay(ThemeCapsule().strokeBorder(theme.separator.opacity(0.6)))
        .overlay(alignment: .topLeading) {
            if filtering.wrappedValue { suggestions.offset(y: 38) }
        }
        .animation(Motion.hover, value: model.hasCustomOptions)
    }

    /// The tags to pick from under the bar: all of them when it is empty, else the ones matching what is typed.
    @ViewBuilder private var suggestions: some View {
        let tags = model.tagSuggestions()
        if !tags.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(tags) { tag in
                    Button {
                        model.filter.tag = tag.name
                        filtering.wrappedValue = false
                    } label: {
                        HStack {
                            Text("#" + tag.name)
                                .foregroundStyle(theme.text)
                            Spacer(minLength: 12)
                            Text("\(tag.count)")
                                .foregroundStyle(theme.secondaryText)
                        }
                        .font(.ui(size: 13))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(4)
            .frame(width: 190)
            .background(RoundedRectangle(cornerRadius: Corners.r(10)).fill(theme.background))
            .overlay(RoundedRectangle(cornerRadius: Corners.r(10)).strokeBorder(theme.separator.opacity(0.6)))
            .shadow(color: .black.opacity(0.08), radius: 10, y: 4)
            .transition(.opacity)
        }
    }
}

/// The options popover: what the graph shows beyond the tag filter.
private struct GraphOptions: View {
    @Bindable var model: GraphTabModel
    @Environment(\.themeTokens) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Toggle(isOn: $model.filter.showOrphans) {
                Text("Notes without links")
            }
            .toggleStyle(.loam)
            if model.isLocal {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Distance from the note")
                    Picker("Distance from the note", selection: $model.filter.depth) {
                        Text("1 link").tag(1)
                        Text("2 links").tag(2)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
            }
        }
        .font(.ui(size: 13))
        .foregroundStyle(theme.text)
        .padding(16)
        .frame(width: 240)
    }
}

/// The graph drawn on a `Canvas`, as in Obsidian: the layout moves live until it settles, a node can be dragged
/// (its neighbours follow), dragging the background pans, scrolling or pinching zooms, hovering a note highlights
/// its neighbours, and a click opens it. Notes grow in when they appear and the highlight eases in and out.
private struct GraphCanvas: View {
    let model: GraphTabModel
    @Environment(\.themeTokens) private var theme
    @State private var drag: CanvasDrag?
    @State private var magnifyStart: CGFloat?
    @State private var scrollMonitor: Any?
    @State private var pointer = PointerBox()

    /// What a press on the canvas does, decided where it starts.
    private enum CanvasDrag {
        case node(Int, moved: Bool)
        case pan(from: CGSize)
    }

    /// How far the pointer moves before a press on a node becomes a drag rather than a click.
    private static let clickSlop: CGFloat = 4

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            // Read here so a camera move redraws the canvas even when the layout is at rest.
            let revision = model.cameraRevision
            TimelineView(.animation(paused: !model.isAnimating)) { timeline in
                Canvas { context, size in
                    _ = revision
                    if model.isAnimating { model.frame(at: timeline.date, in: size) }
                    draw(in: &context, size: size)
                }
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let location):
                    pointer.location = location
                    pointer.size = size
                    let node = model.node(at: location, in: size)
                    if node != model.hovered { model.hovered = node }
                case .ended:
                    pointer.location = nil
                    model.hovered = nil
                }
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in changed(value, in: size) }
                    .onEnded { _ in ended() }
            )
            .simultaneousGesture(
                MagnifyGesture()
                    .onChanged { value in
                        let start = magnifyStart ?? model.scale
                        if magnifyStart == nil { magnifyStart = start }
                        let factor = start * value.magnification / model.scale
                        model.zoom(by: factor, around: value.startLocation, in: size)
                    }
                    .onEnded { _ in magnifyStart = nil }
            )
            .overlay(alignment: .bottomLeading) {
                Text(model.stats)
                    .font(.ui(size: 12))
                    .foregroundStyle(theme.secondaryText)
                    .padding(20)
                    .allowsHitTesting(false)
            }
            .overlay(alignment: .bottomTrailing) {
                RecenterButton(model: model)
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(model.summary)
            .accessibilityChildren {
                ForEach(Array(model.data.nodes.enumerated()), id: \.element.path) { index, node in
                    Text(node.title)
                        .accessibilityAddTraits(.isButton)
                        .accessibilityValue(node.degree == 1 ? "1 link" : "\(node.degree) links")
                        .accessibilityAction { model.open(index) }
                }
            }
            .onAppear { installScrollMonitor() }
            .onDisappear { removeScrollMonitor() }
        }
        .clipped()
    }

    private func changed(_ value: DragGesture.Value, in size: CGSize) {
        let distance = hypot(value.translation.width, value.translation.height)
        if drag == nil {
            if let node = model.node(at: value.startLocation, in: size) {
                drag = .node(node, moved: false)
            } else {
                drag = .pan(from: model.offset)
            }
        }
        switch drag {
        case .node(let index, let moved):
            guard moved || distance > Self.clickSlop else { return }
            if !moved {
                model.beginDrag(index)
                drag = .node(index, moved: true)
            }
            model.drag(to: value.location, in: size)
        case .pan(let start):
            guard distance > 0 else { return }
            model.setOffset(CGSize(
                width: start.width + value.translation.width,
                height: start.height + value.translation.height
            ))
        case nil:
            break
        }
    }

    private func ended() {
        if case .node(let index, let moved) = drag {
            if moved { model.endDrag() } else { model.open(index) }
        }
        drag = nil
    }

    private func draw(in context: inout GraphicsContext, size: CGSize) {
        let data = model.data
        let simulation = model.simulation
        let motion = model.motion
        guard simulation.nodeCount == data.nodes.count, motion.appear.count == data.nodes.count else { return }
        let points = (0 ..< data.nodes.count).map { model.screenPoint(simulation.position($0), in: size) }
        let focus = model.highlightedNode
        let focusAmount = motion.focus
        drawScreen(in: &context, size: size)
        // Halos first, under the links, so the links stay readable through them.
        for (i, node) in data.nodes.enumerated() {
            let presence = motion.presence(i)
            guard presence > 0.001 else { continue }
            let grow = motion.grow[i]
            let r = model.screenRadius(degree: node.degree) * presence * (1 + 0.3 * grow)
            let dim = focusAmount * (1 - motion.lit[i])
            drawHalo(at: points[i], radius: r, degree: node.degree, emphasis: max(i == data.center ? 1 : 0, grow),
                     opacity: (1 - 0.9 * dim) * presence, seed: i, in: &context)
        }

        // Links: faint, fading in with their notes; the focused note's links turn to the accent.
        var edges = Path()
        var highlighted = Path()
        var appearing: [(Path, Double)] = []
        for edge in data.edges {
            let presence = min(motion.presence(edge.a), motion.presence(edge.b))
            var line = Path()
            line.move(to: points[edge.a])
            line.addLine(to: points[edge.b])
            if presence < 1 {
                appearing.append((line, presence))
            } else if focus == edge.a || focus == edge.b {
                highlighted.addPath(line)
            } else {
                edges.addPath(line)
            }
        }
        // Links are a dotted line in the accent, as a route on a printed map.
        let edgeStyle = StrokeStyle(lineWidth: 1.4, lineCap: .round, dash: [0.1, 4])
        let edgeColor = theme.accent
        let edgeStrength = 0.55 - 0.35 * focusAmount
        context.stroke(edges, with: .color(edgeColor.opacity(edgeStrength)), style: edgeStyle)
        for (line, presence) in appearing {
            context.stroke(line, with: .color(edgeColor.opacity(edgeStrength * presence)), style: edgeStyle)
        }
        context.stroke(highlighted, with: .color(theme.accent.opacity(0.3 + 0.6 * focusAmount)), lineWidth: 1 + 0.5 * focusAmount)

        for (i, node) in data.nodes.enumerated() {
            let presence = motion.presence(i)
            guard presence > 0.001 else { continue }
            let grow = motion.grow[i]
            let r = model.screenRadius(degree: node.degree) * presence * (1 + 0.3 * grow)
            let rect = CGRect(x: points[i].x - r, y: points[i].y - r, width: r * 2, height: r * 2)
            let dim = focusAmount * (1 - motion.lit[i])
            let core = Path(ellipseIn: rect)
            context.fill(core, with: .color(theme.background))
            context.fill(core, with: .color(theme.accent.opacity(0.3 + 0.7 * (1 - 0.9 * dim))))
        }

        let fade = model.labelOpacity
        var tags: [(GraphicsContext.ResolvedText, CGPoint, Double)] = []
        // Where the looked-at notes' tags go, worked out first: other titles under them are left out.
        var tagAreas: [CGRect] = []
        for (i, node) in data.nodes.enumerated() where i == data.center || motion.grow[i] > 0.05 {
            let r = model.screenRadius(degree: node.degree) * motion.presence(i) * (1 + 0.3 * motion.grow[i])
            let measured = context.resolve(Text(node.title).font(.ui(size: 12, weight: .semibold))).measure(in: CGSize(width: 260, height: 40))
            tagAreas.append(CGRect(x: points[i].x - measured.width / 2 - 14, y: points[i].y + r, width: measured.width + 28, height: measured.height + 20))
        }
        defer {
            // The note being looked at: its title on a paper tag, over everything else.
            for (text, at, opacity) in tags {
                let measured = text.measure(in: CGSize(width: 260, height: 40))
                let tag = CGRect(x: at.x - measured.width / 2 - 8, y: at.y - 2, width: measured.width + 16, height: measured.height + 8)
                let shape = Path(roundedRect: tag, cornerRadius: Corners.r(6))
                context.fill(shape, with: .color(theme.background))
                context.stroke(shape, with: .color(theme.accent.opacity(0.8 * opacity)), lineWidth: 1)
                context.draw(text, at: CGPoint(x: tag.midX, y: tag.midY), anchor: .center)
            }
        }
        for (i, node) in data.nodes.enumerated() {
            let presence = motion.presence(i)
            let lit = motion.lit[i] * focusAmount
            let isCenter = i == data.center
            let dim = focusAmount * (1 - motion.lit[i])
            let base = isCenter ? 1 : fade * (1 - 0.8 * dim)
            let opacity = max(base, lit) * presence
            guard opacity > 0.01 else { continue }
            let grow = motion.grow[i]
            let r = model.screenRadius(degree: node.degree) * presence * (1 + 0.3 * grow)
            let emphasized = isCenter || grow > 0.05
            let text = context.resolve(Text(node.title)
                .font(.ui(size: 11 + grow, weight: emphasized ? .semibold : .regular))
                .foregroundStyle(theme.text.opacity(opacity)))
            let at = CGPoint(x: points[i].x, y: points[i].y + r + 6)
            if emphasized {
                tags.append((text, at, opacity))
            } else {
                let size = text.measure(in: CGSize(width: 260, height: 40))
                let area = CGRect(x: at.x - size.width / 2, y: at.y, width: size.width, height: size.height)
                if tagAreas.contains(where: { $0.intersects(area) }) { continue }
                // A rim of the paper around the letters keeps them readable over dots and links.
                let rim = context.resolve(Text(node.title).font(.ui(size: 11 + grow)).foregroundStyle(theme.background.opacity(opacity)))
                for (dx, dy) in [(-1.0, 0.0), (1, 0), (0, -1), (0, 1)] {
                    context.draw(rim, at: CGPoint(x: at.x + dx, y: at.y + dy), anchor: .top)
                }
                context.draw(text, at: at, anchor: .top)
            }
        }
    }

    /// The print look's paper: a fine screen of dots that moves and scales with the graph, faint enough to read as
    /// texture.
    private func drawScreen(in context: inout GraphicsContext, size: CGSize) {
        let origin = model.screenPoint(.zero, in: size)
        let step = max(14, 22 * model.scale)
        let r = 0.75
        var dots = Path()
        var y = origin.y.truncatingRemainder(dividingBy: step) - step
        while y < size.height + step {
            var x = origin.x.truncatingRemainder(dividingBy: step) - step
            while x < size.width + step {
                dots.addEllipse(in: CGRect(x: x - r, y: y - r, width: 2 * r, height: 2 * r))
                x += step
            }
            y += step
        }
        context.fill(dots, with: .color(theme.accent.opacity(0.18)))
    }

    /// The halo of a note in the print look: dots of the accent around it, large near the note and
    /// shrinking outward, wider for a note with more links and for the one being looked at.
    private func drawHalo(at point: CGPoint, radius: CGFloat, degree: Int, emphasis: Double, opacity: Double,
                          seed: Int, in context: inout GraphicsContext) {
        let reach = max(radius * 2.6, 14 + 3 * Double(min(degree, 8)) + 14 * emphasis) * Double(min(1, model.scale + 0.4))
        let step = 3.2
        var halo = Path()
        let count = Int(reach / step)
        if count > 0 {
            for row in -count...count {
                for column in -count...count {
                    let dx = Double(column) * step + (row % 2 == 0 ? 0 : step / 2), dy = Double(row) * step * 0.87
                    let d = hypot(dx, dy) / reach
                    guard d < 1, d > Double(radius / reach) * 1.15 else { continue }
                    let jitter = HalftoneNoise.hash(column &+ seed &* 31, row &+ seed)
                    let size = step * 0.5 * pow(1 - d, 1.4) * (0.75 + 0.5 * jitter)
                    guard size > 0.35 else { continue }
                    halo.addEllipse(in: CGRect(x: point.x + dx - size, y: point.y + dy - size, width: 2 * size, height: 2 * size))
                }
            }
        }
        context.fill(halo, with: .color(theme.accent.opacity((0.28 + 0.4 * emphasis) * opacity)))
    }

    /// Scrolling over the canvas zooms around the pointer, as in Obsidian. SwiftUI has no scroll-wheel gesture
    /// outside a scroll view, so this watches the window's scroll events while the pointer is inside.
    private func installScrollMonitor() {
        guard scrollMonitor == nil else { return }
        let model = model
        let pointer = pointer
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            let dy = event.scrollingDeltaY
            let precise = event.hasPreciseScrollingDeltas
            let handled = MainActor.assumeIsolated { () -> Bool in
                guard let location = pointer.location else { return false }
                model.zoom(by: exp(dy * (precise ? 0.01 : 0.1)), around: location, in: pointer.size)
                return true
            }
            return handled ? nil : event
        }
    }

    private func removeScrollMonitor() {
        if let scrollMonitor { NSEvent.removeMonitor(scrollMonitor) }
        scrollMonitor = nil
    }
}

/// Where the pointer is over the canvas, read by the scroll monitor without re-rendering the view.
@MainActor
private final class PointerBox {
    var location: CGPoint?
    var size: CGSize = .zero
}

/// Brings the whole graph back in view after panning or zooming: a round button in the corner.
private struct RecenterButton: View {
    let model: GraphTabModel
    @Environment(\.themeTokens) private var theme

    var body: some View {
        Button { model.recenter() } label: {
            Image(symbol: "scope")
                .font(.ui(size: 13, weight: .medium))
                .foregroundStyle(theme.text.opacity(0.8))
                .frame(width: 34, height: 34)
                .background(Circle().fill(theme.background))
                .overlay(Circle().strokeBorder(theme.separator.opacity(0.6)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help("Show the whole graph")
        .padding(20)
    }
}
