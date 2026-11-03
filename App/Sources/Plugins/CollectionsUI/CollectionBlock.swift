import PluginKitUI
import SwiftUI

/// A collection inside a note, as Craft's Collection block: the same page, smaller, following the block's YAML as
/// it is typed or undone. Its entries are the notes whose `collection` property names the note.
struct CollectionBlock: View {
    let model: CollectionViewModel
    let views: CollectionViewStore
    let block: CodeBlockContext

    var body: some View {
        CollectionPage(model: model, views: views)
            .frame(minHeight: 160, maxHeight: 560, alignment: .top)
            .padding(.vertical, 6)
            .onChange(of: block.code) { _, code in
                model.setSource(.inline(yaml: code, host: block.notePath))
            }
    }
}

/// The `/` items that insert a collection block: a table, a board or a gallery of the notes that belong to the note.
enum CollectionBlocks {
    /// The filter of a block: the notes whose `collection` is the note's name. A new entry is written next to the
    /// note with that property, so no folder appears.
    static let filter = """
    filters:
      and:
        - collection == this.file.basename
        - file.ext == "md"
    """

    static func yaml(_ type: String) -> String {
        switch type {
        case "kanban":
            return filter + """

            properties:
              status:
                type: select
                options: [To do, In progress, Done]
            views:
              - type: kanban
                name: Kanban
                groupBy: {property: status, direction: ASC}
                order: [file.name, status]
            """
        case "cards":
            return filter + "\nviews:\n  - type: cards\n    name: Gallery\n    order: [file.name]"
        default:
            return filter + "\nviews:\n  - type: table\n    name: Table\n    order: [file.name]"
        }
    }

    static let slashItems: [SlashItem] = [
        item("collection.block-table", "Collection", "tablecells", ["table", "database", "base"], type: "table"),
        item("collection.block-kanban", "Kanban", "rectangle.split.3x1", ["board", "collection"], type: "kanban"),
        item("collection.block-gallery", "Gallery", "square.grid.2x2", ["cards", "collection"], type: "cards"),
    ]

    private static func item(_ id: String, _ title: String, _ symbol: String, _ keywords: [String], type: String) -> SlashItem {
        SlashItem(id: id, title: title, symbol: symbol, keywords: keywords) { text, trigger in
            let block = "```base\n" + yaml(type) + "\n```\n"
            let ns = text as NSString
            let lineStart = ns.lineRange(for: NSRange(location: trigger.location, length: 0)).location
            let prefix = trigger.location > lineStart ? "\n" : ""
            let replacement = prefix + block
            let end = trigger.location + (replacement as NSString).length
            return TextChange(range: trigger, replacement: replacement, selection: NSRange(location: end, length: 0))
        }
    }
}
