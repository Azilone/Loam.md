import AppKit
import PluginKitUI
import SwiftUI

/// A field's column as the rows draw it: what it holds and how wide it is.
struct TableColumn: Equatable {
    let ref: PropertyRef
    let kind: PropertyKind
    let options: [String]
    let width: CGFloat
}

/// Where a row's cells go at a width: "#", the title taking what the fields leave (at least 220), each field at its
/// width after a 1-point divider, then a divider and the 36 points under the header's "+".
struct TableGeometry {
    let number: CGRect
    let title: CGRect
    let fields: [CGRect]
    let dividers: [CGFloat]

    init(width: CGFloat, fieldWidths: [CGFloat], top: CGFloat = 1, height: CGFloat = TableMetrics.rowHeight) {
        let fixed = TableMetrics.number + 1 + fieldWidths.reduce(0) { $0 + $1 + 1 } + 1 + 36
        let titleWidth = max(TableMetrics.titleMinimum, width - fixed)
        number = CGRect(x: 0, y: top, width: TableMetrics.number, height: height)
        var dividers = [number.maxX]
        title = CGRect(x: number.maxX + 1, y: top, width: titleWidth, height: height)
        var x = title.maxX
        var fields: [CGRect] = []
        for fieldWidth in fieldWidths {
            dividers.append(x)
            fields.append(CGRect(x: x + 1, y: top, width: fieldWidth, height: height))
            x += 1 + fieldWidth
        }
        dividers.append(x)
        self.fields = fields
        self.dividers = dividers
    }
}

/// The table's rows in AppKit: a scroll view whose document places one reused row per entry near the screen. Rows
/// of SwiftUI cells (a `PropertyValueEditor` each) took 215-280 ms to show when the view switched to the table
/// (docs/APPKIT.md). The header stays SwiftUI above it, for its menus.
struct TableRows: NSViewRepresentable {
    let model: CollectionViewModel
    let entries: [NoteRecord]
    let columns: [TableColumn]
    @Environment(\.themeTokens) private var theme

    func makeNSView(context: Context) -> TableScrollView {
        let view = TableScrollView()
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ view: TableScrollView, context: Context) {
        // Rows the page is replacing by another view keep what they show (see `GalleryScrollView`).
        guard model.view.map({ $0.type == "table" }) ?? true else { return }
        view.document.update(model: model, entries: entries, columns: columns, theme: theme)
    }

    /// A short table hugs its rows; a long one takes the height it is given and scrolls.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: TableScrollView, context: Context) -> CGSize? {
        let content = CGFloat(entries.count) * TableRowView.height
        let width = proposal.width ?? 0
        guard entries.count >= 12, let height = proposal.height, height.isFinite else { return CGSize(width: width, height: content) }
        return CGSize(width: width, height: height)
    }
}

final class TableScrollView: NSScrollView {
    let document = TableDocumentView()

    init() {
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
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var mouseDownCanMoveWindow: Bool { false }

    override func tile() {
        super.tile()
        document.widthChanged(contentView.bounds.width)
    }

    /// Rows that fit hand the wheel to what holds them (the note around a table block).
    override func scrollWheel(with event: NSEvent) {
        if document.frame.height <= contentView.bounds.height + 0.5 {
            nextResponder?.scrollWheel(with: event)
        } else {
            super.scrollWheel(with: event)
        }
    }

    @objc private func scrolled() { document.showVisible(animated: false) }
}

final class TableDocumentView: NSView {
    private weak var model: CollectionViewModel?
    private var entries: [NoteRecord] = []
    private var columns: [TableColumn] = []
    private var theme: ThemeTokens = .standard
    private var width: CGFloat = 0
    private var live: [String: TableRowView] = [:]
    private var pool: [TableRowView] = []

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    func update(model: CollectionViewModel, entries: [NoteRecord], columns: [TableColumn], theme: ThemeTokens) {
        let order = self.entries.map(\.path)
        // Sorting, filtering, adding and removing move the rows rather than redrawing them.
        let moved = !order.isEmpty && order != entries.map(\.path)
        self.model = model
        self.entries = entries
        self.columns = columns
        if theme != self.theme {
            self.theme = theme
            for row in Array(live.values) + pool { row.theme = theme }
        }
        relayout(animated: moved)
    }

    func widthChanged(_ newWidth: CGFloat) {
        guard newWidth != width else { return }
        width = newWidth
        relayout(animated: false)
    }

    private func relayout(animated: Bool) {
        guard width > 0 else { return }
        let content = CGFloat(entries.count) * TableRowView.height
        let height = max(content, superview?.bounds.height ?? 0)
        if frame.size != NSSize(width: width, height: height) { setFrameSize(NSSize(width: width, height: height)) }
        // As `scrollBounceBehavior(.basedOnSize)`: rows that fit do not bounce.
        enclosingScrollView?.verticalScrollElasticity = content > (superview?.bounds.height ?? 0) ? .allowed : .none
        showVisible(animated: animated)
    }

    func showVisible(animated: Bool) {
        guard let model, let clip = enclosingScrollView?.contentView else { return }
        let visible = clip.bounds.insetBy(dx: 0, dy: -400)
        let height = TableRowView.height
        var wanted = Set<String>()
        let animate = animated && !Motion.reduceMotion
        if !entries.isEmpty {
            let first = max(0, Int(visible.minY / height))
            let last = min(entries.count - 1, Int(visible.maxY / height))
            if first <= last {
                for index in first...last {
                    let entry = entries[index]
                    let frame = CGRect(x: 0, y: CGFloat(index) * height, width: width, height: height)
                    wanted.insert(entry.path)
                    if let row = live[entry.path] {
                        row.show(entry, number: index + 1, columns: columns, model: model)
                        guard row.frame != frame else { continue }
                        if animate {
                            NSAnimationContext.runAnimationGroup { context in
                                context.duration = Motion.Spring.standard.duration
                                context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1)
                                row.animator().frame = frame
                            }
                        } else {
                            row.frame = frame
                        }
                        continue
                    }
                    let row = pool.popLast() ?? {
                        let made = TableRowView()
                        addSubview(made)
                        return made
                    }()
                    row.theme = theme
                    row.show(entry, number: index + 1, columns: columns, model: model)
                    row.frame = frame
                    row.isHidden = false
                    row.alphaValue = 1
                    live[entry.path] = row
                    if animate { row.enter() }
                }
            }
        }
        let paths = animate ? Set(entries.map(\.path)) : []
        for (path, row) in live where !wanted.contains(path) {
            live[path] = nil
            row.recycle()
            // A row whose entry left fades out in place; one only scrolled away goes back to the pool at once.
            if animate, !paths.contains(path) {
                NSAnimationContext.runAnimationGroup({ context in
                    context.duration = 0.16
                    row.animator().alphaValue = 0
                }, completionHandler: { [weak self, weak row] in
                    MainActor.assumeIsolated {
                        guard let self, let row, !self.live.values.contains(row) else { return }
                        row.isHidden = true
                        self.pool.append(row)
                    }
                })
            } else {
                row.isHidden = true
                pool.append(row)
            }
        }
    }
}

// MARK: - Row

/// A row: its number, the title (a click opens the note, a drag carries it), then the fields, drawn at once into one
/// layer. A click on a field edits it in place: a text field for text and numbers, a toggle for a checkbox, the
/// options' menu for a select, a calendar for a date. The row lightens under the pointer.
final class TableRowView: NSView, NSDraggingSource, NSTextFieldDelegate {
    /// The hairline above, then the 40-point row.
    static let height: CGFloat = TableMetrics.rowHeight + 1

    var theme: ThemeTokens = .standard {
        didSet {
            guard theme != oldValue else { return }
            refresh()
        }
    }
    private weak var model: CollectionViewModel?
    private var entry: NoteRecord?
    private var number = 0
    private var columns: [TableColumn] = []
    private var cells: [TableCell] = []
    private let hover = CALayer()
    private let drawing = TableRowDrawing()
    private var tracking: NSTrackingArea?
    private var mouseDownEvent: NSEvent?
    private var pressed: Region?
    private var editor: NSTextField?
    private var editing: Int?
    private var cancelled = false
    private var tip: NSString = ""

    private enum Region: Equatable {
        case title
        case field(Int)
    }

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        hover.opacity = 0
        layer?.addSublayer(hover)
        addSubview(drawing)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func show(_ entry: NoteRecord, number: Int, columns: [TableColumn], model: CollectionViewModel) {
        self.model = model
        let cells = columns.map { TableCell(kind: $0.kind, value: model.value($0.ref, of: entry), options: $0.options, width: $0.width) }
        guard entry != self.entry || number != self.number || columns != self.columns || cells != self.cells else { return }
        self.entry = entry
        self.number = number
        self.columns = columns
        self.cells = cells
        refresh()
    }

    private func refresh() {
        guard let entry else { return }
        drawing.show(TableRowDrawing.Content(number: number, title: entry.title, cells: cells, theme: theme))
        effectiveAppearance.performAsCurrentDrawingAppearance {
            hover.backgroundColor = NSColor(theme.text.opacity(0.03)).cgColor
        }
        tip = "Open \(entry.path)" as NSString
        setAccessibilityLabel(entry.title)
        needsLayout = true
    }

    /// Back to the pool: an edit in progress is kept, the pointer forgotten.
    func recycle() {
        finishEditing(commit: true)
        setHovered(false)
    }

    /// Appears as a SwiftUI row did (`CollectionMotion.enter`): from a little smaller, anchored at its top, fading in.
    func enter() {
        guard let layer else { return }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        fade.duration = Motion.Spring.standard.duration
        layer.add(fade, forKey: "enterFade")
        let spring = CASpringAnimation(perceptualDuration: Motion.Spring.standard.duration, bounce: Motion.Spring.standard.bounce)
        spring.keyPath = "sublayerTransform.scale.y"
        spring.fromValue = Motion.Metrics.enterScale
        spring.toValue = 1
        layer.add(spring, forKey: "enterScale")
    }

    private var geometry: TableGeometry { TableGeometry(width: bounds.width, fieldWidths: cells.map(\.width)) }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        hover.frame = CGRect(x: 0, y: 1, width: bounds.width, height: TableMetrics.rowHeight)
        CATransaction.commit()
        drawing.frame = bounds
        let geometry = geometry
        removeAllToolTips()
        addToolTip(geometry.title, owner: tip, userData: nil)
        if let editing, let editor, editing < geometry.fields.count {
            editor.frame = editorFrame(geometry.fields[editing])
        }
    }

    // MARK: Pointer

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        // Its own bounds: `.inVisibleRect` reaches past a view that does not clip (see `NativeCardView`).
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { setHovered(true) }
    override func mouseExited(with event: NSEvent) { setHovered(false) }

    func setHovered(_ hovered: Bool) {
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.12)
        hover.opacity = hovered ? 1 : 0
        CATransaction.commit()
    }

    private func region(at point: CGPoint) -> Region? {
        let geometry = geometry
        if point.x >= geometry.title.minX, point.x < geometry.title.maxX { return .title }
        if let index = geometry.fields.firstIndex(where: { point.x >= $0.minX && point.x < $0.maxX }) { return .field(index) }
        return nil
    }

    override func mouseDown(with event: NSEvent) {
        mouseDownEvent = event
        pressed = region(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = mouseDownEvent, pressed == .title, let entry else { return }
        let a = start.locationInWindow, b = event.locationInWindow
        guard hypot(b.x - a.x, b.y - a.y) > 4 else { return }
        mouseDownEvent = nil
        let resource = Resource.file(entry.path)
        let item = NSPasteboardItem()
        item.setData(Data(DragPayload.resource(resource).string.utf8), forType: NSPasteboard.PasteboardType(DragPayload.type.identifier))
        let dragging = NSDraggingItem(pasteboardWriter: item)
        // What follows the pointer is the shell's ghost (`DragGhost`); AppKit's own image is a single clear pixel.
        let origin = convert(a, from: nil)
        dragging.setDraggingFrame(NSRect(x: origin.x, y: origin.y, width: 1, height: 1), contents: NSImage(size: NSSize(width: 1, height: 1)))
        DragSession.shared.begin(.resource(resource), title: entry.title)
        beginDraggingSession(with: [dragging], event: start, source: self)
    }

    override func mouseUp(with event: NSEvent) {
        defer { mouseDownEvent = nil }
        let point = convert(event.locationInWindow, from: nil)
        guard mouseDownEvent != nil, bounds.contains(point), let pressed, region(at: point) == pressed else { return }
        switch pressed {
        case .title:
            guard let entry else { return }
            model?.open(entry.path, placement: event.modifierFlags.contains(.command) ? .newTab : .replace)
        case .field(let index):
            edit(index)
        }
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .withinApplication ? [.copy, .move, .generic] : []
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        DragSession.shared.end()
    }

    override func accessibilityPerformPress() -> Bool {
        guard let entry else { return false }
        model?.open(entry.path, placement: .replace)
        return true
    }

    // MARK: Editing

    private func edit(_ index: Int) {
        guard let model, let entry, index < columns.count else { return }
        let column = columns[index], value = cells[index].value
        let cell = geometry.fields[index]
        switch column.kind {
        case .checkbox:
            model.set(column.ref, to: .bool(value != .bool(true)), on: entry.path)
        case .select, .multiselect:
            let menu = PropertyEdits.choicesMenu(model: model, ref: column.ref, path: entry.path, value: value) { [weak self] in
                self?.askNewOption(column: column, path: entry.path, value: value)
            }
            menu.popUp(positioning: nil, at: CGPoint(x: cell.minX + 6, y: cell.maxY), in: self)
        case .date:
            let popover = NSPopover()
            popover.behavior = .transient
            popover.animates = !Motion.reduceMotion
            popover.contentViewController = NSHostingController(rootView: PropertyDatePicker(model: model, ref: column.ref, path: entry.path) {
                [weak popover] in popover?.close()
            }.environment(\.themeTokens, theme))
            popover.show(relativeTo: cell, of: self, preferredEdge: .maxY)
        default:
            beginEditing(index, text: value.map(CollectionViewModel.text) ?? "")
        }
    }

    private func askNewOption(column: TableColumn, path: String, value: PropertyValue?) {
        let alert = NSAlert()
        alert.messageText = String(localized: "New option")
        alert.addButton(withTitle: String(localized: "Add"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
        field.placeholderString = String(localized: "Name")
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        let add: (NSApplication.ModalResponse) -> Void = { [weak model] response in
            guard response == .alertFirstButtonReturn, let model else { return }
            PropertyEdits.addOption(field.stringValue, model: model, ref: column.ref, path: path, value: value)
        }
        if let window { alert.beginSheetModal(for: window, completionHandler: add) } else { add(alert.runModal()) }
    }

    private func editorFrame(_ cell: CGRect) -> CGRect {
        // A borderless field insets its text by 2 points and sits it a little high: line it up with the drawn value.
        let height: CGFloat = 20
        return CGRect(x: cell.minX + 10, y: cell.midY - height / 2 + 1.5, width: cell.width - 20, height: height)
    }

    private func beginEditing(_ index: Int, text: String) {
        finishEditing(commit: true)
        let field = NSTextField(string: text)
        field.isBordered = false
        field.isBezeled = false
        field.focusRingType = .none
        field.drawsBackground = true
        field.backgroundColor = NSColor(theme.background)
        field.font = .ui(size: 13)
        field.textColor = NSColor(theme.text)
        field.usesSingleLineMode = true
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        field.delegate = self
        field.frame = editorFrame(geometry.fields[index])
        addSubview(field)
        editor = field
        editing = index
        cancelled = false
        window?.makeFirstResponder(field)
    }

    private func finishEditing(commit: Bool) {
        guard let field = editor, let index = editing else { return }
        editor = nil
        editing = nil
        let text = field.stringValue
        if field.currentEditor() != nil { window?.makeFirstResponder(nil) }
        field.removeFromSuperview()
        guard commit, let model, let entry, index < columns.count else { return }
        PropertyEdits.commitText(text, model: model, ref: columns[index].ref, path: entry.path, value: cells[index].value)
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        finishEditing(commit: !cancelled)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.cancelOperation(_:)):
            cancelled = true
            finishEditing(commit: false)
            return true
        case #selector(NSResponder.insertNewline(_:)):
            finishEditing(commit: true)
            return true
        default:
            return false
        }
    }
}

/// A field's value in a row, as drawn.
struct TableCell: Equatable {
    let kind: PropertyKind
    let value: PropertyValue?
    let options: [String]
    let width: CGFloat
}

/// A row's look, drawn once into its layer: the hairline above, the dividers, the number, the title, and each value
/// as `PropertyValueView` shows it (text, a link, a checkmark, a date pill, pills cut at the cell's edge).
final class TableRowDrawing: CachedDrawingView {
    struct Content: Equatable {
        var number: Int
        var title: String
        var cells: [TableCell]
        var theme: ThemeTokens
    }

    private var content: Content?

    func show(_ content: Content) {
        guard content != self.content else { return }
        self.content = content
        invalidate()
    }

    override func drawContent(in bounds: CGRect) {
        guard let content else { return }
        let theme = content.theme
        let geometry = TableGeometry(width: bounds.width, fieldWidths: content.cells.map(\.width))
        let separator = NSColor(theme.separator.opacity(0.5))
        separator.setFill()
        CGRect(x: 0, y: 0, width: bounds.width, height: 1).fill()
        for x in geometry.dividers { CGRect(x: x, y: 1, width: 1, height: TableMetrics.rowHeight).fill() }

        let font = NSFont.ui(size: 13)
        let digits = NSFont(descriptor: font.fontDescriptor.addingAttributes([.featureSettings: [[
            NSFontDescriptor.FeatureKey.typeIdentifier: kNumberSpacingType,
            NSFontDescriptor.FeatureKey.selectorIdentifier: kMonospacedNumbersSelector,
        ]]]), size: 13) ?? font
        let numberText = NSAttributedString(string: "\(content.number)", attributes: [.font: digits, .foregroundColor: NSColor(theme.secondaryText)])
        let numberSize = numberText.size()
        numberText.draw(at: CGPoint(x: geometry.number.midX - numberSize.width / 2, y: geometry.number.midY - numberSize.height / 2))
        Self.line(content.title, font: font, color: NSColor(theme.text), in: geometry.title.insetBy(dx: 12, dy: 0))

        for (cell, rect) in zip(content.cells, geometry.fields) {
            NSGraphicsContext.saveGraphicsState()
            rect.clip()
            draw(cell, in: rect, font: font, theme: theme)
            NSGraphicsContext.restoreGraphicsState()
        }
    }

    private func draw(_ cell: TableCell, in rect: CGRect, font: NSFont, theme: ThemeTokens) {
        let inner = rect.insetBy(dx: 12, dy: 0)
        if cell.kind == .checkbox {
            let on = cell.value == .bool(true)
            guard let image = tintedSymbol(on ? "checkmark.square.fill" : "square", size: 13,
                                           color: on ? NSColor(theme.accent) : NSColor(theme.secondaryText)) else { return }
            let frame = CGRect(x: inner.minX, y: inner.midY - image.size.height / 2, width: image.size.width, height: image.size.height)
            image.draw(in: frame, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            return
        }
        guard let value = cell.value else { return }
        let text = CollectionViewModel.text(value)
        switch cell.kind {
        case .select, .multiselect:
            // Whole pills at their own width, cut by the cell rather than squeezed to "…".
            var x = inner.minX
            for item in PropertyValueView.items(value) {
                guard x < rect.maxX else { break }
                x += Self.pill(item, options: cell.options, at: x, midY: inner.midY) + 4
            }
        case .url:
            Self.line(text, font: font, color: NSColor(theme.link), in: inner)
        case .date where DateValuePill.label(text) != nil:
            Self.datePill(text, font: font, theme: theme, at: inner.minX, midY: inner.midY)
        default:
            Self.line(text, font: font, color: NSColor(theme.text), in: inner)
        }
    }

    /// One line of text in `rect`, centred vertically, cut with "…".
    private static func line(_ text: String, font: NSFont, color: NSColor, in rect: CGRect) {
        guard !text.isEmpty, rect.width > 0 else { return }
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        let string = NSAttributedString(string: text.replacingOccurrences(of: "\n", with: " "),
                                        attributes: [.font: font, .foregroundColor: color, .paragraphStyle: style])
        let height = ceil(font.ascender - font.descender + font.leading)
        string.draw(with: CGRect(x: rect.minX, y: rect.midY - height / 2, width: rect.width, height: height),
                    options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }

    /// An option's pill (`OptionPill`) at `x`; its width.
    private static func pill(_ text: String, options: [String], at x: CGFloat, midY: CGFloat) -> CGFloat {
        let swatch = OptionPalette.swatch(for: text, in: options)
        let size: CGFloat = 12
        let font = NSFont.ui(size: size, weight: .medium)
        let string = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: NSColor(swatch.text)])
        let measured = string.size()
        let rect = CGRect(x: x, y: midY - (measured.height + size * 0.4) / 2,
                          width: ceil(measured.width + size * 1.1), height: ceil(measured.height + size * 0.4))
        let radius = Corners.r(6)
        NSColor(swatch.fill).setFill()
        NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
        NSColor(swatch.text.opacity(0.12)).setStroke()
        let border = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: max(0, radius - 0.5), yRadius: max(0, radius - 0.5))
        border.lineWidth = 1
        border.stroke()
        string.draw(at: CGPoint(x: x + size * 0.55, y: rect.midY - measured.height / 2))
        return rect.width
    }

    /// A date's pill (`DateValuePill`): a calendar and the day, blue, grey once past.
    private static func datePill(_ day: String, font: NSFont, theme: ThemeTokens, at x: CGFloat, midY: CGFloat) {
        let past = String(day.prefix(10)) < DateValuePill.today()
        let colour = NSColor(past ? theme.secondaryText : theme.link)
        let string = NSAttributedString(string: DateValuePill.label(day) ?? day, attributes: [.font: font, .foregroundColor: colour])
        let measured = string.size()
        let icon = tintedSymbol("calendar", size: 11, color: colour)
        let iconWidth = icon.map { $0.size.width + 4 } ?? 0
        let rect = CGRect(x: x, y: midY - (measured.height + 4) / 2, width: ceil(6 + iconWidth + measured.width + 6), height: ceil(measured.height + 4))
        colour.withAlphaComponent(past ? 0.1 : 0.12).setFill()
        let radius = Corners.r(6)
        NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
        if let icon {
            let frame = CGRect(x: x + 6, y: rect.midY - icon.size.height / 2, width: icon.size.width, height: icon.size.height)
            icon.draw(in: frame, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
        string.draw(at: CGPoint(x: x + 6 + iconWidth, y: rect.midY - measured.height / 2))
    }
}
