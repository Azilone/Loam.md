import AppKit
import CanvasPlugin
import PluginKitUI
import SwiftUI

/// A handle round what is selected or hovered, in view points: a square on a corner or a strip along a side to resize,
/// a dot outside a side to draw an arrow from, an arrow's or a line's end to move, a table's bars to add a row or a
/// column.
struct BoardHandle {
    enum Kind {
        case corner(CanvasHandle)
        case strip(CanvasHandle)
        case link(CanvasSide)
        case addRow, addColumn
        case edgeEnd(movesStart: Bool)
        case lineEnd(movesStart: Bool)

        var isLink: Bool {
            if case .link = self { return true }
            return false
        }
    }

    let id: String
    /// The card, group or arrow it belongs to.
    let owner: String
    let kind: Kind
    /// What is drawn (nil for a strip, which is only a place to grab) and what takes the click.
    let visual: CGRect?
    let hit: CGRect

    var cursor: NSCursor? {
        let handle: CanvasHandle
        switch kind {
        case .corner(let side), .strip(let side): handle = side
        default: return nil
        }
        let position: NSCursor.FrameResizePosition = switch handle {
        case .topLeft: .topLeft
        case .top: .top
        case .topRight: .topRight
        case .right: .right
        case .bottomRight: .bottomRight
        case .bottom: .bottom
        case .bottomLeft: .bottomLeft
        case .left: .left
        }
        return NSCursor.frameResize(position: position, directions: .all)
    }
}

extension BoardCanvasView {
    // MARK: Handles

    /// The handles to show now, as `BoardCardView`, `BoardEdgeHandles` and `BoardLineHandles` showed them.
    func currentHandles() -> [BoardHandle] {
        guard model.presentation == nil, model.isEditable, model.marquee == nil else { return [] }
        let camera = model.camera
        var result: [BoardHandle] = []
        let single = model.selection.count == 1 ? model.selection.first : nil
        let linking = model.link?.reconnect == nil ? model.link?.from : nil
        if model.dragged.isEmpty {
            var owners = model.selection
            if let hovered = model.hovered { owners.insert(hovered) }
            if let linking { owners.insert(linking) }
            for id in owners.sorted() {
                guard let node = model.node(id) else { continue }
                let screen = camera.screenRect(CGRect(model.frame(of: node)))
                if node.kind == .group {
                    if single == id { result += resizeHandles(node, screen, cornersOnly: false) }
                    continue
                }
                if node.isDrawing {
                    if single == id, node.drawing?.kind != .line { result += resizeHandles(node, screen, cornersOnly: false) }
                    continue
                }
                guard model.editing?.target != .node(id) else { continue }
                if single == id {
                    result += resizeHandles(node, screen, cornersOnly: node.sizesToText)
                    if node.isTable {
                        result.append(BoardHandle(id: id + ".row", owner: id, kind: .addRow,
                                                  visual: CGRect(x: screen.minX + 14, y: screen.maxY + 8, width: max(0, screen.width - 28), height: 18),
                                                  hit: CGRect(x: screen.minX + 14, y: screen.maxY + 8, width: max(0, screen.width - 28), height: 18)))
                        result.append(BoardHandle(id: id + ".column", owner: id, kind: .addColumn,
                                                  visual: CGRect(x: screen.maxX + 8, y: screen.minY + 14, width: 18, height: max(0, screen.height - 28)),
                                                  hit: CGRect(x: screen.maxX + 8, y: screen.minY + 14, width: 18, height: max(0, screen.height - 28))))
                    }
                }
                if single == id || model.hovered == id || linking == id {
                    for side in CanvasSide.allCases {
                        let outside: CGFloat = node.isTable && single == id && (side == .right || side == .bottom) ? 46 : 24
                        let center: CGPoint = switch side {
                        case .top: CGPoint(x: screen.midX, y: screen.minY - outside)
                        case .right: CGPoint(x: screen.maxX + outside, y: screen.midY)
                        case .bottom: CGPoint(x: screen.midX, y: screen.maxY + outside)
                        case .left: CGPoint(x: screen.minX - outside, y: screen.midY)
                        }
                        let size = BoardStyle.handleSize - 1
                        result.append(BoardHandle(id: id + ".link.\(side)", owner: id, kind: .link(side),
                                                  visual: CGRect(x: center.x - size / 2, y: center.y - size / 2, width: size, height: size),
                                                  hit: CGRect(x: center.x - size / 2 - 7, y: center.y - size / 2 - 7, width: size + 14, height: size + 14)))
                    }
                }
            }
        }
        // The ends of the selected arrow, to drag onto another card.
        if let edge = model.selectedEdgeValue, model.link == nil || model.link?.reconnect?.edge == edge.id, model.editing == nil,
           model.link?.reconnect == nil, let curve = model.curve(of: edge) {
            for (point, movesStart) in [(curve.start, true), (curve.end, false)] {
                let center = camera.screenPoint(CGPoint(point))
                let size = BoardStyle.handleSize + 2
                result.append(BoardHandle(id: edge.id + ".end.\(movesStart)", owner: edge.id, kind: .edgeEnd(movesStart: movesStart),
                                          visual: CGRect(x: center.x - size / 2, y: center.y - size / 2, width: size, height: size),
                                          hit: CGRect(x: center.x - size / 2 - 8, y: center.y - size / 2 - 8, width: size + 16, height: size + 16)))
            }
        }
        // The ends of the selected free line.
        if let node = model.selectedLine, let ends = model.lineEnds(of: node), model.editing == nil {
            for (point, movesStart) in [(ends.0, true), (ends.1, false)] {
                let center = camera.screenPoint(CGPoint(point))
                let size = BoardStyle.handleSize + 2
                result.append(BoardHandle(id: node.id + ".line.\(movesStart)", owner: node.id, kind: .lineEnd(movesStart: movesStart),
                                          visual: CGRect(x: center.x - size / 2, y: center.y - size / 2, width: size, height: size),
                                          hit: CGRect(x: center.x - size / 2 - 8, y: center.y - size / 2 - 8, width: size + 16, height: size + 16)))
            }
        }
        return result
    }

    private func resizeHandles(_ node: CanvasNode, _ screen: CGRect, cornersOnly: Bool) -> [BoardHandle] {
        var result: [BoardHandle] = []
        let rect = CanvasRect(screen)
        if !cornersOnly {
            for handle in CanvasHandle.allCases where !handle.isCorner {
                let point = CGPoint(handle.position(in: rect))
                let horizontal = handle == .top || handle == .bottom
                let size = horizontal ? CGSize(width: max(0, screen.width - 34), height: 14) : CGSize(width: 14, height: max(0, screen.height - 34))
                result.append(BoardHandle(id: node.id + ".strip.\(handle)", owner: node.id, kind: .strip(handle), visual: nil,
                                          hit: CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2, width: size.width, height: size.height)))
            }
        }
        for handle in CanvasHandle.allCases where handle.isCorner {
            let point = CGPoint(handle.position(in: rect))
            let size = BoardStyle.handleSize - 1
            result.append(BoardHandle(id: node.id + ".corner.\(handle)", owner: node.id, kind: .corner(handle),
                                      visual: CGRect(x: point.x - size / 2, y: point.y - size / 2, width: size, height: size),
                                      hit: CGRect(x: point.x - size / 2 - 10, y: point.y - size / 2 - 10, width: size + 20, height: size + 20)))
        }
        return result
    }

    /// Shows the handles where they are now: their layers made, moved or let go.
    func updateHandles() {
        guard let palette else { return }
        handles = currentHandles()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        var seen = Set<String>()
        for handle in handles {
            guard let visual = handle.visual else { continue }
            seen.insert(handle.id)
            let layer = handleLayers[handle.id] ?? makeHandleLayer(handle, palette: palette)
            layer.bounds = CGRect(origin: .zero, size: visual.size)
            layer.position = CGPoint(x: visual.midX, y: visual.midY)
            styleHandle(layer, handle, palette: palette)
        }
        for (id, layer) in handleLayers where !seen.contains(id) {
            layer.removeFromSuperlayer()
            handleLayers[id] = nil
        }
        CATransaction.commit()
        if let hoveredHandle, !seen.contains(hoveredHandle) { self.hoveredHandle = nil }
    }

    private func makeHandleLayer(_ handle: BoardHandle, palette: BoardPalette) -> CALayer {
        let layer = QuietLayer()
        layer.shadowColor = NSColor.black.cgColor
        layer.shadowOpacity = 0.18
        layer.shadowRadius = 2
        layer.shadowOffset = CGSize(width: 0, height: 1)
        let glyph = QuietLayer()
        glyph.name = "glyph"
        glyph.contentsGravity = .center
        layer.addSublayer(glyph)
        chrome.addSublayer(layer)
        handleLayers[handle.id] = layer
        if case .link = handle.kind { layer.opacity = 0; BoardSprings.fade(layer, to: 1) }
        return layer
    }

    private func styleHandle(_ layer: CALayer, _ handle: BoardHandle, palette: BoardPalette) {
        let hovered = hoveredHandle == handle.id
        let glyph = layer.sublayers?.first { $0.name == "glyph" }
        glyph?.frame = layer.bounds
        switch handle.kind {
        case .corner:
            // A square, as in Craft and Whimsical: it never reads as the round dot an arrow starts from.
            layer.backgroundColor = NSColor.white.cgColor
            layer.borderColor = palette.accent.cgColor
            layer.borderWidth = 1.75
            layer.cornerRadius = Corners.r(2.5)
        case .link(let side):
            // Filled and round, away from the card: a place to pull an arrow from.
            layer.backgroundColor = palette.accent.withAlphaComponent(hovered ? 1 : 0.85).cgColor
            layer.borderColor = NSColor.white.cgColor
            layer.borderWidth = 1.5
            layer.cornerRadius = layer.bounds.height / 2
            let symbol = switch side {
            case .top: "arrow.up"
            case .right: "arrow.right"
            case .bottom: "arrow.down"
            case .left: "arrow.left"
            }
            glyph?.contents = hovered ? tintedSymbol(symbol, size: 7 / 1.6 * 1.6, weight: .heavy, color: .white) : nil
            glyph?.contentsScale = backing
            let scale: CGFloat = hovered ? 1.6 : 1
            if (layer.value(forKeyPath: "transform.scale") as? CGFloat) != scale {
                let from = layer.presentation()?.value(forKeyPath: "transform.scale") ?? 1
                layer.transform = CATransform3DMakeScale(scale, scale, 1)
                layer.add(BoardSprings.animation("transform.scale", Motion.Spring.lift, from: from, to: scale), forKey: "grow")
            }
        case .edgeEnd(let movesStart), .lineEnd(let movesStart):
            _ = movesStart
            layer.backgroundColor = NSColor.white.cgColor
            layer.borderColor = palette.accent.cgColor
            layer.borderWidth = 2
            layer.cornerRadius = layer.bounds.height / 2
            layer.shadowOpacity = 0.2
        case .addRow, .addColumn:
            layer.shadowOpacity = 0
            layer.cornerRadius = Corners.r(6)
            layer.backgroundColor = (hovered ? palette.accent.withAlphaComponent(0.16) : palette.text.withAlphaComponent(0.06)).cgColor
            glyph?.contents = tintedSymbol("plus", size: 10, weight: .bold, color: hovered ? palette.accent : palette.secondary)
            glyph?.contentsScale = backing
        case .strip:
            break
        }
    }

    func setHoveredHandle(_ id: String?) {
        guard id != hoveredHandle else { return }
        let old = hoveredHandle
        hoveredHandle = id
        guard let palette else { return }
        for changed in [old, id].compactMap({ $0 }) {
            if let layer = handleLayers[changed], let handle = handles.first(where: { $0.id == changed }) {
                styleHandle(layer, handle, palette: palette)
            }
        }
    }

    // MARK: Marquee and strokes

    func updateMarquee(_ rect: CGRect?) {
        marqueeLayer.path = rect.map { CGPath(rect: $0.insetBy(dx: 0.5, dy: 0.5), transform: nil) }
    }

    /// The stroke, line or arrow being drawn, in board units under the world's transform.
    func updateStroke(_ state: BoardViewState) {
        guard let palette, !state.liveStroke.isEmpty, model.tool != .eraser else {
            strokeLayer.path = nil
            return
        }
        let highlights = model.tool == .highlighter
        let width = highlights ? BoardModel.highlighterWidth : model.inkWidth
        let color = (BoardStyle.nsColor(highlights ? model.highlighterColor : model.inkColor) ?? palette.text)
            .withAlphaComponent(highlights ? BoardModel.highlighterOpacity : 1)
        let path = CGMutablePath()
        path.addPath(BoardDrawing.inkPath(state.liveStroke) { CGPoint($0) })
        if model.tool == .arrow, let tip = state.liveStroke.last, state.liveStroke.count > 1 {
            let from = state.liveStroke[state.liveStroke.count - 2]
            let (left, right) = CanvasInk.arrowHead(tip: tip, from: from, size: CanvasInk.headSize(width))
            path.move(to: CGPoint(left))
            path.addLine(to: CGPoint(tip))
            path.addLine(to: CGPoint(right))
        }
        strokeLayer.path = path
        strokeLayer.lineWidth = width
        strokeLayer.strokeColor = color.cgColor
    }

    // MARK: The chrome round the board

    /// The tools, the zoom, the minimap, the empty state and the error banner, made as they are needed.
    func updateChrome(_ state: BoardViewState) {
        guard theme != nil else { return }
        let shows = state.showsChrome && state.presentation == nil
        if zoomControls == nil {
            let zoom = CanvasZoomControlsView(camera: model.camera, fit: { [weak self] in self?.model.fit() })
            let button = zoom.symbolButton("map", "Minimap") { [weak self] in self?.model.toggleMinimap() }
            self.minimapButton = button
            zoom.addExtra(button)
            zoom.theme = theme ?? .standard
            addSubview(zoom)
            zoomControls = zoom
        }
        if toolbarHost == nil, let palette {
            let tools = BoardToolsView(model: model, palette: palette)
            addSubview(tools)
            toolbarHost = tools
            prewarmChrome()
        }
        toolbarHost?.isHidden = !shows
        zoomControls?.isHidden = !shows
        updateMinimapButton()
        let inks = shows && state.tool.draws && state.tool != .hand
        if inks, inkBarHost == nil { inkBarHost = host(AnyView(BoardInkStyleBar(model: model))) }
        if let inkBarHost, inkBarHost.isHidden == inks { show(inkBarHost, inks) }
        let mapped = shows && state.showsMinimap
        if mapped, minimap == nil, let palette {
            let map = BoardMinimapView(model: model, palette: palette)
            addSubview(map)
            minimap = map
        }
        if let minimap, minimap.isHidden == mapped { show(minimap, mapped) }
        let empty = state.document.nodes.isEmpty && model.isEditable
        if empty, emptyHost == nil { emptyHost = host(AnyView(BoardEmptyState(model: model).fixedSize(horizontal: false, vertical: true))) }
        if let emptyHost, emptyHost.isHidden == empty { show(emptyHost, empty) }
        if let error = state.loadError {
            if bannerHost == nil { bannerHost = host(AnyView(BoardBanner(text: error))) }
            if let bannerHost {
                chromeViews[ObjectIdentifier(bannerHost)] = AnyView(BoardBanner(text: error))
                bannerHost.rootView = themed(AnyView(BoardBanner(text: error)))
            }
            bannerHost?.isHidden = false
        } else {
            bannerHost?.isHidden = true
        }
        needsLayout = true
    }

    func updateMinimapButton() {
        guard let minimapButton, let zoomControls, let palette else { return }
        zoomControls.setSymbol(minimapButton, color: model.showsMinimap ? palette.accent : nil)
    }

    /// A hosting view of the board's SwiftUI chrome, with the board's theme.
    func host(_ view: AnyView) -> NSHostingView<AnyView> {
        let host = NSHostingView(rootView: themed(view))
        chromeViews[ObjectIdentifier(host)] = view
        host.sizingOptions = [.intrinsicContentSize]
        host.safeAreaRegions = []
        addSubview(host)
        return host
    }

    /// Shows or hides a piece of chrome with the overlay spring (a fade under Reduce Motion).
    func show(_ view: NSView, _ shown: Bool) {
        view.wantsLayer = true
        guard let layer = view.layer else {
            view.isHidden = !shown
            return
        }
        if shown {
            view.isHidden = false
            layer.opacity = 1
            layer.add(BoardSprings.animation("opacity", Motion.Spring.overlay, from: 0, to: 1), forKey: "show")
        } else {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = Motion.appKitDuration(0.12)
                view.animator().alphaValue = 0
            } completionHandler: { [weak view] in
                MainActor.assumeIsolated {
                    view?.isHidden = true
                    view?.alphaValue = 1
                }
            }
        }
    }

    /// Places the chrome: the tools centred at the bottom, the zoom at the trailing edge (above the tools when the
    /// board is too narrow for both), the ink bar over the tools, the minimap at the bottom left.
    static var toolsSize = CGSize(width: 640, height: 38)

    func layoutChrome() {
        let spacing: CGFloat = 10, margin: CGFloat = 14
        var toolsTop = bounds.maxY
        if let zoomControls {
            // Until the tools come in, the room they took last time.
            let tools = toolbarHost?.intrinsicContentSize ?? Self.toolsSize
            if toolbarHost != nil { Self.toolsSize = tools }
            let zoom = zoomControls.intrinsicContentSize
            let room = bounds.width - margin * 2
            let inline = tools.width + spacing + zoom.width <= room
            let bottom = bounds.maxY - margin
            // The ink bar rides on the tools: the zoom, stacked, rises above both.
            let ink = inkBarHost.map { $0.isHidden ? 0 : $0.intrinsicContentSize.height + 8 } ?? 0
            zoomControls.frame = CGRect(x: bounds.maxX - margin - zoom.width,
                                        y: bottom - zoom.height - (inline ? 0 : tools.height + ink + spacing),
                                        width: zoom.width, height: zoom.height)
            let centred = bounds.midX - tools.width / 2
            let limit = inline ? bounds.maxX - margin - zoom.width - spacing - tools.width : bounds.maxX - margin - tools.width
            let x = max(margin, min(centred, limit))
            let toolsFrame = CGRect(x: x, y: bottom - tools.height, width: tools.width, height: tools.height)
            toolbarHost?.frame = toolsFrame
            toolsTop = toolsFrame.minY
            if let inkBarHost {
                let size = inkBarHost.intrinsicContentSize
                inkBarHost.frame = CGRect(x: toolsFrame.midX - size.width / 2, y: toolsTop - 8 - size.height,
                                          width: size.width, height: size.height)
            }
        }
        if let minimap {
            minimap.frame = CGRect(x: margin, y: bounds.maxY - margin - BoardMinimapView.size.height,
                                   width: BoardMinimapView.size.width, height: BoardMinimapView.size.height)
        }
        if let emptyHost {
            let width = max(0, bounds.width - 24)
            let height = emptyHost.fittingSize.height
            let size = NSHostingController(rootView: emptyHost.rootView).sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude))
            emptyHost.frame = CGRect(x: 12, y: bounds.midY - 20 - max(height, size.height) / 2, width: width, height: max(height, size.height))
        }
        if let bannerHost {
            let size = bannerHost.fittingSize
            bannerHost.frame = CGRect(x: bounds.midX - size.width / 2, y: 56, width: size.width, height: size.height)
        }
        if let presentBar {
            let size = presentBar.fittingSize
            presentBar.frame = CGRect(x: bounds.midX - size.width / 2, y: bounds.maxY - 18 - size.height, width: size.width, height: size.height)
        }
        if let selectionBar, selectionBarShown { placeSelectionBar(selectionBar) }
    }

    /// The selection bar and the ink bar are SwiftUI, tens of milliseconds to make: made hidden while the board is
    /// idle after it opens, so the first selection or the first drawing tool only shows them.
    func prewarmChrome() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self, self.window != nil, self.selectionBar == nil, self.model.dragged.isEmpty else { return }
            let bar = self.host(AnyView(BoardSelectionBar(model: self.model)))
            bar.isHidden = true
            self.selectionBar = bar
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                guard let self, self.window != nil, self.inkBarHost == nil else { return }
                let ink = self.host(AnyView(BoardInkStyleBar(model: self.model)))
                ink.isHidden = true
                self.inkBarHost = ink
            }
        }
    }

    // MARK: Selection bar

    /// The bar over the selection: shown while something is selected and nothing is being moved or written.
    func updateSelectionBar(_ state: BoardViewState?) {
        guard state != nil, theme != nil else { return }
        let visible = model.isEditable && model.editing == nil && model.link == nil && model.marquee == nil && model.dragged.isEmpty
            && model.resizing == nil && model.presentation == nil && (model.selectedEdge != nil || !model.selection.isEmpty)
        if visible, selectionBar == nil {
            let bar = host(AnyView(BoardSelectionBar(model: model)))
            bar.isHidden = true
            selectionBar = bar
        }
        guard let selectionBar else { return }
        if visible { selectionBarSize = selectionBar.fittingSize }
        if visible != selectionBarShown {
            selectionBarShown = visible
            if visible {
                selectionBar.isHidden = false
                placeSelectionBar(selectionBar)
                selectionBar.wantsLayer = true
                selectionBar.layer?.add(BoardSprings.animation("opacity", Motion.Spring.overlay, from: 0, to: 1), forKey: "show")
            } else {
                show(selectionBar, false)
            }
        } else if visible {
            placeSelectionBar(selectionBar)
        }
    }

    /// Above what is selected, or below it when there is no room; kept inside the view.
    func placeSelectionBar(_ bar: NSView) {
        let camera = model.camera
        var anchor: CGPoint?
        if let edge = model.selectedEdgeValue, let curve = model.curve(of: edge) {
            let middle = camera.screenPoint(CGPoint(curve.middle))
            anchor = CGPoint(x: middle.x, y: middle.y - 44)
        } else if let bounds = model.selectionBounds {
            let rect = camera.screenRect(CGRect(bounds))
            let above = rect.minY - 46
            anchor = CGPoint(x: rect.midX, y: above < 28 ? rect.maxY + 46 : above)
        }
        guard let anchor else { return }
        let size = selectionBarSize
        let view = bounds.size
        let x = min(max(anchor.x, size.width / 2 + 10), max(size.width / 2 + 10, view.width - size.width / 2 - 10))
        let y = min(max(anchor.y, size.height / 2 + 10), max(size.height / 2 + 10, view.height - size.height / 2 - 70))
        let frame = CGRect(x: (x - size.width / 2).rounded(), y: (y - size.height / 2).rounded(), width: size.width, height: size.height)
        if bar.frame != frame { bar.frame = frame }
    }

    // MARK: Presenting

    /// Presenting: the board hidden behind the floor colour but for the slide, a bar at the bottom; changing slide
    /// pushes the old one out while the new one comes in from the side (a fade under Reduce Motion).
    func updatePresentation(_ state: BoardViewState, previous: BoardViewState?) {
        guard let palette else { return }
        let presenting = state.presentation != nil
        cutout.isHidden = !presenting
        if presenting, presentBar == nil {
            presentBar = host(AnyView(BoardPresentationBar(model: model)))
            needsLayout = true
        }
        presentBar?.isHidden = !presenting
        cutout.fillColor = palette.background.cgColor
        positionPresentation()
        if let change = model.slideChange, change.id != previous?.slideChange {
            pushSlide(change)
        }
    }

    func positionPresentation() {
        guard model.presentation != nil, let frame = model.presentedFrame else { return }
        let slide = model.camera.screenRect(CGRect(frame))
        let path = CGMutablePath()
        path.addRect(bounds.insetBy(dx: -bounds.width * 1.2, dy: -10))
        let radius = Corners.r(10 * model.camera.scale)
        path.addPath(CGPath(roundedRect: slide, cornerWidth: radius, cornerHeight: radius, transform: nil))
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        cutout.path = path
        CATransaction.commit()
    }

    private func pushSlide(_ change: BoardSlideChange) {
        let width = bounds.width
        let direction: CGFloat = change.shift >= 0 ? 1 : -1
        // The slide leaving, as drawn on the board: its layers rendered into a picture where it was on screen.
        let scale = change.screen.width / max(CGFloat(change.rect.width), 1)
        let pixels = backing
        let size = change.screen.size
        if let context = CGContext(data: nil, width: Int(size.width * pixels), height: Int(size.height * pixels), bitsPerComponent: 8,
                                   bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.displayP3)!,
                                   bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) {
            context.translateBy(x: 0, y: size.height * pixels)
            context.scaleBy(x: pixels * scale, y: -pixels * scale)
            context.translateBy(x: -change.rect.x, y: -change.rect.y)
            context.setFillColor((palette?.background ?? .white).cgColor)
            context.fill(CGRect(change.rect))
            for layer in [groupsLayer, edges, cardsLayer] { layer.render(in: context) }
            leavingSlide.contents = context.makeImage()
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        leavingSlide.frame = change.screen
        leavingSlide.cornerRadius = Corners.r(10 * scale)
        leavingSlide.isHidden = false
        leavingSlide.opacity = 1
        CATransaction.commit()
        let reduced = Motion.reduceMotion
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            MainActor.assumeIsolated {
                guard self?.model.slideChange?.id == change.id || self?.model.slideChange == nil else { return }
                self?.leavingSlide.isHidden = true
                self?.leavingSlide.contents = nil
            }
        }
        if reduced {
            leavingSlide.opacity = 0
            leavingSlide.add(BoardSprings.animation("opacity", Motion.Spring.smooth, from: 1, to: 0), forKey: "leave")
        } else {
            let out = BoardSprings.animation("position.x", Motion.Spring.smooth, from: 0, to: -direction * width, additive: true)
            out.isRemovedOnCompletion = false
            (out as? CAPropertyAnimation)?.fillMode = .forwards
            leavingSlide.add(out, forKey: "leave")
            for layer in [world, grid as CALayer, cutout] {
                layer.add(BoardSprings.animation("position.x", Motion.Spring.smooth, from: direction * width, to: 0, additive: true),
                          forKey: "arrive")
            }
        }
        CATransaction.commit()
    }
}

/// The error banner at the top of a board that cannot be read or saved.
struct BoardBanner: View {
    let text: String
    @Environment(\.themeTokens) private var theme

    var body: some View {
        Label(text, symbol: "exclamationmark.triangle")
            .font(.ui(.label))
            .foregroundStyle(theme.secondaryText)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .glassEffect(.regular, in: ThemeCapsule())
            .fixedSize()
    }
}
