import CanvasPlugin
import PluginKitUI
import SwiftUI

/// A board's "Board" tab in the right sidebar: what the toolbar does not offer, for the selected cards, their
/// colour and how to line them up. With nothing selected it says so in one line.
struct BoardInspector: View {
    let model: BoardModel
    @Environment(\.themeTokens) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: InspectorStyle.groupSpacing) {
            if model.selection.isEmpty {
                InspectorEmpty("Select cards to colour or line them up.", systemImage: "cursorarrow.rays")
            } else {
                InspectorGroup("Colour") {
                    InspectorSwatches(
                        [(id: "none", color: theme.text.opacity(0.12), name: "No colour")]
                            + BoardStyle.presets.compactMap { preset in
                                BoardStyle.color(preset.value).map { (id: preset.value, color: $0, name: preset.name) }
                            },
                        selection: model.selectedColor ?? "none"
                    ) { id in
                        model.setColor(id == "none" ? nil : id)
                    }
                    .disabled(!model.isEditable)
                }
                if model.selection.count > 1 {
                    InspectorGroup("Arrange") {
                        InspectorTileGrid {
                            InspectorTile("Left", symbol: "align.horizontal.left", height: 56) { model.align(.left) }
                            InspectorTile("Centre", symbol: "align.horizontal.center", height: 56) { model.align(.centerX) }
                            InspectorTile("Right", symbol: "align.horizontal.right", height: 56) { model.align(.right) }
                            InspectorTile("Top", symbol: "align.vertical.top", height: 56) { model.align(.top) }
                            InspectorTile("Middle", symbol: "align.vertical.center", height: 56) { model.align(.centerY) }
                            InspectorTile("Bottom", symbol: "align.vertical.bottom", height: 56) { model.align(.bottom) }
                        }
                        .disabled(!model.isEditable)
                    }
                }
            }
        }
    }
}
