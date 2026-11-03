import PluginKitUI
import SwiftUI

/// A graph's "Graph" tab in the right sidebar: what the page does not already offer, the folders to show or hide
/// and the most linked notes. A folder goes through `model.filter`, which saves it in the tab and rebuilds the
/// graph; the tag, the depth and the orphans stay in the page's own options.
struct GraphInspector: View {
    let model: GraphTabModel
    @Environment(\.themeTokens) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: InspectorStyle.groupSpacing) {
            let folders = model.folders
            if folders.count > 1 {
                InspectorGroup("Folders", accessory: "click to hide") {
                    InspectorCard {
                        ForEach(folders.prefix(8), id: \.name) { folder in
                            let hidden = model.filter.hiddenFolders.contains(folder.name)
                            InspectorRow(
                                folder.name.isEmpty ? "Vault root" : folder.name,
                                symbol: hidden ? "eye.slash" : "folder",
                                count: folder.count,
                                isDimmed: hidden
                            ) { model.toggleFolder(folder.name) }
                        }
                    }
                }
            }
            let linked = model.mostLinked()
            if !linked.isEmpty {
                let top = model.data.nodes[linked[0]].degree
                InspectorGroup("Most linked") {
                    InspectorCard {
                        ForEach(linked, id: \.self) { index in
                            let node = model.data.nodes[index]
                            InspectorBarRow(node.title, value: node.degree, maximum: top, color: theme.accent.opacity(0.7)) {
                                model.open(index)
                            }
                            .help(node.path)
                        }
                    }
                }
            }
        }
    }
}
