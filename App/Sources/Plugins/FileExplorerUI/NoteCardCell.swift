import AppKit
import PluginKit
import PluginKitUI
import SwiftUI

/// One card of a folder page in AppKit, as Craft draws it: the title in bold over the note drawn small (as
/// tall as it is up to a limit, then faded out), its first picture, and a footer with when it changed and its tags;
/// a folder is its name and how many notes it holds. A note that opens in another view (a drawing, a mindmap) shows
/// that view instead of its text, hosted in SwiftUI as the view's plugin draws it.
///
/// Reused from card to card as the grid scrolls (`show`); its height at a width is worked out without laying out
/// (`height(for:)`).
final class NoteCardCell: NativeCardView {
    private weak var model: ExplorerModel?
    private(set) var path: String?
    private var card: NoteCard?
    private var embed: (type: ViewType, context: ViewContext)?

    private let icon = CALayer()
    private let title = CardTextView()
    private let preview = CardTextView()
    private let fade = CAGradientLayer()
    private let picture = CardPictureView()
    private let footer = CardFooterView()
    private let hairline = CALayer()
    private var embedHost: NSHostingView<AnyView>?

    /// Whether the pointer has been over the card since it was last checked: it may be in its hover pose.
    var mayBeHovered = false
    /// Grows each time the card is taken out of its hover pose by the grid (`dropHover`).
    private(set) var hoverGeneration = 0
    var isScrolling = false { didSet { if isScrolling != oldValue, embed != nil { updateEmbed() } } }

    /// The card's own rect.
    var cardFrame: CGRect { frame }
    /// Where its title is, for the tests.
    var titleFrame: CGRect { title.frame }

    static let padding: CGFloat = 18
    static let maxPreviewHeight = NoteCardMetrics.maxPreviewHeight

    init(model: ExplorerModel, theme: ThemeTokens) {
        self.model = model
        super.init(frame: .zero)
        self.theme = theme
        cornerRadius = 16
        title.maxLines = 3
        content.addSubview(title)
        content.addSubview(preview)
        content.addSubview(picture)
        content.addSubview(footer)
        content.layer?.addSublayer(icon)
        content.layer?.addSublayer(hairline)
        preview.layer?.addSublayer(fade)
        picture.layer?.cornerRadius = Corners.r(6)
        picture.layer?.cornerCurve = .continuous
        icon.contentsGravity = .center
        onOpen = { [weak self] origin, newTab in
            guard let self, let card = self.card else { return }
            self.model?.open(card, newTab: newTab, from: origin)
        }
        menuProvider = { [weak self] in self?.makeMenu() }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Shows `item`'s card, reading its note (`ExplorerModel.card(for:)` keeps it while the note is the same).
    func show(_ item: ExplorerModel.Item) {
        guard let model else { return }
        let card = model.card(for: item)
        guard card != self.card else { return }
        self.card = card
        path = item.path
        embed = model.cardEmbed(for: card)
        dragResource = card.kind == .note ? .file(card.path) : .folder(card.path)
        dragTitle = card.title
        setAccessibilityLabel(card.title)
        toolTip = nil
        fill()
        needsLayout = true
    }

    /// Takes the card out of its hover pose, without animation: it moved away from under a still pointer.
    func dropHover() {
        mayBeHovered = false
        hoverGeneration += 1
        setHovered(false, animated: false)
    }

    func themeChanged() {
        fill()
        needsLayout = true
    }

    // MARK: Content

    private func fill() {
        lastFrames = []
        contentGeneration += 1
        guard let card else { return }
        let text = NSColor(theme.text)
        let titleStyle = NSMutableParagraphStyle()
        titleStyle.lineBreakMode = .byWordWrapping
        title.attributed = NSAttributedString(string: card.title, attributes: [
            .font: NSFont.ui(size: 15, weight: .semibold), .kern: -0.3, .foregroundColor: text, .paragraphStyle: titleStyle,
        ])
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let iconColor = card.kind == .folder ? NSColor(theme.secondaryText) : NSColor(theme.accent)
        // An image's points are its pixels over the layer's scale: at 1 a Retina image showed twice its size.
        icon.contentsScale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        if card.kind == .folder {
            switch FolderStyles.shared.icon(for: card.path, fallback: "folder") {
            case .symbol(let name): icon.contents = tintedSymbol(name, size: 14, weight: .medium, color: iconColor)
            case .emoji(let emoji): icon.contents = Self.emojiImage(emoji)
            }
        } else if let symbol = card.symbol {
            icon.contents = tintedSymbol(symbol, size: 14, weight: .medium, color: iconColor)
        } else {
            icon.contents = nil
        }
        hairline.backgroundColor = NSColor(theme.text).withAlphaComponent(0.07).cgColor
        if let blocks = card.blocks, embed == nil {
            preview.attributed = NotePreviewText.attributed(blocks, size: 11.5, theme: theme)
        } else if card.blocks == nil {
            preview.attributed = NSAttributedString(string: card.preview, attributes: [
                .font: NSFont.ui(size: 12), .foregroundColor: NSColor(theme.secondaryText),
            ])
        } else {
            preview.attributed = NSAttributedString()
        }
        let paper = NSColor(theme.background)
        fade.colors = [paper.withAlphaComponent(0).cgColor, paper.cgColor]
        CATransaction.commit()
        picture.show(embed == nil ? card.cover : nil, style: theme.dither)
        footer.theme = theme
        footer.modified = embed == nil && card.blocks != nil ? card.modified : nil
        footer.tags = embed == nil && card.blocks != nil ? card.tags : []
        updateEmbed()
    }

    private func updateEmbed() {
        guard let embed else {
            embedHost?.removeFromSuperview()
            embedHost = nil
            return
        }
        let root = AnyView(embed.type.makeView(embed.context)
            .environment(\.themeTokens, theme)
            .environment(\.isScrollingCards, isScrolling)
            .tint(theme.accent))
        if let embedHost {
            embedHost.rootView = root
        } else {
            let host = PassThroughHostingView(rootView: root)
            host.safeAreaRegions = []
            host.sizingOptions = []
            content.addSubview(host)
            embedHost = host
        }
    }

    private static func emojiImage(_ emoji: String) -> NSImage {
        let text = NSAttributedString(string: emoji, attributes: [.font: NSFont.systemFont(ofSize: 13)])
        let size = text.size()
        return NSImage(size: size, flipped: false) { rect in
            text.draw(in: rect)
            return true
        }
    }

    // MARK: Layout

    /// Where each part goes at `width`, and the card's height.
    private struct Frames {
        var icon: CGRect?
        var title = CGRect.zero
        var hairline: CGRect?
        var embed: CGRect?
        var preview: CGRect?
        var previewFades = false
        var picture: CGRect?
        var footer: CGRect?
        var height: CGFloat = 0
        /// The texts' heights they were worked out with.
        var texts = TextHeights()
    }

    /// The heights the title and the note's text take at a width.
    private struct TextHeights {
        var title: CGFloat = 0
        var preview: CGFloat = 0
    }

    /// The frames worked out at the last four widths, kept while the card stays: a layout pass measures no text again,
    /// and a page that goes back and forth between two widths (the right sidebar showing for a note, not for the
    /// grid) finds both.
    private var lastFrames: [(width: CGFloat, frames: Frames)] = []
    /// Grows each time the card shows other content: a measure made off the main thread before it is thrown away.
    private var contentGeneration = 0
    /// The widths being measured off the main thread, with who waits for each.
    private var measuring: [CGFloat: [(CGFloat?) -> Void]] = [:]

    private func frames(width: CGFloat) -> Frames {
        if let known = lastFrames.first(where: { $0.width == width }) { return known.frames }
        let frames = makeFrames(width: width)
        lastFrames = Array((lastFrames + [(width, frames)]).suffix(4))
        return frames
    }

    /// The widths the title and the note's text are laid out at, in a card `width` wide.
    private func textWidths(_ width: CGFloat) -> (title: CGFloat, preview: CGFloat) {
        let inset = Self.padding
        let titleX = inset + (icon.contents != nil ? 16 + 7 : 0)
        return (width - inset - titleX, max(0, width - 2 * inset))
    }

    /// The frames at `width`, the texts measured there unless their heights are given.
    private func makeFrames(width: CGFloat, texts: TextHeights? = nil) -> Frames {
        guard let card else { return Frames() }
        var frames = Frames()
        let inset = Self.padding, inner = max(0, width - 2 * inset)
        let titleWidth = textWidths(width).title
        var y: CGFloat = inset
        if icon.contents != nil {
            frames.icon = CGRect(x: inset, y: y + 1, width: 16, height: 18)
        }
        let titleHeight = texts?.title ?? title.height(for: titleWidth)
        frames.texts.title = titleHeight
        frames.title = CGRect(x: width - inset - titleWidth, y: y, width: titleWidth, height: titleHeight)
        y += titleHeight
        var roomBelow = Self.padding
        if embed != nil {
            y += 12
            frames.hairline = CGRect(x: inset, y: y, width: inner, height: 1)
            y += 1 + 12
            frames.embed = CGRect(x: inset, y: y, width: inner, height: NoteCardMetrics.embedHeight)
            y += NoteCardMetrics.embedHeight
            roomBelow = 14
        } else if card.blocks != nil {
            if preview.attributed.length > 0 {
                y += 10
                let natural = texts?.preview ?? preview.height(for: inner)
                frames.texts.preview = natural
                let cap = card.cover == nil ? Self.maxPreviewHeight : Self.maxPreviewHeight / 2
                let shown = min(natural, cap)
                frames.preview = CGRect(x: inset, y: y, width: inner, height: shown)
                frames.previewFades = natural > cap + 0.5
                y += shown
                roomBelow = 14
            }
            if card.cover != nil {
                y += 10
                frames.picture = CGRect(x: inset, y: y, width: inner, height: NoteCardMetrics.coverHeight)
                y += NoteCardMetrics.coverHeight
            }
            if !footer.isEmpty {
                y += 12
                let height = footer.height
                frames.footer = CGRect(x: inset, y: y, width: inner, height: height)
                y += height
            }
        } else if preview.attributed.length > 0 {
            y += 6
            let height = texts?.preview ?? preview.height(for: inner)
            frames.texts.preview = height
            frames.preview = CGRect(x: inset, y: y, width: inner, height: height)
            y += height
        }
        frames.height = ceil(y + roomBelow)
        return frames
    }

    /// The card's height at `width`, without laying it out.
    func height(for width: CGFloat) -> CGFloat {
        frames(width: width).height
    }

    /// The card's height at `width` if it is known, else as it would be with its texts as tall as at the last width
    /// it was at: nil when it has been at none.
    func provisionalHeight(for width: CGFloat) -> CGFloat? {
        if let known = lastFrames.first(where: { $0.width == width }) { return known.frames.height }
        return lastFrames.last.map { makeFrames(width: width, texts: $0.frames.texts).height }
    }

    /// Measures the card's texts at `width` off the main thread; `done` gets its height there, on the main thread,
    /// or nil when the card shows another note by then.
    func measure(width: CGFloat, done: @escaping (CGFloat?) -> Void) {
        if let known = lastFrames.first(where: { $0.width == width }) {
            done(known.frames.height)
            return
        }
        if measuring[width] != nil {
            measuring[width]?.append(done)
            return
        }
        measuring[width] = [done]
        let generation = contentGeneration
        let widths = textWidths(width)
        let titleText = TextToMeasure(text: title.attributed, maxLines: title.maxLines)
        let previewText = TextToMeasure(text: preview.attributed, maxLines: preview.maxLines)
        Self.measuring.async {
            let texts = TextHeights(title: titleText.height(width: widths.title), preview: previewText.height(width: widths.preview))
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated { self?.measured(texts, width: width, generation: generation) }
            }
        }
    }

    /// The queue cards are measured on off the main thread.
    private static let measuring = DispatchQueue(label: "loam.card-measure", qos: .userInitiated, attributes: .concurrent)

    /// A card's text handed to the measuring queue: its attributed string is never changed once set (`CardTextView`
    /// copies it), so it is only read there.
    private struct TextToMeasure: @unchecked Sendable {
        let text: NSAttributedString
        let maxLines: Int

        /// Its height at `width`, as a `CardTextView` lays it out, with a text stack of its own.
        func height(width: CGFloat) -> CGFloat {
            guard text.length > 0, width > 0 else { return 0 }
            let storage = NSTextStorage(attributedString: text), manager = NSLayoutManager()
            let container = NSTextContainer(size: CGSize(width: width, height: .greatestFiniteMagnitude))
            container.lineFragmentPadding = 0
            container.maximumNumberOfLines = maxLines
            container.lineBreakMode = maxLines > 0 ? .byTruncatingTail : .byWordWrapping
            manager.addTextContainer(container)
            storage.addLayoutManager(manager)
            manager.ensureLayout(for: container)
            return withExtendedLifetime(storage) { ceil(manager.usedRect(for: container).height) }
        }
    }

    private func measured(_ texts: TextHeights, width: CGFloat, generation: Int) {
        let waiting = measuring.removeValue(forKey: width) ?? []
        guard generation == contentGeneration else {
            for done in waiting { done(nil) }
            return
        }
        let frames = makeFrames(width: width, texts: texts)
        lastFrames = Array((lastFrames.filter { $0.width != width } + [(width, frames)]).suffix(4))
        if bounds.width == width { needsLayout = true }
        for done in waiting { done(frames.height) }
    }

    /// The frames to lay the card out with at `width`: the known ones, else (a width it has not been at) the last
    /// width's text heights while the texts are measured off the main thread, else measured now.
    private func layoutFrames(width: CGFloat) -> Frames {
        if let known = lastFrames.first(where: { $0.width == width }) { return known.frames }
        guard let last = lastFrames.last else { return frames(width: width) }
        measure(width: width) { _ in }
        return makeFrames(width: width, texts: last.frames.texts)
    }

    override func layout() {
        super.layout()
        let frames = layoutFrames(width: bounds.width)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        icon.frame = frames.icon ?? .zero
        icon.isHidden = frames.icon == nil
        title.frame = frames.title
        hairline.frame = frames.hairline ?? .zero
        hairline.isHidden = frames.hairline == nil
        preview.isHidden = frames.preview == nil
        preview.frame = frames.preview ?? .zero
        fade.isHidden = !frames.previewFades
        fade.frame = CGRect(x: 0, y: preview.bounds.height - 36, width: preview.bounds.width, height: 36)
        picture.isHidden = frames.picture == nil
        picture.frame = frames.picture ?? .zero
        footer.isHidden = frames.footer == nil
        footer.frame = frames.footer ?? .zero
        embedHost?.frame = frames.embed ?? .zero
        CATransaction.commit()
    }

    // MARK: Menu

    private func makeMenu() -> NSMenu? {
        guard let model, let card else { return nil }
        let resource: Resource = card.kind == .folder ? .folder(card.path) : .file(card.path)
        let menu = NSMenu()
        menu.addItem(ActionMenuItem("Open in New Tab".uiLocalized) { [weak model] in model?.open(card, newTab: true, from: nil) })
        menu.addItem(.separator())
        let favorite = model.isFavorite(card.path) ? "Remove from Favorites" : "Add to Favorites"
        menu.addItem(ActionMenuItem(favorite.uiLocalized) { [weak model] in model?.toggleFavorite(card.path) })
        let actions = model.actions(resource)
        if !actions.isEmpty {
            menu.addItem(.separator())
            for action in actions {
                menu.addItem(ActionMenuItem(action.title, symbol: action.symbol) { action.perform(resource) })
            }
        }
        menu.addItem(.separator())
        menu.addItem(ActionMenuItem("Move to…".uiLocalized) { [weak model] in model?.askMove(card.path) })
        menu.addItem(ActionMenuItem("Reveal in Finder".uiLocalized) { [weak model] in model?.revealInFinder(card.path) })
        menu.addItem(.separator())
        menu.addItem(ActionMenuItem("Move to Recently Deleted".uiLocalized) { [weak model] in model?.trash(card.path) })
        return menu
    }
}

/// A hosting view the clicks go through: an embedded view on a card only shows, the card opens.
private final class PassThroughHostingView: NSHostingView<AnyView> {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// The bottom of a note's card, as Craft's: a hairline, when it last changed, then its tags as pills, as many as fit
/// whole and the rest counted.
final class CardFooterView: CachedDrawingView {
    var theme: ThemeTokens = .standard { didSet { invalidate() } }
    var modified: Date? { didSet { invalidate() } }
    var tags: [String] = [] { didSet { invalidate() } }

    var isEmpty: Bool { modified == nil && tags.isEmpty }
    /// The hairline's 11 points, then a pill's height.
    var height: CGFloat { 11 + 20 }

    private var labelFont: NSFont {
        let mono = (13 * 0.78).rounded()
        return NSFont.theme(theme.monoFamily, size: mono)
    }

    private var pillFont: NSFont { NSFont.theme(theme.monoFamily, size: 10.5) }

    override func drawContent(in bounds: CGRect) {
        NSColor(theme.separator).withAlphaComponent(0.7).setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()
        let rowTop: CGFloat = 11, rowHeight: CGFloat = 20
        var dateWidth: CGFloat = 0
        if let modified {
            let font = labelFont
            let label = NSAttributedString(string: NoteCardMetrics.format(modified).uppercased(), attributes: [
                .font: font, .foregroundColor: NSColor(theme.secondaryText), .kern: font.pointSize * 0.09,
            ])
            let size = label.size()
            label.draw(at: NSPoint(x: 0, y: rowTop + (rowHeight - size.height) / 2))
            dateWidth = size.width + 4
        }
        guard !tags.isEmpty else { return }
        // As many tags as fit whole, then "+N": a tag is never cut.
        let room = bounds.width - dateWidth
        var shown = tags.count
        var pills: [String] = []
        while shown > 0 {
            pills = tags.prefix(shown).map { "# " + $0 } + (shown < tags.count ? ["+\(tags.count - shown)"] : [])
            if width(of: pills) <= room { break }
            shown -= 1
        }
        if shown == 0 { pills = ["+\(tags.count)"] }
        var x = bounds.width - width(of: pills)
        let accent = NSColor(theme.accent)
        for pill in pills {
            let text = NSAttributedString(string: pill, attributes: [.font: pillFont, .foregroundColor: accent])
            let size = text.size()
            let rect = NSRect(x: x, y: rowTop + (rowHeight - (size.height + 6)) / 2, width: size.width + 14, height: size.height + 6)
            accent.withAlphaComponent(0.1).setFill()
            NSBezierPath(roundedRect: rect, xRadius: Corners.r(6), yRadius: Corners.r(6)).fill()
            text.draw(at: NSPoint(x: rect.minX + 7, y: rect.minY + 3))
            x = rect.maxX + 6
        }
    }

    private func width(of pills: [String]) -> CGFloat {
        let widths = pills.map { (($0 as NSString).size(withAttributes: [.font: pillFont]).width + 14).rounded(.up) }
        return widths.reduce(0, +) + CGFloat(max(0, widths.count - 1)) * 6
    }
}
