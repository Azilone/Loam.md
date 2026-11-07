import AppKit
import CanvasPlugin
import PluginKitUI
import QuartzCore

/// The board's items as layers: made, placed, drawn and decorated (selected, hovered, lifted) from the model.
extension BoardCanvasView {
    /// The zoom under which cards are drawn far out: a tinted sheet with their title.
    static let farScale: CGFloat = 0.35

    /// Makes, places and orders a layer per card and group, as the board is now; draws the ones that changed.
    func reconcileItems() {
        guard palette != nil else { return }
        let document = model.document
        var cards: [CALayer] = []
        var groupList: [CALayer] = []
        var seen = Set<String>()
        for node in document.nodes {
            seen.insert(node.id)
            if node.kind == .group {
                let layer = groupLayers[node.id] ?? makeGroup(node)
                placeGroup(layer, node)
                groupList.append(layer)
            } else {
                let layer = items[node.id] ?? makeItem(node)
                place(layer, model.drawnFrame(of: node))
                cards.append(layer)
            }
        }
        for (id, layer) in items where !seen.contains(id) {
            layer.removeFromSuperlayer()
            items[id] = nil
        }
        for (id, layer) in groupLayers where !seen.contains(id) {
            layer.removeFromSuperlayer()
            groupLayers[id] = nil
        }
        // In the board's order: a card later in the file is above.
        if (cardsLayer.sublayers ?? []).map(ObjectIdentifier.init) != cards.map(ObjectIdentifier.init) {
            cardsLayer.sublayers = cards
        }
        if (groupsLayer.sublayers ?? []).map(ObjectIdentifier.init) != groupList.map(ObjectIdentifier.init) {
            groupsLayer.sublayers = groupList
        }
        updateShadows()
        renderItems(settled: true)
    }

    private func makeItem(_ node: CanvasNode) -> BoardItemLayer {
        let layer = BoardItemLayer()
        layer.id = node.id
        items[node.id] = layer
        if model.justAdded.contains(node.id) { appear(layer, from: 0.84) }
        return layer
    }

    private func makeGroup(_ node: CanvasNode) -> BoardGroupLayer {
        let layer = BoardGroupLayer()
        layer.id = node.id
        groupLayers[node.id] = layer
        if model.justAdded.contains(node.id) { appear(layer, from: 0.94) }
        return layer
    }

    /// A new card or group pops in.
    private func appear(_ layer: CALayer, from scale: CGFloat) {
        let grow = BoardSprings.animation("transform.scale", Motion.Spring.pop, from: scale, to: 1)
        let fade = BoardSprings.animation("opacity", Motion.Spring.pop, from: 0, to: 1)
        layer.add(grow, forKey: "appear")
        layer.add(fade, forKey: "appearFade")
    }

    /// Puts an item at its frame, in board units, by its centre: a lifted card's scale stays round it.
    func place(_ layer: CALayer, _ frame: CanvasRect) {
        let bounds = CGRect(x: 0, y: 0, width: frame.width, height: frame.height)
        if layer.bounds != bounds {
            layer.bounds = bounds
            if let item = layer as? BoardItemLayer, let node = model.node(item.id) {
                item.shadowPath = shadowPath(node, bounds)
                item.ring.frame = bounds
                item.outline.frame = bounds
            }
        }
        layer.position = CGPoint(x: frame.x + frame.width / 2, y: frame.y + frame.height / 2)
    }

    private func shadowPath(_ node: CanvasNode, _ bounds: CGRect) -> CGPath {
        BoardShape(node.kind == .text ? node.shape : nil, radius: node.isSticky ? 4 : BoardStyle.cornerRadius)
            .path(in: bounds).cgPath
    }

    /// Moves what is dragged or resized, at each step of the gesture.
    func moveItems() {
        var moved = model.dragged
        if let resizing = model.resizing { moved.insert(resizing.id) }
        if let end = model.lineEnd { moved.insert(end.id) }
        // A card let go goes back to its place in the file's frame.
        moved.formUnion(movedLastTime)
        movedLastTime = model.dragged.union(model.resizing.map { [$0.id] } ?? []).union(model.lineEnd.map { [$0.id] } ?? [])
        for id in moved {
            guard let node = model.node(id) else { continue }
            if node.kind == .group, let layer = groupLayers[id] {
                placeGroup(layer, node)
            } else if let layer = items[id] {
                place(layer, model.drawnFrame(of: node))
            }
        }
        // A resized card's text follows its size, and a line's end its drag: drawn again as they change.
        if model.resizing != nil || model.lineEnd != nil { renderItems(settled: true) }
    }

    // MARK: Drawing

    /// Draws the items near the screen whose drawing is not what they show now. While the camera moves only what
    /// shows nothing or is drawn far too small is drawn; once it rests, everything for the zoom it rests at.
    func renderItems(settled: Bool) {
        guard let palette, bounds.width > 0 else { return }
        let camera = model.camera
        let scale = camera.scale
        let visible = camera.visibleWorldRect
        let coverage = visible.insetBy(dx: -visible.width * 0.5, dy: -visible.height * 0.5)
        let mode: BoardRenderKey.Mode = scale < Self.farScale ? .far : .near
        let step = BoardRenderer.scaleStep(scale)
        let space = drawingSpace
        let version = model.store.previewVersion &+ model.store.links.version &* 7919
        var urgent: [BoardRenderer.Job] = []
        var later: [BoardRenderer.Job] = []
        for (id, layer) in items {
            guard let node = model.node(id) else { continue }
            let frame = model.drawnFrame(of: node)
            guard CGRect(frame).intersects(coverage) else { continue }
            if !settled, let shown = layer.shown, shown.size == CGSize(width: frame.width, height: frame.height),
               layer.contentsScale >= BoardRenderer.pixelScale(for: shown.size, scale: scale, backing: backing) / 2.01 {
                // Only the zoom changed, and the picture is still sharp enough: drawn again once it rests.
                continue
            }
            var itemMode = mode
            if case .node(let edited) = model.editing?.target, edited == id, node.kind == .text, !node.isTable { itemMode = .editing }
            if embeds.isLive(id) { itemMode = .live }
            let size = CGSize(width: frame.width, height: frame.height)
            // Where the item is does not change its picture: a moved card is not drawn again.
            var placed = node
            placed.x = 0
            placed.y = 0
            let key = BoardRenderKey(node: placed, size: size, version: version, mode: itemMode, scaleStep: step, palette: palette)
            if layer.shown == key || layer.drawing == key { continue }
            let pixels = BoardRenderer.pixelScale(for: size, scale: scale, backing: backing)
            if let shown = layer.shown, !settled, shown.node == placed, shown.mode == itemMode, shown.size == size,
               shown.version == version, layer.contentsScale >= pixels / 2.01 {
                // Only the zoom changed, and the picture is still sharp enough: drawn again once it rests.
                continue
            }
            let job = BoardRenderer.Job(
                layer: layer, key: key, spec: model.spec(of: node, frame: frame, mode: itemMode, scale: scale),
                pixelScale: pixels, lineScale: 1 / scale, palette: palette, appearance: effectiveAppearance, space: space
            )
            // A picture is decoded in the background: its card shows its paper meanwhile.
            if layer.shown == nil, layer.contents == nil, !job.spec.decodesPicture, !model.isNavigating { urgent.append(job) } else { later.append(job) }
        }
        // What shows nothing yet is drawn at once, on every core: a card never comes in empty.
        BoardRenderer.render(urgent, now: true)
        guard !later.isEmpty else { return }
        guard !rendering else {
            renderAgain = true
            return
        }
        rendering = true
        BoardRenderer.render(later, now: false) { [weak self] in
            guard let self else { return }
            self.rendering = false
            if self.renderAgain {
                self.renderAgain = false
                self.renderItems(settled: !self.model.isNavigating)
            }
        }
    }

    /// Glass-like cards (a soft shadow under each) while few are on screen and they are big enough.
    func updateShadows() {
        // Sized for the screen: not before the view has a size (the camera is not framed yet).
        guard bounds.width > 0 else { return }
        let scale = model.camera.scale
        let visible = model.camera.visibleWorldRect
        var count = 0
        if scale >= BoardModel.glassScale {
            for node in model.document.nodes where node.kind != .group && CGRect(node.frame).intersects(visible) { count += 1 }
        }
        let wanted = scale >= BoardModel.glassScale && count <= BoardModel.glassLimit
        let dark = palette?.dark ?? false
        for (id, layer) in items where layer.shadowColor == nil || wanted != shadowed || layer.shadowOpacity == 0 && wanted {
            guard let node = model.node(id), !layer.isLifted else { continue }
            layer.shadowColor = NSColor.black.cgColor
            layer.shadowOffset = CGSize(width: 0, height: 4)
            layer.shadowRadius = 10
            if node.border == .invisible || node.isDrawing || (wanted && model.isBare(node)) {
                layer.shadowOpacity = 0
            } else if node.isSticky {
                layer.shadowOpacity = 0.16
            } else {
                layer.shadowOpacity = wanted ? Float(dark ? 0.32 : 0.11) : 0
            }
        }
        shadowed = wanted
    }

    // MARK: Decorations

    /// The selection ring, the hover outline, a drawing's dashed box, the lift of what is dragged and the order on
    /// screen (lifted, then selected, then hovered above the rest).
    func decorateItems() {
        guard let palette else { return }
        let scale = model.camera.scale
        let presenting = model.presentation != nil
        for (id, layer) in items {
            guard let node = model.node(id) else { continue }
            let selected = model.selection.contains(id) && !presenting
            let targeted = model.link?.target == id
            let hovered = model.hovered == id && !presenting
            let editing = model.editing?.target == .node(id)
            let lifted = model.dragged.contains(id)
            let drawing = node.isDrawing
            let bare = model.isBare(node)
            let shape = BoardShape(node.kind == .text ? node.shape : nil,
                                   radius: node.isSticky ? 4 : node.isFreeText ? 6 : BoardStyle.cornerRadius)
            // The ring: the accent round a selected card (or the one an arrow is drawn to); a dashed box round a drawing.
            let ringed = (selected || targeted) && !(drawing && node.drawing?.kind == .line)
            if ringed || (drawing && hovered && !selected) {
                ringPath(layer, node: node, shape: shape, scale: scale, drawing: drawing)
                layer.ring.strokeColor = palette.accent.withAlphaComponent(drawing ? (selected ? 0.9 : 0.4) : 1).cgColor
                layer.ring.shadowColor = drawing ? nil : palette.accent.withAlphaComponent(0.35).cgColor
                if layer.ring.opacity < 1 { BoardSprings.fade(layer.ring, to: 1) }
                decorated.insert(id)
            } else if layer.ring.opacity > 0 {
                BoardSprings.fade(layer.ring, to: 0)
            }
            // Free text has no card: a faint outline under the pointer says it is one thing to grab.
            if (node.border == .invisible || bare) && !drawing && !selected && hovered && !editing {
                layer.outline.path = shape.inset(by: 0.625 / scale).path(in: layer.bounds).cgPath
                layer.outline.lineWidth = 1.25 / scale
                layer.outline.strokeColor = palette.accent.withAlphaComponent(0.45).cgColor
                if layer.outline.opacity < 1 { BoardSprings.fade(layer.outline, to: 1) }
                decorated.insert(id)
            } else if layer.outline.opacity > 0 {
                BoardSprings.fade(layer.outline, to: 0)
            }
            // The light on the card under the pointer.
            let lit = hovered && !selected && !editing && node.border != .invisible && !bare && !node.isSticky && !drawing
                && model.dragged.isEmpty
            layer.showSpecular(at: lit ? model.hoverPoint.map { CGPoint(x: $0.x / scale, y: $0.y / scale) } : nil,
                               path: lit ? shape.path(in: layer.bounds).cgPath : nil, dark: palette.dark)
            if lifted != layer.isLifted { lift(layer, lifted, node: node) }
            layer.zPosition = editing ? 4 : lifted ? 3 : selected ? 2 : hovered ? 1 : 0
        }
        for (id, layer) in groupLayers {
            guard let node = model.node(id) else { continue }
            decorateGroup(layer, node, palette: palette)
        }
    }

    private func ringPath(_ layer: BoardItemLayer, node: CanvasNode, shape: BoardShape, scale: CGFloat, drawing: Bool) {
        if drawing {
            layer.ring.path = CGPath(rect: layer.bounds.insetBy(dx: -4 / scale, dy: -4 / scale), transform: nil)
            layer.ring.lineWidth = 1.25 / scale
            layer.ring.lineDashPattern = [NSNumber(value: Double(5 / scale)), NSNumber(value: Double(4 / scale))]
            layer.ring.shadowOpacity = 0
        } else {
            let width = 2.25 / scale
            layer.ring.path = shape.inset(by: -3 / scale + width / 2).path(in: layer.bounds).cgPath
            layer.ring.lineWidth = width
            layer.ring.lineDashPattern = nil
            layer.ring.shadowRadius = 6 / scale
            layer.ring.shadowOpacity = 1
        }
    }

    /// What depends on the zoom: the rings, outlines and groups' lines stay as wide on screen.
    func rescaleDecorations(_ scale: CGFloat) {
        for id in decorated {
            guard let layer = items[id], let node = model.node(id) else { continue }
            let shape = BoardShape(node.kind == .text ? node.shape : nil,
                                   radius: node.isSticky ? 4 : node.isFreeText ? 6 : BoardStyle.cornerRadius)
            if layer.ring.opacity > 0 { ringPath(layer, node: node, shape: shape, scale: scale, drawing: node.isDrawing) }
            if layer.outline.opacity > 0 {
                layer.outline.path = shape.inset(by: 0.625 / scale).path(in: layer.bounds).cgPath
                layer.outline.lineWidth = 1.25 / scale
            }
        }
        decorated = decorated.filter { items[$0].map { $0.ring.opacity > 0 || $0.outline.opacity > 0 } ?? false }
        for (id, layer) in groupLayers {
            guard let node = model.node(id) else { continue }
            let selected = model.selection.contains(id) && model.presentation == nil
            let width = (selected ? 2.25 : 1.25) / scale
            layer.body.lineWidth = width
            let radius = Corners.r(node.ratio != nil ? 10 : BoardStyle.cornerRadius)
            layer.body.path = CGPath(roundedRect: layer.bounds.insetBy(dx: width / 2, dy: width / 2), cornerWidth: radius,
                                     cornerHeight: radius, transform: nil)
        }
    }

    /// The groups' labels drawn for the zoom the camera rests at.
    func relabelGroups() {
        guard let palette else { return }
        for (id, layer) in groupLayers {
            guard let node = model.node(id) else { continue }
            decorateGroup(layer, node, palette: palette)
        }
    }

    /// A dragged card rises: a little bigger, its shadow deeper; and settles back when let go.
    private func lift(_ layer: BoardItemLayer, _ lifted: Bool, node: CanvasNode) {
        layer.isLifted = lifted
        let scale: CGFloat = lifted ? 1.018 : 1
        let from = layer.presentation()?.value(forKeyPath: "transform.scale") ?? (lifted ? 1 : 1.018)
        layer.transform = CATransform3DMakeScale(scale, scale, 1)
        layer.add(BoardSprings.animation("transform.scale", Motion.Spring.lift, from: from, to: scale), forKey: "lift")
        let invisible = node.border == .invisible || model.isBare(node) || node.isDrawing
        guard !invisible else { return }
        let dark = palette?.dark ?? false
        let opacity: Float = lifted ? (node.isSticky ? 0.3 : Float(dark ? 0.5 : 0.22))
            : node.isSticky ? 0.16 : shadowed ? Float(dark ? 0.32 : 0.11) : 0
        let radius: CGFloat = lifted ? 26 : 10
        let offset = CGSize(width: 0, height: lifted ? 14 : 4)
        for (key, from, to) in [("shadowOpacity", layer.shadowOpacity as Any, opacity as Any),
                                ("shadowRadius", layer.shadowRadius as Any, radius as Any),
                                ("shadowOffset", NSValue(size: layer.shadowOffset) as Any, NSValue(size: offset) as Any)] {
            layer.add(BoardSprings.animation(key, Motion.Spring.lift, from: from, to: to), forKey: "lift." + key)
        }
        layer.shadowOpacity = opacity
        layer.shadowRadius = radius
        layer.shadowOffset = offset
    }

    // MARK: Groups

    func placeGroup(_ layer: BoardGroupLayer, _ node: CanvasNode) {
        place(layer, model.frame(of: node))
        if let palette { decorateGroup(layer, node, palette: palette) }
    }

    /// A group's tinted area and label, or a frame's page; as wide lines on screen at any zoom.
    func decorateGroup(_ layer: BoardGroupLayer, _ node: CanvasNode, palette: BoardPalette) {
        let scale = model.camera.scale
        let selected = model.selection.contains(node.id) && model.presentation == nil
        let tint = BoardStyle.nsColor(node.color) ?? palette.secondary
        let isFrame = node.ratio != nil
        let lineWidth = (selected ? 2.25 : 1.25) / scale
        let bounds = layer.bounds
        let radius = Corners.r(isFrame ? 10 : BoardStyle.cornerRadius)
        let path = CGPath(roundedRect: bounds.insetBy(dx: lineWidth / 2, dy: lineWidth / 2), cornerWidth: radius,
                          cornerHeight: radius, transform: nil)
        layer.body.frame = bounds
        layer.body.path = path
        layer.body.lineWidth = lineWidth
        layer.body.strokeColor = (selected ? palette.accent : tint.withAlphaComponent(0.4)).cgColor
        if isFrame {
            let paper = node.color == nil ? palette.background : palette.background.blended(withFraction: 0.05, of: tint) ?? palette.background
            layer.body.fillColor = paper.cgColor
            layer.body.shadowColor = NSColor.black.cgColor
            layer.body.shadowOpacity = 0.08
            layer.body.shadowRadius = 12 / scale
            layer.body.shadowOffset = CGSize(width: 0, height: 4 / scale)
            layer.body.shadowPath = path
        } else {
            layer.body.fillColor = tint.withAlphaComponent(0.07).cgColor
            layer.body.shadowOpacity = 0
        }
        // The label, above the group, as big on screen whatever the zoom (from 11 points).
        let editing = model.editing?.target == .node(node.id)
        layer.label.isHidden = editing
        let size = max(11, BoardStyle.groupLabelSize * scale)
        let pixels = BoardRenderer.pixelScale(for: CGSize(width: 400 / scale, height: 40 / scale), scale: scale, backing: backing)
        // While the camera moves a label keeps its picture, scaled with the world; it is drawn again once it rests.
        let moving = model.isNavigating && layer.labelKey != nil
        let title = node.label?.isEmpty == false ? node.label! : isFrame ? "Frame" : "Group"
        let number = model.slideNumbers[node.id]
        let key = "\(title)|\(number ?? 0)|\(selected)|\(node.color ?? "")|\(palette.dark)|\(BoardRenderer.scaleStep(scale))|\(pixels)|\(node.label?.isEmpty == false)"
        if layer.labelKey != key, !moving {
            layer.labelKey = key
            let (image, labelSize) = Self.groupLabel(title, number: number, named: node.label?.isEmpty == false, size: size / scale,
                                                     selected: selected, tint: tint, palette: palette, pixels: pixels)
            layer.label.contents = image
            layer.label.contentsScale = pixels
            layer.label.bounds = CGRect(origin: .zero, size: labelSize)
        }
        let height = max(16, BoardStyle.groupLabelSize * scale * 1.5) / scale
        layer.label.position = CGPoint(x: layer.label.bounds.width / 2, y: -height - 6 / scale + layer.label.bounds.height / 2
                                       + (height - layer.label.bounds.height) / 2)
    }

    /// A group's label: its name on a tinted capsule, after its slide number for a frame.
    static func groupLabel(_ title: String, number: Int?, named: Bool, size: CGFloat, selected: Bool, tint: NSColor,
                           palette: BoardPalette, pixels: CGFloat) -> (CGImage?, CGSize) {
        let font = NSFont.ui(size: size, weight: .semibold)
        let text = NSAttributedString(string: title.uiLocalized, attributes: [
            .font: font, .foregroundColor: named ? palette.text : palette.secondary,
        ])
        let textSize = text.size()
        let capsule = CGSize(width: ceil(min(textSize.width, size * 30)) + size * 1.2, height: ceil(textSize.height) + size * 0.36)
        var badge: (NSAttributedString, CGSize)?
        if let number {
            let digits = NSAttributedString(string: "\(number)", attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: size * 0.8, weight: .bold), .foregroundColor: NSColor.white,
            ])
            let side = max(size * 1.3, digits.size().width + size * 0.7)
            badge = (digits, CGSize(width: side, height: size * 1.3))
        }
        let gap = size * 5 / 17
        let total = CGSize(width: (badge.map { $0.1.width + gap } ?? 0) + capsule.width, height: max(capsule.height, badge?.1.height ?? 0))
        let width = Int(ceil(total.width * pixels)), height = Int(ceil(total.height * pixels))
        guard width > 0, height > 0, let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.displayP3)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return (nil, total) }
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: pixels, y: -pixels)
        var x: CGFloat = 0
        if let (digits, side) = badge {
            let rect = CGRect(x: 0, y: (total.height - side.height) / 2, width: side.width, height: side.height)
            context.addPath(CGPath(roundedRect: rect, cornerWidth: Corners.r(rect.height / 2), cornerHeight: Corners.r(rect.height / 2), transform: nil))
            context.setFillColor((selected ? palette.accent : tint.withAlphaComponent(0.9)).cgColor)
            context.fillPath()
            let digitSize = digits.size()
            BoardTextLayout.draw(digits, in: CGRect(x: rect.midX - digitSize.width / 2, y: rect.midY - digitSize.height / 2,
                                                    width: ceil(digitSize.width) + 1, height: ceil(digitSize.height) + 1), context: context)
            x = side.width + gap
        }
        let rect = CGRect(x: x, y: (total.height - capsule.height) / 2, width: capsule.width, height: capsule.height)
        context.addPath(CGPath(roundedRect: rect, cornerWidth: Corners.r(rect.height / 2), cornerHeight: Corners.r(rect.height / 2), transform: nil))
        context.setFillColor((selected ? palette.accent.withAlphaComponent(0.18) : tint.withAlphaComponent(0.14)).cgColor)
        context.fillPath()
        BoardTextLayout.draw(text, in: CGRect(x: rect.minX + size * 0.6, y: rect.minY + size * 0.18, width: rect.width - size * 1.2 + 1,
                                              height: ceil(textSize.height) + 1), context: context, maxLines: 1)
        return (context.makeImage(), total)
    }
}
