import AppKit

/// What a host is asked to draw for a fenced code block of a language it renders (` ```mermaid `): the code and the
/// look of the page, so the picture matches the text around it. Hashable: the editor keeps pictures by request.
public struct PictureRequest: Hashable, Sendable {
    /// Lowercased, as written after the opening fence (`mermaid`).
    public var language: String
    /// The text between the fences.
    public var code: String
    public var isDark: Bool
    public var colors: PictureColors
    /// A CSS font family: `-apple-system`, `ui-serif`, `ui-rounded` or a family name.
    public var fontFamily: String
    public var fontSize: CGFloat

    public init(language: String, code: String, isDark: Bool, colors: PictureColors, fontFamily: String, fontSize: CGFloat) {
        self.language = language
        self.code = code
        self.isDark = isDark
        self.colors = colors
        self.fontFamily = fontFamily
        self.fontSize = fontSize
    }
}

/// The page's colours as CSS (`#1f2225`, `rgba(0, 0, 0, 0.1)`), resolved for the editor's appearance.
public struct PictureColors: Hashable, Sendable {
    public var text: String
    public var secondaryText: String
    public var accent: String
    public var background: String
    public var codeBackground: String
    public var separator: String

    public init(text: String, secondaryText: String, accent: String, background: String, codeBackground: String, separator: String) {
        self.text = text
        self.secondaryText = secondaryText
        self.accent = accent
        self.background = background
        self.codeBackground = codeBackground
        self.separator = separator
    }
}

/// Draws the code of one language as a picture, sized in points. Nil when the code cannot be drawn (a syntax
/// error): the block then stays code.
public typealias PictureRenderer = @MainActor (PictureRequest) async -> NSImage?

extension NSAttributedString.Key {
    /// On the last character of a fenced code block drawn as a picture; the value is a `PictureMark`.
    static let markdownPicture = NSAttributedString.Key("Loam.markdownPicture")
}

/// What goes below the last line of a fenced code block, in the room the paragraph spacing of that line leaves: a
/// picture or a live view. The text view places it (`EditorTextView.blockFrames`).
protocol BlockMark: AnyObject {
    var size: NSSize { get }
    /// Where a click puts the caret, to show the code; nil while the code shows already.
    var caret: Int? { get }
}

/// A picture the text view draws below a line, in the room the paragraph spacing of that line leaves, or the place
/// of a live view it hosts there (an embed's player).
final class PictureMark: NSObject, BlockMark {
    /// What the text view draws; nil for a hosted view.
    let image: NSImage?
    /// The key of the view the text view hosts in this place, in `EditorTextView.embedViews`.
    let viewKey: String?
    let size: NSSize
    /// Where a click on the picture puts the caret, to show the code; nil while the code shows already.
    let caret: Int?
    /// The link a double click opens (an embed's); nil for a diagram.
    let destination: String?
    /// Drawn on the picture, at its bottom corner (an image's alt text).
    let caption: String?
    let cornerRadius: CGFloat
    /// Where the embed's line starts, when its width can be dragged (a still or animated picture); nil otherwise.
    let resizableLine: Int?
    /// The widest it can be dragged to: the column.
    let maxWidth: CGFloat
    /// Craft's selected block: the caret on its line (a click on it puts it there), or its code showing. It wears a
    /// ring, and its handles when it can be resized.
    let isSelected: Bool
    /// Whether a click opens it large, to zoom (a diagram), rather than showing its code (`PictureViewer`).
    let zoomable: Bool

    init(
        image: NSImage?, viewKey: String? = nil, size: NSSize, caret: Int?, destination: String? = nil,
        caption: String? = nil, cornerRadius: CGFloat = 0, resizableLine: Int? = nil, maxWidth: CGFloat = 0,
        zoomable: Bool = false, isSelected: Bool? = nil
    ) {
        self.isSelected = isSelected ?? (caret == nil)
        self.zoomable = zoomable
        self.image = image
        self.viewKey = viewKey
        self.size = size
        self.caret = caret
        self.destination = destination
        self.caption = caption
        self.cornerRadius = cornerRadius
        self.resizableLine = resizableLine
        self.maxWidth = maxWidth
    }

    /// Equal when it draws the same thing in the same place: setting an equal mark again is skipped
    /// (`NSTextStorage.setIfChanged`).
    override func isEqual(_ object: Any?) -> Bool {
        guard let other = object as? PictureMark else { return false }
        return image === other.image && viewKey == other.viewKey && size == other.size && caret == other.caret
            && destination == other.destination && caption == other.caption && cornerRadius == other.cornerRadius
            && resizableLine == other.resizableLine && maxWidth == other.maxWidth && isSelected == other.isSelected
            && zoomable == other.zoomable
    }

    override var hash: Int { viewKey.hashValue ^ (caret ?? -1) }

    /// The narrowest a picture is dragged to.
    static let minWidth: CGFloat = 48

    /// The room above and below a picture.
    static let margin: CGFloat = 10
}

/// The pictures already drawn, by request, at most `limit` of them, the least recently used going first. Requests
/// that could not be drawn are remembered too, so a syntax error is not drawn again on every restyle. Editors share
/// `shared`, so a note opened again (back, forward, another tab) shows its diagrams at once instead of drawing them
/// again; what each editor is waiting for stays its own (`EditorController.drawingPictures`).
@MainActor
final class PictureCache {
    static let shared = PictureCache()

    private var images: [PictureRequest: NSImage] = [:]
    private var order: [PictureRequest] = []
    private(set) var failed: Set<PictureRequest> = []
    let limit: Int

    init(limit: Int = 64) {
        self.limit = limit
    }

    func image(for request: PictureRequest) -> NSImage? {
        guard let image = images[request] else { return nil }
        if let index = order.firstIndex(of: request) {
            order.remove(at: index)
            order.append(request)
        }
        return image
    }

    func store(_ image: NSImage?, for request: PictureRequest) {
        guard let image else {
            // Every keystroke of a diagram being typed can fail: forget the oldest failures now and then.
            if failed.count >= 4 * limit { failed.removeAll() }
            failed.insert(request)
            return
        }
        images[request] = image
        order.removeAll { $0 == request }
        order.append(request)
        while order.count > limit {
            images[order.removeFirst()] = nil
        }
    }

    /// Whether `request` still needs drawing: never drawn, and not failing.
    func needs(_ request: PictureRequest) -> Bool {
        images[request] == nil && !failed.contains(request)
    }
}

extension EditorController {
    /// Draws the fenced code blocks of the languages a host renders as pictures, after the theme styled the text.
    /// Outside the block the picture takes its place (the code is hidden, as hidden syntax is); with the caret
    /// inside, the code shows and the picture stays under it, following the typing. A block whose picture is not
    /// there yet asks for it and stays code until it comes; a block whose code cannot be drawn stays code, or keeps
    /// its last picture while the caret is in it.
    func applyPictures(_ spans: [StyleSpan], to storage: NSTextStorage, revealing selection: NSRange) {
        guard let textView, !pictureRenderers.isEmpty else {
            lastPictures = [:]
            return
        }
        let ns = storage.string as NSString
        let appearance = textView.effectiveAppearance
        let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let colors = theme.pictureColors(in: appearance)
        let available = textView.columnWidth
        var ordinal = 0
        var shown: [Int: NSImage] = [:]
        for span in spans {
            // A live view, when a host has one for the language, wins over a picture.
            guard case .fencedCode(let language, let code) = span.style, let renderer = pictureRenderers[language],
                  liveBlockProviders[language] == nil else { continue }
            defer { ordinal += 1 }
            let request = PictureRequest(
                language: language, code: ns.substring(with: code), isDark: isDark, colors: colors,
                fontFamily: theme.cssFontFamily, fontSize: theme.fontSize
            )
            let fresh = pictures.image(for: request)
            if fresh == nil, pictures.needs(request), !drawingPictures.contains(request) { draw(request, with: renderer) }
            let editing = syntaxMode == .source || MarkdownTheme.enters(selection, span.range)
            // The last picture of this block stands in while a new one is on its way, or while the code being typed
            // does not draw, so the text below does not jump.
            let stale = editing || drawingPictures.contains(request) ? lastPictures[ordinal] : nil
            guard let image = fresh ?? stale else { continue }
            shown[ordinal] = image
            let scale = min(1, available / max(image.size.width, 1))
            let size = NSSize(width: image.size.width * scale, height: image.size.height * scale)
            if !editing {
                storage.setIfChanged(MarkdownTheme.concealed, range: span.range)
                storage.collapseLines(of: span.range)
            }
            let last = NSMaxRange(span.range) - 1
            let paragraph = ns.paragraphRange(for: NSRange(location: last, length: 0))
            let current = editing ? storage.attribute(.paragraphStyle, at: paragraph.location, effectiveRange: nil) as? NSParagraphStyle
                : NSTextStorage.collapsedLine
            let style = current?.mutableCopy() as? NSMutableParagraphStyle ?? NSMutableParagraphStyle()
            style.paragraphSpacing = size.height + 2 * PictureMark.margin
            storage.setIfChanged([.paragraphStyle: style], range: paragraph)
            storage.setIfChanged(
                [.markdownPicture: PictureMark(image: image, size: size, caret: editing ? nil : code.location, zoomable: true)],
                range: NSRange(location: last, length: 1)
            )
        }
        lastPictures = shown
    }

    /// The code page of the diagram whose code starts at `start` (`PictureViewer`): its code, drawn again as it
    /// changes, and written back into the block as one undoable edit each time.
    func codeEditing(at start: Int) -> PictureViewer.CodeEditing? {
        if blockSession != nil { return blockCodeEditing(at: start) }
        guard let textView, let found = fencedCode(at: start), let renderer = pictureRenderers[found.language] else { return nil }
        let ns = textView.string as NSString
        let language = found.language
        return PictureViewer.CodeEditing(
            code: ns.substring(with: found.code),
            render: { [weak self] code in
                guard let self, let textView = self.textView else { return nil }
                let appearance = textView.effectiveAppearance
                let request = PictureRequest(
                    language: language, code: code, isDark: appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua,
                    colors: self.theme.pictureColors(in: appearance), fontFamily: self.theme.cssFontFamily, fontSize: self.theme.fontSize
                )
                if let image = self.pictures.image(for: request) { return image }
                let image = await renderer(request)
                self.pictures.store(image, for: request)
                return image
            },
            commit: { [weak self] code in
                guard let self, let textView = self.textView, let block = self.fencedCode(at: start) else { return }
                let selection = textView.selectedRange()
                let delta = (code as NSString).length - block.code.length
                // The caret stays out of the block, so the note shows the diagram when the code page closes.
                let caret = selection.location < block.whole.location ? selection.location
                    : selection.location >= NSMaxRange(block.whole) ? selection.location + delta
                    : max(0, block.whole.location - 1)
                self.applyEdit(TextEdit(range: block.code, replacement: code, selection: NSRange(location: caret, length: 0)))
            }
        )
    }

    /// The fenced block whose code starts at `start`, from the last restyle.
    private func fencedCode(at start: Int) -> (language: String, code: NSRange, whole: NSRange)? {
        for span in styledSpans {
            if case .fencedCode(let language, let code) = span.style, code.location == start {
                return (language, code, span.range)
            }
        }
        return nil
    }

    /// Asks the host for a picture, and restyles when it comes.
    /// The picture is kept even when the editor closed meanwhile, for the next one that shows the note.
    private func draw(_ request: PictureRequest, with renderer: @escaping PictureRenderer) {
        drawingPictures.insert(request)
        let pictures = pictures
        Task { [weak self] in
            let image = await renderer(request)
            pictures.store(image, for: request)
            guard let self else { return }
            self.drawingPictures.remove(request)
            self.restyle(everything: true)
        }
    }
}

extension MarkdownTheme {
    /// The body family as CSS.
    var cssFontFamily: String {
        switch bodyFamily {
        case .system(.serif): "ui-serif"
        case .system(.rounded): "ui-rounded"
        case .system(.monospaced): "ui-monospace"
        case .system: "-apple-system"
        case .named(let name): "\"\(name)\""
        }
    }

    func pictureColors(in appearance: NSAppearance) -> PictureColors {
        var colors = PictureColors(text: "", secondaryText: "", accent: "", background: "", codeBackground: "", separator: "")
        appearance.performAsCurrentDrawingAppearance {
            colors = PictureColors(
                text: Self.css(textColor),
                secondaryText: Self.css(secondaryTextColor),
                accent: Self.css(accentColor),
                background: Self.css(backgroundColor),
                codeBackground: Self.css(codeBackgroundColor),
                separator: Self.css(textColor.withAlphaComponent(0.18))
            )
        }
        return colors
    }

    /// `#rrggbb`, or `rgba(...)` when not opaque. Call inside the appearance the colour should resolve in.
    static func css(_ color: NSColor) -> String {
        guard let rgb = color.usingColorSpace(.sRGB) else { return "#808080" }
        let r = Int((rgb.redComponent * 255).rounded()), g = Int((rgb.greenComponent * 255).rounded())
        let b = Int((rgb.blueComponent * 255).rounded())
        if rgb.alphaComponent >= 0.999 { return String(format: "#%02x%02x%02x", r, g, b) }
        return String(format: "rgba(%d, %d, %d, %.3f)", r, g, b, rgb.alphaComponent)
    }
}

extension NSTextStorage {
    /// The lines of a block drawn as a picture or a view take no room: its code block's padding and the spacing of
    /// each hidden line made an empty band above the picture, where the caret stood alone and a click opened the code.
    /// The last line is left to the caller, which gives `collapsedLine` the spacing below that holds the picture.
    func collapseLines(of range: NSRange) {
        guard range.length > 0, NSMaxRange(range) <= length else { return }
        let ns = string as NSString
        let last = ns.paragraphRange(for: NSRange(location: NSMaxRange(range) - 1, length: 0))
        var location = range.location
        while location < last.location {
            let paragraph = ns.paragraphRange(for: NSRange(location: location, length: 0))
            location = NSMaxRange(paragraph)
            setIfChanged([.paragraphStyle: Self.collapsedLine], range: paragraph)
        }
    }

    /// A hidden line with no spacing around it: its vanishing font leaves it about a point high. (A line squeezed
    /// to no height at all threw off the estimate TextKit 2 makes of where the text after it goes.)
    nonisolated(unsafe) static let collapsedLine = NSParagraphStyle()

    /// Sets `attributes` over `range`, each unless it is there already. Any attribute set, even to the value it has,
    /// makes TextKit 2 lay the paragraph out again; a picture's paragraph laid out again is placed for a moment
    /// without its height, so everything under it jumps on each keystroke or move.
    func setIfChanged(_ attributes: [NSAttributedString.Key: Any], range: NSRange) {
        guard range.length > 0, NSMaxRange(range) <= length else { return }
        for (key, value) in attributes {
            var effective = NSRange()
            let current = attribute(key, at: range.location, longestEffectiveRange: &effective, in: range) as? NSObject
            if let current, NSEqualRanges(effective, range), current.isEqual(value) { continue }
            addAttribute(key, value: value, range: range)
        }
    }
}
