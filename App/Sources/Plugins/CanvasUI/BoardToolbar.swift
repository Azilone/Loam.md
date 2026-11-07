import AppKit
import CanvasPlugin
import PluginKitUI
import SwiftUI

/// The bar that floats over the selection: colour, text size, alignment, grouping, deleting; for an arrow, its
/// colour, shape, dashes, heads and label. The board places it (above what is selected, or below when there is no
/// room) and shows it while something is selected and nothing moves (`BoardCanvasView.updateSelectionBar`).
struct BoardSelectionBar: View {
    let model: BoardModel
    @Environment(\.themeTokens) private var theme
    @State private var picking = false

    var body: some View {
        Group {
            if let edge = model.selectedEdgeValue { edgeBar(edge) } else { nodeBar }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .glassEffect(.regular, in: ThemeCapsule())
        .fixedSize()
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

