import AppKit
import CanvasPlugin
import PluginKitUI
import QuartzCore

/// The arrows between cards, in board units under the world's transform: a pan or a zoom moves them with the cards
/// and draws nothing again. The many plain arrows are one shape layer per colour; the selected, dashed, new and
/// moving ones each have their own. Labels are small bitmaps at the arrows' middles. A new arrow draws itself from
/// its start (`strokeEnd`).
@MainActor
final class BoardEdgesLayer: QuietLayer {
    private struct Single {
        let line = QuietShapeLayer()
        let heads = QuietShapeLayer()
        let glow = QuietShapeLayer()
    }

    private var batches: [String: (line: QuietShapeLayer, heads: QuietShapeLayer)] = [:]
    private var singles: [String: Single] = [:]
    private var labels: [String: (layer: QuietLayer, key: String)] = [:]
    /// The arrows drawn on their own last time, so a moving one goes back to its batch once still.
    private var animated: Set<String> = []
    private let pending = QuietShapeLayer()
    private let pendingHead = QuietShapeLayer()
    private var scale: CGFloat = 1
    /// The arrows touching what is moved: drawn on their own while it moves.
    private(set) var moving: Set<String> = []

    override init() {
        super.init()
        MainActor.assumeIsolated {
            pending.fillColor = nil
            pending.lineCap = .round
            pending.lineDashPattern = [6, 5]
            addSublayer(pending)
            addSublayer(pendingHead)
        }
    }

    override init(layer: Any) { super.init(layer: layer) }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// The line width in board units for a zoom: 2.5 points at 100 %, never under 1.25 on screen.
    static func lineWidth(_ scale: CGFloat) -> CGFloat { max(1.25, BoardStyle.edgeWidth * scale) / scale }

    /// Draws every arrow again (the board, the selection or the theme changed).
    func rebuild(_ model: BoardModel, palette: BoardPalette, scale: CGFloat, backing: CGFloat) {
        self.scale = scale
        moving = movingEdges(model)
        let skipped = model.link?.reconnect?.edge
        var batched: [String: (color: NSColor, line: CGMutablePath, heads: CGMutablePath)] = [:]
        var keep: Set<String> = []
        var keepLabels: Set<String> = []
        let births = model.edgeBirths
        for edge in model.document.edges where edge.id != skipped {
            guard let curve = model.curve(of: edge) else { continue }
            let selected = model.selectedEdge == edge.id
            let color = selected ? palette.accent
                : BoardStyle.nsColor(edge.color) ?? palette.secondary.withAlphaComponent(0.7 * palette.secondary.alphaComponent)
            let born = births[edge.id]
            if !selected, !edge.isDashed, born == nil, !moving.contains(edge.id) {
                var batch = batched[edge.color ?? ""] ?? (color, CGMutablePath(), CGMutablePath())
                batch.line.addPath(Self.path(curve))
                addHeads(edge, curve, to: batch.heads)
                batched[edge.color ?? ""] = batch
            } else {
                keep.insert(edge.id)
                single(edge, curve: curve, color: color, selected: selected, palette: palette, born: born)
            }
            if let label = edge.label, !label.isEmpty, model.editedEdge != edge.id {
                keepLabels.insert(edge.id)
                placeLabel(edge.id, label, at: CGPoint(curve.middle), selected: selected, palette: palette, backing: backing,
                           born: born)
            }
        }
        for (key, batch) in batched {
            let layers = batches[key] ?? makeBatch(key)
            layers.line.path = batch.line
            layers.line.strokeColor = batch.color.cgColor
            layers.heads.path = batch.heads
            layers.heads.fillColor = batch.color.cgColor
        }
        for key in batches.keys where batched[key] == nil {
            batches[key]?.line.removeFromSuperlayer()
            batches[key]?.heads.removeFromSuperlayer()
            batches[key] = nil
        }
        for (id, layers) in singles where !keep.contains(id) {
            layers.line.removeFromSuperlayer()
            layers.heads.removeFromSuperlayer()
            layers.glow.removeFromSuperlayer()
            singles[id] = nil
            animated.remove(id)
        }
        for (id, label) in labels where !keepLabels.contains(id) {
            label.layer.removeFromSuperlayer()
            labels[id] = nil
        }
        updatePending(model, palette: palette)
        setScale(scale)
    }

    /// Draws again only the arrows touching what moves (a card dragged or resized).
    func updateMoving(_ model: BoardModel, palette: BoardPalette, backing: CGFloat) {
        let now = movingEdges(model)
        guard now == moving else {
            rebuild(model, palette: palette, scale: scale, backing: backing)
            return
        }
        for id in moving {
            guard let edge = model.document.edge(id), let curve = model.curve(of: edge) else { continue }
            let selected = model.selectedEdge == edge.id
            let color = selected ? palette.accent : BoardStyle.nsColor(edge.color) ?? palette.secondary.withAlphaComponent(0.7)
            single(edge, curve: curve, color: color, selected: selected, palette: palette, born: nil)
            if let label = edge.label, !label.isEmpty, let layer = labels[id]?.layer {
                layer.position = CGPoint(curve.middle)
            }
        }
        updatePending(model, palette: palette)
    }

    func updatePending(_ model: BoardModel, palette: BoardPalette) {
        guard let link = model.link, let from = model.node(link.from) else {
            pending.path = nil
            pendingHead.path = nil
            return
        }
        let start = model.frame(of: from).anchor(link.side)
        let reach = min(max((link.point - start).length / 2, 30), 160)
        let curve = CanvasCurve(start: start, control1: start + link.side.normal * reach, control2: link.point, end: link.point)
        pending.path = Self.path(curve)
        pending.strokeColor = palette.accent.cgColor
        let heads = CGMutablePath()
        let (left, right) = curve.arrowHead(atStart: false, size: BoardStyle.arrowSize)
        heads.move(to: CGPoint(curve.end))
        heads.addLine(to: CGPoint(left))
        heads.addLine(to: CGPoint(right))
        heads.closeSubpath()
        pendingHead.path = heads
        pendingHead.fillColor = palette.accent.cgColor
    }

    /// The line widths for a zoom; labels hide under 30 %.
    func setScale(_ scale: CGFloat) {
        self.scale = scale
        let width = Self.lineWidth(scale)
        for batch in batches.values { batch.line.lineWidth = width }
        for (id, single) in singles {
            let selected = single.glow.superlayer != nil
            single.line.lineWidth = selected ? width + 1.25 / scale : width
            single.glow.lineWidth = width + 7 / scale
            if single.line.lineDashPattern != nil {
                single.line.lineDashPattern = [NSNumber(value: Double(width * 2.6)), NSNumber(value: Double(width * 2.4))]
            }
            _ = id
        }
        pending.lineWidth = width
        pending.lineDashPattern = [NSNumber(value: Double(6 / scale)), NSNumber(value: Double(5 / scale))]
        let hidden = scale < 0.3
        for label in labels.values where label.layer.isHidden != hidden { label.layer.isHidden = hidden }
    }

    private func movingEdges(_ model: BoardModel) -> Set<String> {
        var moved = model.dragged
        if let resizing = model.resizing { moved.insert(resizing.id) }
        if let end = model.lineEnd { moved.insert(end.id) }
        guard !moved.isEmpty else { return [] }
        return Set(model.document.edges.filter { moved.contains($0.fromNode) || moved.contains($0.toNode) }.map(\.id))
    }

    private func makeBatch(_ key: String) -> (line: QuietShapeLayer, heads: QuietShapeLayer) {
        let line = QuietShapeLayer()
        line.fillColor = nil
        line.lineCap = .round
        let heads = QuietShapeLayer()
        insertSublayer(line, below: pending)
        insertSublayer(heads, below: pending)
        batches[key] = (line, heads)
        return (line, heads)
    }

    private func single(_ edge: CanvasEdge, curve: CanvasCurve, color: NSColor, selected: Bool, palette: BoardPalette,
                        born: Date?) {
        let layers: Single
        if let known = singles[edge.id] { layers = known } else {
            layers = Single()
            for layer in [layers.line, layers.glow] {
                layer.fillColor = nil
                layer.lineCap = .round
            }
            insertSublayer(layers.line, below: pending)
            insertSublayer(layers.heads, below: pending)
            singles[edge.id] = layers
        }
        let path = Self.path(curve)
        let width = Self.lineWidth(scale)
        layers.line.path = path
        layers.line.strokeColor = color.cgColor
        layers.line.lineWidth = selected ? width + 1.25 / scale : width
        layers.line.lineDashPattern = edge.isDashed
            ? [NSNumber(value: Double(width * 2.6)), NSNumber(value: Double(width * 2.4))] : nil
        let heads = CGMutablePath()
        addHeads(edge, curve, to: heads)
        layers.heads.path = heads
        layers.heads.fillColor = color.cgColor
        if selected {
            layers.glow.path = path
            layers.glow.strokeColor = palette.accent.withAlphaComponent(0.22).cgColor
            layers.glow.lineWidth = width + 7 / scale
            if layers.glow.superlayer == nil { insertSublayer(layers.glow, below: layers.line) }
        } else if layers.glow.superlayer != nil {
            layers.glow.removeFromSuperlayer()
        }
        // A new arrow draws itself from its start, easing out; its heads come in at the end.
        if let born, !animated.contains(edge.id), !Motion.reduceMotion {
            animated.insert(edge.id)
            let left = max(0.05, BoardMotion.linkDraw - Date().timeIntervalSince(born))
            let draw = CABasicAnimation(keyPath: "strokeEnd")
            draw.fromValue = 0
            draw.toValue = 1
            draw.duration = left
            draw.timingFunction = CAMediaTimingFunction(controlPoints: 0.33, 1, 0.68, 1)
            layers.line.add(draw, forKey: "draw")
            let heads = CABasicAnimation(keyPath: "opacity")
            heads.fromValue = 0
            heads.toValue = 1
            heads.beginTime = CACurrentMediaTime() + left * 0.9
            heads.duration = left * 0.1 + 0.04
            heads.fillMode = .backwards
            layers.heads.add(heads, forKey: "draw")
        }
    }

    private func addHeads(_ edge: CanvasEdge, _ curve: CanvasCurve, to path: CGMutablePath) {
        for (shown, atStart) in [(edge.endsWithArrow, false), (edge.startsWithArrow, true)] where shown {
            let (left, right) = curve.arrowHead(atStart: atStart, size: BoardStyle.arrowSize)
            path.move(to: CGPoint(atStart ? curve.start : curve.end))
            path.addLine(to: CGPoint(left))
            path.addLine(to: CGPoint(right))
            path.closeSubpath()
        }
    }

    private func placeLabel(_ id: String, _ text: String, at point: CGPoint, selected: Bool, palette: BoardPalette,
                            backing: CGFloat, born: Date?) {
        let pixels = BoardRenderer.pixelScale(for: CGSize(width: 260, height: 40), scale: scale, backing: backing)
        let key = "\(text)|\(selected)|\(palette.dark)|\(palette.theme.accent.description)|\(pixels)"
        let layer: QuietLayer
        if let known = labels[id] {
            layer = known.layer
        } else {
            layer = QuietLayer()
            layer.contentsGravity = .resize
            addSublayer(layer)
            labels[id] = (layer, "")
        }
        if labels[id]?.key != key {
            let (image, size) = Self.labelImage(text, selected: selected, palette: palette, pixels: pixels)
            layer.bounds = CGRect(origin: .zero, size: size)
            layer.contents = image
            layer.contentsScale = pixels
            labels[id] = (layer, key)
        }
        layer.position = point
        layer.isHidden = scale < 0.3
        if let born, Date().timeIntervalSince(born) < BoardMotion.linkDraw {
            layer.opacity = 0
            DispatchQueue.main.asyncAfter(deadline: .now() + BoardMotion.linkDraw) { [weak layer] in
                guard let layer else { return }
                BoardSprings.fade(layer, to: 1)
            }
        } else {
            layer.opacity = 1
        }
    }

    /// An arrow's label: its text on a capsule of the page's colour with a hairline, in board units.
    static func labelImage(_ text: String, selected: Bool, palette: BoardPalette, pixels: CGFloat) -> (CGImage?, CGSize) {
        let string = NSAttributedString(string: text.uiLocalized, attributes: [
            .font: NSFont.ui(size: 13, weight: .medium), .foregroundColor: palette.text,
        ])
        let measured = string.boundingRect(with: CGSize(width: 240, height: 80), options: [.usesLineFragmentOrigin, .usesFontLeading]).size
        let size = CGSize(width: ceil(measured.width) + 16, height: ceil(measured.height) + 7)
        let width = Int(ceil(size.width * pixels)), height = Int(ceil(size.height * pixels))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.displayP3)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return (nil, size) }
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: pixels, y: -pixels)
        let box = CGRect(origin: .zero, size: size).insetBy(dx: 1, dy: 1)
        let radius = Corners.r(box.height / 2)
        context.addPath(CGPath(roundedRect: box, cornerWidth: radius, cornerHeight: radius, transform: nil))
        context.setFillColor(palette.background.cgColor)
        context.fillPath()
        context.addPath(CGPath(roundedRect: box, cornerWidth: radius, cornerHeight: radius, transform: nil))
        context.setStrokeColor((selected ? palette.accent : palette.secondary.withAlphaComponent(0.35)).cgColor)
        context.setLineWidth(selected ? 1.5 : 0.75)
        context.strokePath()
        BoardTextLayout.draw(string, in: CGRect(x: 8, y: 3.5, width: ceil(measured.width) + 1, height: ceil(measured.height) + 1),
                             context: context)
        return (context.makeImage(), size)
    }

    static func path(_ curve: CanvasCurve) -> CGPath {
        let path = CGMutablePath()
        path.move(to: CGPoint(curve.start))
        path.addCurve(to: CGPoint(curve.end), control1: CGPoint(curve.control1), control2: CGPoint(curve.control2))
        return path
    }
}
