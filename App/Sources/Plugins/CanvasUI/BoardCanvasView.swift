import AppKit
import CanvasPlugin
import PluginKitUI
import QuartzCore
import SwiftUI

/// What the board view shows of its model, followed as it changes (`Follow`).
struct BoardViewState: Equatable {
    var document: CanvasDocument
    var selection: Set<String>
    var selectedEdge: String?
    var hovered: String?
    var hoverPoint: CGPoint?
    var dragged: Set<String>
    var dragDelta: CGSize
    var resizing: CanvasRect?
    var resizingID: String?
    var editing: BoardEditing.Target?
    /// Free text being written grows with what is typed.
    var editedFrame: CanvasRect?
    var link: PendingLink?
    var lineEnd: LineEndDrag?
    var justAdded: Set<String>
    var births: Set<String>
    var activeEmbed: String?
    var previewVersion: Int
    var linksVersion: Int
    var presentation: BoardPresentation?
    var slideChange: UUID?
    var tool: BoardTool
    var loadError: String?
    var dropTargeted: Bool
    var showsMinimap: Bool
    var isNavigating: Bool
    var marquee: CGRect?
    var liveStroke: [CanvasPoint]
    var focusRequest: Int
    var showsChrome: Bool

    @MainActor init(_ model: BoardModel) {
        document = model.document
        selection = model.selection
        selectedEdge = model.selectedEdge
        hovered = model.hovered
        hoverPoint = model.hovered == nil ? nil : model.hoverPoint
        dragged = model.dragged
        dragDelta = model.dragDelta
        resizing = model.resizing?.frame
        resizingID = model.resizing?.id
        editing = model.editing?.target
        if case .node(let id) = model.editing?.target, let node = model.node(id), node.isFreeText {
            editedFrame = model.frame(of: node)
        }
        link = model.link
        lineEnd = model.lineEnd
        justAdded = model.justAdded
        births = Set(model.edgeBirths.keys)
        activeEmbed = model.activeEmbed
        previewVersion = model.store.previewVersion
        linksVersion = model.store.links.version
        presentation = model.presentation
        slideChange = model.slideChange?.id
        tool = model.tool
        loadError = model.loadError
        dropTargeted = model.dropTargeted
        showsMinimap = model.showsMinimap
        isNavigating = model.isNavigating
        marquee = model.marquee
        liveStroke = model.liveStroke
        focusRequest = model.focusRequest
        showsChrome = model.view.presentation == .page || model.view.isActive
    }
}

/// What the camera shows, followed as it moves.
struct BoardCameraState: Equatable {
    var offset: CGSize
    var scale: CGFloat
    var shift: CGFloat
}

/// A board in AppKit (`ViewType.makeNSView`): the dotted infinite canvas, groups under the arrows under the cards.
/// Every item is a layer in board units under one world layer whose transform is the camera, so a pan or a zoom sets
/// one transform and the dot grid's position: nothing is laid out or drawn again. Items are drawn into bitmaps off
/// the main thread (`BoardRenderer`), again when the zoom rests at a new level. Live views (a mindmap, a PDF, a
/// video) are views over their cards, made only for the few near the middle of the screen. The chrome round the
/// board (tools, selection bar, empty state) is SwiftUI in hosting views of its own; the zoom controls are AppKit.
///
/// Clicks, drags, keys, scrolling and drops are the view's own (`BoardCanvasView+Input`): it finds the handle,
/// card, arrow or group under the pointer itself, so cards need no views.
final class BoardCanvasView: NSView, NativeHostedView {
    let model: BoardModel
    private(set) var theme: ThemeTokens?
    private(set) var palette: BoardPalette?

    // The layers, bottom to top.
    let grid = CanvasDotGridLayer()
    let world = QuietLayer()
    let groupsLayer = QuietLayer()
    let edges = BoardEdgesLayer()
    let cardsLayer = QuietLayer()
    let strokeLayer = QuietShapeLayer()
    let chrome = QuietLayer()
    let marqueeLayer = QuietShapeLayer()
    let dropRing = QuietShapeLayer()
    let cutout = QuietShapeLayer()
    let leavingSlide = QuietLayer()

    var items: [String: BoardItemLayer] = [:]
    var groupLayers: [String: BoardGroupLayer] = [:]
    /// The live views over their cards.
    let embedsView = BoardPassthroughView()
    lazy var embeds = BoardEmbeds(board: self)
    /// The editor of what is being written, over the board.
    var editor: BoardEditorHost?

    // The chrome.
    var toolbarHost: BoardToolsView?
    var inkBarHost: NSHostingView<AnyView>?
    var zoomControls: CanvasZoomControlsView?
    var minimapButton: NSButton?
    var minimap: BoardMinimapView?
    var selectionBar: NSHostingView<AnyView>?
    var selectionBarShown = false
    var selectionBarSize: CGSize = .zero
    /// The SwiftUI views of the chrome's hosting views, given the theme again when it changes.
    var chromeViews: [ObjectIdentifier: AnyView] = [:]
    var emptyHost: NSHostingView<AnyView>?
    var bannerHost: NSHostingView<AnyView>?
    var presentBar: NSHostingView<AnyView>?

    var state: BoardViewState?
    var cameraState: BoardCameraState?
    private var stateFollow: Follow<BoardViewState>?
    private var cameraFollow: Follow<BoardCameraState>?
    private var saveCameraTask: Task<Void, Never>?
    /// The handles shown, in view points (`BoardHandles`): drawn and clicked.
    var handles: [BoardHandle] = []
    var handleLayers: [String: CALayer] = [:]
    var hoveredHandle: String?
    /// What the pointer does now that it is down.
    var gesture: BoardGesture?
    var spaceDown = false
    var tracking: NSTrackingArea?
    /// The scale the items' strokes are sized for, and the last zoom the board was laid out at.
    var renderedScale: CGFloat = 0
    var laidOutScale: CGFloat = 0
    var rendering = false
    var renderAgain = false
    var shadowed = false
    var lastSize: CGSize = .zero
    /// The items whose ring or outline is shown: sized again when the zoom changes.
    var decorated: Set<String> = []
    /// What moved at the last step of a gesture: put back at its place when let go.
    var movedLastTime: Set<String> = []

    init(model: BoardModel) {
        self.model = model
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        guard let root = layer else { return }
        root.masksToBounds = true
        grid.zPosition = -1
        root.addSublayer(grid)
        // The camera's transform is applied round the world's top-left corner, the view's origin.
        world.anchorPoint = .zero
        world.addSublayer(groupsLayer)
        world.addSublayer(edges)
        world.addSublayer(cardsLayer)
        strokeLayer.fillColor = nil
        strokeLayer.lineCap = .round
        strokeLayer.lineJoin = .round
        world.addSublayer(strokeLayer)
        root.addSublayer(world)
        root.addSublayer(chrome)
        marqueeLayer.lineWidth = 1
        root.addSublayer(marqueeLayer)
        cutout.fillRule = .evenOdd
        cutout.isHidden = true
        root.addSublayer(cutout)
        leavingSlide.isHidden = true
        leavingSlide.masksToBounds = true
        root.addSublayer(leavingSlide)
        dropRing.lineWidth = 3
        dropRing.lineDashPattern = [10, 8]
        dropRing.opacity = 0
        root.addSublayer(dropRing)
        addSubview(embedsView)
        registerForDraggedTypes(BoardModel.dropTypes)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Board \(model.title)")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    /// The click that brings the window back from another app acts at once, as in Craft: a drag on a handle resizes
    /// on the first try, not only once the window is key.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// A board as a page of the shell: its toolbar title and its inspector.
    static func page(store: BoardStore, view: ViewContext) -> BoardCanvasView {
        let model = store.model(for: view)
        if view.presentation == .page { view.toolbarTitle = ToolbarTitle(title: model.title) }
        view.setInspector(viewType: CanvasUIPlugin.viewTypeID, tabs: [
            InspectorTab(id: "canvas.board", title: "Board") { AnyView(BoardInspector(model: model)) },
        ])
        return BoardCanvasView(model: model)
    }

    func hostEnvironmentChanged(_ environment: NativeViewEnvironment) {
        guard environment.theme != theme else { return }
        theme = environment.theme
        themeChanged()
        if stateFollow == nil { startFollowing() }
    }

    /// A board takes the room it is given; asked for its ideal size (nothing proposed), 640 by 480.
    func fittingSize(width: CGFloat, maxHeight: CGFloat?) -> CGSize? {
        CGSize(width: width > 0 ? width : 640, height: maxHeight ?? 480)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        themeChanged()
    }

    private func themeChanged() {
        guard let theme else { return }
        let palette = BoardPalette(theme: theme, appearance: effectiveAppearance)
        guard palette != self.palette else { return }
        self.palette = palette
        layer?.backgroundColor = palette.floor.cgColor
        cutout.fillColor = palette.background.cgColor
        marqueeLayer.fillColor = palette.accent.withAlphaComponent(0.08).cgColor
        marqueeLayer.strokeColor = palette.accent.withAlphaComponent(0.6).cgColor
        dropRing.strokeColor = palette.accent.withAlphaComponent(0.8).cgColor
        dropRing.fillColor = palette.accent.withAlphaComponent(0.05).cgColor
        zoomControls?.theme = theme
        updateMinimapButton()
        toolbarHost?.palette = palette
        for host in [inkBarHost, selectionBar, emptyHost, bannerHost, presentBar].compactMap({ $0 }) {
            if let base = chromeViews[ObjectIdentifier(host)] { host.rootView = themed(base) }
        }
        minimap?.palette = palette
        embeds.themeChanged(theme)
        if let state {
            apply(state, previous: nil)
            applyCamera(force: true)
        }
    }

    private func startFollowing() {
        stateFollow = Follow({ [model] in BoardViewState(model) }) { [weak self] state in
            guard let self else { return }
            let previous = self.state
            self.state = state
            self.apply(state, previous: previous)
        }
        cameraFollow = Follow({ [model] in
            BoardCameraState(offset: model.camera.offset, scale: model.camera.scale, shift: model.presentShift)
        }) { [weak self] camera in
            // Already shown by the event that moved it (`showCameraNow`).
            guard let self, camera != self.cameraState else { return }
            let first = self.cameraState == nil
            self.cameraState = camera
            self.applyCamera(force: first)
            if !first { self.cameraChanged() }
        }
    }

    // MARK: Window

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let window {
            model.undoManager = window.undoManager
            model.requestKeyboard()
            updateTracking()
        } else {
            model.commitEditing()
            model.flush()
            model.saveCamera()
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        updateTracking()
    }

    private func updateTracking() {
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect,
                                                         .cursorUpdate], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        grid.frame = bounds
        chrome.frame = bounds
        marqueeLayer.frame = bounds
        cutout.frame = bounds
        dropRing.frame = bounds
        dropRing.path = CGPath(roundedRect: bounds.insetBy(dx: 9.5, dy: 9.5), cornerWidth: Corners.r(18), cornerHeight: Corners.r(18), transform: nil)
        CATransaction.commit()
        embedsView.frame = bounds
        if bounds.size != lastSize, bounds.width > 0, bounds.height > 0 {
            lastSize = bounds.size
            model.viewResized(bounds.size)
            applyCamera(force: true)
            embeds.update()
        }
        layoutChrome()
    }

    // MARK: Following the model

    func themed(_ view: AnyView) -> AnyView {
        guard let theme else { return view }
        return AnyView(view.environment(\.themeTokens, theme).tint(theme.accent))
    }


    func apply(_ state: BoardViewState, previous: BoardViewState?) {
        guard let palette else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        let changed = { (read: (BoardViewState) -> AnyHashable) in previous.map { read($0) != read(state) } ?? true }
        let content = previous == nil || previous!.document != state.document || changed { $0.previewVersion }
            || changed { $0.linksVersion } || changed { AnyHashable($0.editing.map { "\($0)" }) }
            || changed { $0.activeEmbed } || changed { $0.editedFrame.map { "\($0)" } }
        let moving = changed { $0.dragged } || changed { $0.dragDelta.width } || changed { $0.dragDelta.height }
            || changed { $0.resizing.map { "\($0)" } } || changed { $0.lineEnd.map { "\($0.point)" } }
        if content { reconcileItems() } else if moving { moveItems() }
        if content || changed({ $0.selectedEdge }) || changed({ $0.births }) || changed({ AnyHashable($0.editing.map { "\($0)" }) })
            || changed({ $0.link?.reconnect?.edge }) || changed({ $0.dragged.isEmpty }) {
            edges.rebuild(model, palette: palette, scale: model.camera.scale, backing: backing)
        } else if moving || changed({ $0.link.map { "\($0.point)" } }) {
            edges.updateMoving(model, palette: palette, backing: backing)
        }
        if content || moving || changed({ $0.selection }) || changed({ $0.hovered }) || changed({ $0.hoverPoint.map { "\($0)" } })
            || changed({ $0.link?.target }) || changed({ $0.marquee == nil }) || changed({ $0.presentation == nil }) {
            decorateItems()
        }
        updateMarquee(state.marquee)
        updateStroke(state)
        updateHandles()
        if previous?.dropTargeted != state.dropTargeted { BoardSprings.fade(dropRing, to: state.dropTargeted ? 1 : 0) }
        if changed({ $0.tool }) || changed({ $0.showsChrome }) || changed({ $0.showsMinimap }) || changed({ $0.presentation == nil })
            || changed({ $0.loadError }) || changed({ $0.document.nodes.isEmpty }) || previous == nil {
            updateChrome(state)
        }
        updateSelectionBar(state)
        if changed({ $0.presentation.map { "\($0)" } }) || changed({ $0.slideChange }) { updatePresentation(state, previous: previous) }
        if changed({ $0.focusRequest }) { takeKeyboard() }
        if changed({ AnyHashable($0.editing.map { "\($0)" }) }) { updateEditor() } else { editor?.refresh() }
        if previous?.isNavigating == true, !state.isNavigating { cameraRested() }
        embeds.update()
        minimap?.update()
        if changed({ $0.tool }) { window?.invalidateCursorRects(for: self) }
    }

    var backing: CGFloat { window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2 }

    /// The display's colour space: a bitmap in another one is converted pixel by pixel when its layer is committed.
    var drawingSpace: CGColorSpace {
        guard let space = (window?.screen ?? NSScreen.main)?.colorSpace?.cgColorSpace, space.model == .rgb else {
            return CGColorSpace(name: CGColorSpace.sRGB)!
        }
        return space
    }

    func takeKeyboard() {
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window, window.firstResponder !== self, self.model.editing == nil,
                  self.model.activeEmbed == nil else { return }
            window.makeFirstResponder(self)
        }
    }

    // MARK: Camera

    /// Shows the camera: one transform for the world, the grid's place, the chrome in view points.
    func applyCamera(force: Bool = false) {
        guard let palette else { return }
        let camera = model.camera
        let scale = camera.scale, offset = camera.offset
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        var transform = CATransform3DMakeScale(scale, scale, 1)
        transform = CATransform3DConcat(transform, CATransform3DMakeTranslation(offset.width + model.presentShift, offset.height, 0))
        world.sublayerTransform = transform
        world.bounds = bounds
        world.position = .zero
        grid.update(offset: CGSize(width: offset.width + model.presentShift, height: offset.height), scale: scale,
                    color: palette.secondary)
        if force || abs(scale - laidOutScale) > 0.0001 {
            let crossed = (laidOutScale >= BoardModel.glassScale) != (scale >= BoardModel.glassScale)
            laidOutScale = scale
            edges.setScale(scale)
            rescaleDecorations(scale)
            if force || crossed { updateShadows() }
        }
        CATransaction.commit()
        updateHandles()
        if let selectionBar, selectionBarShown { placeSelectionBar(selectionBar) }
        positionPresentation()
        editor?.place()
        embeds.place()
        minimap?.update()
        // An item coming into view, or one drawn far too small for this zoom, is drawn now; the rest when it rests.
        renderItems(settled: false)
    }

    func cameraChanged() {
        model.cameraMoved()
        saveCameraTask?.cancel()
        saveCameraTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            if !Task.isCancelled { self?.model.saveCamera() }
        }
    }

    /// The camera came to rest: the items are drawn for this zoom, the live views placed for it.
    private func cameraRested() {
        renderItems(settled: true)
        relabelGroups()
        updateShadows()
        embeds.update()
    }
}

/// A view that takes only the clicks its subviews take: the live views' layer of the board.
final class BoardPassthroughView: NSView {
    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
    }
}
