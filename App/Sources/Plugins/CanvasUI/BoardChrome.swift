import CanvasPlugin
import PluginKitUI
import SwiftUI

/// A colour's name in the picker, and the swatches themselves.
struct BoardSwatches: View {
    let current: String?
    let pick: (String?) -> Void
    @Environment(\.themeTokens) private var theme

    var body: some View {
        HStack(spacing: 8) {
            swatch(nil, Color.clear)
            ForEach(BoardStyle.presets, id: \.value) { preset in
                swatch(preset.value, BoardStyle.color(preset.value) ?? .gray)
            }
        }
        .padding(12)
    }

    private func swatch(_ value: String?, _ color: Color) -> some View {
        Button { pick(value) } label: {
            ZStack {
                Circle().fill(color)
                if value == nil {
                    Circle().strokeBorder(theme.secondaryText.opacity(0.5), lineWidth: 1.5)
                    Rectangle().fill(Color.red.opacity(0.7)).frame(width: 1.5, height: 22).rotationEffect(.degrees(45)) // ui-rules: illustration
                        .clipShape(Circle())
                }
                if value == current {
                    Circle().strokeBorder(theme.text, lineWidth: 2).padding(-3)
                }
            }
            .frame(width: 22, height: 22)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(value == nil ? "No colour" : BoardStyle.presets.first { $0.value == value }?.name ?? "")
    }
}
