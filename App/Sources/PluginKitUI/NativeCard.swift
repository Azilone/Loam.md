import AppKit
import SwiftUI

// The note cards of the grids (All Notes, a folder page, a collection's gallery) in AppKit. A grid makes dozens of
// cards when it opens and more as it scrolls: one SwiftUI hosting view per card cost a page 250-450 ms to open
// (docs/APPKIT.md). These draw the same card with layers and Core Text, and are reused from card to card.

public extension NSFont {
    /// The app's own text at `size`, as `Font.ui(size:weight:)`: the system font, or the interface's family.
    static func ui(size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        switch InterfaceFont.family {
        case .system(let design):
            let base = NSFont.systemFont(ofSize: size, weight: weight)
            let systemDesign: NSFontDescriptor.SystemDesign = switch design {
            case .default: .default
            case .serif: .serif
            case .monospaced: .monospaced
            case .rounded: .rounded
            }
            guard systemDesign != .default, let descriptor = base.fontDescriptor.withDesign(systemDesign) else { return base }
            return NSFont(descriptor: descriptor, size: size) ?? base
        case .named(let name):
            let descriptor = NSFontDescriptor(fontAttributes: [
                .family: name, .traits: [NSFontDescriptor.TraitKey.weight: weight],
            ])
            return NSFont(descriptor: descriptor, size: size) ?? .systemFont(ofSize: size, weight: weight)
        }
    }
}

public extension NSFont {
    /// `family` at `size`, as `Font.theme(_:size:)`.
    static func theme(_ family: ThemeFontFamily, size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        switch family {
        case .system(.monospaced): return NSFont.monospacedSystemFont(ofSize: size, weight: weight)
        case .system(let design):
            let base = NSFont.systemFont(ofSize: size, weight: weight)
            let systemDesign: NSFontDescriptor.SystemDesign = design == .serif ? .serif : design == .rounded ? .rounded : .default
            return base.fontDescriptor.withDesign(systemDesign).flatMap { NSFont(descriptor: $0, size: size) } ?? base
        case .named(let name): return NSFont(name: name, size: size) ?? .systemFont(ofSize: size, weight: weight)
        }
    }
}

/// A menu item that runs a closure, for menus built in AppKit.
public final class ActionMenuItem: NSMenuItem {
    private let run: () -> Void

    public init(_ title: String, symbol: String? = nil, run: @escaping () -> Void) {
        self.run = run
        super.init(title: title, action: #selector(runAction), keyEquivalent: "")
        target = self
        if let symbol { image = NSImage.symbol(symbol, accessibilityDescription: nil) }
    }

    required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc private func runAction() { run() }
}

/// A symbol drawn in `color` at `size` points, for a layer or an image view.
public func tintedSymbol(_ name: String, size: CGFloat, weight: NSFont.Weight = .regular, color: NSColor) -> NSImage? {
    let configuration = NSImage.SymbolConfiguration(pointSize: size, weight: weight)
        .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
    return NSImage.symbol(name, accessibilityDescription: nil)?.withSymbolConfiguration(configuration)
}

// MARK: - Text

/// A note's first blocks as attributed text, as `NotePreviewView` draws them on a card: headings bolder, lists with
/// bullets or numbers, tasks with a box, quotes with a bar, code in the mono face, inline bold, italics, links and tags.
public enum NotePreviewText {
    /// `singleLines`: each block on one line, cut at its end (a gallery's cover, where the note is a glimpse).
    public static func attributed(_ preview: NotePreview, size: CGFloat = 10, singleLines: Bool = false, theme: ThemeTokens) -> NSAttributedString {
        let k = size / 10
        let result = NSMutableAttributedString()
        let body = NSFont.ui(size: size)
        let text = NSColor(theme.text).withAlphaComponent(0.82)
        let secondary = NSColor(theme.secondaryText)
        for (index, block) in preview.blocks.enumerated() {
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineSpacing = 1.5 * k
            paragraph.paragraphSpacingBefore = index == 0 ? 0 : 3 * k
            paragraph.lineBreakMode = singleLines ? .byTruncatingTail : .byWordWrapping
            var line = NSMutableAttributedString()
            switch block {
            case .heading(let level, let content):
                let sizes: [CGFloat] = [1.2, 1.1, 1.05, 1.05]
                let font = NSFont.ui(size: size * sizes[min(max(level, 1), 4) - 1], weight: level <= 2 ? .bold : .semibold)
                line = inline(content, font: font, color: NSColor(theme.text), theme: theme)
                if index > 0 { paragraph.paragraphSpacingBefore = 8 * k }
            case .bullet(let depth, let content):
                line = marked("\u{2022}", depth: depth, content, font: body, color: text, marker: secondary, k: k, paragraph: paragraph, theme: theme)
            case .ordered(let number, let depth, let content):
                line = marked(number + ".", depth: depth, content, font: body, color: text, marker: secondary, k: k, paragraph: paragraph, theme: theme)
            case .task(let depth, let done, let content):
                let color = done ? secondary.withAlphaComponent(0.7) : text
                line = marked("\u{2022}", depth: depth, content, font: body, color: color, marker: secondary, k: k, paragraph: paragraph, theme: theme)
                // The box in place of the bullet: a rounded square, filled with the accent when done.
                let box = NSTextAttachment()
                box.image = tintedSymbol(done ? "checkmark.square.fill" : "square", size: 8.5 * k, color: done ? NSColor(theme.accent) : secondary)
                box.bounds = CGRect(x: 0, y: -1 * k, width: 9 * k, height: 9 * k)
                line.replaceCharacters(in: NSRange(location: 0, length: 1), with: NSAttributedString(attachment: box))
                if done {
                    line.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue,
                                      range: NSRange(location: 2, length: max(0, line.length - 2)))
                }
            case .quote(let content):
                line = NSMutableAttributedString(string: "\u{258F} ", attributes: [.font: body, .foregroundColor: NSColor(theme.text).withAlphaComponent(0.7)])
                line.append(inline(content, font: body, color: NSColor(theme.text).withAlphaComponent(0.75), theme: theme))
            case .code(let content):
                line = code(content, k: k, theme: theme)
            case .fenced(_, let content):
                for (number, codeLine) in content.components(separatedBy: "\n").prefix(8).enumerated() {
                    if number > 0 { line.append(NSAttributedString(string: "\n")) }
                    line.append(code(codeLine, k: k, theme: theme))
                }
            case .tableRow(let cells, let header):
                let font = NSFont.ui(size: 9.5 * k, weight: header ? .semibold : .regular)
                for (number, cell) in cells.enumerated() {
                    if number > 0 { line.append(NSAttributedString(string: "  \u{2502}  ", attributes: [.font: font, .foregroundColor: secondary.withAlphaComponent(0.5)])) }
                    line.append(inline(cell, font: font, color: text, theme: theme))
                }
                paragraph.lineBreakMode = .byTruncatingTail
            case .paragraph(let content):
                line = inline(content, font: body, color: text, theme: theme)
            }
            if index > 0 { result.append(NSAttributedString(string: "\n")) }
            line.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: line.length))
            result.append(line)
        }
        return result
    }

    private static func marked(_ marker: String, depth: Int, _ content: String, font: NSFont, color: NSColor, marker markerColor: NSColor,
                               k: CGFloat, paragraph: NSMutableParagraphStyle, theme: ThemeTokens) -> NSMutableAttributedString {
        let line = NSMutableAttributedString(string: marker + " ", attributes: [.font: font, .foregroundColor: markerColor])
        line.append(inline(content, font: font, color: color, theme: theme))
        let indent = CGFloat(depth) * 10 * k
        paragraph.firstLineHeadIndent = indent
        paragraph.headIndent = indent + (marker as NSString).size(withAttributes: [.font: font]).width + 4 * k
        return line
    }

    private static func code(_ content: String, k: CGFloat, theme: ThemeTokens) -> NSMutableAttributedString {
        NSMutableAttributedString(string: content.isEmpty ? " " : content, attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 9 * k, weight: .regular),
            .foregroundColor: NSColor(theme.accent).withAlphaComponent(0.85),
            .backgroundColor: NSColor(theme.codeBackground),
        ])
    }

    private static let htmlTag = try? NSRegularExpression(pattern: #"</?[A-Za-z][^>]*>"#)

    /// Bold, italic, code and links through Foundation's inline Markdown, HTML tags left out, `==highlights==`,
    /// wikilinks and tags in the link colour.
    public static func inline(_ content: String, font: NSFont, color: NSColor, theme: ThemeTokens) -> NSMutableAttributedString {
        let result = NSMutableAttributedString()
        let link = NSColor(theme.link)
        for run in InlineRun.split(content) {
            switch run {
            case .text(var plain):
                if plain.contains("<"), let htmlTag {
                    plain = htmlTag.stringByReplacingMatches(in: plain, range: NSRange(plain.startIndex..., in: plain), withTemplate: "")
                }
                let pieces = plain.components(separatedBy: "==")
                for (index, piece) in pieces.enumerated() {
                    let part = markdown(piece, font: font, color: color, link: link, theme: theme)
                    if index % 2 == 1, pieces.count > 2 {
                        part.addAttribute(.backgroundColor, value: theme.palette.highlight.map { NSColor(Color($0)) } ?? NSColor.systemYellow.withAlphaComponent(0.35),
                                          range: NSRange(location: 0, length: part.length))
                    }
                    result.append(part)
                }
            case .link(let name):
                result.append(NSAttributedString(string: name, attributes: [.font: font, .foregroundColor: link]))
            case .tag(let tag):
                result.append(NSAttributedString(string: "#" + tag, attributes: [.font: font, .foregroundColor: link]))
            }
        }
        return result
    }

    private static func markdown(_ text: String, font: NSFont, color: NSColor, link: NSColor, theme: ThemeTokens) -> NSMutableAttributedString {
        // Most lines have no inline syntax: no parse for them.
        guard text.contains(where: { "*_`[".contains($0) }) else {
            return NSMutableAttributedString(string: text, attributes: [.font: font, .foregroundColor: color])
        }
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        guard let parsed = try? AttributedString(markdown: text, options: options) else {
            return NSMutableAttributedString(string: text, attributes: [.font: font, .foregroundColor: color])
        }
        let result = NSMutableAttributedString()
        for run in parsed.runs {
            let piece = String(parsed[run.range].characters)
            var runFont = font
            var attributes: [NSAttributedString.Key: Any] = [.foregroundColor: color]
            if let intent = run.inlinePresentationIntent {
                var traits: NSFontDescriptor.SymbolicTraits = []
                if intent.contains(.stronglyEmphasized) { traits.insert(.bold) }
                if intent.contains(.emphasized) { traits.insert(.italic) }
                if !traits.isEmpty {
                    runFont = NSFont(descriptor: font.fontDescriptor.withSymbolicTraits(traits), size: font.pointSize) ?? font
                }
                if intent.contains(.code) {
                    runFont = NSFont.monospacedSystemFont(ofSize: font.pointSize * 0.92, weight: .regular)
                    attributes[.backgroundColor] = NSColor(theme.codeBackground)
                }
                if intent.contains(.strikethrough) { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            }
            if run.link != nil { attributes[.foregroundColor] = link }
            attributes[.font] = runFont
            result.append(NSAttributedString(string: piece, attributes: attributes))
        }
        return result
    }
}

/// A view drawn once into a bitmap kept as its layer's contents: shown again (a kept page coming back, a card
/// scrolled back into view) it costs nothing, where `draw(_:)` would draw it again. Subclasses draw in `drawContent`
/// and call `invalidate()` when what they draw changes.
///
/// A subclass in this module that can draw off the main thread (`backgroundDrawing`, `CardTextView`) is drawn again there when only its size
/// changed (a column narrowing as a sidebar slides in, a window resized): it keeps showing its last drawing, at its
/// top left and unstretched, until the new one is ready, and no frame waits for it. Its first drawing, and one after
/// `invalidate()`, is made at once on the main thread, so a card coming into view never shows empty.
open class CachedDrawingView: NSView {
    private typealias Rendered = (size: CGSize, scale: CGFloat, appearance: NSAppearance.Name, image: CGImage)
    /// The drawings at the last two sizes: a card going back and forth between two widths finds both.
    private var rendered: [Rendered] = []
    /// Grows at each `invalidate()`: a drawing started off the main thread before it is thrown away.
    private var contentGeneration = 0
    /// The size of the drawing being made off the main thread, if one is: one at a time per view.
    private var drawingSize: CGSize?

    nonisolated private static let bitmapInfo = HalftoneImages.bitmapInfo

    /// The queue drawings are made on off the main thread.
    nonisolated static let drawingQueue = DispatchQueue(label: "loam.card-drawing", qos: .userInitiated, attributes: .concurrent)

    open override var isFlipped: Bool { true }
    open override var isOpaque: Bool { false }
    open override var wantsUpdateLayer: Bool { true }
    open override func hitTest(_ point: NSPoint) -> NSView? { nil }

    public override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        // A drawing of a larger size, shown until its successor is ready, stays inside the view.
        layer?.masksToBounds = true
    }

    required public init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// The display's colour space: an sRGB bitmap on a P3 screen was converted pixel by pixel when its layer was
    /// committed, ~1 ms a table row on the main thread.
    static func drawingSpace(for window: NSWindow?) -> CGColorSpace {
        guard let space = (window?.screen ?? NSScreen.main)?.colorSpace?.cgColorSpace, space.model == .rgb else {
            return CGColorSpace(name: CGColorSpace.sRGB)!
        }
        return space
    }

    public func invalidate() {
        rendered = []
        contentGeneration += 1
        needsDisplay = true
    }

    open func drawContent(in bounds: CGRect) {}

    /// The view's drawing as a closure that runs off the main thread and touches nothing of the view, or nil when it
    /// draws only on the main thread (`drawContent`). Asked on the main thread, for the content as it is now.
    func backgroundDrawing() -> (@Sendable (CGRect) -> Void)? { nil }

    /// Whether a drawing is being made off the main thread, for the tests.
    var isDrawingInBackground: Bool { drawingSize != nil }

    open override func layout() {
        super.layout()
        if rendered.last?.size != bounds.size { needsDisplay = true }
    }

    open override func updateLayer() {
        let scale = window?.backingScaleFactor ?? 2
        let appearance = effectiveAppearance
        let size = bounds.size
        let space = UncheckedBox(Self.drawingSpace(for: window))
        if let known = rendered.first(where: { $0.size == size && $0.scale == scale && $0.appearance == appearance.name }) {
            show(known.image, scale: scale)
            return
        }
        guard size.width >= 1, size.height >= 1 else {
            layer?.contents = nil
            return
        }
        if let previous = rendered.last, let draw = backgroundDrawing() {
            // The last drawing stays, at its own size, until this one is made.
            show(previous.image, scale: previous.scale)
            guard drawingSize != size else { return }
            drawingSize = size
            let generation = contentGeneration
            let box = UncheckedBox(appearance)
            Self.drawingQueue.async { [weak self] in
                let image = Self.render(size: size, scale: scale, space: space.value, appearance: box.value, draw: draw)
                let made = UncheckedBox(image)
                DispatchQueue.main.async { [weak self] in
                    MainActor.assumeIsolated {
                        self?.drawn(made.value, size: size, scale: scale, appearance: box.value.name, generation: generation)
                    }
                }
            }
            return
        }
        guard let image = Self.render(size: size, scale: scale, space: space.value, appearance: appearance, draw: { [self] in drawContent(in: $0) }) else {
            layer?.contents = nil
            return
        }
        keep((size, scale, appearance.name, image))
        show(image, scale: scale)
    }

    private func drawn(_ image: CGImage?, size: CGSize, scale: CGFloat, appearance: NSAppearance.Name, generation: Int) {
        if drawingSize == size { drawingSize = nil }
        guard generation == contentGeneration, let image else { return }
        keep((size, scale, appearance, image))
        // Shown if the view is still that size; else the size it took since is drawn next.
        needsDisplay = true
    }

    private func keep(_ drawing: Rendered) {
        rendered = Array((rendered.filter { $0.size != drawing.size } + [drawing]).suffix(2))
    }

    private func show(_ image: CGImage, scale: CGFloat) {
        guard let layer else { return }
        layer.contentsScale = scale
        // At the top left, unstretched: a drawing of another size shows as it was until its successor is ready.
        // A flipped view's layer has its geometry flipped, where the top is the minimum y.
        layer.contentsGravity = layer.contentsAreFlipped() ? .bottomLeft : .topLeft
        layer.contents = image
    }

    /// `draw` into a bitmap of `size` points at `scale` in `space`, flipped (y grows down), in `appearance`. Runs on any thread.
    nonisolated private static func render(size: CGSize, scale: CGFloat, space: CGColorSpace, appearance: NSAppearance,
                                           draw: (CGRect) -> Void) -> CGImage? {
        guard let context = CGContext(data: nil, width: Int(ceil(size.width * scale)), height: Int(ceil(size.height * scale)),
                                      bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                      bitmapInfo: Self.bitmapInfo) else { return nil }
        context.translateBy(x: 0, y: size.height * scale)
        context.scaleBy(x: scale, y: -scale)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        appearance.performAsCurrentDrawingAppearance { draw(CGRect(origin: .zero, size: size)) }
        NSGraphicsContext.restoreGraphicsState()
        return context.makeImage()
    }
}

/// A value handed to another thread that is not marked `Sendable` but is not shared while it is used there (an
/// attributed string copied for a drawing, an appearance, a finished image).
struct UncheckedBox<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}

/// Attributed text laid out by TextKit, with its height for a width worked out without laying out a view. The text's
/// layout is kept (`NSLayoutManager`): measured again at another width (a card whose column narrowed as a sidebar
/// opened) it only breaks its lines again, where measuring it afresh typeset it from scratch each time.
///
/// At a new width it is drawn again off the main thread (`CachedDrawingView`), with a text stack of its own.
public final class CardTextView: CachedDrawingView {
    public var attributed = NSAttributedString() {
        didSet {
            snapshot = attributed.copy() as? NSAttributedString ?? NSAttributedString()
            storage.setAttributedString(snapshot)
            laidOutWidth = nil
            invalidate()
        }
    }
    /// The lines it shows at most; 0 for all.
    public var maxLines = 0 {
        didSet {
            Self.configure(container, maxLines: maxLines)
            laidOutWidth = nil
            invalidate()
        }
    }

    /// The text as it was set, never changed after: what a drawing or a measure off the main thread reads.
    private var snapshot = NSAttributedString()
    private let storage = NSTextStorage()
    private let manager = NSLayoutManager()
    private let container = NSTextContainer(size: .zero)
    private var laidOutWidth: CGFloat?

    public override init(frame: NSRect) {
        super.init(frame: frame)
        Self.assemble(storage, manager, container)
        Self.configure(container, maxLines: maxLines)
    }

    required public init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    nonisolated private static func assemble(_ storage: NSTextStorage, _ manager: NSLayoutManager, _ container: NSTextContainer) {
        container.lineFragmentPadding = 0
        manager.addTextContainer(container)
        storage.addLayoutManager(manager)
    }

    nonisolated private static func configure(_ container: NSTextContainer, maxLines: Int) {
        container.maximumNumberOfLines = maxLines
        container.lineBreakMode = maxLines > 0 ? .byTruncatingTail : .byWordWrapping
    }

    /// Lays the text out at `width`, unless it already is.
    private func layOut(width: CGFloat) {
        guard laidOutWidth != width else { return }
        laidOutWidth = width
        container.size = CGSize(width: width, height: .greatestFiniteMagnitude)
        manager.ensureLayout(for: container)
    }

    /// The height the text takes at `width`, its line limit applied.
    public func height(for width: CGFloat) -> CGFloat {
        guard attributed.length > 0, width > 0 else { return 0 }
        layOut(width: width)
        return ceil(manager.usedRect(for: container).height)
    }

    /// The height `text` takes at `width` drawn by a `CardTextView` with `maxLines` (0 for all).
    public static func height(of text: NSAttributedString, maxLines: Int = 0, width: CGFloat) -> CGFloat {
        measure(text, maxLines: maxLines, width: width)
    }

    /// `height(of:maxLines:width:)` on any thread.
    nonisolated private static func measure(_ text: NSAttributedString, maxLines: Int, width: CGFloat) -> CGFloat {
        guard text.length > 0, width > 0 else { return 0 }
        // The storage holds the layout manager, which only refers back to it: kept until the text is measured.
        let (storage, manager, container) = stack(text, maxLines: maxLines, width: width)
        return withExtendedLifetime(storage) { ceil(manager.usedRect(for: container).height) }
    }

    /// A text stack of its own for `text`, laid out at `width`. The storage is returned: it holds the rest.
    nonisolated private static func stack(_ text: NSAttributedString, maxLines: Int, width: CGFloat) -> (NSTextStorage, NSLayoutManager, NSTextContainer) {
        let storage = NSTextStorage(attributedString: text), manager = NSLayoutManager()
        let container = NSTextContainer(size: CGSize(width: width, height: .greatestFiniteMagnitude))
        assemble(storage, manager, container)
        configure(container, maxLines: maxLines)
        manager.ensureLayout(for: container)
        return (storage, manager, container)
    }

    public override func drawContent(in bounds: CGRect) {
        guard attributed.length > 0 else { return }
        layOut(width: bounds.width)
        let glyphs = manager.glyphRange(for: container)
        manager.drawBackground(forGlyphRange: glyphs, at: .zero)
        manager.drawGlyphs(forGlyphRange: glyphs, at: .zero)
    }

    override func backgroundDrawing() -> (@Sendable (CGRect) -> Void)? {
        let text = UncheckedBox(snapshot), maxLines = maxLines
        return { bounds in
            guard text.value.length > 0 else { return }
            let (storage, manager, container) = Self.stack(text.value, maxLines: maxLines, width: bounds.width)
            let glyphs = manager.glyphRange(for: container)
            manager.drawBackground(forGlyphRange: glyphs, at: .zero)
            manager.drawGlyphs(forGlyphRange: glyphs, at: .zero)
            withExtendedLifetime(storage) {}
        }
    }
}

// MARK: - Card

/// A card's paper, as `interactiveNoteCard` draws it: the page colour with a hairline, a faint halftone grain in the
/// top right; under the pointer the hairline takes the accent, a glow of it rises under the card, a halftone spreads
/// from the lower right corner and the paper lifts 2 points. Clicks open (`onOpen`, with the card's frame for the
/// page to grow out of), a drag carries `dragResource` into the workspace, a right click shows `menu()`.
///
/// Subclasses put their content in `content`, which is clipped to the card's rounded shape.
@MainActor
open class NativeCardView: NSView, NSDraggingSource {
    public var theme: ThemeTokens = .standard { didSet { if theme != oldValue { applyTheme() } } }
    public var cornerRadius: CGFloat = 10 { didSet { needsLayout = true } }
    public var onOpen: ((OpenOrigin?, _ newTab: Bool) -> Void)?
    public var dragResource: Resource?
    public var dragTitle = ""
    public var menuProvider: (() -> NSMenu?)?

    /// What the card shows, clipped to its shape.
    public let content = FlippedView()

    private let paper = CALayer()
    private let grain = CALayer()
    private let ink = CALayer()
    private let ring = CAShapeLayer()
    private var tracking: NSTrackingArea?
    public private(set) var isHovered = false
    private var mouseDownEvent: NSEvent?

    public override var isFlipped: Bool { true }
    public override var mouseDownCanMoveWindow: Bool { false }

    public override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = false
        paper.masksToBounds = true
        paper.addSublayer(grain)
        paper.addSublayer(ink)
        layer?.addSublayer(paper)
        content.wantsLayer = true
        content.layer?.masksToBounds = true
        addSubview(content)
        ring.fillColor = nil
        ring.lineWidth = 1
        ring.zPosition = 5
        layer?.addSublayer(ring)
        ink.opacity = 0
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        applyTheme()
    }

    required public init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// The card's content: never the target of a click, the card is.
    public final class FlippedView: NSView {
        public override var isFlipped: Bool { true }
        public override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    /// A click opens the card even in a window that is not in front, as a SwiftUI card did.
    open override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private var radius: CGFloat { Corners.r(min(cornerRadius, 10)) }

    open override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        paper.frame = bounds
        paper.cornerRadius = radius
        paper.cornerCurve = .continuous
        content.frame = bounds
        content.layer?.cornerRadius = radius
        content.layer?.cornerCurve = .continuous
        layer?.shadowPath = CGPath(roundedRect: bounds, cornerWidth: radius, cornerHeight: radius, transform: nil)
        ring.frame = bounds
        ring.path = CGPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), cornerWidth: max(0, radius - 0.5),
                           cornerHeight: max(0, radius - 0.5), transform: nil)
        // The grain sits in the top right, the ink in the bottom right (flipped coordinates: y grows down).
        let grainSize = CGSize(width: min(bounds.width * 0.3, 90), height: min(bounds.height * 0.22, 54))
        grain.frame = CGRect(x: bounds.width - grainSize.width, y: 0, width: grainSize.width, height: grainSize.height)
        let inkSize = CGSize(width: bounds.width * 0.55, height: min(bounds.height * 0.5, 150))
        ink.anchorPoint = CGPoint(x: 1, y: 1)
        ink.bounds = CGRect(origin: .zero, size: inkSize)
        ink.position = CGPoint(x: bounds.width, y: bounds.height)
        CATransaction.commit()
        drawClouds()
    }

    private var grainKey: (CGSize, ThemeTokens)?
    private var inkKey: (CGSize, ThemeTokens)?

    private func drawClouds() {
        let accent = NSColor(theme.accent)
        let scale = window?.backingScaleFactor ?? 2
        if grainKey.map({ $0.0 != grain.bounds.size || $0.1 != theme }) ?? true {
            grainKey = (grain.bounds.size, theme)
            grain.contents = HalftoneImages.image(size: grain.bounds.size, corner: .topTrailing, step: 2, seed: 29, color: accent.withAlphaComponent(0.14), scale: scale)
            grain.contentsScale = scale
        }
        // The ink shows only under the pointer: drawn when the card takes its hover pose, not at each width a card
        // passes through (a sidebar sliding in, a window resized).
        guard isHovered, inkKey.map({ $0.0 != ink.bounds.size || $0.1 != theme }) ?? true else { return }
        inkKey = (ink.bounds.size, theme)
        ink.contents = HalftoneImages.image(size: ink.bounds.size, corner: .bottomTrailing, step: 2.5, seed: 17, color: accent.withAlphaComponent(0.4), scale: scale)
        ink.contentsScale = scale
    }

    private func applyTheme() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            paper.backgroundColor = NSColor(theme.background).cgColor
            ring.strokeColor = (isHovered ? NSColor(theme.accent).withAlphaComponent(0.85) : NSColor(theme.separator)).cgColor
            layer?.shadowColor = NSColor(theme.accent).cgColor
        }
        layer?.shadowRadius = 16
        layer?.shadowOffset = CGSize(width: 0, height: -6)
        layer?.shadowOpacity = isHovered ? 0.16 : 0
        grainKey = nil
        inkKey = nil
        needsLayout = true
    }

    // MARK: Hover

    open override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        // Its own bounds, not `.inVisibleRect`: a view that does not clip (`clipsToBounds`, false since macOS 14)
        // has a visible rect as large as the scroll view's, and every card took the pointer at once.
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    open override func mouseEntered(with event: NSEvent) { setHovered(true) }
    open override func mouseExited(with event: NSEvent) { setHovered(false) }

    /// Takes the card in or out of its hover pose, animated.
    public func setHovered(_ hovered: Bool, animated: Bool = true) {
        guard hovered != isHovered else { return }
        isHovered = hovered
        if hovered { drawClouds() }
        let reduce = Motion.reduceMotion
        guard let layer else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(!animated)
        CATransaction.setAnimationDuration(hovered ? 0.45 : 0.25)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
        effectiveAppearance.performAsCurrentDrawingAppearance {
            ring.strokeColor = (hovered ? NSColor(theme.accent).withAlphaComponent(0.85) : NSColor(theme.separator)).cgColor
        }
        if animated {
            let fade = CABasicAnimation(keyPath: "shadowOpacity")
            fade.fromValue = layer.presentation()?.shadowOpacity ?? layer.shadowOpacity
            layer.add(fade, forKey: "shadowOpacity")
        }
        layer.shadowOpacity = hovered ? 0.16 : 0
        ink.opacity = hovered ? 1 : 0
        ink.transform = hovered || reduce ? CATransform3DIdentity : CATransform3DMakeScale(0.6, 0.6, 1)
        CATransaction.commit()
        // The paper rises a little: the lift spring, on the layer only (the view's frame stays for the grid).
        let rise: CGFloat = hovered && !reduce ? -2 : 0
        // The sublayers move, not the layer: AppKit owns the layer's own geometry.
        let from = (layer.presentation()?.value(forKeyPath: "sublayerTransform.translation.y") as? CGFloat) ?? 0
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.setValue(rise, forKeyPath: "sublayerTransform.translation.y")
        CATransaction.commit()
        if animated, !reduce {
            let spring = CASpringAnimation(perceptualDuration: Motion.Spring.lift.duration, bounce: Motion.Spring.lift.bounce)
            spring.keyPath = "sublayerTransform.translation.y"
            spring.fromValue = from
            spring.toValue = rise
            layer.add(spring, forKey: "lift")
        }
    }

    // MARK: Cascade

    /// Appears as part of a cascade, `delay` seconds after it is shown: from a little lower and smaller, fading
    /// in. Under "Reduce motion" it only fades.
    public func cascadeIn(delay: Double) {
        guard let layer else { return }
        let reduce = Motion.reduceMotion
        let begin = CACurrentMediaTime() + delay
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        fade.duration = reduce ? 0.12 : Motion.Spring.standard.duration
        fade.beginTime = begin
        fade.fillMode = .backwards
        layer.add(fade, forKey: "cascadeFade")
        guard !reduce else { return }
        let spring = CASpringAnimation(perceptualDuration: Motion.Spring.standard.duration, bounce: Motion.Spring.standard.bounce)
        spring.keyPath = "sublayerTransform"
        var start = CATransform3DMakeTranslation(0, CardMotion.cascadeRise, 0)
        start = CATransform3DScale(start, Motion.Metrics.enterScale, Motion.Metrics.enterScale, 1)
        spring.fromValue = start
        spring.toValue = CATransform3DIdentity
        spring.beginTime = begin
        spring.fillMode = .backwards
        layer.add(spring, forKey: "cascadeMove")
    }

    // MARK: Clicks, drags and the menu

    /// The card's frame in its window, as `OpenOriginProbe` gives it, for the page to grow out of.
    public var openOrigin: OpenOrigin? {
        guard let window, let root = window.contentView else { return nil }
        let rect = convert(bounds, to: root)
        guard rect.width > 0, rect.height > 0 else { return nil }
        let top = root.isFlipped ? rect.minY : root.bounds.height - rect.maxY
        return .frame(CGRect(x: rect.minX, y: top, width: rect.width, height: rect.height))
    }

    open override func mouseDown(with event: NSEvent) {
        mouseDownEvent = event
    }

    open override func mouseDragged(with event: NSEvent) {
        guard let start = mouseDownEvent, let resource = dragResource else { return }
        let a = start.locationInWindow, b = event.locationInWindow
        guard hypot(b.x - a.x, b.y - a.y) > 4 else { return }
        mouseDownEvent = nil
        let item = NSPasteboardItem()
        item.setData(Data(DragPayload.resource(resource).string.utf8), forType: NSPasteboard.PasteboardType(DragPayload.type.identifier))
        let dragging = NSDraggingItem(pasteboardWriter: item)
        // What follows the pointer is the shell's ghost (`DragGhost`); AppKit's own image is a single clear pixel.
        dragging.setDraggingFrame(NSRect(x: convert(a, from: nil).x, y: convert(a, from: nil).y, width: 1, height: 1), contents: NSImage(size: NSSize(width: 1, height: 1)))
        DragSession.shared.begin(.resource(resource), title: dragTitle.isEmpty ? nil : dragTitle)
        beginDraggingSession(with: [dragging], event: start, source: self)
    }

    open override func mouseUp(with event: NSEvent) {
        defer { mouseDownEvent = nil }
        guard mouseDownEvent != nil, bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        onOpen?(openOrigin, event.modifierFlags.contains(.command))
    }

    open override func menu(for event: NSEvent) -> NSMenu? {
        menuProvider?()
    }

    public func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .withinApplication ? [.copy, .move, .generic] : []
    }

    public func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        DragSession.shared.end()
    }

    open override func accessibilityPerformPress() -> Bool {
        onOpen?(openOrigin, false)
        return true
    }
}

/// The halftone clouds of the cards as bitmaps, drawn once per size, corner and colour.
@MainActor
enum HalftoneImages {
    /// Premultiplied BGRA, the layout Core Animation shows as is: another one is converted on the main thread as
    /// the layer tree is committed.
    nonisolated static let bitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue

    private static let cache = NSCache<NSString, CGImage>()

    static func image(size: CGSize, corner: HalftoneCloud.Corner, step: CGFloat, seed: Int, color: NSColor, scale: CGFloat) -> CGImage? {
        guard size.width >= 2, size.height >= 2 else { return nil }
        let key = "\(Int(size.width))x\(Int(size.height))|\(corner)|\(step)|\(seed)|\(color)|\(scale)" as NSString
        if let known = cache.object(forKey: key) { return known }
        let width = Int(size.width * scale), height = Int(size.height * scale)
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: Self.bitmapInfo) else { return nil }
        // The dots are laid out top-left first, as SwiftUI's Canvas draws them: flip to match.
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: scale, y: -scale)
        context.setFillColor(color.cgColor)
        for dot in HalftoneCloud.dots(in: size, corner: corner, step: step, seed: seed) { context.fill(dot) }
        guard let image = context.makeImage() else { return nil }
        cache.setObject(image, forKey: key)
        return image
    }
}

/// A card's picture: the vault file decoded at the card's size and dithered off the main thread
/// (`DitheredThumbnails`), shown when ready, kept for the next card that shows it.
@MainActor
public final class CardPictureView: NSView {
    private var key: String?
    private var task: Task<Void, Never>?

    public override var isFlipped: Bool { true }
    public override func hitTest(_ point: NSPoint) -> NSView? { nil }

    public override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.contentsGravity = .resizeAspectFill
        layer?.masksToBounds = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public func show(_ url: URL?, style: DitherStyle) {
        guard let url else {
            task?.cancel()
            key = nil
            layer?.contents = nil
            return
        }
        let newKey = DitheredThumbnails.key(url, style)
        guard newKey != key else { return }
        key = newKey
        task?.cancel()
        if let cached = DitheredThumbnails.cached(newKey) {
            layer?.contents = cached
            return
        }
        layer?.contents = nil
        task = Task { [weak self] in
            let made = await Task.detached(priority: .userInitiated) { DitheredThumbnails.make(url, style: style) }.value
            guard !Task.isCancelled, let self, self.key == newKey, let made else { return }
            let image = NSImage(cgImage: made.image, size: made.size)
            DitheredThumbnails.keep(image, for: newKey)
            self.layer?.contents = image
        }
    }
}
