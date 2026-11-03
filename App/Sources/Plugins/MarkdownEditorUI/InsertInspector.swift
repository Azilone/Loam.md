import MarkdownEditor
import PluginKitUI
import SwiftUI

/// A note's "Insert" tab in the right sidebar, as Craft's: the `/` menu's blocks as tiles, a click inserting at the
/// caret what the entry would, then what plugins add (a diagram, a collection). Text styles stay in the format bar.
struct InsertInspector: View {
    let items: [SlashMenuItem]
    let insert: @MainActor (SlashMenuItem) -> Void

    var body: some View {
        let standard = Set(SlashMenu.standardItems.map(\.id))
        let blocks = items.filter { standard.contains($0.id) && $0.section != "Text Style" }
        let plugins = items.filter { !standard.contains($0.id) }
        VStack(alignment: .leading, spacing: InspectorStyle.groupSpacing) {
            InspectorGroup("Blocks") {
                InspectorTileGrid {
                    ForEach(blocks) { item in
                        InspectorTile(Self.shortTitle(item), symbol: item.symbol) { insert(item) }
                            .help(item.title)
                    }
                }
            }
            if !plugins.isEmpty {
                InspectorGroup("Plugins") {
                    InspectorTileGrid {
                        ForEach(plugins) { item in
                            InspectorTile(item.title, symbol: item.symbol) { insert(item) }
                                .help(item.title)
                        }
                    }
                }
            }
        }
    }

    /// The tile's name, short enough for a third of the sidebar: "Todo List" is "Todo".
    static func shortTitle(_ item: SlashMenuItem) -> String {
        switch item.id {
        case "tasks": "Todo"
        case "bullets": "Bullets"
        case "numbers": "Numbered"
        default: item.title
        }
    }
}
