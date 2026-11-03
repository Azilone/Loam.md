import AppKit
import CanvasPlugin
import PluginKitUI
import SwiftUI

/// Strokes as the board draws them: quadratic curves through the middles of their points, the way the SVG is
/// written, so the board and any SVG reader draw the same line.
enum BoardInkPath {
    static func path(_ points: [CanvasPoint], transform: (CanvasPoint) -> CGPoint) -> Path {
        var path = Path()
        guard let first = points.first else { return path }
        path.move(to: transform(first))
        if points.count == 1 {
            path.addLine(to: transform(first))
            return path
        }
        for index in 1..<points.count - 1 {
            let point = points[index], next = points[index + 1]
            path.addQuadCurve(to: transform(CanvasPoint(x: (point.x + next.x) / 2, y: (point.y + next.y) / 2)),
                              control: transform(point))
        }
        path.addLine(to: transform(points[points.count - 1]))
        return path
    }

    /// Strokes the drawing `ink` (relative to its node, `width` by `height` as written) into `context` at `size`.
    static func draw(_ ink: CanvasInk, natural: CGSize, in size: CGSize, context: GraphicsContext, text: Color,
                     lineScale: CGFloat = 1) {
        let sx = size.width / max(natural.width, 1), sy = size.height / max(natural.height, 1)
        func transform(_ point: CanvasPoint) -> CGPoint { CGPoint(x: point.x * sx, y: point.y * sy) }
        let scale = min(sx, sy) * lineScale
        for stroke in ink.strokes {
            let color = (BoardStyle.color(stroke.color) ?? text).opacity(stroke.opacity)
            let width = max(0.5, stroke.width * scale)
            let style = StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round,
                                    dash: stroke.dashed ? [width * 3, width * 2.5] : [])
            context.stroke(path(stroke.points, transform: transform), with: .color(color), style: style)
        }
        if ink.kind == .line, let stroke = ink.strokes.first, let (start, end) = ink.ends {
            let color = (BoardStyle.color(stroke.color) ?? text).opacity(stroke.opacity)
            for (tip, from, shown) in [(end, stroke.points.dropLast().last ?? start, ink.endArrow),
                                       (start, stroke.points.dropFirst().first ?? end, ink.startArrow)] where shown {
                let (left, right) = CanvasInk.arrowHead(tip: tip, from: from, size: CanvasInk.headSize(stroke.width))
                var head = Path()
                head.move(to: transform(left))
                head.addLine(to: transform(tip))
                head.addLine(to: transform(right))
                context.stroke(head, with: .color(color), style: StrokeStyle(lineWidth: max(0.5, stroke.width * scale),
                                                                             lineCap: .round, lineJoin: .round))
            }
        }
    }
}

/// A drawing on the board: its strokes, stretched to its card. Only the strokes take clicks, so a card under a
/// drawing's empty parts can still be clicked.
struct BoardInkView: View {
    let node: CanvasNode
    let ink: CanvasInk
    /// The line's ends as drawn now (one may be dragged), in the card's board units.
    var ends: (CanvasPoint, CanvasPoint)?
    @Environment(\.themeTokens) private var theme

    var body: some View {
        let text = theme.text
        var shown = ink
        if let ends, !shown.strokes.isEmpty {
            shown.strokes[0].points = [ends.0, ends.1]
        }
        let natural = CGSize(width: node.width, height: node.height)
        guard let ends else {
            return AnyView(Canvas { context, size in
                BoardInkPath.draw(shown, natural: natural, in: size, context: context, text: text)
            })
        }
        // A dragged end can leave the card's frame: the canvas spans both ends too, so the line is not cut off.
        let margin = CanvasInk.headSize(ink.strokes.first?.width ?? 2) + 8
        let area = CGRect(origin: .zero, size: natural)
            .union(CGRect(x: min(ends.0.x, ends.1.x), y: min(ends.0.y, ends.1.y),
                          width: abs(ends.1.x - ends.0.x), height: abs(ends.1.y - ends.0.y)))
            .insetBy(dx: -margin, dy: -margin)
        return AnyView(GeometryReader { proxy in
            let unit = proxy.size.width / max(natural.width, 1)
            Canvas { context, _ in
                context.translateBy(x: -area.minX * unit, y: -area.minY * unit)
                BoardInkPath.draw(shown, natural: natural, in: CGSize(width: natural.width * unit, height: natural.height * unit),
                                  context: context, text: text)
            }
            .frame(width: area.width * unit, height: area.height * unit)
            .offset(x: area.minX * unit, y: area.minY * unit)
        })
    }
}

/// What a drawing answers clicks on: its strokes, widened to be easy to hit.
struct BoardInkHitShape: Shape {
    let ink: CanvasInk
    let natural: CGSize
    /// The extra room on each side of a stroke, in the shape's own points.
    let slop: CGFloat

    func path(in rect: CGRect) -> Path {
        let sx = rect.width / max(natural.width, 1), sy = rect.height / max(natural.height, 1)
        var all = Path()
        for stroke in ink.strokes {
            let line = BoardInkPath.path(stroke.points) { CGPoint(x: $0.x * sx, y: $0.y * sy) }
            all.addPath(line.strokedPath(StrokeStyle(lineWidth: stroke.width * min(sx, sy) + slop * 2, lineCap: .round)))
        }
        return all
    }
}

/// While a drawing tool is chosen, the board takes drags for it: the stroke or line being drawn shows here.
struct BoardDrawingLayer: View {
    let model: BoardModel
    @Environment(\.themeTokens) private var theme
    @State private var drawing = false

    var body: some View {
        let camera = model.camera
        let live = model.liveStroke
        let tool = model.tool
        ZStack {
            Color.clear
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0, coordinateSpace: .named(BoardView.space))
                        .onChanged { value in
                            let point = CanvasPoint(camera.worldPoint(value.location))
                            if !drawing {
                                drawing = true
                                model.beginStroke(at: CanvasPoint(camera.worldPoint(value.startLocation)))
                            }
                            model.continueStroke(to: point, snaps: NSEvent.modifierFlags.contains(.shift))
                        }
                        .onEnded { _ in
                            drawing = false
                            model.endStroke()
                        }
                )
                .pointerStyle(tool == .eraser ? .rectSelection : .default)
            if !live.isEmpty, tool != .eraser {
                let highlights = tool == .highlighter
                let stroke = CanvasInkStroke(points: live,
                                             color: highlights ? model.highlighterColor : model.inkColor,
                                             width: highlights ? BoardModel.highlighterWidth : model.inkWidth,
                                             opacity: highlights ? BoardModel.highlighterOpacity : 1)
                let ink = CanvasInk(kind: tool == .line || tool == .arrow ? .line : .ink, strokes: [stroke],
                                    endArrow: tool == .arrow)
                let text = theme.text
                Canvas { context, size in
                    // The stroke in view points: board units moved and scaled by the camera.
                    var moved = context
                    moved.translateBy(x: camera.offset.width, y: camera.offset.height)
                    moved.scaleBy(x: camera.scale, y: camera.scale)
                    BoardInkPath.draw(ink, natural: CGSize(width: 1, height: 1), in: CGSize(width: 1, height: 1),
                                      context: moved, text: text)
                }
                .allowsHitTesting(false)
            }
        }
    }
}

/// The colours and widths of the drawing tools, over the toolbar while one is chosen.
struct BoardInkStyleBar: View {
    @Bindable var model: BoardModel
    @Environment(\.themeTokens) private var theme

    var body: some View {
        HStack(spacing: 6) {
            if model.tool == .highlighter {
                ForEach(BoardStyle.presets, id: \.value) { preset in
                    swatch(preset.value, selected: model.highlighterColor == preset.value) { model.highlighterColor = preset.value }
                }
            } else if model.tool != .eraser {
                swatch(nil, selected: model.inkColor == nil) { model.inkColor = nil }
                ForEach(BoardStyle.presets, id: \.value) { preset in
                    swatch(preset.value, selected: model.inkColor == preset.value) { model.inkColor = preset.value }
                }
                Divider().frame(height: 18).padding(.horizontal, 2)
                ForEach(BoardModel.inkWidths, id: \.self) { width in
                    Button { model.inkWidth = width } label: {
                        ThemeCapsule().fill(theme.text)
                            .frame(width: 18, height: max(1.5, width * 0.9))
                            .frame(width: 30, height: 26)
                            .background(RoundedRectangle(cornerRadius: Corners.r(8), style: .continuous)
                                .fill(model.inkWidth == width ? theme.accent.opacity(0.18) : .clear))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Width \(Int(width))")
                }
            } else {
                Text("Drag over strokes to erase them")
                    .font(.ui(size: 12))
                    .foregroundStyle(theme.secondaryText)
                    .padding(.horizontal, 6)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .glassEffect(.regular, in: ThemeCapsule())
    }

    private func swatch(_ value: String?, selected: Bool, pick: @escaping () -> Void) -> some View {
        Button(action: pick) {
            Circle().fill(BoardStyle.color(value) ?? theme.text)
                .frame(width: 16, height: 16)
                .overlay { if selected { Circle().strokeBorder(theme.accent, lineWidth: 2).padding(-4) } }
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(value.flatMap { value in BoardStyle.presets.first { $0.value == value }?.name } ?? "Text colour")
    }
}

/// The two ends of the selected free line, to drag elsewhere (Shift: at 45° steps).
struct BoardLineHandles: View {
    let model: BoardModel
    @Environment(\.themeTokens) private var theme
    @State private var active = false

    var body: some View {
        if let node = model.selectedLine, let ends = model.lineEnds(of: node), model.editing == nil {
            ZStack {
                handle(node, movesStart: true, at: model.camera.screenPoint(CGPoint(ends.0)))
                handle(node, movesStart: false, at: model.camera.screenPoint(CGPoint(ends.1)))
            }
        }
    }

    private func handle(_ node: CanvasNode, movesStart: Bool, at point: CGPoint) -> some View {
        Circle()
            .fill(Color.white)
            .overlay(Circle().strokeBorder(theme.accent, lineWidth: 2))
            .frame(width: BoardStyle.handleSize + 2, height: BoardStyle.handleSize + 2)
            .shadow(color: .black.opacity(0.2), radius: 2, y: 1)
            .padding(8)
            .contentShape(Circle())
            .position(point)
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .named(BoardView.space))
                    .onChanged { value in
                        if !active {
                            active = true
                            model.beginLineEnd(node, movesStart: movesStart)
                        }
                        model.updateLineEnd(to: CanvasPoint(model.camera.worldPoint(value.location)),
                                            snaps: NSEvent.modifierFlags.contains(.shift))
                    }
                    .onEnded { _ in
                        active = false
                        model.endLineEnd()
                    }
            )
            .help("Drag to move this end of the line")
    }
}
