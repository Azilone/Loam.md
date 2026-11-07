import AppKit

/// The page's blocks that are shown as more than text (embeds, tables, diagrams and live blocks) and its headings,
/// found in one pass over the page after each styling: each of them read the whole page on every keystroke.
struct PageScan {
    /// Each embed block's attribute and paragraph.
    var embeds: [(attribute: BlockAttribute, paragraph: NSRange)] = []
    /// Each table block's attribute and its one character.
    var tables: [(attribute: BlockAttribute, content: NSRange)] = []
    /// Each atomic code block (a diagram, a live block) and its one character.
    var components: [(block: NoteBlock, content: NSRange)] = []
    /// Each heading's paragraph and level.
    var headings: [(paragraph: NSRange, level: Int)] = []

    init() {}

    init(_ storage: NSAttributedString) {
        guard storage.length > 0 else { return }
        let ns = storage.string as NSString
        var seen = Set<ObjectIdentifier>()
        storage.enumerateAttribute(.noteBlock, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            guard let attribute = value as? BlockAttribute else { return }
            let kind = attribute.block.kind
            switch kind {
            case .embed, .table, .heading, .code: break
            default: return
            }
            guard seen.insert(ObjectIdentifier(attribute)).inserted else { return }
            let paragraph = ns.paragraphRange(for: range)
            switch kind {
            case .embed:
                embeds.append((attribute, paragraph))
            case .table:
                let content = BlockStorage.content(of: paragraph, in: storage)
                if content.length == 1 { tables.append((attribute, content)) }
            case .heading(let level):
                if paragraph.length > 0 { headings.append((paragraph, level)) }
            case .code where BlockStorage.isAtomic(kind):
                let content = BlockStorage.content(of: paragraph, in: storage)
                if content.length == 1 { components.append((attribute.block, content)) }
            default:
                break
            }
        }
    }
}
