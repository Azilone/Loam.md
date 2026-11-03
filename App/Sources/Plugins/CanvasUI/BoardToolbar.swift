import AppKit
import CanvasPlugin
import PluginKitUI
import SwiftUI

/// The board's tools, in a Liquid Glass capsule at the bottom: select or move the board, then add a text card, a
/// note, files or a web page, and group the selection.
struct BoardToolbar: View {
    @Bindable var model: BoardModel
    @Environment(\.themeTokens) private var theme
    @State private var addingLink = false
    @State private var address = ""

    var body: some View {
        HStack(spacing: 2) {
            tool(.select, "cursorarrow", "Select (V)")
            tool(.hand, "hand.raised", "Move the board (H, or hold Space)")
            divider
            drawMenu(.arrow, "arrow.up.right", "Draw an arrow (A); hold for a line (L)", [
                (.arrow, "Arrow (A)", "arrow.up.right"), (.line, "Line (L)", "line.diagonal"),
            ])
            drawMenu(.pen, "pencil.tip", "Draw with the pen (P); hold for the highlighter", [
                (.pen, "Pen (P)", "pencil.tip"), (.highlighter, "Highlighter", "highlighter"),
            ])
            tool(.eraser, "eraser", "Erase strokes (E)")
            divider
            button("textformat", "Add text (T, or double-click the board)") {
                model.addText(at: model.viewCenter)
            }
            shapeMenu
            button("note", "Add a sticky note (S)") { model.addSticky(at: model.viewCenter) }
            button("tablecells", "Add a table: Tab goes to the next cell") { model.addTable(at: model.viewCenter) }
            button(LoamSymbol.mindmap, "Add a mindmap: Tab adds a topic, Return the next one") {
                model.addMindmap(at: model.viewCenter)
            }
            Menu {
                // macOS leaves a menu item's icon out unless asked: the icon says what each one adds.
                Group {
                    Button("Note… (N)", symbol: "doc.text") { BoardActions.addNote(model) }
                    Button("Pictures, PDFs, Videos…", symbol: "photo.on.rectangle") { BoardActions.addFiles(model) }
                    Button("Web Page…", symbol: "globe") { addingLink = true }
                }
                .labelStyle(.titleAndIcon)
            } label: {
                Image(symbol: "plus.rectangle.on.rectangle").font(.ui(size: 15)).frame(width: 34, height: 28)
                    .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Add a note, files or a web page (or drag them here)")
            .popover(isPresented: $addingLink, arrowEdge: .top) { linkPrompt }
            divider
            button("square.on.square.dashed", model.selection.isEmpty ? "Add a group to drop cards into (⌘G)" : "Group the selection (⌘G)") {
                if model.selection.isEmpty { model.addGroup(at: model.viewCenter) } else { model.groupSelection() }
            }
            button("tv", model.selection.isEmpty ? "Add a frame, a slide (F)" : "Frame the selection as a slide (F)") {
                model.addFrame(at: model.viewCenter)
            }
            divider
            button("play.fill", "Present the frames (⌥⌘P)") { model.present() }
                .disabled(model.document.slideCandidates.isEmpty)
        }
        .foregroundStyle(theme.text)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .glassEffect(.regular, in: ThemeCapsule())
        .disabled(!model.isEditable)
    }

    private var divider: some View { Divider().frame(height: 18).padding(.horizontal, 4) }

    /// Adds the last shape chosen; held or opened, the menu chooses another.
    private var shapeMenu: some View {
        Menu {
            Button("Text Card", symbol: "note.text") { model.addText(at: model.viewCenter, card: true) }
            Divider()
            ForEach(CanvasNodeShape.allCases, id: \.self) { shape in
                Button(shape.name + (shape.key.map { " (\($0))" } ?? ""), symbol: shape.symbol) {
                    model.addShape(shape, at: model.viewCenter)
                }
            }
        } label: {
            Image(symbol: model.lastShape.symbol).font(.ui(size: 15)).frame(width: 34, height: 28)
                .contentShape(Rectangle())
        } primaryAction: {
            model.addShape(model.lastShape, at: model.viewCenter)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Add a shape (R, O, D; hold for the others)")
    }

    private var linkPrompt: some View {
        HStack(spacing: 8) {
            TextField("https://…", text: $address)
                .textFieldStyle(.roundedBorder)
                .frame(width: 260)
                .onSubmit(add)
            Button("Add", action: add)
                .keyboardShortcut(.defaultAction)
                .disabled(BoardActions.webAddress(address) == nil)
        }
        .padding(12)
    }

    private func add() {
        guard let url = BoardActions.webAddress(address) else { return }
        model.addLink(url, at: model.viewCenter)
        address = ""
        addingLink = false
        model.requestKeyboard()
    }

    /// A drawing tool and its variants: a click picks the one shown, holding opens the others.
    private func drawMenu(_ main: BoardTool, _ image: String, _ help: String,
                          _ tools: [(tool: BoardTool, name: String, symbol: String)]) -> some View {
        let current = tools.first { $0.tool == model.tool }
        let on = current != nil
        return Menu {
            ForEach(tools, id: \.tool) { item in
                Button(item.name, symbol: item.symbol) { model.tool = item.tool }
            }
        } label: {
            Image(symbol: current?.symbol ?? image)
                .font(.ui(size: 15))
                .frame(width: 34, height: 28)
                .background(RoundedRectangle(cornerRadius: Corners.r(10), style: .continuous).fill(on ? theme.accent.opacity(0.18) : .clear))
                .foregroundStyle(on ? theme.accent : theme.text)
                .contentShape(Rectangle())
        } primaryAction: {
            model.tool = current?.tool ?? main
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(help)
    }

    private func tool(_ tool: BoardTool, _ image: String, _ help: String) -> some View {
        Button { model.tool = tool } label: {
            Image(symbol: image)
                .font(.ui(size: 15))
                .frame(width: 34, height: 28)
                .background(RoundedRectangle(cornerRadius: Corners.r(10), style: .continuous)
                    .fill(model.tool == tool ? theme.accent.opacity(0.18) : .clear))
                .foregroundStyle(model.tool == tool ? theme.accent : theme.text)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private func button(_ image: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button { action() } label: {
            Image(symbol: image).font(.ui(size: 15)).frame(width: 34, height: 28).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

/// The bar that floats over the selection: colour, text size, alignment, grouping, deleting; for an arrow, its
/// colour, shape, dashes, heads and label. It sits above what is selected, or below when there is no room.
struct BoardSelectionBar: View {
    let model: BoardModel
    @Environment(\.themeTokens) private var theme
    @State private var picking = false
    @State private var size = CGSize(width: 260, height: 36)

    private var visible: Bool {
        model.isEditable && model.editing == nil && model.link == nil && model.marquee == nil && model.dragged.isEmpty
            && model.resizing == nil && (model.selectedEdge != nil || !model.selection.isEmpty)
    }

    var body: some View {
        if visible, let anchor = anchor() {
            Group {
                if let edge = model.selectedEdgeValue { edgeBar(edge) } else { nodeBar }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .glassEffect(.regular, in: ThemeCapsule())
            .fixedSize()
            .onGeometryChange(for: CGSize.self) { $0.size } action: { size = $0 }
            .position(clamped(anchor))
            .transition(.scale(scale: 0.9).combined(with: .opacity))
            .animation(BoardMotion.chrome, value: model.selection)
        }
    }

    /// Where the bar's middle goes, before it is kept inside the view.
    private func anchor() -> CGPoint? {
        let camera = model.camera
        if let edge = model.selectedEdgeValue, let curve = model.curve(of: edge) {
            let middle = camera.screenPoint(CGPoint(curve.middle))
            return CGPoint(x: middle.x, y: middle.y - 44)
        }
        guard let bounds = model.selectionBounds else { return nil }
        let rect = camera.screenRect(CGRect(bounds))
        let above = rect.minY - 46
        return CGPoint(x: rect.midX, y: above < 28 ? rect.maxY + 46 : above)
    }

    private func clamped(_ point: CGPoint) -> CGPoint {
        let view = model.camera.viewSize
        return CGPoint(x: min(max(point.x, size.width / 2 + 10), max(size.width / 2 + 10, view.width - size.width / 2 - 10)),
                       y: min(max(point.y, size.height / 2 + 10), max(size.height / 2 + 10, view.height - size.height / 2 - 70)))
    }

    // MARK: Cards

    @ViewBuilder private var nodeBar: some View {
        HStack(spacing: 2) {
            colorButton
            if model.selectionHasDrawing {
                divider
                ForEach(BoardModel.inkWidths, id: \.self) { width in
                    Button { model.setDrawingWidth(width) } label: {
                        ThemeCapsule().fill(theme.text).frame(width: 16, height: max(1.5, width * 0.9))
                            .frame(width: 28, height: 26).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Width \(Int(width))")
                }
            }
            if let line = model.selectedLine, let ink = line.drawing {
                toggle("ellipsis", "Dashed", on: ink.strokes.first?.dashed == true) { model.toggleLineDashed() }
                Menu {
                    Button("No arrow head") { model.setLineHeads(start: false, end: false) }
                    Button("Arrow at the end", symbol: "arrow.right") { model.setLineHeads(start: false, end: true) }
                    Button("Arrow at the start", symbol: "arrow.left") { model.setLineHeads(start: true, end: false) }
                    Button("Arrows at both ends", symbol: "arrow.left.arrow.right") { model.setLineHeads(start: true, end: true) }
                } label: {
                    Image(symbol: "arrow.right").font(.ui(size: 14)).frame(width: 30, height: 26)
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Arrow heads")
            }
            if model.selectionHasText {
                if !model.selectedNodes.contains(where: \.isTable) { shapeMenu }
                divider
                button("textformat.size.smaller", "Smaller text (⌥⌘−)") { model.stepFontSize(larger: false) }
                    .disabled((model.selectedFontSize ?? 0) <= CanvasNode.fontSizes.first!)
                Text(model.selectedFontSize.map { "\(Int($0))" } ?? "–")
                    .font(.ui(size: 12, weight: .semibold).monospacedDigit())
                    .frame(minWidth: 22)
                    .foregroundStyle(theme.secondaryText)
                button("textformat.size.larger", "Larger text (⌥⌘+)") { model.stepFontSize(larger: true) }
                    .disabled((model.selectedFontSize ?? 0) >= CanvasNode.fontSizes.last!)
            }
            divider
            if model.selection.count > 1 { alignMenu }
            button("square.on.square.dashed", "Group (⌘G)") { model.groupSelection() }
            button("plus.square.on.square", "Duplicate (or Option-drag)") { model.duplicateSelection() }
            if model.selection.count == 1, let node = model.selectedNodes.first, node.kind == .file || node.kind == .link {
                button("arrow.up.forward.square", "Open") { model.activate(node) }
            }
            divider
            button("trash", "Remove from the board (⌫)") { model.deleteSelection() }
        }
    }

    /// The shape, outline and text alignment of the selected text cards.
    private var shapeMenu: some View {
        Menu {
            Section("Shape") {
                Button("Text", symbol: "textformat") { model.makeFreeText() }
                Button("Card", symbol: "note.text") { model.clearShape() }
                ForEach(CanvasNodeShape.allCases, id: \.self) { shape in
                    Button(shape.name, symbol: shape.symbol) { model.setShape(shape) }
                }
            }
            Section("Outline") {
                ForEach(CanvasBorder.allCases, id: \.self) { border in
                    Button(border.rawValue.capitalized) { model.setBorder(border) }
                }
            }
            Section("Text") {
                ForEach(CanvasTextAlign.allCases, id: \.self) { align in
                    Button(align == .center ? "Centre" : align.rawValue.capitalized, symbol: align.symbol) {
                        model.setTextAlign(align)
                    }
                }
            }
        } label: {
            Image(symbol: model.selectionIsFreeText ? "textformat" : model.selectedShape?.symbol ?? "note.text")
                .font(.ui(size: 14))
                .frame(width: 30, height: 26)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Shape, outline and alignment")
    }

    private var alignMenu: some View {
        Menu {
            Button("Align Left", symbol: "align.horizontal.left") { model.align(.left) }
            Button("Align Center", symbol: "align.horizontal.center") { model.align(.centerX) }
            Button("Align Right", symbol: "align.horizontal.right") { model.align(.right) }
            Divider()
            Button("Align Top", symbol: "align.vertical.top") { model.align(.top) }
            Button("Align Middle", symbol: "align.vertical.center") { model.align(.centerY) }
            Button("Align Bottom", symbol: "align.vertical.bottom") { model.align(.bottom) }
            if model.selection.count > 2 {
                Divider()
                Button("Distribute Horizontally", symbol: "distribute.horizontal.center") { model.distribute(.horizontal) }
                Button("Distribute Vertically", symbol: "distribute.vertical.center") { model.distribute(.vertical) }
            }
        } label: {
            Image(symbol: "align.horizontal.left").font(.ui(size: 14)).frame(width: 30, height: 26)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Align")
    }

    // MARK: Arrows

    @ViewBuilder private func edgeBar(_ edge: CanvasEdge) -> some View {
        HStack(spacing: 2) {
            colorButton
            divider
            toggle("point.topleft.down.curvedto.point.bottomright.up", "Curved", on: !edge.isStraight) {
                model.setEdgeShape(.curve)
            }
            toggle("line.diagonal", "Straight", on: edge.isStraight) { model.setEdgeShape(.straight) }
            toggle("ellipsis", "Dashed", on: edge.isDashed) { model.toggleEdgeDashed() }
            Menu {
                Button("No arrow head") { model.setEdgeHeads(start: false, end: false) }
                Button("Arrow at the end", symbol: "arrow.right") { model.setEdgeHeads(start: false, end: true) }
                Button("Arrow at the start", symbol: "arrow.left") { model.setEdgeHeads(start: true, end: false) }
                Button("Arrows at both ends", symbol: "arrow.left.arrow.right") { model.setEdgeHeads(start: true, end: true) }
            } label: {
                Image(symbol: "arrow.right").font(.ui(size: 14)).frame(width: 30, height: 26)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Arrow heads")
            divider
            button("character.cursor.ibeam", "Label") { if let id = model.selectedEdge { model.beginEditing(.edge(id)) } }
            button("arrow.left.arrow.right.circle", "Reverse direction") { model.reverseEdge() }
            divider
            button("trash", "Remove the arrow (⌫)") { model.deleteSelection() }
        }
    }

    // MARK: Pieces

    private var colorButton: some View {
        Button { picking.toggle() } label: {
            ZStack {
                Circle().fill(BoardStyle.color(model.selectedColor) ?? Color.clear)
                Circle().strokeBorder(BoardStyle.color(model.selectedColor) == nil ? theme.secondaryText.opacity(0.7) : .white.opacity(0.7),
                                      lineWidth: 1.5)
            }
            .frame(width: 18, height: 18)
            .frame(width: 30, height: 26)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Colour")
        .popover(isPresented: $picking, arrowEdge: .bottom) {
            BoardSwatches(current: model.selectedColor) { value in
                model.setColor(value)
                picking = false
            }
        }
    }

    private var divider: some View { Divider().frame(height: 16).padding(.horizontal, 3) }

    private func button(_ image: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button { action() } label: {
            Image(symbol: image).font(.ui(size: 14)).frame(width: 30, height: 26).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private func toggle(_ image: String, _ help: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button { action() } label: {
            Image(symbol: image)
                .font(.ui(size: 14))
                .frame(width: 30, height: 26)
                .background(RoundedRectangle(cornerRadius: Corners.r(8), style: .continuous).fill(on ? theme.accent.opacity(0.18) : .clear))
                .foregroundStyle(on ? theme.accent : theme.text)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

/// A small map of the whole board, with the part on screen outlined. Click or drag in it to go there.
struct BoardMinimap: View {
    let model: BoardModel
    @Environment(\.themeTokens) private var theme
    /// The map's scale and origin, held while it is dragged so the board does not slide under the finger.
    @State private var held: (fit: CGFloat, origin: CGPoint)?
    static let size = CGSize(width: 190, height: 128)

    var body: some View {
        let nodes = model.document.nodes
        let visible = model.camera.visibleWorldRect
        let all = CanvasRect.bounds(nodes.map(\.frame)).map { CGRect($0).union(visible) } ?? visible
        let inset = Self.size.width * 0.06
        let liveFit = min((Self.size.width - inset * 2) / max(all.width, 1), (Self.size.height - inset * 2) / max(all.height, 1))
        let liveOrigin = CGPoint(x: (Self.size.width - all.width * liveFit) / 2 - all.minX * liveFit,
                                 y: (Self.size.height - all.height * liveFit) / 2 - all.minY * liveFit)
        let fit = held?.fit ?? liveFit
        let origin = held?.origin ?? liveOrigin
        let text = theme.text, accent = theme.accent
        Canvas { context, _ in
            func rect(_ world: CGRect) -> CGRect {
                CGRect(x: world.minX * fit + origin.x, y: world.minY * fit + origin.y,
                       width: world.width * fit, height: world.height * fit)
            }
            for node in nodes where node.kind == .group {
                let color = BoardStyle.color(node.color) ?? text
                context.stroke(Path(roundedRect: rect(CGRect(node.frame)), cornerRadius: Corners.r(2)), with: .color(color.opacity(0.4)),
                               lineWidth: 0.75)
            }
            for node in nodes where node.kind != .group {
                let color = BoardStyle.color(node.color)
                let shape = Path(roundedRect: rect(CGRect(node.frame)), cornerRadius: Corners.r(1.5))
                context.fill(shape, with: .color(color?.opacity(0.75) ?? text.opacity(0.28)))
            }
            let view = rect(visible)
            context.fill(Path(roundedRect: view, cornerRadius: Corners.r(4)), with: .color(accent.opacity(0.1)))
            context.stroke(Path(roundedRect: view, cornerRadius: Corners.r(4)), with: .color(accent), lineWidth: 1.5)
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    if held == nil { held = (liveFit, liveOrigin) }
                    let world = CanvasPoint(x: (value.location.x - origin.x) / fit, y: (value.location.y - origin.y) / fit)
                    model.center(on: world, animated: false)
                }
                .onEnded { _ in held = nil }
        )
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: Corners.r(16), style: .continuous))
        .help("Click or drag to go somewhere on the board")
    }
}
