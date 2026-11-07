import AppKit
import PluginKitUI
import SwiftUI

/// The gallery in AppKit: a scroll view whose document places the cards in rows of equal columns (210 to 260 points),
/// only the cards near the screen alive and reused as it scrolls. One SwiftUI view per card cost the gallery ~300 ms
/// to open and frames while scrolling (docs/APPKIT.md). The same view in a page and in a note (a `base` block), where
/// it is as tall as its cards (`fittingSize`); with no entry it shows the collection's empty state.
final class GalleryScrollView: NSScrollView, NativeHostedView {
    /// What the gallery shows of its model, followed as it changes.
    struct Shown: Equatable {
        var entries: [NoteRecord]
        var fields: [PropertyRef]
        var imageField: String?
        var searchText: String
    }

    let document = GalleryDocumentView()
    private let model: CollectionViewModel
    private let covers: CardCovers
    private var shown: Follow<Shown?>?
    /// The host's theme; nil until it is first given, and nothing is shown before (it would be laid out twice).
    private var theme: ThemeTokens?
    private var emptyState: NSHostingView<AnyView>?
    private var isEmpty = false

    init(model: CollectionViewModel, covers: CardCovers) {
        self.model = model
        self.covers = covers
        super.init(frame: .zero)
        drawsBackground = false
        contentView.drawsBackground = false
        hasVerticalScroller = true
        autohidesScrollers = true
        scrollerStyle = .overlay
        hasHorizontalScroller = false
        horizontalScrollElasticity = .none
        automaticallyAdjustsContentInsets = false
        documentView = document
        contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(scrolled), name: NSView.boundsDidChangeNotification, object: contentView)
        shown = Follow({ [weak model] in
            // A gallery the page is replacing by another view (the table) is updated once more with that view's
            // fields: it would measure every card again for them (~200 ms) just before it goes.
            guard let model, model.view.map({ $0.type == "cards" }) ?? true else { return nil }
            return Shown(entries: model.entries, fields: model.fields, imageField: Self.imageField(model), searchText: model.searchText)
        }) { [weak self] shown in
            guard let shown, self?.theme != nil else { return }
            self?.show(shown)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var mouseDownCanMoveWindow: Bool { false }

    static func imageField(_ model: CollectionViewModel) -> String? {
        if case .string(let field)? = model.view?.options["image"] { return PropertyRef(field).name }
        return nil
    }

    func hostEnvironmentChanged(_ environment: NativeViewEnvironment) {
        guard environment.theme != theme else { return }
        theme = environment.theme
        refresh()
    }

    /// In a note: as tall as the cards (or the empty state) at `width`, up to the block's limit, then it scrolls.
    func fittingSize(width: CGFloat, maxHeight: CGFloat?) -> CGSize? {
        guard model.isEmbedded else { return nil }
        let content = isEmpty ? emptyHeight(width: width) : document.contentHeight(width: width)
        return CGSize(width: width, height: min(content, maxHeight ?? .greatestFiniteMagnitude))
    }

    private func refresh() {
        let current = Shown(entries: model.entries, fields: model.fields, imageField: Self.imageField(model), searchText: model.searchText)
        show(current)
    }

    private func show(_ shown: Shown) {
        guard let theme else { return }
        isEmpty = shown.entries.isEmpty
        document.isHidden = isEmpty
        document.update(model: model, covers: covers, entries: shown.entries, fields: shown.fields,
                        imageField: shown.imageField, theme: theme)
        if isEmpty {
            let root = AnyView(CollectionEmptyState(model: model, symbol: "square.grid.2x2")
                .environment(\.themeTokens, theme).tint(theme.accent))
            if let emptyState {
                emptyState.rootView = root
            } else {
                let host = NSHostingView(rootView: root)
                host.safeAreaRegions = []
                host.sizingOptions = []
                addSubview(host)
                emptyState = host
            }
            emptyState?.isHidden = false
            needsLayout = true
        } else {
            emptyState?.isHidden = true
        }
        invalidateIntrinsicContentSize()
    }

    private func emptyHeight(width: CGFloat) -> CGFloat {
        guard let emptyState else { return 0 }
        return ceil(NSHostingController(rootView: emptyState.rootView)
            .sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude)).height)
    }

    override func layout() {
        super.layout()
        if let emptyState, !emptyState.isHidden {
            emptyState.frame = CGRect(x: 0, y: 0, width: bounds.width, height: min(bounds.height, max(emptyHeight(width: bounds.width), 160)))
        }
    }

    override func tile() {
        super.tile()
        document.widthChanged(contentView.bounds.width)
    }

    /// Cards that fit hand the wheel to what holds them (the note around a gallery block).
    override func scrollWheel(with event: NSEvent) {
        if document.frame.height <= contentView.bounds.height + 0.5 || isEmpty {
            nextResponder?.scrollWheel(with: event)
        } else {
            super.scrollWheel(with: event)
        }
    }

    @objc private func scrolled() { document.showVisibleCards() }
}

final class GalleryDocumentView: NSView {
    private weak var model: CollectionViewModel?
    private var covers: CardCovers?
    private var entries: [NoteRecord] = []
    private var fields: [PropertyRef] = []
    private var imageField: String?
    private var theme: ThemeTokens = .standard
    private var width: CGFloat = 0
    private var frames: [String: CGRect] = [:]
    private(set) var live: [String: GalleryCardCell] = [:]
    private var pool: [GalleryCardCell] = []
    /// Heights of the cards with fields, which a hosted SwiftUI view draws: measured once per note, change and width.
    private var heights: [String: CGFloat] = [:]
    /// Whether the first cards have cascaded in; later ones (added, re-sorted) appear at once.
    private var settled = false
    private var appeared: Date?

    static let spacing: CGFloat = 14
    static let minColumn: CGFloat = 210
    static let maxColumn: CGFloat = 260
    static let padding = NSEdgeInsets(top: 8, left: 8, bottom: 24, right: 8)

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    func update(model: CollectionViewModel, covers: CardCovers, entries: [NoteRecord], fields: [PropertyRef], imageField: String?, theme: ThemeTokens) {
        let order = self.entries.map(\.path)
        let themeChanged = theme != self.theme
        let reordered = !order.isEmpty && order != entries.map(\.path)
        self.model = model
        self.covers = covers
        self.entries = entries
        self.fields = fields
        self.imageField = imageField
        self.theme = theme
        if appeared == nil {
            appeared = Date()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in self?.settled = true }
        }
        if themeChanged || !fields.isEmpty { heights = [:] }
        for cell in Array(live.values) + pool {
            cell.theme = theme
        }
        // Cards already shown take their new data; a sort or a filter slides them to their new place.
        for (path, cell) in live {
            if let entry = entries.first(where: { $0.path == path }) { fill(cell, entry) }
        }
        relayout(animated: reordered)
    }

    func widthChanged(_ newWidth: CGFloat) {
        guard newWidth != width else { return }
        width = newWidth
        heights = [:]
        relayout(animated: false)
    }

    private func columns(width: CGFloat) -> (count: Int, width: CGFloat) {
        let room = max(0, width - Self.padding.left - Self.padding.right)
        let count = max(1, Int((room + Self.spacing) / (Self.minColumn + Self.spacing)))
        let column = min(Self.maxColumn, (room - Self.spacing * CGFloat(count - 1)) / CGFloat(count))
        return (count, max(0, column))
    }

    private func relayout(animated: Bool) {
        guard width > 0 else { return }
        let (frames, content) = place(width: width)
        self.frames = frames
        let height = max(content, superview?.bounds.height ?? 0)
        if frame.size != NSSize(width: width, height: height) { setFrameSize(NSSize(width: width, height: height)) }
        showVisibleCards(animated: animated)
    }

    /// How tall the cards are at `width`, padding included: what a gallery in a note takes.
    func contentHeight(width: CGFloat) -> CGFloat {
        width > 0 && width.isFinite ? place(width: width).height : 0
    }

    /// Each card's frame at `width`, in rows, and the height they take.
    private func place(width: CGFloat) -> (frames: [String: CGRect], height: CGFloat) {
        let (count, column) = columns(width: width)
        var frames: [String: CGRect] = [:]
        var y = Self.padding.top
        var index = 0
        while index < entries.count {
            let row = entries[index..<min(index + count, entries.count)]
            let rowHeight = row.map { height(of: $0, width: column) }.max() ?? 0
            for (slot, entry) in row.enumerated() {
                let x = Self.padding.left + CGFloat(slot) * (column + Self.spacing)
                frames[entry.path] = CGRect(x: x, y: y, width: column, height: height(of: entry, width: column))
            }
            y += rowHeight + Self.spacing
            index += count
        }
        return (frames, entries.isEmpty ? 0 : y - Self.spacing + Self.padding.bottom)
    }

    private func height(of entry: NoteRecord, width: CGFloat) -> CGFloat {
        let key = "\(entry.path)|\(entry.modified)|\(Int(width))"
        if let known = heights[key] { return known }
        let measured = GalleryCardCell.height(title: entry.title, fieldsHeight: fieldsHeight(entry, width: width), width: width)
        heights[key] = measured
        return measured
    }

    private func fieldsHeight(_ entry: NoteRecord, width: CGFloat) -> CGFloat {
        guard let model, !fields.isEmpty else { return 0 }
        let view = GalleryFields(model: model, entry: entry, fields: fields, theme: theme)
        guard view.hasValues else { return 0 }
        let controller = NSHostingController(rootView: view)
        return ceil(controller.sizeThatFits(in: CGSize(width: width - 24, height: .greatestFiniteMagnitude)).height)
    }

    func showVisibleCards(animated: Bool = false) {
        guard let clip = enclosingScrollView?.contentView else { return }
        let visible = clip.bounds.insetBy(dx: 0, dy: -400)
        var wanted = Set<String>()
        for (index, entry) in entries.enumerated() {
            guard let frame = frames[entry.path], frame.intersects(visible) else { continue }
            wanted.insert(entry.path)
            if let cell = live[entry.path] {
                if cell.frame != frame {
                    if animated, !Motion.reduceMotion {
                        NSAnimationContext.runAnimationGroup { context in
                            context.duration = Motion.Spring.standard.duration
                            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1)
                            cell.animator().frame = frame
                        }
                    } else {
                        cell.frame = frame
                    }
                }
                continue
            }
            let cell = pool.popLast() ?? {
                let made = GalleryCardCell()
                addSubview(made)
                return made
            }()
            cell.theme = theme
            cell.setHovered(false, animated: false)
            fill(cell, entry)
            cell.frame = frame
            cell.isHidden = false
            live[entry.path] = cell
            if !settled, let delay = CardMotion.cascadeDelay(index: index, reduceMotion: Motion.reduceMotion) {
                cell.cascadeIn(delay: delay)
            }
        }
        for (path, cell) in live where !wanted.contains(path) {
            live[path] = nil
            cell.isHidden = true
            pool.append(cell)
        }
    }

    private func fill(_ cell: GalleryCardCell, _ entry: NoteRecord) {
        guard let model, let covers else { return }
        let fieldsView = fields.isEmpty ? nil : GalleryFields(model: model, entry: entry, fields: fields, theme: theme)
        cell.show(entry, cover: covers.cover(of: entry, imageField: imageField), fields: fieldsView?.hasValues == true ? fieldsView : nil)
        cell.onOpen = { [weak model] origin, newTab in model?.open(entry.path, placement: newTab ? .newTab : .replace, from: origin) }
    }
}

/// A gallery card, as Craft draws it: the cover on a light grey band (the note's picture, else the note drawn
/// small), a hairline, then the title and the shown fields.
final class GalleryCardCell: NativeCardView {
    private let band = CALayer()
    private let picture = CardPictureView()
    private let preview = CardTextView()
    private let previewFade = CAGradientLayer()
    private let hairline = CALayer()
    private let title = CardTextView()
    private var fieldsHost: NSHostingView<GalleryFields>?
    private var cover: CardCovers.Cover?

    static let coverHeight: CGFloat = 124
    static let inset: CGFloat = 12

    override init(frame: NSRect) {
        super.init(frame: frame)
        cornerRadius = 12
        title.maxLines = 2
        content.layer?.addSublayer(band)
        content.addSubview(preview)
        content.addSubview(picture)
        content.layer?.addSublayer(hairline)
        content.addSubview(title)
        preview.layer?.addSublayer(previewFade)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// The card's height at `width`, its fields taking `fieldsHeight`.
    static func height(title: String, fieldsHeight: CGFloat, width: CGFloat) -> CGFloat {
        let titleHeight = CardTextView.height(of: titleText(title, theme: .standard), maxLines: 2, width: width - 2 * inset)
        return ceil(coverHeight + 1 + inset + titleHeight + (fieldsHeight > 0 ? 8 + fieldsHeight : 0) + inset)
    }

    private static func titleText(_ title: String, theme: ThemeTokens) -> NSAttributedString {
        NSAttributedString(string: title, attributes: [.font: NSFont.ui(size: 15, weight: .semibold), .foregroundColor: NSColor(theme.text)])
    }

    func show(_ entry: NoteRecord, cover: CardCovers.Cover, fields: GalleryFields?) {
        title.attributed = Self.titleText(entry.title, theme: theme)
        setAccessibilityLabel(entry.title)
        toolTip = String(localized: "Open \(entry.title)")
        dragResource = .file(entry.path)
        dragTitle = entry.title
        self.cover = cover
        let paper = NSColor(theme.background)
        let bandColor = paper.blended(withFraction: 0.03, of: NSColor(theme.text)) ?? paper
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        band.backgroundColor = bandColor.cgColor
        hairline.backgroundColor = NSColor(theme.separator).withAlphaComponent(0.5).cgColor
        previewFade.colors = [bandColor.withAlphaComponent(0).cgColor, bandColor.cgColor]
        CATransaction.commit()
        switch cover {
        case .image(let url):
            picture.show(url, style: theme.dither)
            preview.attributed = NSAttributedString()
        case .preview(let blocks):
            picture.show(nil, style: theme.dither)
            preview.attributed = NotePreviewText.attributed(blocks, singleLines: true, theme: theme)
        }
        if let fields {
            if let fieldsHost {
                fieldsHost.rootView = fields
            } else {
                let host = FieldsHostingView(rootView: fields)
                host.safeAreaRegions = []
                host.sizingOptions = []
                content.addSubview(host)
                fieldsHost = host
            }
            fieldsHost?.isHidden = false
        } else {
            fieldsHost?.isHidden = true
        }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let width = bounds.width
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        band.frame = CGRect(x: 0, y: 0, width: width, height: Self.coverHeight)
        picture.frame = band.frame
        picture.isHidden = { if case .image = cover { return false } else { return true } }()
        preview.frame = CGRect(x: 14, y: 12, width: max(0, width - 28), height: Self.coverHeight - 12)
        preview.isHidden = !picture.isHidden
        previewFade.frame = CGRect(x: 0, y: preview.bounds.height * 0.5, width: preview.bounds.width, height: preview.bounds.height * 0.5)
        hairline.frame = CGRect(x: 0, y: Self.coverHeight, width: width, height: 1)
        let inner = max(0, width - 2 * Self.inset)
        let titleHeight = title.height(for: inner)
        title.frame = CGRect(x: Self.inset, y: Self.coverHeight + 1 + Self.inset, width: inner, height: titleHeight)
        if let fieldsHost, !fieldsHost.isHidden {
            let top = title.frame.maxY + 8
            fieldsHost.frame = CGRect(x: Self.inset, y: top, width: inner, height: max(0, bounds.height - top - Self.inset))
        }
        CATransaction.commit()
    }
}

/// The fields a gallery card shows, drawn by their SwiftUI views (every kind of property has its own).
struct GalleryFields: View {
    let model: CollectionViewModel
    let entry: NoteRecord
    let fields: [PropertyRef]
    let theme: ThemeTokens

    var hasValues: Bool { fields.contains { model.value($0, of: entry) != nil } }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(fields, id: \.self) { ref in
                if let value = model.value(ref, of: entry) {
                    PropertyValueView(value, kind: model.kind(ref), options: model.property(ref).options)
                        .font(.ui(size: 13))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .clipped()
        .environment(\.themeTokens, theme)
        .tint(theme.accent)
    }
}

/// The fields only show: a click on them opens the card.
private final class FieldsHostingView: NSHostingView<GalleryFields> {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
