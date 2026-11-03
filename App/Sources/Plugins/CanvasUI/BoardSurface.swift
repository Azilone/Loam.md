import AppKit
import CanvasPlugin
import PluginKitUI
import SwiftUI

/// The arrows between cards, drawn in one pass in view points, and the arrow being drawn. Only arrows crossing the
/// screen are drawn. Clicks go to the board, which finds the arrow under the pointer (`BoardModel.edge(at:)`).
/// A new arrow draws itself from its start.
struct BoardEdges: View {
    let model: BoardModel
    @Environment(\.themeTokens) private var theme

    var body: some View {
        let births = model.edgeBirths
        TimelineView(.animation(paused: births.isEmpty)) { timeline in
            canvas(now: timeline.date, births: births)
        }
        .allowsHitTesting(false)
    }

    private func canvas(now: Date, births: [String: Date]) -> some View {
        let camera = model.camera
        let visible = CanvasRect(camera.visibleWorldRect)
        let scale = camera.scale
        let skipped = model.link?.reconnect?.edge
        let edges = BoardProfile.measure("edges") { model.document.edges.compactMap { edge -> (CanvasEdge, CanvasCurve)? in
            guard edge.id != skipped, let curve = model.curve(of: edge), curve.bounds.intersects(visible) else { return nil }
            return (edge, curve)
        } }
        let pending = model.link.flatMap { link -> CanvasCurve? in
            guard let from = model.node(link.from) else { return nil }
            let start = model.frame(of: from).anchor(link.side)
            let reach = min(max((link.point - start).length / 2, 30), 160)
            return CanvasCurve(start: start, control1: start + link.side.normal * reach, control2: link.point,
                               end: link.point)
        }
        let offset = camera.offset
        let selectedEdge = model.selectedEdge
        let editedEdge = model.editedEdge
        let accent = theme.accent, secondary = theme.secondaryText, text = theme.text
        let background = theme.background, separator = theme.separator
        return Canvas { context, _ in BoardProfile.measure("edgesDraw") {
            func screen(_ point: CanvasPoint) -> CGPoint {
                CGPoint(x: point.x * scale + offset.width, y: point.y * scale + offset.height)
            }
            func path(_ curve: CanvasCurve) -> Path {
                var path = Path()
                path.move(to: screen(curve.start))
                path.addCurve(to: screen(curve.end), control1: screen(curve.control1), control2: screen(curve.control2))
                return path
            }
            func head(_ curve: CanvasCurve, atStart: Bool) -> Path {
                let (left, right) = curve.arrowHead(atStart: atStart, size: BoardStyle.arrowSize)
                var path = Path()
                path.move(to: screen(atStart ? curve.start : curve.end))
                path.addLine(to: screen(left))
                path.addLine(to: screen(right))
                path.closeSubpath()
                return path
            }
            let width = max(1.25, BoardStyle.edgeWidth * scale)
            // Plain arrows (the many) are stroked together, one pass per colour; the selected, dashed and drawing
            // ones one by one.
            var lines: [String: (color: Color, path: Path, heads: Path)] = [:]
            for (edge, curve) in edges {
                let selected = selectedEdge == edge.id
                let color = selected ? accent : BoardStyle.color(edge.color) ?? secondary.opacity(0.7)
                // How much of a new arrow is drawn: 0 to 1, easing out.
                var progress = 1.0
                if let born = births[edge.id] {
                    let t = min(1, max(0, now.timeIntervalSince(born) / BoardMotion.linkDraw))
                    progress = 1 - pow(1 - t, 3)
                }
                if !selected, !edge.isDashed, progress >= 1 {
                    var batch = lines[edge.color ?? ""] ?? (color, Path(), Path())
                    batch.path.addPath(path(curve))
                    if edge.endsWithArrow { batch.heads.addPath(head(curve, atStart: false)) }
                    if edge.startsWithArrow { batch.heads.addPath(head(curve, atStart: true)) }
                    lines[edge.color ?? ""] = batch
                    continue
                }
                let style = StrokeStyle(lineWidth: selected ? width + 1.25 : width, lineCap: .round,
                                        dash: edge.isDashed ? [width * 2.6, width * 2.4] : [])
                var line = path(curve)
                if progress < 1 { line = line.trimmedPath(from: 0, to: progress) }
                if selected {
                    context.stroke(line, with: .color(accent.opacity(0.22)),
                                   style: StrokeStyle(lineWidth: width + 7, lineCap: .round))
                }
                context.stroke(line, with: .color(color), style: style)
                if progress > 0.9 {
                    context.opacity = min(1, (progress - 0.9) * 10)
                    if edge.endsWithArrow { context.fill(head(curve, atStart: false), with: .color(color)) }
                    if edge.startsWithArrow { context.fill(head(curve, atStart: true), with: .color(color)) }
                    context.opacity = 1
                }
            }
            for (_, batch) in lines {
                context.stroke(batch.path, with: .color(batch.color), style: StrokeStyle(lineWidth: width, lineCap: .round))
                context.fill(batch.heads, with: .color(batch.color))
            }
            if let pending {
                context.stroke(path(pending), with: .color(accent),
                               style: StrokeStyle(lineWidth: width, lineCap: .round, dash: [6, 5]))
                context.fill(head(pending, atStart: false), with: .color(accent))
            }
            guard scale >= 0.3 else { return }
            for (edge, curve) in edges {
                guard let label = edge.label, !label.isEmpty, editedEdge != edge.id else { continue }
                if let born = births[edge.id], now.timeIntervalSince(born) < BoardMotion.linkDraw { continue }
                let resolved = context.resolve(Text(label.uiLocalized)
                    .font(.ui(size: 13 * scale, weight: .medium))
                    .foregroundStyle(text))
                let size = resolved.measure(in: CGSize(width: 240 * scale, height: 80 * scale))
                let center = screen(curve.middle)
                let box = CGRect(x: center.x - size.width / 2 - 8 * scale, y: center.y - size.height / 2 - 3.5 * scale,
                                 width: size.width + 16 * scale, height: size.height + 7 * scale)
                context.fill(Path(roundedRect: box, cornerRadius: Corners.r(box.height / 2)), with: .color(background))
                context.stroke(Path(roundedRect: box, cornerRadius: Corners.r(box.height / 2)),
                               with: .color(selectedEdge == edge.id ? accent : separator.opacity(0.7)),
                               lineWidth: selectedEdge == edge.id ? 1.5 : 0.75)
                context.draw(resolved, in: box.insetBy(dx: 8 * scale, dy: 3.5 * scale))
            }
        } }
    }
}

/// The two ends of the selected arrow, as handles to drag onto another card.
struct BoardEdgeHandles: View {
    let model: BoardModel
    @Environment(\.themeTokens) private var theme
    /// Where the drag of an end started; a new start is a new drag, even if SwiftUI dropped the last one unended.
    @State private var active: CGPoint?

    var body: some View {
        // Stays while an end is dragged: the handle under the hand carries the gesture, and taking it away would
        // drop the gesture, leaving the arrow half moved.
        let reconnecting = model.link?.reconnect
        if let edge = model.selectedEdgeValue, model.link == nil || reconnecting?.edge == edge.id, model.editing == nil,
           let curve = model.curve(of: edge) {
            ZStack {
                handle(edge, movesStart: true, at: model.camera.screenPoint(CGPoint(curve.start)))
                    .opacity(reconnecting == nil ? 1 : 0)
                handle(edge, movesStart: false, at: model.camera.screenPoint(CGPoint(curve.end)))
                    .opacity(reconnecting == nil ? 1 : 0)
            }
            .transition(.opacity)
        }
    }

    private func handle(_ edge: CanvasEdge, movesStart: Bool, at point: CGPoint) -> some View {
        Circle()
            .fill(Color.white)
            .overlay(Circle().strokeBorder(theme.accent, lineWidth: 2))
            .frame(width: BoardStyle.handleSize + 2, height: BoardStyle.handleSize + 2)
            .shadow(color: .black.opacity(0.2), radius: 2, y: 1)
            .padding(8)
            .contentShape(Circle())
            .position(point)
            .gesture(
                DragGesture(minimumDistance: 2, coordinateSpace: .named(BoardView.space))
                    .onChanged { value in
                        if active != value.startLocation {
                            active = value.startLocation
                            model.beginReconnect(edge, movesStart: movesStart)
                        }
                        model.updateLink(to: value.location)
                    }
                    .onEnded { _ in
                        active = nil
                        model.endLink()
                    }
            )
            .help("Drag onto a card to move this end of the arrow")
    }
}

/// The text field of an arrow's label, at the middle of the arrow.
struct BoardEdgeLabelEditor: View {
    let model: BoardModel

    var body: some View {
        if let editing = model.editing, case .edge(let id) = editing.target, let edge = model.document.edge(id),
           let curve = model.curve(of: edge) {
            let center = model.camera.screenPoint(CGPoint(curve.middle))
            BoardLabelField(model: model, size: max(11, 13 * model.camera.scale))
                .frame(width: 200)
                .position(center)
        }
    }
}

/// A one-line field for a label (a group's, an arrow's): Return saves, Escape cancels, focus is taken at once.
struct BoardLabelField: View {
    let model: BoardModel
    let size: CGFloat
    @FocusState private var focused: Bool
    @Environment(\.themeTokens) private var theme

    var body: some View {
        TextField("Label", text: Binding(
            get: { model.editing?.draft ?? "" },
            set: { model.editing?.draft = $0 }
        ))
        .textFieldStyle(.plain)
        .font(.ui(size: size, weight: .semibold))
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(ThemeCapsule().fill(theme.background))
        .overlay(ThemeCapsule().strokeBorder(theme.accent, lineWidth: 1.5))
        .focused($focused)
        // A frame later: on its first appearance the field is not in the window yet, and the keys went to the board.
        .onAppear { DispatchQueue.main.async { focused = true } }
        .onSubmit { model.commitEditing() }
        .onExitCommand { model.cancelEditing() }
        .onChange(of: focused) { if !focused { model.commitEditing() } }
    }
}

/// A text card being written: Markdown as typed, at the card's font size. Escape or a click elsewhere saves; the
/// card grows to keep the text in view.
struct BoardTextEditor: View {
    let model: BoardModel
    let node: CanvasNode
    let scale: CGFloat
    @FocusState private var focused: Bool
    @Environment(\.themeTokens) private var theme

    var body: some View {
        let frame = model.frame(of: node)
        let inner = (node.shape ?? .rectangle).textRect(in: CanvasRect(x: 0, y: 0, width: frame.width, height: frame.height))
        TextEditor(text: Binding(
            get: { model.editing?.draft ?? "" },
            set: { model.editing?.draft = $0 }
        ))
        .font(.ui(size: node.effectiveFontSize * scale))
        .foregroundStyle(theme.text)
        .multilineTextAlignment(node.effectiveTextAlign.swiftUI)
        .scrollContentBackground(.hidden)
        .scrollIndicators(.never)
        // The text view keeps a few points of its own on each side.
        .padding(.horizontal, node.isFreeText ? max(0, BoardStyle.freeTextPadding - 5) * scale
                 : max(2, (BoardStyle.textPadding - 5) * scale))
        .padding(.vertical, node.isFreeText ? max(0, BoardStyle.freeTextPadding - 1) * scale
                 : max(2, (BoardStyle.textPadding - 3) * scale))
        // Free text: the text view lays a line out a little wider than it is drawn, so it gets room for that and
        // the next letter past the outline, which hugs the text: it runs past its right edge, never its left.
        .frame(width: (inner.width + (node.isFreeText ? 12 + node.effectiveFontSize : 0)) * scale,
               height: inner.height * scale)
        .frame(width: inner.width * scale, height: inner.height * scale, alignment: .topLeading)
        .offset(x: inner.x * scale, y: inner.y * scale)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .focused($focused)
        // A frame later: on its first appearance the field is not in the window yet, and the keys went to the board.
        .onAppear { DispatchQueue.main.async { focused = true } }
        .onExitCommand { model.commitEditing() }
        .onKeyPress(.return, phases: .down) { press in
            guard press.modifiers.contains(.command) else { return .ignored }
            model.commitEditing()
            return .handled
        }
        .onChange(of: focused) { if !focused { model.commitEditing() } }
    }
}

// MARK: - Keyboard

/// An invisible AppKit view that becomes the first responder when the board is clicked, so keys reach the board
/// rather than an editor beside it. It answers the Edit menu's Copy, Cut, Paste and Select All; undo goes through
/// the window's undo manager. Clicks pass through it. It also takes what is dropped on the board: SwiftUI's
/// `onDrop` never received a drop from the Finder here, while AppKit finds a view registered for the dragged types
/// whatever its hit test says.
struct BoardKeyCatcher: NSViewRepresentable {
    let model: BoardModel
    let focusRequest: Int
    let onKey: (NSEvent) -> Bool

    func makeNSView(context: Context) -> BoardKeyView {
        let view = BoardKeyView()
        view.model = model
        view.onKey = onKey
        return view
    }

    func updateNSView(_ view: BoardKeyView, context: Context) {
        view.model = model
        view.onKey = onKey
        guard view.focusRequest != focusRequest else { return }
        view.focusRequest = focusRequest
        DispatchQueue.main.async { [weak view, model] in
            guard let view, let window = view.window, window.firstResponder !== view, model.editing == nil,
                  model.activeEmbed == nil else { return }
            window.makeFirstResponder(view)
        }
    }
}

final class BoardKeyView: NSView {
    weak var model: BoardModel?
    var onKey: ((NSEvent) -> Bool)?
    var focusRequest = -1

    override var acceptsFirstResponder: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil, registeredDraggedTypes.isEmpty { registerForDraggedTypes(BoardModel.dropTypes) }
    }

    // MARK: Drops

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        draggingUpdated(sender)
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        MainActor.assumeIsolated {
            guard let model, model.isEditable else { return [] }
            if !model.dropTargeted { model.dropTargeted = true }
            return .copy
        }
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        MainActor.assumeIsolated { model?.dropTargeted = false }
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        MainActor.assumeIsolated {
            guard let model else { return false }
            model.dropTargeted = false
            let local = convert(sender.draggingLocation, from: nil)
            let point = CGPoint(x: local.x, y: isFlipped ? local.y : bounds.height - local.y)
            return model.drop(sender.draggingPasteboard, at: CanvasPoint(model.camera.worldPoint(point)))
        }
    }

    override func becomeFirstResponder() -> Bool {
        MainActor.assumeIsolated { model?.hasKeyboard = true }
        return true
    }

    override func resignFirstResponder() -> Bool {
        MainActor.assumeIsolated { model?.hasKeyboard = false }
        return true
    }

    override func keyDown(with event: NSEvent) {
        if onKey?(event) != true { super.keyDown(with: event) }
    }

    override func keyUp(with event: NSEvent) {
        if onKey?(event) != true { super.keyUp(with: event) }
    }

    /// The board's Command keys while it has the keyboard; the Edit menu keeps the others.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self, event.type == .keyDown,
              event.modifierFlags.contains(.command) else { return super.performKeyEquivalent(with: event) }
        let key = event.charactersIgnoringModifiers ?? ""
        guard event.keyCode == 29 || event.keyCode == 35 || ["=", "+", "-", "g", "[", "]"].contains(key) else {
            return super.performKeyEquivalent(with: event)
        }
        return onKey?(event) == true
    }

    @objc func copy(_ sender: Any?) {
        MainActor.assumeIsolated {
            guard let text = model?.copySelection() else { return }
            put(text)
        }
    }

    @objc func cut(_ sender: Any?) {
        MainActor.assumeIsolated {
            guard let text = model?.cutSelection() else { return }
            put(text)
        }
    }

    @objc func paste(_ sender: Any?) {
        MainActor.assumeIsolated {
            model?.pasteFromPasteboard(NSPasteboard.general)
        }
    }

    @objc func delete(_ sender: Any?) {
        MainActor.assumeIsolated { model?.deleteSelection() }
    }

    override func selectAll(_ sender: Any?) {
        MainActor.assumeIsolated { model?.selectAll() }
    }

    private func put(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
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
