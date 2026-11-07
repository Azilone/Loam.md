import AppKit
import PluginKit
import PluginKitUI
import SwiftUI

/// What a folder page shows, as Craft's folder view: one card per note (its title and the start of its text) and
/// per subfolder. "All Notes" (`notes:`) shows every note of the vault; `notes:<title>#<viewType>` every file that view
/// type opens first (the drawings, the boards).
struct NoteCard: Identifiable, Equatable {
    enum Kind: Equatable { case note, folder }
    let path: String
    let title: String
    let preview: String
    let kind: Kind
    /// The icon of a note that opens with another view than the editor (a mindmap); nil for a plain note.
    var symbol: String?
    /// A note's first blocks, drawn on its card as a small rendering of the note; nil for a folder.
    var blocks: NotePreview?
    /// The note's first picture, shown under its text as on Craft's cards.
    var cover: URL?
    /// When the note last changed, in the card's footer.
    var modified: Date?
    /// The note's tags, in the card's footer: its frontmatter's, then the ones in its text.
    var tags: [String] = []
    var id: String { path }
}

extension ExplorerModel {
    /// The resource of "All Notes".
    static let allNotes = Resource.virtual("notes:")

    /// Whether the explorer's grid shows `resource`: a folder, "All Notes" or the page of one kind of file.
    static func isPage(_ resource: Resource) -> Bool {
        resource.kind == .folder || (resource.kind == .virtual && resource.path.hasPrefix("notes:"))
    }

    /// The view type of a page of one kind of file (`notes:Drawings#excalidraw.drawing`), nil for any other page.
    static func pageViewType(of resource: Resource) -> String? { resource.notesViewType }

    /// What the "+" of a page of one kind creates (a drawing on the drawings' page); nil for a note.
    func newItem(for resource: Resource) -> NewItem? {
        guard let kind = resource.notesViewType else { return nil }
        return newItems().first { $0.viewType == kind }
    }

    /// Where a note made from a page goes: the folder it shows, or the inbox.
    func newNoteFolder(for resource: Resource) -> String {
        resource.kind == .folder ? Self.newNoteFolder(resource.path) : VaultPath.inbox
    }

    /// The page title of a folder resource.
    static func title(of resource: Resource) -> String {
        if resource == allNotes { return "All Notes".uiLocalized }
        if resource.kind == .virtual { return resource.name.uiLocalized }
        return resource.path.isEmpty ? "Vault".uiLocalized : lastComponent(resource.path)
    }

    /// The cards of a folder page: the subfolders, then the notes, as in the tree; every note for "All Notes", the
    /// last edited first. Attachments are left out. Only the first `limit` are built: a note's card reads the note, and a folder
    /// of thousands draws a screenful first.
    func cards(for resource: Resource, limit: Int = .max) -> [NoteCard] {
        cardItems(for: resource).prefix(limit).map(card(for:))
    }

    /// What `cards(for:)` shows, without reading any note.
    func cardItems(for resource: Resource) -> [Item] {
        let shown: [Item]
        if resource == Self.allNotes {
            // An edit moves its note to the top without the tree changing: the cache follows the notes' stamps too.
            if let sortedNotes, sortedNotes.tree == items, sortedNotes.stamps == noteStamps { return sortedNotes.notes }
            let stamps = noteStamps
            let notes: [Item] = Self.flatten(items).filter { $0.kind == .note }.sorted { a, b in
                let edited = stamps[a.path]?.modified ?? 0, other = stamps[b.path]?.modified ?? 0
                if edited != other { return edited > other }
                return a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
            sortedNotes = (items, noteStamps, notes)
            return notes
        } else if let viewType = Self.pageViewType(of: resource) {
            // A note becomes a drawing by its text, without the tree changing: the cache follows the notes' stamps too.
            if let kept = sortedFiles[resource], kept.tree == items, kept.stamps == noteStamps { return kept.files }
            let files = Self.flatten(items)
                .filter { $0.kind != .folder && views()?.viewTypes(for: .file($0.path)).first?.id == viewType }
                .sorted { title(of: $0).localizedStandardCompare(title(of: $1)) == .orderedAscending }
            // None found is not kept: the plugin of that kind may not have loaded yet.
            sortedFiles[resource] = files.isEmpty ? nil : (items, noteStamps, files)
            return files
        } else if resource.kind == .virtual {
            return []
        } else if resource.path.isEmpty {
            shown = items
        } else {
            shown = Self.find(resource.path, in: items)?.children ?? []
        }
        return shown.filter { $0.kind != .attachment }
    }

    func card(for item: Item) -> NoteCard {
        switch item.kind {
        case .folder:
            let count = (item.children ?? []).filter { $0.kind == .note }.count
            return NoteCard(path: item.path, title: item.name, preview: count == 1 ? "1 note" : "\(count) notes", kind: .folder)
        case .attachment:
            // A file of one kind (a board) shows its view on its card, not its text.
            return NoteCard(path: item.path, title: title(of: item), preview: "", kind: .note, symbol: symbol(forFile: item.path))
        case .note:
            let stamp = noteStamps[item.path]
            // A kept card is good while its note is the same: what view a note opens in (its symbol) follows its
            // text, and asking the view registry for every card on screen was most of a scroll's frame.
            if let kept = noteCards[item.path], stamp != nil, kept.stamp == stamp, kept.card.title == item.name {
                return kept.card
            }
            let read: NoteCard
            if let ahead = readAhead.removeValue(forKey: item.path), stamp != nil, ahead.stamp == stamp, ahead.card.title == item.name {
                read = ahead.card
            } else {
                read = Self.noteCard(of: (try? vault.read(item.path)) ?? "", path: item.path, title: item.name, root: vault.rootURL)
            }
            let card = finished(read, stamp: stamp)
            noteCards[item.path] = (stamp, card)
            return card
        }
    }

    /// A note's card from its text, what can be made of it off the main thread.
    nonisolated static func noteCard(of text: String, path: String, title: String, root: URL) -> NoteCard {
        var card = NoteCard(path: path, title: title, preview: preview(of: text, title: title), kind: .note,
                            blocks: NotePreview.parse(text, title: title, limit: 24))
        card.cover = pictureCandidates(in: text, of: path)
            .map { root.appendingPathComponent($0) }
            .first { FileManager.default.fileExists(atPath: $0.path) }
        card.tags = tags(in: text)
        return card
    }

    /// `card` with what the main thread knows: the view the note opens in, and when it changed.
    private func finished(_ card: NoteCard, stamp: FileStamp?) -> NoteCard {
        var card = card
        let symbol = symbol(forNote: card.path)
        card.symbol = symbol == "doc.text" ? nil : symbol
        card.modified = stamp.map { Date(timeIntervalSince1970: $0.modified) }
        return card
    }

    /// Reads, off the main thread, the notes of the first `limit` cards of "All Notes" that have no card kept: the
    /// page's first open then reads none of them on the main thread. Called at launch and once the titles are known.
    /// What only the main thread knows (the view a note opens in: its plugin may not be active yet) is added when the
    /// card is first drawn.
    func warmAllNotes(limit: Int = 60) {
        guard warmingCards == nil else { return }
        let stale = cardItems(for: Self.allNotes).prefix(limit).compactMap { item -> (path: String, title: String, stamp: FileStamp)? in
            guard let stamp = noteStamps[item.path] else { return nil }
            if let kept = noteCards[item.path], kept.stamp == stamp, kept.card.title == item.name { return nil }
            if let ahead = readAhead[item.path], ahead.stamp == stamp, ahead.card.title == item.name { return nil }
            return (item.path, item.name, stamp)
        }
        guard !stale.isEmpty else { return }
        let root = vault.rootURL
        warmingCards = Task { [weak self] in
            let read = await Task.detached(priority: .utility) {
                stale.compactMap { note -> (path: String, stamp: FileStamp, card: NoteCard)? in
                    // A note that does not read as UTF-8 is left to `card(for:)`, which reads it as the vault does.
                    guard let text = try? String(contentsOf: root.appendingPathComponent(note.path), encoding: .utf8)
                    else { return nil }
                    return (note.path, note.stamp, Self.noteCard(of: text, path: note.path, title: note.title, root: root))
                }
            }.value
            guard let self else { return }
            self.warmingCards = nil
            // A note that changed meanwhile is read again when its card is drawn.
            for note in read where self.noteStamps[note.path] == note.stamp {
                self.readAhead[note.path] = (note.stamp, note.card)
            }
        }
    }

    /// The view a note's card shows instead of its text: the one meant for the note when it is not the editor (a
    /// drawing shows its picture, a mindmap its map), embedded as on a board card. Nil for a plain note.
    func cardEmbed(for card: NoteCard) -> (type: ViewType, context: ViewContext)? {
        guard card.kind == .note, card.symbol != nil else { return nil }
        let resource = Resource.file(card.path)
        guard let first = views()?.viewTypes(for: resource).first, first.prefers(resource) || !Self.isNote(card.path)
        else { return nil }
        if let known = cardEmbedContexts[card.path] { return (first, known) }
        let context = ViewContext(resource: resource, presentation: .embedded)
        cardEmbedContexts[card.path] = context
        return (first, context)
    }

    /// Opens a card: a note or a folder page in the focused tab, or a new one.
    func open(_ card: NoteCard, newTab: Bool, from origin: OpenOrigin? = nil) {
        switch card.kind {
        case .note: open(card.path, newTab: newTab, from: origin)
        case .folder: workspace()?.open(.folder(card.path), placement: newTab ? .newTab : .replace, from: origin)
        }
    }

    static func flatten(_ items: [Item]) -> [Item] {
        items.flatMap { [$0] + flatten($0.children ?? []) }
    }

    static func find(_ path: String, in items: [Item]) -> Item? {
        for item in items {
            if item.path == path { return item }
            if let found = find(path, in: item.children ?? []) { return found }
        }
        return nil
    }

    nonisolated static let pictureExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "heic", "webp", "tiff", "bmp"]

    /// Where the pictures the note embeds may be, in order: for each `![alt](path)` or `![[path|size]]`, the path
    /// beside the note, then from the vault's root, as the editor finds them.
    nonisolated static func pictureCandidates(in text: String, of notePath: String) -> [String] {
        let pattern = #"!\[\[([^\]|#]+)[^\]]*\]\]|!\[[^\]]*\]\(<?([^)>\s]+)>?(?:\s+"[^"]*")?\)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        var candidates: [String] = []
        for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            for group in 1...2 {
                guard let range = Range(match.range(at: group), in: text) else { continue }
                let written = String(text[range]).trimmingCharacters(in: .whitespaces)
                let link = written.removingPercentEncoding ?? written
                guard pictureExtensions.contains((link as NSString).pathExtension.lowercased()) else { continue }
                if let path = try? VaultPath.resolve(link, from: notePath) { candidates.append(path) }
                if let path = try? VaultPath.normalize(link), !candidates.contains(path) { candidates.append(path) }
            }
        }
        return candidates
    }

    /// A note's tags, at most three: its frontmatter's `tags`, then the `#tags` of its text, without duplicates.
    nonisolated static func tags(in text: String) -> [String] {
        var found: [String] = []
        var body = Substring(text)
        if text.hasPrefix("---\n"), let end = text.range(of: "\n---", range: text.index(text.startIndex, offsetBy: 4)..<text.endIndex) {
            let front = text[text.index(text.startIndex, offsetBy: 4)..<end.lowerBound]
            var inList = false
            for line in front.split(separator: "\n", omittingEmptySubsequences: false) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("tags:") {
                    let rest = trimmed.dropFirst(5).trimmingCharacters(in: CharacterSet(charactersIn: " []"))
                    found += rest.split(separator: ",").map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " \"'#")) }
                    inList = rest.isEmpty
                } else if inList, trimmed.hasPrefix("- ") {
                    found.append(trimmed.dropFirst(2).trimmingCharacters(in: CharacterSet(charactersIn: " \"'#")))
                } else {
                    inList = false
                }
            }
            body = text[end.upperBound...]
        }
        if let regex = try? NSRegularExpression(pattern: #"(?:^|\s)#([\p{L}\p{N}_/-]+)"#) {
            let string = String(body)
            for match in regex.matches(in: string, range: NSRange(string.startIndex..., in: string)) {
                if let range = Range(match.range(at: 1), in: string) { found.append(String(string[range])) }
            }
        }
        var seen = Set<String>()
        return Array(found.filter { !$0.isEmpty && !$0.allSatisfy(\.isNumber) && seen.insert($0.lowercased()).inserted }.prefix(3))
    }

    /// The start of a note's text for its card: no frontmatter, no `# heading` repeating its title, no Markdown syntax, one line per
    /// line of text, at most 240 characters.
    nonisolated static func preview(of text: String, title: String) -> String {
        var lines = text.components(separatedBy: .newlines)
        if lines.first == "---", let end = lines.dropFirst().firstIndex(where: { $0 == "---" || $0 == "..." }) {
            lines.removeSubrange(0...end)
        }
        if let first = lines.firstIndex(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }),
           lines[first].hasPrefix("# "),
           lines[first].dropFirst(2).trimmingCharacters(in: .whitespaces).caseInsensitiveCompare(title) == .orderedSame {
            lines.remove(at: first)
        }
        let cleaned = lines.map { line -> String in
            var line = line.trimmingCharacters(in: .whitespaces)
            line = line.replacingOccurrences(of: #"^(#{1,6}\s+|>\s*|[-*+]\s+(\[[ xX]\]\s+)?|\d+\.\s+)"#, with: "", options: .regularExpression)
            line = line.replacingOccurrences(of: #"!?\[([^\]]*)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
            line = line.replacingOccurrences(of: #"\[\[([^\]|]*\|)?([^\]]*)\]\]"#, with: "$2", options: .regularExpression)
            return line.replacingOccurrences(of: #"[*_`~]"#, with: "", options: .regularExpression)
        }
        let joined = cleaned.filter { !$0.isEmpty && !$0.hasPrefix("```") }.joined(separator: "\n")
        return joined.count > 240 ? String(joined.prefix(240)) + "…" : joined
    }
}

/// What an empty page shows: a few cards fanned out with the kind's symbol on the front one, a title, a line, and the
/// page's "+" as a button (a new drawing on the drawings' page, a note elsewhere).
struct FolderEmptyState: View {
    let newItem: NewItem?
    let newNote: () -> Void
    @Environment(\.themeTokens) private var theme
    @State private var appeared = false

    private var symbol: String { newItem?.symbol ?? "doc.text" }

    var body: some View {
        EmptyState(
            newItem == nil ? "No notes here yet" : "Nothing here yet",
            message: newItem == nil ? "Notes you write here show up as cards." : "Each one in the vault shows up here, wherever it lives.",
            actionTitle: newItem?.title ?? "New Note",
            action: { if let newItem { newItem.create(VaultPath.inbox) } else { newNote() } }
        ) {
            FolderEmptyDrawing(symbol: symbol)
                .frame(width: 150, height: 104)
                .padding(.bottom, Space.m)
        }
        .opacity(appeared ? 1 : 0)
        .offset(y: appeared ? 0 : 8)
        .onAppear { withAnimation(Motion.resolved(Motion.Spring.standard.animation)) { appeared = true } }
    }
}

/// Two blank cards fanned behind a front card holding the kind's symbol in the accent colour.
private struct FolderEmptyDrawing: View {
    let symbol: String
    @Environment(\.themeTokens) private var theme

    var body: some View {
        // The print look draws what the page holds.
        PrintIllustration(symbol: symbol)
            .frame(width: 112, height: 112)
            .accessibilityHidden(true)
    }

    private var stack: some View {
        ZStack {
            card { lines([34, 44, 28]) }
                .rotationEffect(.degrees(-10))
                .offset(x: -38, y: 6)
            card { lines([40, 30, 42]) }
                .rotationEffect(.degrees(9))
                .offset(x: 38, y: 6)
            card {
                Image(symbol: symbol)
                    .font(.ui(size: 26, weight: .regular))
                    .foregroundStyle(theme.accent)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .offset(y: -4)
        }
        .accessibilityHidden(true)
    }

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        RoundedRectangle(cornerRadius: Corners.r(12), style: .continuous)
            .fill(theme.background)
            .overlay(RoundedRectangle(cornerRadius: Corners.r(12), style: .continuous).strokeBorder(theme.text.opacity(0.12)))
            .overlay { content().padding(11) }
            .frame(width: 70, height: 86)
            .shadow(color: .black.opacity(0.08), radius: 9, y: 4)
    }

    private func lines(_ widths: [CGFloat]) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            ThemeCapsule().fill(theme.text.opacity(0.24)).frame(width: 30, height: 5)
            ForEach(widths.indices, id: \.self) { index in
                ThemeCapsule().fill(theme.text.opacity(0.11)).frame(width: widths[index], height: 3.5)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// A folder page's metrics and masonry: its title, then the cards, as Craft shows a folder: white cards as tall as
/// their notes (up to a limit, then faded out) packed in columns.
///
/// Only the cards on screen and near it exist, as in Craft, placed by AppKit (`CardGridView`): a card reads its note
/// when it comes near the screen and is measured once per width. The cards are dealt to the columns by their
/// estimated height (`estimatedHeight`, from the note's size on disk, without reading it).
enum FolderGridView {
    static let spacing: CGFloat = 18
    static let minColumnWidth: CGFloat = 220
    static let maxColumns = 5
    static let maxWidth: CGFloat = PageWidth.wide.maxWidth
    static let horizontalPadding: CGFloat = PageMetrics.edge

    /// An item in its column, with its place in the folder (for the cascade).
    struct Dealt {
        let item: ExplorerModel.Item
        let index: Int
    }

    /// How many columns of at least `minColumnWidth` fit in `width`; at least one.
    static func columnCount(for width: CGFloat) -> Int {
        min(maxColumns, max(1, Int((width + spacing) / (minColumnWidth + spacing))))
    }

    /// The items dealt to `count` columns in order, each to the column that is shortest so far by `height`, as a
    /// masonry packs them; with the place of each in the folder.
    static func deal(
        _ items: [ExplorerModel.Item], into count: Int, height: (ExplorerModel.Item) -> CGFloat
    ) -> [[Dealt]] {
        var columns = Array(repeating: [Dealt](), count: max(1, count))
        var heights = Array(repeating: CGFloat(0), count: columns.count)
        for (index, item) in items.enumerated() {
            let column = heights.indices.min { heights[$0] < heights[$1] } ?? 0
            columns[column].append(Dealt(item: item, index: index))
            heights[column] += height(item) + spacing
        }
        return columns
    }
}

extension ExplorerModel {
    /// About how tall an item's card is in a column `width` wide, without reading the note: its title, and as many
    /// lines of preview as its size on disk suggests, up to the card's limit. Only used to deal the cards to columns.
    func estimatedHeight(of item: Item, width: CGFloat) -> CGFloat {
        let textWidth = max(60, width - 36)
        let titleLines = min(3, max(1, ceil(CGFloat(item.name.count) * 9.5 / textWidth)))
        let header: CGFloat = 36 + titleLines * 20
        switch item.kind {
        case .folder:
            return header + 22
        case .attachment:
            return header + 180
        case .note:
            let bytes = CGFloat(noteStamps[item.path]?.size ?? 0) - CGFloat(item.name.utf8.count) - 4
            guard bytes > 2 else { return header }
            // About 6 points a character at the card's size, and short lines: a line per 40 characters at most.
            let lines = bytes / max(20, min(40, textWidth / 6))
            return header + 25 + min(300, lines * 16)
        }
    }
}

/// The sizes of a note's card (`NoteCardCell`).
enum NoteCardMetrics {
    /// A note taller than this on its card fades out at the bottom.
    static let maxPreviewHeight: CGFloat = 300
    /// The height of an embedded view on a card.
    static let embedHeight: CGFloat = 200
    /// The height of a note's picture on its card.
    static let coverHeight: CGFloat = 110

    /// When a note last changed, in its card's footer: "Today", else Craft's short date, "Oct 18, 2026".
    static func format(_ date: Date) -> String {
        if Calendar.current.isDateInToday(date) { return String(localized: "Today") }
        return date.formatted(.dateTime.month(.abbreviated).day().year())
    }
}
