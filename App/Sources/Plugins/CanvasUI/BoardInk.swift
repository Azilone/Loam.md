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

