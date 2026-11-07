import AppKit
import PluginKitUI
import QuartzCore
import SwiftUI

/// A mindmap tab: an infinite dotted canvas with the topics, coloured by branch and joined by curves. Everything
/// works from the keyboard (Tab, Return, arrows, Space…, `MindmapShortcuts` lists them), topics can be dragged
/// onto, before or after others and across to the other side, and every change animates.
///
/// AppKit and Core Animation only (docs/APPKIT.md): each topic is a layer whose body is a bitmap drawn off the main
/// thread once per look (`MindmapTopicArt`), the edges are a few shape layers (one per colour, width and shade), and
/// the camera is the transform of the layer holding them, so a pan or a zoom moves one transform and lays nothing
/// out. A change of the layout springs each topic to its place on the render server; the edges follow their topics
/// frame by frame while it plays. The same view is a map in a page and on a board's card (`presentation ==
/// .embedded`), where it shows a picture of the map until it is entered.
final class MindmapCanvasView: NSView, NativeHostedView {
    let model: MindmapTabModel
    private var theme: ThemeTokens?
    private var palette: MindmapPalette?
    private var paletteIndex = -1
    private var topInset: CGFloat = 0

    private let grid = MindmapGridLayer()
    /// The camera: world coordinates in, the view's out (`cameraTransform`).
    private let worldLayer = CALayer()
    private let edgesLayer = CALayer()
    private let topicsLayer = CALayer()
    /// The drag's guides and the marquee, in the view's coordinates.
    private let overlayLayer = CALayer()
    private let pictureLayer = CALayer()

    private var topics: [String: MindmapTopicLayer] = [:]
    /// Topics on their way out (folded or deleted), shrinking into their parent.
    private var leaving: [MindmapTopicLayer] = []
    private var scene: [MindmapSceneTopic] = []
    private var edgeLayers: [MindmapEdgeStyle: CAShapeLayer] = [:]
    private var dragged: Set<String> = []
    private var hoveredID: String?
    private var pointer: CGPoint?

    /// The camera shown, and the pixels per point the topics are drawn at for it.
    private var camera: Camera?
    private var rasterScale: CGFloat = 2
    private var rasterWork: DispatchWorkItem?
    private var rasterGeneration = 0

    /// Runs while a layout or camera animation plays: the edges and the grid follow what the layers show.
    private var ticker: CADisplayLink?
    private var tickUntil: CFTimeInterval = 0
    /// Until when topics move: the edges follow them; a camera gliding alone moves only the grid.
    private var edgesUntil: CFTimeInterval = 0

    private var editorBox: NSView?
    private var editorField: MindmapTextField.FocusingTextField?
    private var editorCoordinator: MindmapTextField.Coordinator?
    private var editorTopic: String?

    private var toolbar: NSHostingView<AnyView>?
    private var banner: NSHostingView<AnyView>?
    private var shortcuts: NSHostingView<AnyView>?
    private var missing: NSHostingView<AnyView>?
    private var chromeTheme: ThemeTokens?
    /// The chrome's sizes, measured once per theme and bounds: measuring a hosting view lays its SwiftUI out.
    private var chromeSizes: [ObjectIdentifier: (bounds: CGSize, size: CGSize)] = [:]

    private var ghost: CALayer?
    private let dropIndicator = CAShapeLayer()
    private let dropLink = CAShapeLayer()
    private let dropDot = CAShapeLayer()
    private let marquee = CAShapeLayer()

    private var follows: [AnyObject] = []
    private var mouse: Mouse?
    private var pictureKey: MindmapPictures.Key?

    private struct Camera: Equatable {
        var offset: CGSize
        var scale: CGFloat
        var inset: CGFloat
    }

    /// A press in progress: on a topic (a click, or a drag past 4 points) or on the background (a click, or a
    /// marquee past 3 points).
    private struct Mouse {
        var topic: String?
        var start: CGPoint
        var started = false
    }

    init(model: MindmapTabModel) {
        self.model = model
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        guard let root = layer else { return }
        root.masksToBounds = true
        root.addSublayer(grid)
        worldLayer.anchorPoint = .zero
        worldLayer.addSublayer(edgesLayer)
        worldLayer.addSublayer(topicsLayer)
        root.addSublayer(worldLayer)
        overlayLayer.anchorPoint = .zero
        root.addSublayer(overlayLayer)
        pictureLayer.contentsGravity = .resizeAspect
        pictureLayer.minificationFilter = .trilinear
        pictureLayer.isHidden = true
        root.addSublayer(pictureLayer)
        for layer in [dropIndicator, dropLink, dropDot, marquee] {
            layer.isHidden = true
            overlayLayer.addSublayer(layer)
        }
        model.keyView = self
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { model.root != nil && !showsPicture }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private var embedded: Bool { model.context.presentation == .embedded }
    /// On a board and not entered: a picture of the map, which takes no clicks (the board's).
    private var showsPicture: Bool { embedded && !model.context.isActive }

    // MARK: - Host

    func hostEnvironmentChanged(_ environment: NativeViewEnvironment) {
        let first = theme == nil
        let inset = embedded ? 0 : environment.topInset
        if inset != topInset {
            topInset = inset
            needsLayout = true
        }
        guard first || environment.theme != theme else { return }
        theme = environment.theme
        // The host tells again for changes the map does not show (a font, the page's width): only new colours
        // draw the topics again.
        let changed = updatePalette()
        if first {
            startFollowing()
            needsLayout = true
        } else if changed {
            rebuildAll()
        } else {
            applyChrome()
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        guard theme != nil, updatePalette() else { return }
        rebuildAll()
    }


    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        guard theme != nil else { return }
        rasterScale = 0
        updateRaster(now: true)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        // Drawn for the window's colour space: drawn again only if it is another one.
        if theme != nil, updatePalette() { rebuildAll() }
        model.undoManager = undoManager
        // Embedded, the map is as big as its card and the board scrolls it; it takes the keyboard when entered.
        if !embedded { model.requestKeyboard() }
    }

    /// The colours for the theme, the appearance and the window: true when they changed.
    @discardableResult private func updatePalette() -> Bool {
        guard let theme else { return false }
        let palette = MindmapPalette(theme: theme, appearance: effectiveAppearance,
                                     space: window?.colorSpace?.cgColorSpace ?? self.palette?.space)
        guard palette != self.palette else { return false }
        self.palette = palette
        paletteIndex = MindmapTopicArt.shared.index(of: palette)
        layer?.backgroundColor = embedded ? nil : palette.background
        grid.color = embedded ? nil : palette.secondaryText.copy(alpha: 0.22)
        let accent = palette.accent
        marquee.fillColor = accent.copy(alpha: 0.08)
        marquee.strokeColor = accent.copy(alpha: 0.6)
        marquee.lineWidth = 1
        return true
    }

    /// Follows the model: each part of the map runs again only for what it shows.
    private func startFollowing() {
        let model = model
        follows = [
            Follow({ model.scene }) { [weak self] scene in self?.applyScene(scene) },
            Follow({ Camera(offset: model.offset, scale: model.scale, inset: 0) }) { [weak self] _ in self?.applyCamera() },
            Follow({ StateKey(model) }) { [weak self] _ in self?.applyStates() },
            Follow({ DragKey(model) }) { [weak self] _ in self?.applyDragFeedback() },
            Follow({ ChromeKey(model) }) { [weak self] _ in self?.applyChrome() },
            Follow({ model.focusRequest }) { [weak self] _ in self?.takeKeyboardSoon() },
            Follow({ model.draft }) { [weak self] draft in
                guard let field = self?.editorField, field.currentEditor() == nil, field.stringValue != draft else { return }
                field.stringValue = draft
            },
            Follow({ [model.context.isActive, model.context.presentation == .embedded] }) { [weak self] _ in
                self?.applyPresentation()
            },
        ]
    }

    private func rebuildAll() {
        applyScene(model.scene, force: true)
        applyChrome()
        applyPresentation()
    }

    override func layout() {
        super.layout()
        let size = CGSize(width: bounds.width, height: max(0, bounds.height - topInset))
        if size != model.viewSize { model.viewResized(size) }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        pictureLayer.frame = bounds
        overlayLayer.position = CGPoint(x: 0, y: topInset)
        CATransaction.commit()
        applyCamera()
        // The shortcuts' card takes the map's size: made again for a new one.
        if shortcuts != nil, let known = chromeSizes[ObjectIdentifier(shortcuts!)], known.bounds != bounds.size {
            chromeTheme = nil
            applyChrome()
        } else {
            layoutChrome()
        }
    }

    // MARK: - The camera

    private func cameraTransform(_ camera: Camera) -> CATransform3D {
        CATransform3DMakeAffineTransform(CGAffineTransform(
            a: camera.scale, b: 0, c: 0, d: camera.scale, tx: camera.offset.width, ty: camera.offset.height + camera.inset
        ))
    }

    private func applyCamera() {
        guard theme != nil else { return }
        let new = Camera(offset: model.offset, scale: model.scale, inset: topInset)
        let animated = model.animatesCamera && camera != nil && !Motion.reduceMotion
        model.animatesCamera = false
        guard new != camera else { return }
        let old = camera
        camera = new
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let transform = cameraTransform(new)
        if animated, let old {
            let glide = CASpringAnimation(perceptualDuration: Motion.Spring.smooth.duration, bounce: Motion.Spring.smooth.bounce)
            glide.keyPath = "transform"
            glide.fromValue = worldLayer.presentation()?.transform ?? cameraTransform(old)
            glide.toValue = transform
            worldLayer.add(glide, forKey: "camera")
            tick(for: glide.settlingDuration)
        } else {
            worldLayer.removeAnimation(forKey: "camera")
            grid.update(offset: CGSize(width: new.offset.width, height: new.offset.height + new.inset), scale: new.scale,
                        size: bounds.size)
        }
        worldLayer.transform = transform
        if old?.scale != new.scale { updateEdgeWidths() }
        CATransaction.commit()
        placeEditor()
        applyDragFeedback()
        if old?.scale != new.scale { updateRaster(now: false) }
    }

    /// The topics are drawn again at the pixels per point the zoom needs once it settles: sharp at 400 %, light at 10 %.
    private func updateRaster(now: Bool) {
        rasterWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.rasterize() }
        rasterWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (now ? 0 : 0.18), execute: work)
    }

    private func wantedRaster() -> CGFloat {
        let backing = window?.backingScaleFactor ?? 2
        let scale = model.scale
        return backing * (scale > 2 ? 4 : scale > 1 ? 2 : 1)
    }

    private func rasterize() {
        let wanted = wantedRaster()
        guard wanted != rasterScale else { return }
        rasterScale = wanted
        rasterGeneration += 1
        let generation = rasterGeneration
        // Off the main thread: the map stays as it is (scaled) until the new drawings are in.
        let looks = Dictionary(uniqueKeysWithValues: topics.compactMap { id, layer in
            layer.look.map { (id, MindmapTopicLook(text: $0.text, depth: $0.depth, size: $0.size, branch: $0.branch,
                                                   hidesText: $0.hidesText, palette: $0.palette, scale: wanted)) }
        })
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let images = MindmapTopicArt.shared.images(Array(looks.values))
            DispatchQueue.main.async {
                guard let self, generation == self.rasterGeneration else { return }
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                for (id, look) in looks {
                    guard let layer = self.topics[id], let current = layer.look, current.scale != wanted,
                          current.text == look.text, current.size == look.size, current.hidesText == look.hidesText,
                          current.palette == look.palette, let image = images[look] else { continue }
                    layer.setBody(image, look: look)
                }
                CATransaction.commit()
            }
        }
    }

    // MARK: - The scene

    private func look(for item: MindmapSceneTopic, editing: Bool) -> MindmapTopicLook {
        let placement = item.placement
        return MindmapTopicLook(
            text: item.text, depth: min(placement.depth, 2), size: placement.frame.size, branch: placement.branch,
            hidesText: editing, palette: paletteIndex, scale: rasterScale
        )
    }

    private func applyScene(_ scene: [MindmapSceneTopic], force: Bool = false) {
        guard palette != nil, !showsPicture else { return }
        if rasterScale == 0 || topics.isEmpty { rasterScale = wantedRaster() }
        let animated = model.animatesLayout && !self.scene.isEmpty && window != nil
        model.animatesLayout = false
        guard force || scene != self.scene || topics.count != scene.count else { return }
        self.scene = scene
        let editing = model.editingID
        if let root = scene.first(where: { $0.placement.depth == 0 }), editing != root.id {
            MindmapTopicArt.prepareHalftone(root.placement.frame.size)
        }
        let looks = scene.map { look(for: $0, editing: $0.id == editing) }
        let images = MindmapTopicArt.shared.images(looks)
        let reduce = Motion.reduceMotion
        let spring = CASpringAnimation(perceptualDuration: MindmapTabModel.spring.duration, bounce: MindmapTabModel.spring.bounce)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        var seen = Set<String>()
        for (item, look) in zip(scene, looks) {
            seen.insert(item.id)
            let frame = item.placement.frame
            let center = CGPoint(x: frame.midX, y: frame.midY)
            if let layer = topics[item.id] {
                let from = layer.presentation()?.position ?? layer.position
                layer.item = item
                layer.bounds = CGRect(origin: .zero, size: frame.size)
                layer.position = center
                if animated, !reduce, from != center {
                    let move = spring.copy() as! CASpringAnimation
                    move.keyPath = "position"
                    move.fromValue = from
                    move.toValue = center
                    layer.add(move, forKey: "move")
                }
            } else {
                let layer = MindmapTopicLayer(item: item)
                layer.bounds = CGRect(origin: .zero, size: frame.size)
                layer.position = center
                topics[item.id] = layer
                topicsLayer.addSublayer(layer)
                if animated {
                    if reduce {
                        layer.add(Self.fade(from: 0, to: 1), forKey: "enter")
                    } else {
                        let parent = item.parentFrame.map { CGPoint(x: $0.midX, y: $0.midY) } ?? center
                        layer.add(Self.grow(spring, from: parent, to: center, entering: true), forKey: "enter")
                    }
                }
            }
            if let layer = topics[item.id], layer.look != look, let image = images[look] {
                layer.setBody(image, look: look)
            }
        }
        for (id, layer) in topics where !seen.contains(id) {
            topics[id] = nil
            guard animated else {
                layer.removeFromSuperlayer()
                continue
            }
            let item = layer.item
            let target = item.parentID.flatMap { model.placements[$0]?.frame }.map { CGPoint(x: $0.midX, y: $0.midY) }
                ?? layer.position
            let leave = reduce ? Self.fade(from: 1, to: 0) : Self.grow(spring, from: target, to: layer.position, entering: false)
            leave.isRemovedOnCompletion = false
            leave.fillMode = .forwards
            leaving.append(layer)
            layer.add(leave, forKey: "leave")
            DispatchQueue.main.asyncAfter(deadline: .now() + leave.duration) { [weak self, weak layer] in
                guard let layer else { return }
                layer.removeFromSuperlayer()
                self?.leaving.removeAll { $0 === layer }
            }
        }
        CATransaction.commit()
        applyStates()
        if animated, !reduce {
            edgesUntil = max(edgesUntil, CACurrentMediaTime() + spring.settlingDuration)
            tick(for: spring.settlingDuration)
        } else {
            drawEdges()
        }
        placeEditor()
        applyDragFeedback()
    }

    /// Grows from (or folds back into) the parent topic: from its centre, a fifth of the size, transparent.
    private static func grow(_ spring: CASpringAnimation, from parent: CGPoint, to place: CGPoint, entering: Bool) -> CAAnimation {
        func animation(_ keyPath: String, _ hidden: Any, _ shown: Any) -> CASpringAnimation {
            let animation = spring.copy() as! CASpringAnimation
            animation.keyPath = keyPath
            animation.fromValue = entering ? hidden : shown
            animation.toValue = entering ? shown : hidden
            return animation
        }
        let group = CAAnimationGroup()
        group.animations = [
            animation("position", parent, place),
            animation("transform.scale", 0.2, 1),
            animation("opacity", 0, 1),
        ]
        group.duration = spring.settlingDuration
        return group
    }

    /// Under Reduce Motion, what arrives or leaves fades.
    private static func fade(from: Float, to: Float) -> CABasicAnimation {
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = from
        fade.toValue = to
        fade.duration = 0.12
        fade.timingFunction = CAMediaTimingFunction(name: to > from ? .easeOut : .easeIn)
        return fade
    }

    /// Selection, editing, hover, folding and the drag on each topic: rings, tints, toggles, nothing drawn again
    /// but the body of a topic starting or stopping being edited.
    private func applyStates() {
        guard let palette, !showsPicture else { return }
        let selection = model.selection
        let editing = model.editingID
        let folded = model.folded
        let model = model
        let newDragged = Set(model.scene.lazy.map(\.id).filter { model.isDragged($0) })
        let draggedChanged = newDragged != dragged
        dragged = newDragged
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (id, layer) in topics {
            let item = layer.item
            let isEditing = editing == id
            let look = look(for: item, editing: isEditing)
            if layer.look != look, let image = MindmapTopicArt.shared.image(look) { layer.setBody(image, look: look) }
            layer.update(
                selected: selection.contains(id), editing: isEditing, hovered: hoveredID == id,
                folded: folded.contains(id), dragged: dragged.contains(id), palette: palette
            )
        }
        CATransaction.commit()
        if draggedChanged { drawEdges() }
        updateEditor()
    }

    // MARK: - Edges

    /// The edges as the topics are shown now: their final places, or where an animation has them on this frame.
    private func drawEdges(live: Bool = false) {
        guard let palette else { return }
        var paths: [MindmapEdgeStyle: CGMutablePath] = [:]
        func frame(_ layer: MindmapTopicLayer?) -> CGRect? {
            guard let layer else { return nil }
            return live ? (layer.presentation()?.frame ?? layer.frame) : layer.frame
        }
        var items = scene.map { ($0, topics[$0.id]) }
        if live { items += leaving.map { ($0.item, Optional($0)) } }
        for (item, layer) in items {
            guard var source = item.source else { continue }
            var child = item.placement
            if live {
                guard let childFrame = frame(layer) else { continue }
                child.frame = childFrame
                let sourceID = item.placement.edgeFrom ?? item.parentID
                if let sourceFrame = frame(sourceID.flatMap { topics[$0] }) { source.frame = sourceFrame }
            }
            let curve = MindmapEdgeCurve(child: child, source: source)
            let width = item.placement.depth == 1 ? 0 : item.placement.depth == 2 ? 1 : 2
            let faded = dragged.contains(item.id)
            for (index, piece) in curve.pieces(MindmapEdgeStyle.shades).enumerated() {
                let style = MindmapEdgeStyle(branch: item.placement.branch, width: width, shade: index, faded: faded)
                let path = paths[style] ?? CGMutablePath()
                path.move(to: piece.from)
                path.addCurve(to: piece.to, control1: piece.c1, control2: piece.c2)
                paths[style] = path
            }
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (style, layer) in edgeLayers where paths[style] == nil { layer.path = nil }
        for (style, path) in paths {
            let layer = edgeLayers[style] ?? {
                let layer = CAShapeLayer()
                layer.fillColor = nil
                layer.lineCap = .butt
                edgesLayer.addSublayer(layer)
                edgeLayers[style] = layer
                return layer
            }()
            let color = palette.color(branch: style.branch)
            layer.strokeColor = color.copy(alpha: style.alpha)
            layer.lineWidth = max(style.lineWidth, 0.75 / max(model.scale, 0.01))
            layer.path = path
        }
        CATransaction.commit()
    }

    private func updateEdgeWidths() {
        for (style, layer) in edgeLayers { layer.lineWidth = max(style.lineWidth, 0.75 / max(model.scale, 0.01)) }
    }

    /// Follows the animations on each display frame for `duration`: the edges between moving topics, the grid
    /// under a gliding camera.
    private func tick(for duration: CFTimeInterval) {
        tickUntil = max(tickUntil, CACurrentMediaTime() + duration)
        guard ticker == nil else { return }
        let link = displayLink(target: self, selector: #selector(step(_:)))
        link.add(to: .main, forMode: .common)
        ticker = link
    }

    @objc private func step(_ link: CADisplayLink) {
        let now = CACurrentMediaTime()
        let done = now >= tickUntil
        if now < edgesUntil + 1 / 30 { drawEdges(live: now < edgesUntil) }
        let transform = done ? worldLayer.transform : (worldLayer.presentation()?.transform ?? worldLayer.transform)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        grid.update(offset: CGSize(width: transform.m41, height: transform.m42), scale: transform.m11, size: bounds.size)
        CATransaction.commit()
        guard done else { return }
        link.invalidate()
        ticker = nil
    }

    // MARK: - Editing

    /// The topic being edited gets an AppKit text field over it, in a box scaled as the camera is.
    private func updateEditor() {
        let editing = model.editingID
        if editing != editorTopic {
            editorBox?.removeFromSuperview()
            editorBox = nil
            editorField = nil
            editorCoordinator = nil
            editorTopic = nil
        }
        guard let editing, let placement = model.placements[editing], let theme else { return }
        if editorBox == nil {
            let box = FlippedView()
            let depth = placement.depth
            let (field, coordinator) = MindmapTextField.make(
                model: model, font: MindmapStyle.font(depth: depth),
                color: depth == 0 ? .white : NSColor(theme.text)
            )
            field.alignment = depth <= 1 ? .center : .left
            box.addSubview(field)
            editorBox = box
            editorField = field
            editorCoordinator = coordinator
            editorTopic = editing
            placeEditor()
            addSubview(box)
        } else {
            placeEditor()
        }
    }

    private func placeEditor() {
        guard let box = editorBox, let field = editorField, let id = editorTopic,
              let placement = model.placements[id] else { return }
        let frame = placement.frame
        var rect = model.screenRect(frame)
        rect.origin.y += topInset
        box.frame = rect
        box.bounds = CGRect(origin: .zero, size: frame.size)
        let padding = MindmapStyle.padding(depth: placement.depth)
        let height = ceil(MindmapStyle.font(depth: placement.depth).boundingRectForFont.height)
        let textHeight = frame.height - padding.top - padding.bottom
        field.frame = CGRect(x: padding.leading - 2, y: padding.top + (textHeight - max(textHeight, height)) / 2,
                             width: frame.width - padding.leading - padding.trailing + 6, height: max(textHeight, height))
    }

    // MARK: - Drag feedback

    /// The dragged topic under the pointer, the ring or bar where it would land, the dashed curve from its new
    /// parent, the marquee: all in the view's coordinates, set again at each pointer move.
    private func applyDragFeedback() {
        guard let palette, camera != nil else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        if let rect = model.marquee {
            marquee.isHidden = false
            marquee.path = CGPath(rect: rect.insetBy(dx: 0.5, dy: 0.5), transform: nil)
        } else {
            marquee.isHidden = true
        }
        updateGhost(palette)
        updateDropIndicator(palette)
        updateDropLink(palette)
    }

    private func updateGhost(_ palette: MindmapPalette) {
        guard let location = model.dragLocation, let first = model.dragging.first,
              let item = scene.first(where: { $0.id == first }) else {
            ghost?.removeFromSuperlayer()
            ghost = nil
            return
        }
        let look = look(for: item, editing: false)
        if ghost == nil || (ghost as? MindmapTopicLayer)?.look != look {
            ghost?.removeFromSuperlayer()
            let layer = MindmapTopicLayer(item: item)
            layer.bounds = CGRect(origin: .zero, size: item.placement.frame.size)
            if let image = MindmapTopicArt.shared.image(look) { layer.setBody(image, look: look) }
            layer.update(selected: true, editing: false, hovered: false, folded: false, dragged: false, palette: palette)
            layer.opacity = 0.45
            layer.shadowColor = CGColor(gray: 0, alpha: 1)
            layer.shadowOpacity = 0.12
            layer.shadowRadius = 10
            layer.shadowOffset = CGSize(width: 0, height: 4)
            if model.dragging.count > 1 {
                let badge = CALayer()
                let image = MindmapBadges.capsule(text: "\(model.dragging.count)", font: .systemFont(ofSize: 11, weight: .bold),
                                                  fill: palette.accent, stroke: nil, textColor: CGColor(gray: 1, alpha: 1),
                                                  scale: window?.backingScaleFactor ?? 2)
                badge.contents = image.image
                badge.bounds = CGRect(origin: .zero, size: image.size)
                badge.position = CGPoint(x: layer.bounds.maxX + 8 - image.size.width / 2 + image.size.width / 2,
                                         y: -8 + image.size.height / 2)
                layer.addSublayer(badge)
            }
            overlayLayer.addSublayer(layer)
            ghost = layer
        }
        ghost?.position = CGPoint(x: location.x - model.dragGrab.width, y: location.y - model.dragGrab.height)
        ghost?.setAffineTransform(CGAffineTransform(scaleX: model.scale, y: model.scale))
    }

    private func updateDropIndicator(_ palette: MindmapPalette) {
        guard let target = model.dropTarget, let placement = model.placements[target.id] else {
            dropIndicator.isHidden = true
            return
        }
        let rect = model.screenRect(placement.frame)
        let color = palette.color(branch: placement.branch)
        dropIndicator.isHidden = false
        switch target.mode {
        case .inside:
            let ring = rect.insetBy(dx: -7, dy: -7).insetBy(dx: 1.25, dy: 1.25)
            dropIndicator.path = Path(roundedRect: ring, cornerRadius: Corners.r(12 * model.scale + 4) - 1.25,
                                      style: .continuous).cgPath
            dropIndicator.fillColor = nil
            dropIndicator.strokeColor = color
            dropIndicator.lineWidth = 2.5
            dropIndicator.lineDashPattern = [6, 4]
            dropIndicator.shadowOpacity = 0
        case .before, .after:
            let bar: CGRect
            if model.mode == .timeline, placement.depth == 1 {
                let x = target.mode == .before ? rect.minX - 10 : rect.maxX + 10
                let height = max(rect.height, 24)
                bar = CGRect(x: x - 2, y: rect.midY - height / 2, width: 4, height: height)
            } else {
                let y = target.mode == .before ? rect.minY - 7 : rect.maxY + 7
                let width = max(rect.width, 48)
                bar = CGRect(x: rect.midX - width / 2, y: y - 2, width: width, height: 4)
            }
            dropIndicator.path = CGPath(roundedRect: bar, cornerWidth: 2, cornerHeight: 2, transform: nil)
            dropIndicator.fillColor = color
            dropIndicator.strokeColor = nil
            dropIndicator.lineDashPattern = nil
            dropIndicator.shadowColor = color
            dropIndicator.shadowOpacity = 0.4
            dropIndicator.shadowRadius = 3
            dropIndicator.shadowOffset = .zero
        }
    }

    /// A dashed curve from the topic the dragged ones would hang from to the dragged topic, leaving that topic's
    /// side: it shows at once which side of the central topic a drop lands on.
    private func updateDropLink(_ palette: MindmapPalette) {
        guard let target = model.dropTarget, let location = model.dragLocation, let first = model.dragging.first,
              let dragged = model.placements[first],
              let parentID = target.mode == .inside ? target.id : model.parent(of: target.id)?.id,
              let parent = model.placements[parentID] else {
            dropLink.isHidden = true
            dropDot.isHidden = true
            return
        }
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
        let color = parent.depth == 0 ? palette.accent : palette.color(branch: parent.branch)
        let path = CGMutablePath()
        path.move(to: start)
        path.addCurve(to: end, control1: CGPoint(x: start.x + CGFloat(side) * dx, y: start.y),
                      control2: CGPoint(x: end.x - CGFloat(side) * dx, y: end.y))
        dropLink.isHidden = false
        dropLink.path = path
        dropLink.fillColor = nil
        dropLink.strokeColor = color
        dropLink.lineWidth = 2.5
        dropLink.lineCap = .round
        dropLink.lineDashPattern = [5, 5]
        dropDot.isHidden = false
        dropDot.path = CGPath(ellipseIn: CGRect(x: start.x - 4, y: start.y - 4, width: 8, height: 8), transform: nil)
        dropDot.fillColor = color
    }

    // MARK: - Chrome

    /// The zoom bar, the read-only banner, the shortcuts and the missing note: SwiftUI, each in a hosting view of
    /// its own, shown only when needed.
    private func applyChrome() {
        guard let theme, !showsPicture else {
            for view in [toolbar, banner, shortcuts, missing] { view?.isHidden = true }
            return
        }
        let model = model
        func host(_ existing: NSHostingView<AnyView>?, _ shown: Bool, _ content: () -> AnyView) -> NSHostingView<AnyView>? {
            guard shown else {
                existing?.removeFromSuperview()
                return nil
            }
            // Made once per theme: the views follow the model themselves.
            if let existing, chromeTheme == theme {
                existing.isHidden = false
                return existing
            }
            let view = existing ?? {
                let view = NSHostingView(rootView: AnyView(EmptyView()))
                view.sizingOptions = [.intrinsicContentSize]
                addSubview(view)
                return view
            }()
            view.rootView = AnyView(content().environment(\.themeTokens, theme))
            view.isHidden = false
            return view
        }
        let missingNote = model.root == nil
        missing = host(missing, missingNote) { AnyView(MindmapMissingNote(path: model.path)) }
        toolbar = host(toolbar, !embedded && !missingNote) { AnyView(MindmapToolbar(model: model)) }
        banner = host(banner, !embedded && !missingNote && !model.isEditable) { AnyView(MindmapReadOnlyBanner()) }
        shortcuts = host(shortcuts, model.showsShortcuts && !missingNote) {
            AnyView(MindmapShortcutsCard(width: bounds.width, height: bounds.height - topInset))
        }
        chromeTheme = theme
        chromeSizes = [:]
        layoutChrome()
    }

    private func setFrame(_ view: NSView, _ frame: CGRect) {
        if view.frame != frame { view.frame = frame }
    }

    private func fitting(_ view: NSView) -> CGSize {
        if let known = chromeSizes[ObjectIdentifier(view)], known.bounds == bounds.size { return known.size }
        let size = view.fittingSize
        chromeSizes[ObjectIdentifier(view)] = (bounds.size, size)
        return size
    }

    private func layoutChrome() {
        if let missing, missing.frame != bounds { missing.frame = bounds }
        if let toolbar {
            let size = fitting(toolbar)
            setFrame(toolbar, CGRect(x: ((bounds.width - size.width) / 2).rounded(), y: bounds.height - 14 - size.height,
                                   width: size.width, height: size.height))
        }
        if let banner {
            let size = fitting(banner)
            setFrame(banner, CGRect(x: ((bounds.width - size.width) / 2).rounded(), y: topInset + 12,
                                  width: size.width, height: size.height))
        }
        if let shortcuts {
            let size = fitting(shortcuts)
            let height = bounds.height - topInset
            setFrame(shortcuts, CGRect(x: ((bounds.width - size.width) / 2).rounded(),
                                     y: topInset + ((height - size.height) / 2 - 25).rounded(),
                                     width: size.width, height: size.height))
        }
    }

    // MARK: - On a board

    private func applyPresentation() {
        let picture = showsPicture
        pictureLayer.isHidden = !picture
        grid.isHidden = picture || embedded
        worldLayer.isHidden = picture
        overlayLayer.isHidden = picture
        if picture {
            showPicture()
        } else {
            pictureLayer.contents = nil
            pictureKey = nil
            if topics.isEmpty { applyScene(model.scene, force: true) }
            // Entered on a board, the map takes the keyboard: Tab, Return and typing go to its topics.
            if embedded, model.context.isActive { model.requestKeyboard() }
        }
        applyChrome()
    }

    /// A picture of all of the map, shrunk to fit, drawn off the main thread once per change of the map and kept:
    /// a board's card shows it until it is entered.
    private func showPicture() {
        guard let theme else { return }
        let dark = palette?.dark ?? false
        let key = MindmapPictures.Key(path: model.path, revision: model.scene.isEmpty ? -1 : model.sceneRevision, dark: dark)
        guard key != pictureKey else { return }
        pictureKey = key
        if let known = MindmapPictures.shared.image(for: key) {
            pictureLayer.contents = known
            return
        }
        guard let sketch = MindmapSketch(model: model, theme: theme, dark: dark) else { return }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let drawn = sketch.draw() else { return }
            DispatchQueue.main.async {
                MindmapPictures.shared.store(drawn, for: key)
                guard let self, self.pictureKey == key else { return }
                self.pictureLayer.contents = drawn
            }
        }
    }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {}

    /// Only a picture of the view drawn by AppKit (`cacheDisplay`, a board's export) comes here; the screen shows the
    /// layers. On a card, that picture is the map's.
    override func draw(_ dirtyRect: NSRect) {
        guard showsPicture, let theme, let context = NSGraphicsContext.current?.cgContext else { return }
        var image = pictureLayer.contents.map { $0 as! CGImage }
        var size = image.map { CGSize(width: $0.width, height: $0.height) } ?? .zero
        if image == nil, let sketch = MindmapSketch(model: model, theme: theme, dark: palette?.dark ?? false) {
            image = sketch.draw()
            size = sketch.size
        }
        guard let image, size.width > 0, size.height > 0 else { return }
        let fit = min(bounds.width / size.width, bounds.height / size.height)
        let rect = CGRect(x: (bounds.width - size.width * fit) / 2, y: (bounds.height - size.height * fit) / 2,
                          width: size.width * fit, height: size.height * fit)
        context.saveGState()
        context.translateBy(x: 0, y: rect.maxY + rect.minY)
        context.scaleBy(x: 1, y: -1)
        context.interpolationQuality = .high
        context.draw(image, in: rect)
        context.restoreGState()
    }

    // MARK: - Pointer

    override func hitTest(_ point: NSPoint) -> NSView? {
        showsPicture ? nil : super.hitTest(point)
    }

    /// A point of the view in the map's coordinates (below the page's toolbar).
    private func canvasPoint(_ event: NSEvent) -> CGPoint {
        // A made event (a test's) may have no window: its location is then on the screen.
        let inWindow = event.window == nil ? (window?.convertPoint(fromScreen: event.locationInWindow) ?? .zero) : event.locationInWindow
        let point = convert(inWindow, from: nil)
        return CGPoint(x: point.x, y: point.y - topInset)
    }

    private func topic(at point: CGPoint) -> String? {
        let world = model.worldPoint(point)
        let editing = model.editingID
        let selection = model.selection
        var best: (id: String, rank: Int)?
        for item in scene where item.placement.frame.insetBy(dx: -2, dy: -2).contains(world) {
            let rank = item.id == editing ? 2 : selection.contains(item.id) ? 1 : 0
            if best == nil || rank >= best!.rank { best = (item.id, rank) }
        }
        return best?.id
    }

    private func foldToggle(at point: CGPoint) -> String? {
        let world = model.worldPoint(point)
        for (id, layer) in topics {
            if let frame = layer.foldFrame, frame.insetBy(dx: -3, dy: -3).contains(world) { return id }
        }
        return nil
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self))
    }

    override func mouseMoved(with event: NSEvent) {
        let point = canvasPoint(event)
        pointer = point
        setHovered(foldToggle(at: point) ?? topic(at: point))
    }

    override func mouseExited(with event: NSEvent) {
        pointer = nil
        setHovered(nil)
    }

    private func setHovered(_ id: String?) {
        guard id != hoveredID, let palette else { return }
        let old = hoveredID
        hoveredID = id
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for changed in [old, id].compactMap({ $0 }) {
            topics[changed]?.update(
                selected: model.selection.contains(changed), editing: model.editingID == changed,
                hovered: changed == id, folded: model.folded.contains(changed), dragged: dragged.contains(changed),
                palette: palette
            )
        }
        CATransaction.commit()
        if let id, let item = topics[id]?.item {
            toolTip = foldToggle(at: pointer ?? .zero) == id
                ? (model.folded.contains(id) ? "\(item.descendantCount) hidden topics: click to unfold (⌥⌘→ or ⌘.)"
                    : "Fold (⌥⌘← or ⌘.)")
                : nil
        } else {
            toolTip = nil
        }
    }

    override func mouseDown(with event: NSEvent) {
        let point = canvasPoint(event)
        if let id = foldToggle(at: point) {
            model.toggleFold(id)
            return
        }
        guard let id = topic(at: point) else {
            mouse = Mouse(topic: nil, start: point)
            return
        }
        if event.clickCount >= 2 {
            model.startEdit(id)
            mouse = nil
            return
        }
        if model.editingID != id {
            model.select(id, extend: event.modifierFlags.contains(.shift))
            model.takeKeyboard()
        }
        mouse = Mouse(topic: id, start: point)
    }

    override func mouseDragged(with event: NSEvent) {
        guard var mouse else { return }
        let point = canvasPoint(event)
        let distance = hypot(point.x - mouse.start.x, point.y - mouse.start.y)
        if let id = mouse.topic {
            guard model.editingID != id else { return }
            if !mouse.started {
                guard distance >= 4, let frame = model.placements[id]?.frame else { return }
                mouse.started = true
                let rect = model.screenRect(frame)
                model.beginDrag(id, grab: CGSize(width: mouse.start.x - rect.midX, height: mouse.start.y - rect.midY))
            }
            model.updateDrag(to: point)
        } else {
            if !mouse.started {
                guard distance >= 3 else { return }
                mouse.started = true
                model.beginMarquee(extend: event.modifierFlags.contains(.shift))
            }
            model.updateMarquee(CGRect(x: min(mouse.start.x, point.x), y: min(mouse.start.y, point.y),
                                       width: abs(point.x - mouse.start.x), height: abs(point.y - mouse.start.y)))
        }
        self.mouse = mouse
        applyDragFeedback()
    }

    override func mouseUp(with event: NSEvent) {
        guard let mouse else { return }
        self.mouse = nil
        if mouse.topic != nil {
            if mouse.started { model.endDrag() }
        } else if mouse.started {
            model.endMarquee()
        } else {
            model.deselect()
            model.takeKeyboard()
        }
    }

    override func scrollWheel(with event: NSEvent) {
        // Embedded, the board scrolls the map with its card.
        guard !embedded else { return super.scrollWheel(with: event) }
        let point = canvasPoint(event)
        pointer = point
        let precise = event.hasPreciseScrollingDeltas
        if event.modifierFlags.contains(.command) {
            model.zoom(by: exp(event.scrollingDeltaY * (precise ? 0.01 : 0.1)), around: point)
        } else {
            model.pan(by: CGSize(width: event.scrollingDeltaX * (precise ? 1 : 8),
                                 height: event.scrollingDeltaY * (precise ? 1 : 8)))
        }
        applyCamera()
    }

    override func magnify(with event: NSEvent) {
        guard !embedded else { return super.magnify(with: event) }
        model.zoom(by: 1 + event.magnification, around: canvasPoint(event))
        applyCamera()
    }

    // MARK: - Keyboard

    override func becomeFirstResponder() -> Bool {
        model.hasKeyboard = true
        return true
    }

    override func resignFirstResponder() -> Bool {
        model.hasKeyboard = false
        return true
    }

    /// The map takes the keyboard on its next turn (`MindmapTabModel.requestKeyboard`); a topic being edited keeps it.
    private func takeKeyboardSoon() {
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window, window.firstResponder !== self, self.model.editingID == nil,
                  self.acceptsFirstResponder else { return }
            window.makeFirstResponder(self)
        }
    }

    override func keyDown(with event: NSEvent) {
        if !handle(event) { super.keyDown(with: event) }
    }

    override func keyUp(with event: NSEvent) {
        if !handle(event) { super.keyUp(with: event) }
    }

    private func handle(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown, let key = MindmapKey(event) else { return false }
        return model.handleKey(key, modifiers: event.modifierFlags, isRepeat: event.isARepeat)
    }

    /// Command keys of the map (⌘+ ⌘- ⌘↩, and ⌘. ⌘0 when a keyboard layout keeps them from the commands) while it
    /// has the keyboard; the Edit menu keeps the others.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self, event.type == .keyDown,
              event.modifierFlags.contains(.command) else { return super.performKeyEquivalent(with: event) }
        let key = event.charactersIgnoringModifiers ?? ""
        guard [".", "0", "à", "=", "+", "-", "\r"].contains(key) else { return super.performKeyEquivalent(with: event) }
        return handle(event)
    }

    @objc func copy(_ sender: Any?) {
        guard let text = model.copySelection() else { return }
        put(text)
    }

    @objc func cut(_ sender: Any?) {
        guard let text = model.cutSelection() else { return }
        put(text)
    }

    @objc func paste(_ sender: Any?) {
        guard let text = NSPasteboard.general.string(forType: .string) else { return }
        model.paste(text)
    }

    override func selectAll(_ sender: Any?) {
        model.selectAll()
    }

    private func put(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    // MARK: - Accessibility

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .group }
    override func accessibilityLabel() -> String? { "Mindmap of \(model.title)" }

    override func accessibilityChildren() -> [Any]? {
        guard !showsPicture else { return [] }
        return scene.map { item in
            let element = MindmapTopicElement(model: model, id: item.id)
            element.setAccessibilityParent(self)
            element.setAccessibilityRole(.button)
            element.setAccessibilityLabel(item.text.isEmpty ? "Empty topic" : item.text)
            element.setAccessibilitySelected(model.selection.contains(item.id))
            var rect = model.screenRect(item.placement.frame)
            rect.origin.y += topInset
            if let window {
                element.setAccessibilityFrame(window.convertToScreen(convert(rect, to: nil)))
            }
            return element
        }
    }
}

/// What a topic shows besides its text, as the model has it: the views follow it as one value.
private struct StateKey: Equatable {
    let selection: Set<String>
    let editing: String?
    let folded: Set<String>
    let dragging: [String]

    @MainActor init(_ model: MindmapTabModel) {
        selection = model.selection
        editing = model.editingID
        folded = model.folded
        dragging = model.dragging
    }
}

private struct DragKey: Equatable {
    let location: CGPoint?
    let target: MindmapDropTarget?
    let marquee: CGRect?

    @MainActor init(_ model: MindmapTabModel) {
        location = model.dragLocation
        target = model.dropTarget
        marquee = model.marquee
    }
}

private struct ChromeKey: Equatable {
    let missing: Bool
    let editable: Bool
    let shortcuts: Bool

    @MainActor init(_ model: MindmapTabModel) {
        missing = model.root == nil
        editable = model.isEditable
        shortcuts = model.showsShortcuts
    }
}

/// A topic for VoiceOver: pressing it selects it.
private final class MindmapTopicElement: NSAccessibilityElement {
    weak var model: MindmapTabModel?
    let id: String

    init(model: MindmapTabModel, id: String) {
        self.model = model
        self.id = id
        super.init()
    }

    override func accessibilityPerformPress() -> Bool {
        let id = id
        nonisolated(unsafe) let model = model
        MainActor.assumeIsolated { model?.select(id) }
        return true
    }
}

private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

// MARK: - Layers

/// One shade of one colour and width of the edges: each edge is cut in `shades` pieces that get stronger toward its
/// topic, so the branch's colour gathers there (one shape layer per style, a handful for a whole map).
struct MindmapEdgeStyle: Hashable {
    static let shades = 4
    let branch: Int
    /// 0 for main branches, 1 for their children, 2 below.
    let width: Int
    let shade: Int
    /// Under a dragged topic.
    let faded: Bool

    var lineWidth: CGFloat { [3, 2, 1.5][width] }
    var alpha: CGFloat {
        (0.35 + 0.65 * (CGFloat(shade) + 0.5) / CGFloat(Self.shades)) * (faded ? 0.25 : 1)
    }
}

/// One topic: its body (a bitmap), the hover tint under the text of a deep topic, the selection ring and the fold
/// toggle, in the topic's own coordinates (world points).
final class MindmapTopicLayer: CALayer {
    var item: MindmapSceneTopic
    private(set) var look: MindmapTopicLook?
    private let body = CALayer()
    private var tint: CAShapeLayer?
    private var ring: CAShapeLayer?
    private var toggle: CALayer?
    private var toggleKey: String?
    /// Where the fold toggle is, in world points, when it shows.
    private(set) var foldFrame: CGRect?
    private var ringShown: Bool?

    init(item: MindmapSceneTopic) {
        self.item = item
        super.init()
        body.minificationFilter = .trilinear
        addSublayer(body)
    }

    override init(layer: Any) {
        let other = layer as! MindmapTopicLayer
        item = other.item
        super.init(layer: layer)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func action(forKey event: String) -> (any CAAction)? { NSNull() }

    func setBody(_ image: CGImage, look: MindmapTopicLook) {
        self.look = look
        body.contents = image
        let margin = look.margin
        body.frame = CGRect(x: -margin, y: -margin, width: look.size.width + margin * 2, height: look.size.height + margin * 2)
    }

    override func layoutSublayers() {
        super.layoutSublayers()
        if let look {
            let margin = look.margin
            body.frame = CGRect(x: -margin, y: -margin, width: bounds.width + margin * 2, height: bounds.height + margin * 2)
        }
    }

    func update(selected: Bool, editing: Bool, hovered: Bool, folded: Bool, dragged: Bool, palette: MindmapPalette) {
        let placement = item.placement
        let depth = placement.depth
        let size = bounds.size
        opacity = dragged ? 0.3 : 1
        zPosition = editing ? 2 : selected ? 1 : 0
        let color = palette.color(branch: placement.branch)

        // The tint under a deep topic's text: the page while editing, a hint of ink on hover.
        if depth >= 2 {
            let fill: CGColor? = editing ? palette.background : hovered ? palette.text.copy(alpha: 0.05) : nil
            if fill != nil || tint != nil {
                let tint = self.tint ?? {
                    let layer = CAShapeLayer()
                    insertSublayer(layer, below: body)
                    self.tint = layer
                    return layer
                }()
                tint.path = UnevenRoundedRectangle(topLeadingRadius: 5, topTrailingRadius: 5, style: .continuous)
                    .path(in: CGRect(origin: .zero, size: size)).cgPath
                tint.fillColor = fill
            }
        }

        // The selection ring: the accent round the topic, faint on hover.
        let radius: CGFloat = depth == 0 ? 15 : depth == 1 ? 10 : 6
        let ringOpacity: Float = selected || editing ? 1 : hovered && depth > 0 ? 0.3 : 0
        if ringOpacity > 0 || ring != nil {
            let ring = self.ring ?? {
                let layer = CAShapeLayer()
                layer.fillColor = nil
                layer.lineWidth = 2
                layer.opacity = 0
                addSublayer(layer)
                self.ring = layer
                return layer
            }()
            let rect = CGRect(origin: .zero, size: size).insetBy(dx: -5, dy: -5)
            ring.bounds = CGRect(origin: .zero, size: rect.size)
            ring.position = CGPoint(x: size.width / 2, y: size.height / 2)
            ring.path = Path(roundedRect: CGRect(origin: .zero, size: rect.size).insetBy(dx: 1, dy: 1),
                             cornerRadius: Corners.r(radius + 5) - 1, style: .continuous).cgPath
            ring.strokeColor = palette.accent
            let shown = selected || editing
            if ring.opacity != ringOpacity || ringShown != shown {
                let fromOpacity = ring.presentation()?.opacity ?? ring.opacity
                let fromScale = (ring.presentation()?.value(forKeyPath: "transform.scale") as? CGFloat) ?? (shown ? 0.97 : 1)
                ring.opacity = ringOpacity
                ring.setAffineTransform(shown ? .identity : CGAffineTransform(scaleX: 0.97, y: 0.97))
                if !Motion.reduceMotion {
                    let fade = CABasicAnimation(keyPath: "opacity")
                    fade.fromValue = fromOpacity
                    let grow = CABasicAnimation(keyPath: "transform.scale")
                    grow.fromValue = fromScale
                    let group = CAAnimationGroup()
                    group.animations = [fade, grow]
                    group.duration = 0.12
                    group.timingFunction = CAMediaTimingFunction(name: .easeOut)
                    ring.add(group, forKey: "hover")
                }
                ringShown = shown
            }
        }

        // The fold toggle on the outer side: the hidden count of a folded branch, or a bar to fold it.
        let showsToggle = depth > 0 && item.childCount > 0 && (folded || hovered || selected)
        guard showsToggle else {
            toggle?.isHidden = true
            foldFrame = nil
            return
        }
        let key = "\(folded)|\(item.descendantCount)|\(placement.branch)|\(MindmapTopicArt.shared.index(of: palette))"
        let toggle = self.toggle ?? {
            let layer = CALayer()
            addSublayer(layer)
            self.toggle = layer
            return layer
        }()
        toggle.isHidden = false
        if key != toggleKey {
            toggleKey = key
            let scale = max(look?.scale ?? 2, 2)
            let image: MindmapBadges.Image
            if folded {
                image = MindmapBadges.capsule(
                    text: "\(item.descendantCount)", font: .monospacedDigitSystemFont(ofSize: 10, weight: .semibold),
                    fill: color, stroke: color, textColor: CGColor(gray: 1, alpha: 1), scale: scale
                )
            } else {
                image = MindmapBadges.foldBar(fill: palette.background, stroke: color, bar: palette.secondaryText, scale: scale)
            }
            toggle.contents = image.image
            toggle.bounds = CGRect(origin: .zero, size: image.size)
        }
        let width = toggle.bounds.width
        let x = placement.direction == 1 ? size.width - width / 2 + 16 : width / 2 - 16
        let y = size.height / 2 + (depth >= 2 ? size.height / 2 - 1 : 0)
        toggle.position = CGPoint(x: x, y: y)
        foldFrame = CGRect(x: placement.frame.minX + x - width / 2, y: placement.frame.minY + y - toggle.bounds.height / 2,
                           width: width, height: toggle.bounds.height)
    }
}

/// The small capsules of the map: a folded branch's count, the fold bar, the number of topics dragged.
enum MindmapBadges {
    struct Image {
        let image: CGImage?
        let size: CGSize
    }

    static func capsule(text: String, font: NSFont, fill: CGColor, stroke: CGColor?, textColor: CGColor,
                        scale: CGFloat) -> Image {
        let string = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: NSColor(cgColor: textColor) ?? .white])
        let textSize = string.size()
        let size = CGSize(width: max(18, ceil(textSize.width) + 10), height: 18)
        return draw(size, scale: scale) { context in
            let rect = CGRect(origin: .zero, size: size)
            context.addPath(CGPath(roundedRect: rect, cornerWidth: 9, cornerHeight: 9, transform: nil))
            context.setFillColor(fill)
            context.fillPath()
            if let stroke {
                context.addPath(CGPath(roundedRect: rect.insetBy(dx: 0.75, dy: 0.75), cornerWidth: 8.25, cornerHeight: 8.25,
                                       transform: nil))
                context.setStrokeColor(stroke)
                context.setLineWidth(1.5)
                context.strokePath()
            }
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
            string.draw(at: CGPoint(x: (size.width - textSize.width) / 2, y: (size.height - textSize.height) / 2))
            NSGraphicsContext.restoreGraphicsState()
        }
    }

    static func foldBar(fill: CGColor, stroke: CGColor, bar: CGColor, scale: CGFloat) -> Image {
        let size = CGSize(width: 18, height: 18)
        return draw(size, scale: scale) { context in
            let rect = CGRect(origin: .zero, size: size)
            context.addEllipse(in: rect)
            context.setFillColor(fill)
            context.fillPath()
            context.addEllipse(in: rect.insetBy(dx: 0.75, dy: 0.75))
            context.setStrokeColor(stroke)
            context.setLineWidth(1.5)
            context.strokePath()
            context.addPath(CGPath(roundedRect: CGRect(x: 5.5, y: 8.25, width: 7, height: 1.5), cornerWidth: 0.75,
                                   cornerHeight: 0.75, transform: nil))
            context.setFillColor(bar)
            context.fillPath()
        }
    }

    private static func draw(_ size: CGSize, scale: CGFloat, _ body: (CGContext) -> Void) -> Image {
        let width = Int(ceil(size.width * scale)), height = Int(ceil(size.height * scale))
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.displayP3)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return Image(image: nil, size: size) }
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: scale, y: -scale)
        body(context)
        return Image(image: context.makeImage(), size: size)
    }
}

/// The dot grid, moving and scaling with the camera: one dot repeated along a row, the row repeated down, by the
/// render server.
final class MindmapGridLayer: CALayer {
    private let rows = CAReplicatorLayer()
    private let columns = CAReplicatorLayer()
    private let dot = CALayer()

    var color: CGColor? {
        didSet { dot.backgroundColor = color }
    }

    override init() {
        super.init()
        anchorPoint = .zero
        columns.addSublayer(dot)
        rows.addSublayer(columns)
        addSublayer(rows)
    }

    override init(layer: Any) { super.init(layer: layer) }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func action(forKey event: String) -> (any CAAction)? { NSNull() }

    /// World (0, 0) at `offset` in the view, at `scale`: a dot every 22 points of the world, never closer than 12
    /// points on screen.
    func update(offset: CGSize, scale: CGFloat, size: CGSize) {
        guard color != nil, scale > 0 else { return }
        var step = 22 * scale
        while step < 12 { step *= 2 }
        let radius = max(0.7, min(1.2, scale))
        let startX = offset.width.truncatingRemainder(dividingBy: step) - step
        let startY = offset.height.truncatingRemainder(dividingBy: step) - step
        dot.frame = CGRect(x: startX - radius, y: startY - radius, width: radius * 2, height: radius * 2)
        dot.cornerRadius = radius
        columns.instanceCount = Int(size.width / step) + 3
        columns.instanceTransform = CATransform3DMakeTranslation(step, 0, 0)
        rows.instanceCount = Int(size.height / step) + 3
        rows.instanceTransform = CATransform3DMakeTranslation(0, step, 0)
    }
}
