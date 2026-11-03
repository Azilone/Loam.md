import PluginKitUI
import AppKit

/// A file dropped on the editor or pasted into it.
public enum DroppedFile: Equatable, Sendable {
    /// A file on disk (from Finder).
    case file(URL)
    /// Bytes and the extension of their format (`png`): a picture copied to the clipboard.
    case data(Data, pathExtension: String)
}

/// An image link alone on its line, as the host is asked to show it.
public struct EmbedLink: Hashable, Sendable {
    /// As written, `../assets/My%20clip.mp4`.
    public var destination: String
    /// The link's text, `![this](...)`.
    public var alt: String

    public init(destination: String, alt: String) {
        self.destination = destination
        self.alt = alt
    }
}

/// What the host shows for an embed: a picture the editor draws, or a view it hosts in the text.
public struct Embed {
    public enum Content {
        case image(NSImage)
        /// Made once per link in the note and kept while it stays (a playing video keeps playing as you type).
        case view(@MainActor () -> NSView)
    }

    public var content: Content
    /// Its size in points when the column has room: scaled down to the column, ratio kept, unless `keepsHeight`.
    public var size: NSSize
    /// Takes the column's width (up to `size.width`) at `size.height`: a player bar, a card.
    public var keepsHeight: Bool
    /// Whether clicks go to the view (a player's controls) rather than to the text (caret on the line, double click
    /// opens the file).
    public var isInteractive: Bool

    public init(content: Content, size: NSSize, keepsHeight: Bool = false, isInteractive: Bool = false) {
        self.content = content
        self.size = size
        self.keepsHeight = keepsHeight
        self.isInteractive = isInteractive
    }

    /// The tallest an embed that scales is shown, so a portrait photo does not fill several pages.
    static let maxHeight: CGFloat = 560

    /// The size it is shown at in a column `width` wide. A `requested` width (the note's `|300`) wins over the
    /// natural size, up to the column, the ratio kept; a card or bar (`keepsHeight`) ignores it.
    func displaySize(in width: CGFloat, requested: CGFloat? = nil) -> NSSize {
        if keepsHeight { return NSSize(width: floor(min(size.width, width)), height: size.height) }
        if let requested {
            let shown = min(max(requested, 1), width)
            return NSSize(width: floor(shown), height: floor(size.height * shown / max(size.width, 1)))
        }
        let scale = min(1, width / max(size.width, 1), Self.maxHeight / max(size.height, 1))
        return NSSize(width: floor(size.width * scale), height: floor(size.height * scale))
    }
}

/// How a host shows image links alone on their line (`MarkdownStyle.embed`).
public struct EmbedProvider {
    /// Changes when the host shows other kinds of files: the editor then asks again for every embed.
    public var id: String
    /// What `link` points to as a key, one embed per key (the file and its version, so a changed file is shown
    /// again); nil when the host does not show it, and the link stays text. Called at every restyle: keep it cheap.
    public var identify: @MainActor (EmbedLink) -> String?
    /// The embed of a link `identify` gave a key for; nil when it cannot be shown.
    public var render: @MainActor (EmbedLink) async -> Embed?

    public init(
        id: String,
        identify: @escaping @MainActor (EmbedLink) -> String?,
        render: @escaping @MainActor (EmbedLink) async -> Embed?
    ) {
        self.id = id
        self.identify = identify
        self.render = render
    }
}

/// The embeds already loaded, by key, at most `limit`, the least recently used going first; keys that could not be
/// shown are remembered, so a broken file is not loaded again on every restyle.
struct EmbedCache {
    private var embeds: [String: Embed] = [:]
    private var order: [String] = []
    private var failed: Set<String> = []
    var pending: Set<String> = []
    let limit = 64

    mutating func embed(for key: String) -> Embed? {
        guard let embed = embeds[key] else { return nil }
        if let index = order.firstIndex(of: key) {
            order.remove(at: index)
            order.append(key)
        }
        return embed
    }

    mutating func store(_ embed: Embed?, for key: String) {
        pending.remove(key)
        guard let embed else {
            failed.insert(key)
            return
        }
        embeds[key] = embed
        order.removeAll { $0 == key }
        order.append(key)
        while order.count > limit { embeds[order.removeFirst()] = nil }
    }

    func needs(_ key: String) -> Bool {
        embeds[key] == nil && !failed.contains(key) && !pending.contains(key)
    }
}

/// Holds an embed's view in the text: clips it to rounded corners, and lets clicks through to the text unless the
/// view takes them (a player's controls).
final class EmbedHostView: NSView {
    let isInteractive: Bool

    init(_ content: NSView, isInteractive: Bool, cornerRadius: CGFloat) {
        self.isInteractive = isInteractive
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = cornerRadius
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        content.frame = bounds
        content.autoresizingMask = [.width, .height]
        addSubview(content)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        isInteractive ? super.hitTest(point) : nil
    }
}

extension EditorController {
    /// Shows the image links alone on their line that the host shows as embeds: outside the line the embed takes its
    /// place (the link hidden, as hidden syntax is); with the caret on the line, the link shows with the embed under
    /// it. A link whose embed is not there yet asks for it and stays text until it comes.
    func applyEmbeds(_ spans: [StyleSpan], to storage: NSTextStorage, revealing selection: NSRange) {
        guard let textView else { return }
        guard let provider = embeds else {
            textView.embedViews = [:]
            return
        }
        let ns = storage.string as NSString
        let available = textView.columnWidth
        var views: [String: NSView] = [:]
        var occurrences: [String: Int] = [:]
        for span in spans {
            guard case .embed(let destination, let alt) = span.style else { continue }
            let (caption, written) = ImageSize.split(alt)
            let link = EmbedLink(destination: destination, alt: caption)
            guard let key = provider.identify(link) else { continue }
            let found = embedCache.embed(for: key)
            if found == nil, embedCache.needs(key) { load(key, link, with: provider) }
            guard let embed = found else { continue }
            // The link shows only as source: a page shows the picture, whatever the caret does.
            let editing = syntaxMode == .source
            let selected = editing || (selection.length == 0 && selection.location >= span.range.location
                && selection.location <= NSMaxRange(span.range))
            // While a handle is dragged, the width follows the mouse; the note changes when it is let go.
            let requested = resizing?.line == span.range.location ? resizing?.width : written.map { CGFloat($0) }
            let size = embed.displaySize(in: available, requested: requested)
            if !editing { storage.setIfChanged(MarkdownTheme.concealed, range: span.range) }
            let paragraph = ns.paragraphRange(for: span.range)
            let style = (storage.attribute(.paragraphStyle, at: paragraph.location, effectiveRange: nil) as? NSParagraphStyle)?
                .mutableCopy() as? NSMutableParagraphStyle ?? NSMutableParagraphStyle()
            style.paragraphSpacing = size.height + 2 * PictureMark.margin
            storage.setIfChanged([.paragraphStyle: style], range: paragraph)

            let resizable = !embed.keepsHeight && !embed.isInteractive
            var image: NSImage?
            var viewKey: String?
            switch embed.content {
            case .image(let picture):
                image = picture
            case .view(let make):
                // The same file twice in a note is two views.
                let index = occurrences[key, default: 0]
                occurrences[key] = index + 1
                let occurrence = key + "#\(index)"
                views[occurrence] = textView.embedViews[occurrence]
                    ?? EmbedHostView(make(), isInteractive: embed.isInteractive, cornerRadius: Corners.r(Self.embedCornerRadius))
                viewKey = occurrence
            }
            storage.setIfChanged(
                [.markdownPicture: PictureMark(
                    image: image, viewKey: viewKey, size: size, caret: editing ? nil : NSMaxRange(span.range),
                    destination: destination, caption: caption.isEmpty ? nil : caption, cornerRadius: Corners.r(Self.embedCornerRadius),
                    resizableLine: resizable ? span.range.location : nil, maxWidth: available, isSelected: selected
                )],
                range: NSRange(location: NSMaxRange(span.range) - 1, length: 1)
            )
        }
        textView.embedViews = views
    }

    /// Craft's slightly rounded pictures.
    static let embedCornerRadius: CGFloat = 6

    /// A picture's width being dragged: the line it is on, and the width so far.
    struct Resizing {
        var line: Int
        var width: CGFloat
    }

    /// Follows a handle: the picture takes `width` at once, the note stays as it is.
    func resizePicture(line: Int, to width: CGFloat) {
        resizing = Resizing(line: line, width: width)
        // The picture's top stays where it is on screen while it grows or shrinks.
        guard let textView else { return restyle(everything: true) }
        textView.keepingOnScreen(line, then: { line }) { restyle(everything: true) }
    }

    /// The handle was let go: the width goes into the note as one edit (one undo), or stays out of it when the drag
    /// was cancelled (`width` nil).
    func finishResizingPicture(line: Int, width: CGFloat?) {
        resizing = nil
        if blockSession != nil {
            guard let width else { return restyle() }
            return finishResizingBlockPicture(at: line, width: width)
        }
        guard let textView, let storage = textView.textStorage, let width else {
            restyle(everything: true)
            return
        }
        let ns = storage.string as NSString
        guard line < ns.length else { return }
        let lineRange = ns.lineWithoutBreak(at: line)
        let text = ns.substring(with: lineRange)
        guard let alt = ImageSize.altRange(inImageLine: text) else { return }
        let old = NSRange(alt, in: text)
        let replacement = ImageSize.alt(String(text[alt]), width: Int(width.rounded()))
        let range = NSRange(location: lineRange.location + old.location, length: old.length)
        guard replacement != ns.substring(with: range), textView.shouldChangeText(in: range, replacementString: replacement) else {
            restyle(everything: true)
            return
        }
        let selection = textView.selectedRange()
        storage.replaceCharacters(in: range, with: replacement)
        textView.didChangeText()
        let shift = (replacement as NSString).length - range.length
        textView.setSelectedRange(NSRange(location: selection.location >= NSMaxRange(range) ? selection.location + shift : selection.location, length: 0))
    }

    /// Asks the host for an embed, and restyles when it comes.
    private func load(_ key: String, _ link: EmbedLink, with provider: EmbedProvider) {
        embedCache.pending.insert(key)
        Task { [weak self] in
            let embed = await provider.render(link)
            guard let self else { return }
            self.embedCache.store(embed, for: key)
            self.restyle(everything: true)
            self.settleAfterEmbeds()
        }
    }

    /// Where `markdown` goes for files dropped at `location`: as lines of their own, on a new line when the line
    /// has text before `location`, with a line break after unless one follows; the caret on the line after.
    nonisolated static func blockInsertion(_ markdown: String, at location: Int, in text: String) -> TextEdit {
        let ns = text as NSString
        var location = min(max(location, 0), ns.length)
        // Inside a table the links go after it, after a blank line (a line right under a row would become a row).
        let tableEnd = Self.endOfTable(containing: location, in: ns)
        if let tableEnd { location = tableEnd }
        let lineStart = ns.lineRange(for: NSRange(location: location, length: 0)).location
        let before = ns.substring(with: NSRange(location: lineStart, length: location - lineStart))
        let lead = tableEnd != nil ? "\n\n" : before.trimmingCharacters(in: .whitespaces).isEmpty ? "" : "\n"
        let followedByBreak = location < ns.length && ns.character(at: location) == 10
        let replacement = lead + markdown + (followedByBreak ? "" : "\n")
        let caret = location + (replacement as NSString).length + (followedByBreak ? 1 : 0)
        return TextEdit(range: NSRange(location: location, length: 0), replacement: replacement, selection: NSRange(location: caret, length: 0))
    }

    /// The end (before its line break) of the table whose row holds `location`; nil when that line is no table row.
    /// A row is a line whose first character, after spaces, is a pipe.
    nonisolated private static func endOfTable(containing location: Int, in text: NSString) -> Int? {
        func isRow(_ range: NSRange) -> Bool {
            text.substring(with: range).trimmingCharacters(in: .whitespaces).hasPrefix("|")
        }
        var line = text.lineRange(for: NSRange(location: location, length: 0))
        guard isRow(line) else { return nil }
        var end = line
        while NSMaxRange(end) < text.length {
            line = text.lineRange(for: NSRange(location: NSMaxRange(end), length: 0))
            guard isRow(line) else { break }
            end = line
        }
        var result = NSMaxRange(end)
        while result > end.location, [10, 13].contains(text.character(at: result - 1)) { result -= 1 }
        return result
    }

    /// `insertion` (from `blockInsertion`) for a drop whose files took a while: the caret goes after the new link only
    /// when it still sits where the drop happened. If the user typed or moved meanwhile, the caret stays with their
    /// text (shifted when the link lands before it), so late links never pull what is typed next out of place.
    nonisolated static func keepingCaret(_ insertion: TextEdit, caret: NSRange, droppedAt location: Int) -> TextEdit {
        if caret.length == 0, caret.location == location { return insertion }
        var kept = caret
        if kept.location >= insertion.range.location {
            kept.location += (insertion.replacement as NSString).length
        }
        return TextEdit(range: insertion.range, replacement: insertion.replacement, selection: kept)
    }
}

/// Reads dropped and pasted files from a pasteboard.
enum FilePasteboard {
    /// The picture formats read as data, best first, with the extension they are saved under. TIFF (what most apps
    /// copy) is saved as PNG.
    static let imageTypes: [(type: NSPasteboard.PasteboardType, pathExtension: String)] = [
        (.png, "png"),
        (NSPasteboard.PasteboardType("public.jpeg"), "jpg"),
        (NSPasteboard.PasteboardType("com.compuserve.gif"), "gif"),
        (NSPasteboard.PasteboardType("public.heic"), "heic"),
        (.tiff, "png"),
    ]

    /// Every type the editor takes as files.
    static var types: [NSPasteboard.PasteboardType] { [.fileURL] + imageTypes.map(\.type) }

    /// The files on `pasteboard`: its file URLs, or the picture it holds; nil for anything else (text). For a paste,
    /// text wins over a picture (a cell copied from a spreadsheet carries a picture of itself), unless the text is
    /// only the picture's address (a browser's Copy Image).
    static func files(on pasteboard: NSPasteboard, forPaste: Bool) -> [DroppedFile]? {
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           !urls.isEmpty {
            return urls.map { .file($0) }
        }
        guard let image = imageTypes.first(where: { pasteboard.availableType(from: [$0.type]) != nil }) else { return nil }
        if forPaste, let text = pasteboard.string(forType: .string), !isAddress(text) { return nil }
        guard var data = pasteboard.data(forType: image.type) else { return nil }
        if image.type == .tiff, let png = NSBitmapImageRep(data: data)?.representation(using: .png, properties: [:]) {
            data = png
        }
        return [.data(data, pathExtension: image.pathExtension)]
    }

    private static func isAddress(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.contains(where: \.isWhitespace), let url = URL(string: trimmed) else { return false }
        return url.scheme != nil
    }
}
