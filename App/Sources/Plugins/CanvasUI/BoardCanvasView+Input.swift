import AppKit
import CanvasPlugin
import PluginKitUI
import SwiftUI

/// What is under the pointer: a handle, a card, a frame or a group, an arrow, or the empty board.
enum BoardTarget {
    case handle(BoardHandle)
    case card(CanvasNode)
    case frame(CanvasNode)
    case group(CanvasNode)
    case edge(String)
    case background
}

/// The pointer's gesture once it is down: waiting to be a click or a drag, then what the drag does.
enum BoardGesture {
    case pending(start: CGPoint, target: BoardTarget, event: NSEvent)
    case moving(start: CGPoint)
    case marquee(start: CGPoint)
    case resizing(start: CGPoint, keepsRatio: Bool)
    case linking
    case lineEnd
    case stroke
    case panning(last: CGPoint)
    case presenting
}

extension BoardCanvasView {
    func point(_ event: NSEvent) -> CGPoint { convert(event.locationInWindow, from: nil) }

    func world(_ point: CGPoint) -> CanvasPoint { CanvasPoint(model.camera.worldPoint(point)) }

    private var panning: Bool { spaceDown || model.tool == .hand }

    // MARK: Hit testing

    /// What a click at a view point lands on, as the board draws them from the top.
    func target(at point: CGPoint) -> BoardTarget {
        if let handle = handles.reversed().first(where: { $0.hit.contains(point) }) { return .handle(handle) }
        let camera = model.camera
        let w = camera.worldPoint(point)
        let slop = 1 / camera.scale
        let ids = model.index.nodes(in: CanvasRect(x: w.x - slop, y: w.y - slop, width: slop * 2, height: slop * 2))
        let order = self.order
        let hits = ids.compactMap(model.node).sorted { (order[$0.id] ?? 0) < (order[$1.id] ?? 0) }
        // What is dragged, resized or lifted is drawn above: it takes the click first.
        for node in hits.reversed() where node.kind != .group && CGRect(model.frame(of: node)).contains(w) {
            if let ink = model.store.ink(node) {
                guard Self.ink(ink, node: node, contains: CanvasPoint(w), slop: 6 / camera.scale) else { continue }
            }
            return .card(node)
        }
        // A group's label and border, or anywhere on a frame (a slide is a page to grab).
        for node in model.document.nodes.reversed() where node.kind == .group {
            if let layer = groupLayers[node.id], !layer.label.isHidden {
                let label = layer.label.frame.offsetBy(dx: CGFloat(node.x), dy: CGFloat(node.y))
                if label.contains(w) { return .group(node) }
            }
            let frame = CGRect(model.frame(of: node))
            if node.ratio != nil, frame.contains(w) { return .frame(node) }
            let band = 9 / camera.scale
            if frame.insetBy(dx: -band, dy: -band).contains(w), !frame.insetBy(dx: band, dy: band).contains(w) { return .group(node) }
        }
        if let edge = model.edge(at: point) { return .edge(edge) }
        return .background
    }

    /// Whether a point of the board is on a drawing's strokes, widened by `slop`.
    static func ink(_ ink: CanvasInk, node: CanvasNode, contains point: CanvasPoint, slop: Double) -> Bool {
        let local = CanvasPoint(x: point.x - node.x, y: point.y - node.y)
        return ink.strokes.contains { $0.distance(to: local) <= slop + $0.width / 2 }
    }

    /// The order of the board's nodes, for hit testing from the top.
    var order: [String: Int] {
        Dictionary(uniqueKeysWithValues: model.document.nodes.enumerated().map { ($1.id, $0) })
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        let point = point(event)
        model.pointer.location = point
        if model.presentation != nil {
            gesture = .presenting
            return
        }
        // A click on the board ends what is being written.
        if model.editing != nil, editor?.contains(event) != true { model.commitEditing() }
        if window?.firstResponder !== self, model.activeEmbed == nil { window?.makeFirstResponder(self) }
        if panning {
            gesture = .panning(last: point)
            NSCursor.closedHand.set()
            return
        }
        if model.tool.draws {
            gesture = .stroke
            model.beginStroke(at: world(point))
            model.continueStroke(to: world(point), snaps: event.modifierFlags.contains(.shift))
            return
        }
        gesture = .pending(start: point, target: target(at: point), event: event)
    }

    override func mouseDragged(with event: NSEvent) {
        let point = point(event)
        model.pointer.location = point
        let shift = event.modifierFlags.contains(.shift)
        guard let gesture else { return }
        switch gesture {
        case .pending(let start, let target, let down):
            let distance = hypot(point.x - start.x, point.y - start.y)
            let threshold: CGFloat
            switch target {
            case .handle(let handle): threshold = handle.kind.isLink ? 2 : 1
            default: threshold = 3
            }
            guard distance >= threshold else { return }
            begin(target, at: start, event: down)
            mouseDragged(with: event)
        case .moving(let start):
            model.updateDrag(CGSize(width: point.x - start.x, height: point.y - start.y))
        case .marquee(let start):
            model.updateMarquee(CGRect(x: min(start.x, point.x), y: min(start.y, point.y),
                                       width: abs(point.x - start.x), height: abs(point.y - start.y)))
        case .resizing(let start, let keepsRatio):
            model.updateResize(CGSize(width: point.x - start.x, height: point.y - start.y), keepRatio: shift != keepsRatio)
        case .linking:
            model.updateLink(to: point)
        case .lineEnd:
            model.updateLineEnd(to: world(point), snaps: shift)
        case .stroke:
            model.continueStroke(to: world(point), snaps: shift)
        case .panning(let last):
            model.camera.pan(by: CGSize(width: point.x - last.x, height: point.y - last.y))
            self.gesture = .panning(last: point)
            showCameraNow()
        case .presenting:
            break
        }
    }

    /// Starts what a drag from `target` does.
    private func begin(_ target: BoardTarget, at start: CGPoint, event: NSEvent) {
        let flags = event.modifierFlags
        switch target {
        case .card(let node):
            model.beginDrag(node, extend: flags.contains(.shift), duplicate: flags.contains(.option))
            gesture = .moving(start: start)
        case .frame(let node), .group(let node):
            model.beginDrag(node, extend: false, duplicate: flags.contains(.option))
            gesture = .moving(start: start)
        case .edge, .background:
            model.beginMarquee(extend: flags.contains(.shift))
            gesture = .marquee(start: start)
        case .handle(let handle):
            switch handle.kind {
            case .corner(let side), .strip(let side):
                guard let node = model.node(handle.owner) else { return }
                model.beginResize(node, handle: side)
                let keepsRatio = node.kind == .file && CardFile.kind(of: node.file ?? "") == .image
                gesture = .resizing(start: start, keepsRatio: keepsRatio)
            case .link(let side):
                guard let node = model.node(handle.owner) else { return }
                model.beginLink(from: node, side: side)
                gesture = .linking
            case .edgeEnd(let movesStart):
                guard let edge = model.document.edge(handle.owner) else { return }
                model.beginReconnect(edge, movesStart: movesStart)
                gesture = .linking
            case .lineEnd(let movesStart):
                guard let node = model.node(handle.owner) else { return }
                model.beginLineEnd(node, movesStart: movesStart)
                gesture = .lineEnd
            case .addRow, .addColumn:
                gesture = nil
            }
        }
    }

    override func mouseUp(with event: NSEvent) {
        let point = point(event)
        defer {
            gesture = nil
            updateCursor(at: point)
        }
        guard let gesture else { return }
        let shift = event.modifierFlags.contains(.shift)
        switch gesture {
        case .pending(_, let target, _):
            tap(target, at: point, count: event.clickCount, extend: shift)
        case .moving: model.endDrag()
        case .marquee: model.endMarquee()
        case .resizing: model.endResize()
        case .linking: model.endLink()
        case .lineEnd: model.endLineEnd()
        case .stroke: model.endStroke()
        case .panning: model.cameraMoved()
        case .presenting:
            if presentBar?.frame.contains(point) != true { model.nextSlide() }
        }
    }

    private func tap(_ target: BoardTarget, at point: CGPoint, count: Int, extend: Bool) {
        switch target {
        case .card(let node):
            let frame = model.frame(of: node)
            let w = model.camera.worldPoint(point)
            model.tap(node, count: count, extend: extend, at: CGPoint(x: w.x - frame.x, y: w.y - frame.y))
        case .frame(let node):
            if count >= 2, model.isEditable {
                model.addText(at: world(point))
            } else {
                model.tap(node, count: 1, extend: extend)
            }
        case .group(let node):
            model.tap(node, count: count, extend: extend)
        case .edge, .background:
            model.tapBackground(at: point, count: count, extend: extend)
        case .handle(let handle):
            guard let node = model.node(handle.owner) else { return }
            if case .addRow = handle.kind { model.appendTableRow(node) }
            if case .addColumn = handle.kind { model.appendTableColumn(node) }
        }
    }

    override func mouseMoved(with event: NSEvent) {
        let point = point(event)
        model.pointer.location = point
        if model.presentation != nil { model.pointerMoves += 1 }
        guard gesture == nil else { return }
        hover(at: point)
        updateCursor(at: point)
    }

    override func mouseExited(with event: NSEvent) {
        model.pointer.location = nil
        if gesture == nil {
            model.setHovered(nil)
            model.hoverPoint = nil
            setHoveredHandle(nil)
        }
    }

    /// The card under the pointer lights up and shows its arrow dots.
    func hover(at point: CGPoint) {
        guard model.presentation == nil else { return }
        if let handle = handles.reversed().first(where: { $0.hit.contains(point) }) {
            setHoveredHandle(handle.id)
            return
        }
        setHoveredHandle(nil)
        if case .card(let node) = target(at: point) {
            let frame = model.camera.screenRect(CGRect(model.frame(of: node)))
            if model.hovered != node.id { model.setHovered(node.id) }
            model.hoverPoint = CGPoint(x: point.x - frame.minX, y: point.y - frame.minY)
        } else {
            if model.hovered != nil { model.setHovered(nil) }
            if model.hoverPoint != nil { model.hoverPoint = nil }
        }
    }

    func updateCursor(at point: CGPoint) {
        if panning {
            (gesture == nil ? NSCursor.openHand : NSCursor.closedHand).set()
        } else if model.tool == .eraser {
            NSCursor.crosshair.set()
        } else if let handle = handles.reversed().first(where: { $0.hit.contains(point) }), let cursor = handle.cursor {
            cursor.set()
        } else {
            NSCursor.arrow.set()
        }
    }

    override func cursorUpdate(with event: NSEvent) {
        updateCursor(at: point(event))
    }

    override func rightMouseDown(with event: NSEvent) {
        let point = point(event)
        model.pointer.location = point
        guard model.presentation == nil else { return }
        let menu: NSMenu
        switch target(at: point) {
        case .card(let node), .frame(let node), .group(let node):
            menu = BoardMenus.node(model, node)
        default:
            menu = BoardMenus.background(model, theme: theme ?? .standard, appearance: effectiveAppearance)
        }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    override func otherMouseDragged(with event: NSEvent) {
        model.camera.pan(by: CGSize(width: event.deltaX, height: event.deltaY))
        showCameraNow()
    }

    // MARK: Scrolling and pinching

    override func scrollWheel(with event: NSEvent) {
        let point = point(event)
        model.pointer.location = point
        let zooms = CanvasCamera.scrollZooms(event, wheelZooms: true)
        // While writing, or over the live card entered, plain scrolling is theirs.
        if !zooms, model.editing != nil || model.isOverActiveEmbed(point) { return }
        model.camera.scroll(with: event, at: point, wheelZooms: true)
        showCameraNow()
    }

    override func magnify(with event: NSEvent) {
        let point = point(event)
        model.camera.magnify(with: event, at: point)
        showCameraNow()
    }

    /// Shows the camera at once, in this turn, rather than on the next (`Follow`): the frame after the event has it.
    func showCameraNow() {
        let camera = BoardCameraState(offset: model.camera.offset, scale: model.camera.scale, shift: model.presentShift)
        guard camera != cameraState else { return }
        cameraState = camera
        applyCamera()
        cameraChanged()
    }

    // MARK: Keyboard

    override func becomeFirstResponder() -> Bool {
        model.hasKeyboard = true
        return true
    }

    override func resignFirstResponder() -> Bool {
        model.hasKeyboard = false
        return true
    }

    override func keyDown(with event: NSEvent) {
        if !handle(event) { super.keyDown(with: event) }
    }

    override func keyUp(with event: NSEvent) {
        if BoardKey(event) == .space {
            spaceDown = false
            if let point = model.pointer.location { updateCursor(at: point) }
            return
        }
        super.keyUp(with: event)
    }

    /// The board's Command keys while it has the keyboard; the Edit menu keeps the others.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self, event.type == .keyDown,
              event.modifierFlags.contains(.command) else { return super.performKeyEquivalent(with: event) }
        let key = event.charactersIgnoringModifiers ?? ""
        guard event.keyCode == 29 || event.keyCode == 35 || ["=", "+", "-", "g", "[", "]"].contains(key) else {
            return super.performKeyEquivalent(with: event)
        }
        return handle(event)
    }

    /// The board's keys. True when the key was used.
    func handle(_ event: NSEvent) -> Bool {
        guard model.editing == nil, let key = BoardKey(event) else { return false }
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if model.presentation != nil {
            switch key {
            case .right, .down, .space, .returnKey: model.nextSlide()
            case .left, .up, .delete: model.previousSlide()
            case .escape: model.stopPresenting()
            default: return mods.contains(.command) ? false : true
            }
            return true
        }
        if mods == [.command, .option], key == .character("p") || key == .character("π") {
            model.present()
            return true
        }
        if mods.contains(.command) {
            if mods.contains(.option) {
                switch key {
                case .character("="), .character("+"): model.stepFontSize(larger: true)
                case .character("-"): model.stepFontSize(larger: false)
                default: return false
                }
                return true
            }
            switch key {
            case .digit(0): model.camera.setScale(1)
            case .character("="), .character("+"): model.camera.zoom(by: 1.25, animated: true)
            case .character("-"): model.camera.zoom(by: 0.8, animated: true)
            case .character("g"): model.groupSelection()
            case .character("]"): model.bringToFront()
            case .character("["): model.sendToBack()
            default: return false
            }
            return true
        }
        if mods.contains(.control) || mods.contains(.option) { return false }
        // A letter typed on a selected shape or card is written in it, as Whimsical and Miro do.
        if let text = event.characters, model.typeIntoSelection(text) { return true }
        let step: Double = mods.contains(.shift) ? 10 : 1
        switch key {
        case .delete: model.deleteSelection()
        case .escape where model.tool.draws:
            model.tool = .select
        case .escape:
            model.leaveEmbed()
            model.selection = []
            model.selectedEdge = nil
        case .returnKey:
            guard model.selection.count == 1, let id = model.selection.first, let node = model.node(id) else { return false }
            model.activate(node)
        case .space:
            spaceDown = true
            if let point = model.pointer.location { updateCursor(at: point) }
        case .up: model.nudge(0, -step)
        case .down: model.nudge(0, step)
        case .left: model.nudge(-step, 0)
        case .right: model.nudge(step, 0)
        case .character("t"): model.addText(at: model.insertionPoint)
        case .character("r"): model.addShape(.rectangle, at: model.insertionPoint)
        case .character("o"): model.addShape(.circle, at: model.insertionPoint)
        case .character("d"): model.addShape(.diamond, at: model.insertionPoint)
        case .character("f"): model.addFrame(at: model.insertionPoint)
        case .character("s"): model.addSticky(at: model.insertionPoint)
        case .character("p"): model.tool = .pen
        case .character("e"): model.tool = .eraser
        case .character("l"): model.tool = .line
        case .character("a"): model.tool = .arrow
        case .character("n"): BoardActions.addNote(model)
        case .character("m"): model.toggleMinimap()
        case .character("v"): model.tool = .select
        case .character("h"): model.tool = .hand
        case .digit(1) where mods.contains(.shift): model.fit()
        case .digit(2) where mods.contains(.shift): model.zoomToSelection()
        default: return false
        }
        return true
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
        model.pasteFromPasteboard(NSPasteboard.general)
    }

    @objc func delete(_ sender: Any?) {
        model.deleteSelection()
    }

    override func selectAll(_ sender: Any?) {
        model.selectAll()
    }

    private func put(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    // MARK: Drops

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        draggingUpdated(sender)
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard model.isEditable else { return [] }
        if !model.dropTargeted { model.dropTargeted = true }
        return .copy
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        model.dropTargeted = false
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        model.dropTargeted = false
        let point = convert(sender.draggingLocation, from: nil)
        return model.drop(sender.draggingPasteboard, at: world(point))
    }
}

/// The keys of the board, from an AppKit key event.
enum BoardKey: Equatable {
    case returnKey, space, delete, escape, up, down, left, right
    /// A number key, by its place on the keyboard: layouts that type a symbol unshifted (AZERTY) still count it.
    case digit(Int)
    case character(String)

    init?(_ event: NSEvent) {
        switch event.keyCode {
        case 36, 76: self = .returnKey
        case 49: self = .space
        case 51, 117: self = .delete
        case 53: self = .escape
        case 18: self = .digit(1)
        case 19: self = .digit(2)
        case 20: self = .digit(3)
        case 21: self = .digit(4)
        case 23: self = .digit(5)
        case 22: self = .digit(6)
        case 26: self = .digit(7)
        case 28: self = .digit(8)
        case 25: self = .digit(9)
        case 29: self = .digit(0)
        case 126: self = .up
        case 125: self = .down
        case 123: self = .left
        case 124: self = .right
        default:
            guard let characters = event.charactersIgnoringModifiers?.lowercased(), !characters.isEmpty else {
                return nil
            }
            self = .character(characters)
        }
    }
}
