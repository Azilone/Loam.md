import AppKit
import PluginKitUI

/// The text view: a plain NSTextView on TextKit 2, with a centred column, a hairline under each title (Craft's),
/// clickable task boxes and links. Styling and keyboard behaviours live in `EditorController`.
final class EditorTextView: NSTextView {
    var theme = MarkdownTheme() {
        didSet {
            if theme.columnWidth != oldValue.columnWidth {
                (superview as? EditorClipView)?.fitDocument(force: true)
                centreColumn(in: frame.size)
            }
            if theme != oldValue { styleTitle() }
        }
    }
    var onOpenLink: ((String, NSEvent.ModifierFlags) -> Void)?
    /// Whether the text is the block editor's page (docs/design/BLOCK-EDITOR.md) rather than Markdown: bullets, boxes
    /// and numbers are drawn from each paragraph's block, and the handles that read Markdown are off.
    var blockMode = false
    /// The highlight whose stroke is being drawn, and the display link that draws it (`HighlighterStroke.swift`).
    var highlightReveal: HighlightReveal?
    var highlightLink: CADisplayLink?
    /// In the block editor, a click on a task's box: the task's paragraph.
    var onToggleBlockTask: ((NSRange) -> Void)?
    /// A click on the title of a callout or a `<details>` that folds: its block.
    var onToggleBlockFold: ((NoteBlock.ID) -> Void)?
    /// In the block editor, a click on a component's card (a diagram not drawn): its character's location.
    var onOpenBlockComponent: ((Int) -> Void)?
    /// In the block editor, the Markdown of any selection, marks included, for a paste in Loam.
    var onCopyLoamMarkdown: ((NSRange) -> String?)?
    /// In the block editor, the Markdown of a selection, which a copy puts as plain text.
    var onCopyMarkdown: ((NSRange) -> String?)?
    /// A click on a date pill: the day (`YYYY-MM-DD`) and the modifier keys held. Without it a click selects the pill.
    var onOpenDate: ((String, NSEvent.ModifierFlags) -> Void)?
    /// The title was edited: the new name. False keeps the old one (the rename failed).
    var onRenameTitle: ((String) -> Bool)?
    /// Return or Down in the title: the caret goes to the text.
    var onLeaveTitle: (() -> Void)?

    /// The note's title, shown above the text as Craft's page title and edited in place (a rename); nil for none.
    var pageTitle: String? {
        didSet {
            guard pageTitle != oldValue else { return }
            styleTitle()
            titleField.stringValue = pageTitle ?? ""
            titleField.isHidden = pageTitle == nil
            centreColumn(in: frame.size)
            needsDisplay = true
        }
    }

    /// A view under the title, as wide as the column and scrolling with the text, such as a collection entry's
    /// fields (Craft draws them there); the hairline goes under it. Shown only with a title.
    var titleAccessory: NSView? {
        didSet {
            guard titleAccessory !== oldValue else { return }
            oldValue?.removeFromSuperview()
            if let titleAccessory { addSubview(titleAccessory) }
            centreColumn(in: frame.size)
            needsDisplay = true
        }
    }

    /// The accessory's height, which it reports as its content changes.
    var titleAccessoryHeight: CGFloat = 0 {
        didSet {
            guard titleAccessoryHeight != oldValue else { return }
            centreColumn(in: frame.size)
            needsLayout = true
            needsDisplay = true
        }
    }

    /// Room the accessory takes under the title: none without one.
    private var accessoryRoom: CGFloat {
        guard pageTitle != nil, titleAccessory != nil, titleAccessoryHeight > 0 else { return 0 }
        return Self.accessoryTop + titleAccessoryHeight
    }

    private static let accessoryTop: CGFloat = 18

    /// Room at the top that the page's toolbar covers (the editor scrolls under it).
    var chromeInset: CGFloat = 0 {
        didSet { if chromeInset != oldValue { centreColumn(in: frame.size) } }
    }

    private lazy var titleDelegate = TitleFieldDelegate(owner: self)

    private(set) lazy var titleField: NSTextField = {
        let field = NSTextField(string: "")
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.isEditable = true
        field.lineBreakMode = .byTruncatingTail
        field.cell?.usesSingleLineMode = true
        field.placeholderString = "Untitled"
        field.isHidden = true
        field.delegate = titleDelegate
        addSubview(field)
        return field
    }()

    private func styleTitle() {
        // The title is the page's first heading: a theme that sets its headings sets it too, at least a level 1's size.
        let size = round(theme.fontSize * (theme.headingScales.first ?? 1.35))
        titleField.font = theme.headingWeight == nil
            ? theme.bodyFont(size: size, weight: .semibold)
            : theme.font(theme.headingFamily ?? theme.bodyFamily, size: size, weight: theme.headingWeight ?? .semibold)
        titleField.textColor = theme.headingColor ?? theme.textColor
    }

    private var titleHeight: CGFloat { ceil((titleField.font ?? theme.bodyFont).boundingRectForFont.height * 0.92) }
    /// Room above the title, and between the title's hairline and the text.
    private static let titleTop: CGFloat = 30
    private static let titleBottom: CGFloat = 30

    /// Where the hairline under the title runs, in view coordinates.
    private var titleRuleY: CGFloat { titleField.frame.maxY + accessoryRoom + 10 }
    /// The column's width (true) or the appearance (false) changed: pictures are sized and coloured again.
    var onLayoutChange: ((_ widthOnly: Bool) -> Void)?
    /// A click or a drag ended: the format bar shows over the selection.
    var onMouseUp: (() -> Void)?
    /// A picture's handle is dragged: the line it is on, the width so far (nil: cancelled), and whether the mouse is up.
    var onResizePicture: ((_ line: Int, _ width: CGFloat?, _ finished: Bool) -> Void)?
    /// The view is leaving its window or losing the keyboard focus: floating panels tied to it must close.
    var onDetach: (() -> Void)?
    /// The view entered a window (or left one, nil), so the controller can watch that window.
    var onWindowChange: ((NSWindow?) -> Void)?
    /// Cmd+B, Cmd+I or Cmd+K; true when it was handled.
    var onFormatShortcut: ((FormatAction) -> Bool)?

    /// Plain text, and files and pictures while the host takes them (`fileDropHandler`). Never file promises: a note
    /// or a tab dragged from the sidebar or the tab bar carries one, which a text view takes by default, and the drop
    /// would then never reach the pane (to open or split).
    override var acceptableDragTypes: [NSPasteboard.PasteboardType] {
        [.string] + (fileDropHandler == nil ? [] : FilePasteboard.types)
    }

    /// Files dropped on the text or pasted into it, and the character offset they go to; nil takes no files.
    var fileDropHandler: (([DroppedFile], Int) -> Void)? {
        didSet { if (fileDropHandler == nil) != (oldValue == nil) { updateDragTypeRegistration() } }
    }

    override var readablePasteboardTypes: [NSPasteboard.PasteboardType] {
        super.readablePasteboardTypes + (fileDropHandler == nil ? [] : FilePasteboard.types)
    }

    override func dragOperation(for dragInfo: NSDraggingInfo, type: NSPasteboard.PasteboardType) -> NSDragOperation {
        if fileDropHandler != nil, FilePasteboard.types.contains(type) { return .copy }
        return super.dragOperation(for: dragInfo, type: type)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let point = convert(sender.draggingLocation, from: nil)
        if dropFiles(from: sender.draggingPasteboard, at: point) {
            cleanUpAfterDragOperation()
            return true
        }
        return super.performDragOperation(sender)
    }

    /// The files or the picture on `pasteboard` go to the host, at the character nearest `point`. False when there are
    /// none (text), or the host takes no files.
    @discardableResult
    func dropFiles(from pasteboard: NSPasteboard, at point: NSPoint) -> Bool {
        guard let fileDropHandler, let files = FilePasteboard.files(on: pasteboard, forPaste: false) else { return false }
        window?.makeFirstResponder(self)
        fileDropHandler(files, characterIndexForInsertion(at: point))
        return true
    }

    override func paste(_ sender: Any?) {
        if pasteFiles(from: .general) { return }
        if blockMode, let onPasteText,
           let string = NSPasteboard.general.string(forType: Self.loamMarkdown) ?? NSPasteboard.general.string(forType: .string) {
            asUserEdit { onPasteText(string) }
            return
        }
        asUserEdit { super.paste(sender) }
    }

    /// Loam's own copy: the Markdown of the selection, marks included, which a paste in Loam reads back as it was.
    static let loamMarkdown = NSPasteboard.PasteboardType("com.azilone.loam.markdown")
    /// In the block editor, a paste of text: read as Markdown into blocks.
    var onPasteText: ((String) -> Void)?

    /// Whether the keyboard, a paste or a cut is changing the text, as opposed to the editor's own edits: only the
    /// first leave no orphan syntax behind (`EditorController.balancing`).
    private(set) var isUserEdit = false

    private func asUserEdit(_ body: () -> Void) {
        let outer = isUserEdit
        isUserEdit = true
        defer { isUserEdit = outer }
        body()
    }

    /// The Markdown (the note's own text) and the page's rich text, without syntax characters.
    override func writeSelection(to pboard: NSPasteboard, types: [NSPasteboard.PasteboardType]) -> Bool {
        let written = super.writeSelection(to: pboard, types: types)
        guard written, let storage = textStorage, selectedRange().length > 0 else { return written }
        if blockMode {
            if let markdown = onCopyMarkdown?(selectedRange()) { pboard.setString(markdown, forType: .string) }
            if let markdown = onCopyLoamMarkdown?(selectedRange()) {
                pboard.addTypes([Self.loamMarkdown], owner: nil)
                pboard.setString(markdown, forType: Self.loamMarkdown)
            }
        }
        let rendered = RenderedCopy.attributedString(from: storage, range: selectedRange())
        if rendered.length > 0, let data = try? rendered.data(
            from: NSRange(location: 0, length: rendered.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]
        ) {
            pboard.addTypes([.rtf], owner: nil)
            pboard.setData(data, forType: .rtf)
        }
        return true
    }

    override func insertText(_ string: Any, replacementRange: NSRange) {
        asUserEdit { super.insertText(string, replacementRange: replacementRange) }
    }

    override func doCommand(by selector: Selector) {
        asUserEdit { super.doCommand(by: selector) }
    }

    override func cut(_ sender: Any?) {
        asUserEdit { super.cut(sender) }
    }

    override func delete(_ sender: Any?) {
        asUserEdit { super.delete(sender) }
    }

    /// The files or the picture on `pasteboard` go to the host, at the caret. False when there are none, or text that
    /// wins over a picture, or the host takes no files.
    @discardableResult
    func pasteFiles(from pasteboard: NSPasteboard) -> Bool {
        guard let fileDropHandler, let files = FilePasteboard.files(on: pasteboard, forPaste: true) else { return false }
        fileDropHandler(files, NSMaxRange(selectedRange()))
        return true
    }

    /// For the app's script driver (a developer tool): a paste from the pasteboard sent as `sender`, without touching
    /// the user's clipboard.
    @objc func loamScriptPaste(_ sender: Any?) {
        if let pasteboard = sender as? NSPasteboard { pasteFiles(from: pasteboard) }
    }

    /// For the app's script driver: a drop of `sender["pasteboard"]` at `sender["point"]`, in window coordinates.
    @objc func loamScriptDrop(_ sender: Any?) {
        guard let info = sender as? NSDictionary, let pasteboard = info["pasteboard"] as? NSPasteboard,
              let point = (info["point"] as? NSValue)?.pointValue else { return }
        dropFiles(from: pasteboard, at: convert(point, from: nil))
    }

    // MARK: Blocks

    /// The handle by the block under the pointer, and the line showing where a dragged block lands (`BlockHandle`).
    let blockHandle = BlockHandleView()
    let dropLine: NSView = {
        let line = NSView()
        line.wantsLayer = true
        line.layer?.cornerRadius = 1
        line.isHidden = true
        return line
    }()
    // MARK: Folds

    /// The headings that can fold, and the bodies of those folded, which the page leaves out (`HeadingFolding`).
    var foldSections: [HeadingFolds.Section] = []
    var foldedBodies: [NSRange] = []
    /// The chevron by the heading under the pointer.
    let foldChevron = FoldChevronView()
    /// A click on a heading's chevron or a folded heading's pill.
    var onToggleFold: ((HeadingFolds.Section) -> Void)?
    /// The pictures of the page moving while a heading folds or unfolds.
    var foldTransition: NSView?
    let foldingDelegate = FoldingContentDelegate()

    /// The blocks of the text they were found in.
    var cachedBlocks: (text: String, blocks: [MarkdownBlock])?
    /// A block dragged by its handle: the block, and the block it goes before (nil: the end of the note).
    var onMoveBlock: ((MarkdownBlock, MarkdownBlock?) -> Void)?
    /// Option-Command-Up or Down: the block at the caret moves over its neighbour; true when it was handled.
    var onMoveBlockByKey: ((_ up: Bool) -> Bool)?

    /// A block selected whole by a click on its handle, and the text that selects it.
    struct BlockSelection: Equatable {
        let block: MarkdownBlock
        let range: NSRange
    }

    /// The block selected by its handle, while the selection is still its text: drawn as Craft's selected block (a
    /// tint behind the block, its box or dot included) instead of selected text, and Delete removes its lines.
    var blockSelection: BlockSelection? {
        didSet {
            guard blockSelection != oldValue else { return }
            hideTextHighlight()
            needsDisplay = true
        }
    }

    override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting: Bool) {
        let before = textSelectionArea()
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
        if let blockSelection, selectedRanges.count != 1 || selectedRange() != blockSelection.range { self.blockSelection = nil }
        // `drawTextSelection` paints the highlight in the page's background, which TextKit does not redraw when the
        // selection moves: without this it showed one change late (a click away brought back the last one).
        if let area = [before, textSelectionArea()].compactMap({ $0 }).reduce(nil, { $0?.union($1) ?? $1 }) {
            setNeedsDisplay(area.insetBy(dx: -2, dy: -2))
        }
    }

    /// Where `drawTextSelection` paints, within the visible part of the page; nil when it paints nothing.
    private func textSelectionArea() -> NSRect? {
        // A caret paints nothing: no need to find the laid out part, twice per keystroke.
        guard selectedRange().length > 0 else { return nil }
        // Only the laid out part: a whole note selected would lay out every line at each step of a drag.
        let shown = NSIntersectionRange(selectedRange(), drawnRange())
        guard blockSelection == nil, shown.length > 0 else { return nil }
        let area = selectionBoxes(for: shown).reduce(NSRect.null) { $0.union($1) }.intersection(visibleRect)
        return area.isEmpty ? nil : area
    }

    /// TextKit draws the selection's highlight in a view of its own over the page's drawing: a box the height of each
    /// whole line, line height included, and over what the page draws in place of hidden syntax (a task's box, a
    /// bullet). So it is hidden, and `drawTextSelection` draws the highlight in the theme's accent instead. The
    /// highlight's colour cannot do it: a window in the background draws it grey whatever the colour asked for.
    /// TextKit makes that view lazily and shows it again as the selection changes: its opacity says it, set again
    /// when the view comes and before each drawing.
    private func hideTextHighlight() {
        for view in subviews where Self.isTextHighlight(view) && view.alphaValue != 0 {
            view.alphaValue = 0
        }
    }

    private static func isTextHighlight(_ view: NSView) -> Bool {
        NSStringFromClass(type(of: view)).contains("Selection")
    }

    override func keyDown(with event: NSEvent) {
        // Typing hides the handle, as in Notion; the pointer moving shows it again.
        hideBlockHandle()
        if moveBlock(for: event) { return }
        super.keyDown(with: event)
    }

    /// Option-Command-Up or Down moves the block at the caret; true when it did (or could not, at an end).
    private func moveBlock(for event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.function, .numericPad])
        guard modifiers == [.command, .option], event.keyCode == 126 || event.keyCode == 125 else { return false }
        return onMoveBlockByKey?(event.keyCode == 126) == true
    }

    override func didChangeText() {
        super.didChangeText()
        hideBlockHandle()
    }

    // MARK: Embeds

    /// The live views of embeds (players, animated pictures), by the key their marks carry. The controller sets them
    /// at each restyle; the text view keeps them in place under their lines.
    var embedViews: [String: NSView] = [:] {
        didSet {
            for (key, view) in oldValue where embedViews[key] !== view { view.removeFromSuperview() }
            for view in embedViews.values where view.superview !== self { addSubview(view) }
            if !embedViews.isEmpty { needsDisplay = true }
        }
    }

    /// Whether some line shows a picture or an embed, which the column's width and the appearance change.
    var hasPictureMarks: Bool {
        guard let storage = textStorage, storage.length > 0 else { return false }
        var found = false
        storage.enumerateAttribute(.markdownPicture, in: NSRange(location: 0, length: storage.length)) { value, _, stop in
            if value != nil {
                found = true
                stop.pointee = true
            }
        }
        return found
    }

    override func viewWillDraw() {
        super.viewWillDraw()
        placeEmbedViews()
        hideTextHighlight()
    }

    /// Puts each embed's view where its picture would be drawn, and hides the ones whose line is not laid out.
    private func placeEmbedViews() {
        placeResizeHandles()
        guard !embedViews.isEmpty else { return }
        var placed: Set<String> = []
        for (mark, frame) in pictureFrames() {
            guard let key = mark.viewKey, let view = embedViews[key] else { continue }
            if view.frame != frame { view.frame = frame }
            view.isHidden = false
            placed.insert(key)
        }
        for (key, view) in embedViews where !placed.contains(key) { view.isHidden = true }
    }

    // MARK: Resizing pictures

    private let resizeHandles = ResizeHandlesView()

    /// The selected picture whose width can be dragged (the caret on its line), with where it is.
    /// Asked on every cursor-rect reset and every draw (a resize asks on each frame): only the selected picture's
    /// mark is looked for, around the caret (a picture is selected when the caret is on its line), and laid out;
    /// nothing when no picture is selected. Placing every picture laid out the text up to the last one, and looking
    /// through the whole note for the mark was still most of each frame of a sidebar's slide.
    func selectedResizablePicture() -> (PictureMark, NSRect)? {
        guard let storage = textStorage, storage.length > 0 else { return nil }
        let selection = selectedRange()
        guard NSMaxRange(selection) <= storage.length else { return nil }
        let ns = storage.string as NSString
        var near = ns.paragraphRange(for: selection)
        if near.location > 0 { near = NSUnionRange(near, ns.paragraphRange(for: NSRange(location: near.location - 1, length: 0))) }
        var selected: NSRange?
        storage.enumerateAttribute(.markdownPicture, in: near) { value, range, stop in
            guard let mark = value as? PictureMark, mark.isSelected, mark.resizableLine != nil, mark.destination != nil
            else { return }
            selected = range
            stop.pointee = true
        }
        guard let selected else { return nil }
        return pictureFrames(near: selected).first { $0.0.resizableLine != nil && $0.0.isSelected && $0.0.destination != nil }
    }

    /// Shows the handles over the selected picture, and none when there is none.
    private func placeResizeHandles() {
        guard let (_, frame) = selectedResizablePicture() else {
            if resizeHandles.superview != nil {
                resizeHandles.removeFromSuperview()
                window?.invalidateCursorRects(for: self)
            }
            return
        }
        let outset = ResizeHandlesView.outset
        let reach = frame.insetBy(dx: -outset, dy: -outset)
        resizeHandles.accent = theme.accentColor
        if resizeHandles.superview !== self {
            addSubview(resizeHandles, positioned: .above, relativeTo: nil)
        } else if subviews.last !== resizeHandles {
            addSubview(resizeHandles, positioned: .above, relativeTo: nil)
        }
        if resizeHandles.frame != reach {
            resizeHandles.frame = reach
            window?.invalidateCursorRects(for: self)
        }
        resizeHandles.needsDisplay = true
    }

    override func resetCursorRects() {
        // The I-beam's cursor rect took over the window edge's resize pointer as the text followed the edge; they
        // come back once the resize ends.
        guard window?.inLiveResize != true else { return }
        super.resetCursorRects()
        guard let (_, frame) = selectedResizablePicture() else { return }
        for handle in ResizeHandle.all {
            addCursorRect(handle.rect(on: frame).insetBy(dx: -4, dy: -4), cursor: .resizeLeftRight)
        }
    }

    override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        window?.invalidateCursorRects(for: self)
    }

    /// Drags the handle pressed at `start` until the mouse is up: the picture follows, the note changes once.
    private func dragHandle(_ handle: ResizeHandle, of mark: PictureMark, from frame: NSRect, startingWith event: NSEvent) {
        guard let line = mark.resizableLine, let window else { return }
        let startX = convert(event.locationInWindow, from: nil).x
        let startWidth = frame.width
        var width = startWidth
        NSCursor.resizeLeftRight.push()
        defer { NSCursor.pop() }
        while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            let x = convert(next.locationInWindow, from: nil).x
            width = handle.width(from: startWidth, dragging: x - startX, maxWidth: mark.maxWidth)
            if next.type == .leftMouseUp {
                onResizePicture?(line, width == startWidth ? nil : width, true)
                return
            }
            onResizePicture?(line, width, false)
        }
        onResizePicture?(line, nil, true)
    }

    override func setFrameSize(_ newSize: NSSize) {
        let changed = newSize != frame.size
        super.setFrameSize(newSize)
        centreColumn(in: newSize)
        // The clip view's I-beam covers the margins around the text view (`EditorClipView.resetCursorRects`).
        if changed, let clip = superview { window?.invalidateCursorRects(for: clip) }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        onLayoutChange?(false)
    }

    /// The width text takes in the column.
    var columnWidth: CGFloat {
        guard let container = textContainer else { return theme.columnWidth }
        return max(1, container.size.width - 2 * container.lineFragmentPadding)
    }

    /// Room above the text: the toolbar's, then the title's when there is one.
    var topInset: CGFloat {
        chromeInset + (pageTitle == nil ? 32 : Self.titleTop + titleHeight + accessoryRoom + Self.titleBottom)
    }

    /// Room on each side of the column for what is drawn beside the text, such as a table's `+` handles.
    static let sideRoom: CGFloat = 64

    /// How wide the text view is in a clip view `width` wide (`EditorClipView`): the column and the room on each
    /// side, or the whole width when that is less.
    func fittingWidth(in width: CGFloat) -> CGFloat {
        min(width, Self.columnContainerWidth(in: width, column: theme.columnWidth) + 2 * Self.sideRoom)
    }

    /// The text container's width in a view `width` wide: the theme's column, narrower only when the view leaves
    /// less than 27 points on each side: with the line fragment's 5, the text starts at `PageMetrics.edge`, under the
    /// toolbar's Back.
    static func columnContainerWidth(in width: CGFloat, column: CGFloat) -> CGFloat {
        max(1, min(column, width - 2 * (PageMetrics.edge - 5)))
    }

    /// Centres the column in the view. The container keeps its width while the view's changes, as it does while a
    /// sidebar slides: only the text's origin moves, and nothing is laid out again. A container tracking the view's
    /// width took the view's new width first and the column's back after, laying the text out twice on each frame.
    private func centreColumn(in size: NSSize) {
        guard let container = textContainer else { return }
        if container.widthTracksTextView { container.widthTracksTextView = false }
        let width = Self.columnContainerWidth(in: size.width, column: theme.columnWidth)
        let horizontal = floor((size.width - width) / 2)
        if pageTitle != nil {
            let padding = container.lineFragmentPadding
            titleField.frame = NSRect(
                x: horizontal + padding - 2, y: chromeInset + Self.titleTop,
                width: max(40, width - 2 * padding + 4), height: titleHeight
            )
        }
        if let accessory = titleAccessory {
            accessory.isHidden = pageTitle == nil
            let padding = container.lineFragmentPadding
            let accessoryFrame = NSRect(
                x: horizontal + padding, y: chromeInset + Self.titleTop + titleHeight + Self.accessoryTop,
                width: max(40, width - 2 * padding), height: max(titleAccessoryHeight, 1)
            )
            if accessory.frame != accessoryFrame { accessory.frame = accessoryFrame }
        }
        if container.size.width != width {
            container.size = NSSize(width: width, height: CGFloat.greatestFiniteMagnitude)
            onLayoutChange?(true)
        }
        // The inset's height is room above and below; the text starts `topInset` down (`textContainerOrigin`), so
        // the rest is below the text: room to scroll the last line up to the middle of the page, as Craft does.
        let visible = enclosingScrollView?.contentSize.height ?? 600
        let vertical = floor((topInset + max(120, visible * 0.45)) / 2)
        if textContainerInset.width != horizontal || textContainerInset.height != vertical {
            textContainerInset = NSSize(width: horizontal, height: vertical)
        }
    }

    /// The column's left edge is the inset `centreColumn` sets. Not `super`'s: with TextKit 2 it lays text out
    /// each time it is asked, and drawing a page asks for it once per block and line.
    override var textContainerOrigin: NSPoint {
        NSPoint(x: textContainerInset.width, y: topInset)
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow !== window {
            onDetach?()
            keepPointer(false)
        }
        super.viewWillMove(toWindow: newWindow)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        onWindowChange?(window)
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { onDetach?() }
        return resigned
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        centreColumn(in: frame.size)
    }

    /// Scrolls so the caret stays clear of the page's edges while typing: a third of the page from the bottom at
    /// most, under the toolbar at the top. Animated, as Craft follows the caret.
    /// The top of the line at `location`, laid out first (with all the text above it) when it is not.
    func lineTop(at location: Int) -> CGFloat? {
        guard let manager = textLayoutManager, let content = manager.textContentManager,
              let start = content.location(content.documentRange.location, offsetBy: max(0, location)) else { return nil }
        // Everything above too: until it is laid out, TextKit 2 only guesses where the line is.
        manager.ensureLayout(for: NSTextRange(location: content.documentRange.location, end: start) ?? NSTextRange(location: start))
        guard let fragment = manager.textLayoutFragment(for: start) else { return nil }
        return fragment.layoutFragmentFrame.minY + textContainerOrigin.y
    }

    /// Makes `change`, then scrolls so the line at `after()` shows where the line at `before` showed. TextKit 2
    /// guesses the height of what is not laid out and guesses again after an edit: without this, what the user was
    /// looking at jumps when a block moves or a picture is resized.
    func keepingOnScreen(_ before: Int, then after: () -> Int, _ change: () -> Void) {
        guard let scrollView = enclosingScrollView, let oldTop = lineTop(at: before) else { return change() }
        let clip = scrollView.contentView
        let offset = oldTop - clip.bounds.minY
        change()
        guard let newTop = lineTop(at: after()) else { return }
        let y = max(0, newTop - offset)
        guard abs(y - clip.bounds.minY) > 0.5 else { return }
        clip.setBoundsOrigin(NSPoint(x: clip.bounds.minX, y: y))
        scrollView.reflectScrolledClipView(clip)
    }

    func keepCaretInView() {
        guard let window, let scrollView = enclosingScrollView, selectedRange().length == 0 else { return }
        let screen = firstRect(forCharacterRange: selectedRange(), actualRange: nil)
        guard screen != .zero else { return }
        let caret = convert(window.convertFromScreen(screen), from: nil)
        let visible = scrollView.contentView.documentVisibleRect
        let bottomMargin = min(160, visible.height * 0.25)
        let topMargin: CGFloat = chromeInset + 32
        var y = visible.minY
        if caret.maxY > visible.maxY - bottomMargin {
            y = caret.maxY + bottomMargin - visible.height
        } else if caret.minY < visible.minY + topMargin {
            y = max(0, caret.minY - topMargin)
        } else {
            return
        }
        y = min(max(0, y), max(0, frame.height - visible.height))
        guard abs(y - visible.minY) > 1 else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Motion.appKitDuration(0.18)
            context.allowsImplicitAnimation = true
            scrollView.contentView.animator().setBoundsOrigin(NSPoint(x: visible.minX, y: y))
        } completionHandler: {
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
    }

    /// No caret on a divider's line: its `---` is invisible, so the caret would sit beside the hairline, past the hidden
    /// dashes. It shows again on the line below, or as soon as the caret is inside the dashes and they show.
    override func drawInsertionPoint(in rect: NSRect, color: NSColor, turnedOn flag: Bool) {
        if onDividerLine { return }
        // Turning the caret off redraws the text under the rect given: the whole line's, not the shortened caret, which
        // a font change since it was drawn (bold on a selection) moves, leaving a stale caret that blinks apart.
        super.drawInsertionPoint(in: flag ? caretRect(rect) : rect, color: color, turnedOn: flag)
    }

    /// The caret as tall as the text it stands in, on its baseline side, as Craft's: the line's own height also
    /// holds the room the line height adds above the letters, and a caret that tall looked too big.
    private func caretRect(_ rect: NSRect) -> NSRect {
        guard let storage = textStorage, storage.length > 0 else { return rect }
        let at = min(max(selectedRange().location - 1, 0), storage.length - 1)
        let font = (typingAttributes[.font] ?? storage.attribute(.font, at: at, effectiveRange: nil)) as? NSFont
        guard let font else { return rect }
        let height = ceil((font.ascender - font.descender) * 1.12)
        guard height < rect.height else { return rect }
        // Flipped: the bottom of the line is its maxY; the descender sits a little above it.
        return NSRect(x: rect.minX, y: rect.maxY - height - max(0, -font.descender * 0.25), width: rect.width, height: height)
    }

    private var onDividerLine: Bool {
        guard let storage = textStorage, selectedRange().length == 0 else { return false }
        let line = (storage.string as NSString).lineWithoutBreak(at: selectedRange().location)
        guard line.length > 0 else { return false }
        return storage.attribute(.markdownRule, at: line.location, effectiveRange: nil) != nil
    }

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        if pageTitle != nil, let container = textContainer {
            theme.textColor.withAlphaComponent(0.12).setFill()
            let padding = container.lineFragmentPadding
            NSRect(x: textContainerOrigin.x + padding, y: titleRuleY, width: container.size.width - 2 * padding, height: 1).fill()
        }
        drawBlockSelection()
        let range = drawnRange()
        drawTitleRules(in: range)
        drawBlocks(in: range)
        drawMarks(in: range)
        drawHighlights(in: range)
        // Over the blocks' and marks' fills (a code block, an inline code span): under them it was hidden. It is
        // translucent, so what they draw shows through.
        drawTextSelection()
        if blockMode { drawBlockDecorations(in: range) }
        drawFolds(in: range)
        for (mark, frame) in pictureFrames(near: range) {
            // An embed with the caret on its line is Craft's selected block: a ring in the accent.
            if mark.destination != nil, mark.isSelected, frame.insetBy(dx: -3, dy: -3).intersects(rect) {
                let ring = NSBezierPath(continuousRoundedRect: frame.insetBy(dx: -2, dy: -2), radius: Corners.r(mark.cornerRadius + 2))
                ring.lineWidth = 2
                theme.accentColor.withAlphaComponent(0.7).setStroke()
                ring.stroke()
            }
            guard let image = mark.image, frame.intersects(rect) else { continue }
            NSGraphicsContext.saveGraphicsState()
            if mark.cornerRadius > 0 { NSBezierPath(continuousRoundedRect: frame, radius: Corners.r(mark.cornerRadius)).addClip() }
            image.draw(in: frame, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])
            NSGraphicsContext.restoreGraphicsState()
            if let caption = mark.caption { drawCaption(caption, on: frame) }
        }
    }

    /// Craft's caption on a picture: white text in a dark translucent chip at its bottom right corner.
    private func drawCaption(_ caption: String, on picture: NSRect) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium), .foregroundColor: NSColor.white,
        ]
        let text = caption as NSString
        let size = text.size(withAttributes: attributes)
        let padding = NSSize(width: 7, height: 3)
        let width = min(size.width + 2 * padding.width, picture.width - 12)
        guard width > 2 * padding.width, picture.height > size.height + 20 else { return }
        let chip = NSRect(
            x: picture.maxX - 6 - width, y: picture.maxY - 6 - size.height - 2 * padding.height,
            width: width, height: size.height + 2 * padding.height
        )
        NSColor.black.withAlphaComponent(0.45).setFill()
        NSBezierPath(continuousRoundedRect: chip, radius: Corners.r(6)).fill()
        text.draw(
            with: chip.insetBy(dx: padding.width, dy: padding.height),
            options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: attributes
        )
    }

    /// Where each picture goes: under the line holding its mark, in the room that line's paragraph spacing leaves,
    /// at the start of the column. Only the pictures whose mark is in `drawn` or the paragraph before it, when given:
    /// a picture hangs under its mark.
    func pictureFrames(near drawn: NSRange? = nil) -> [(PictureMark, NSRect)] { blockFrames(.markdownPicture, near: drawn) }

    /// The text from a screen above what shows (a tall table hangs down from its mark) to a little below it: where
    /// block views (tables, live blocks) are placed. Beyond it the views stay where they were placed (an edit on
    /// screen does not move those above it; below, TextKit only estimates the layout and nothing shows), and each
    /// step of a scroll places the views it brings near. Placing every view above the screen cost each keystroke at
    /// the end of a long note a pass over all its tables, and a screen below laid out that screen again after each
    /// Return, which moves it.
    var placedRange: NSRange {
        guard let storage = textStorage, let layout = textLayoutManager, let content = layout.textContentManager else {
            return NSRange(location: 0, length: 0)
        }
        let visible = visibleRect
        let margin = max(visible.height, 400)
        let bottom = visible.maxY + 120 - textContainerOrigin.y
        let top = visible.minY - margin - textContainerOrigin.y
        let documentRange = content.documentRange
        if let viewport = layout.textViewportLayoutController.viewportRange?.location,
           viewport.compare(documentRange.endLocation) != .orderedDescending {
            // Walked from what TextKit shows, a screen or two of fragments each way. Finding the fragments at two
            // points walked every fragment from the note's start: 5-10 ms a keystroke at the end of a long note.
            func offset(_ location: NSTextLocation) -> Int {
                min(storage.length, max(0, content.offset(from: documentRange.location, to: location)))
            }
            var end = storage.length
            layout.enumerateTextLayoutFragments(from: viewport, options: []) { fragment in
                guard fragment.layoutFragmentFrame.minY > bottom else { return true }
                end = offset(fragment.rangeInElement.location)
                return false
            }
            var start = 0
            if top > 0 {
                layout.enumerateTextLayoutFragments(from: viewport, options: [.reverse]) { fragment in
                    guard fragment.layoutFragmentFrame.maxY <= top else { return true }
                    start = offset(fragment.rangeInElement.endLocation)
                    return false
                }
            }
            start = min(start, end)
            return NSRange(location: start, length: end - start)
        }
        // No fragment there: below the text's end (the page's end shows), up to it.
        let end = layout.textLayoutFragment(for: CGPoint(x: 0, y: bottom)).map {
            min(storage.length, max(0, content.offset(from: content.documentRange.location, to: $0.rangeInElement.endLocation)))
        } ?? storage.length
        guard top > 0, let first = layout.textLayoutFragment(for: CGPoint(x: 0, y: top)) else { return NSRange(location: 0, length: end) }
        let start = min(end, max(0, content.offset(from: content.documentRange.location, to: first.rangeInElement.location)))
        return NSRange(location: start, length: end - start)
    }

    /// Where what a block mark stands for goes (a picture, a live view): under the line holding the mark, in the room
    /// that line's paragraph spacing leaves, at the start of the column. Only the marks in `drawn` or the paragraph
    /// before it, when given.
    func blockFrames<Mark: BlockMark>(_ key: NSAttributedString.Key, near drawn: NSRange? = nil) -> [(Mark, NSRect)] {
        guard let storage = textStorage, let layout = textLayoutManager, let content = layout.textContentManager,
              let container = textContainer else { return [] }
        var frames: [(Mark, NSRect)] = []
        let origin = textContainerOrigin
        var searched = NSRange(location: 0, length: storage.length)
        if let drawn {
            let ns = storage.string as NSString
            let before = drawn.location > 0 ? ns.paragraphRange(for: NSRange(location: drawn.location - 1, length: 0)).location : 0
            searched = NSIntersectionRange(NSRange(location: before, length: NSMaxRange(drawn) - before), searched)
        }
        var marks: [(mark: Mark, location: NSTextLocation)] = []
        storage.enumerateAttribute(key, in: searched) { value, range, _ in
            // Under a folded heading: not laid out, nothing to place.
            guard let mark = value as? Mark, !isFolded(range.location),
                  let location = content.location(content.documentRange.location, offsetBy: range.location) else { return }
            marks.append((mark, location))
        }
        // TextKit 2 lays out lazily and estimates what it has not: lay out everything from the first mark to the
        // last, once, or a block whose room moved (a live block above it grew) lands on the text that now sits there.
        // One pass for all the marks: a pass for each repeated the layout of everything above it. Not from the start
        // of the text: the views are placed where the layout draws the text around them, laid out or estimated above,
        // and laying out from the start cost each keystroke at the end of a long note a walk through all of it.
        if let first = marks.first?.location, let last = marks.last?.location,
           let upTo = NSTextRange(location: first, end: last) {
            layout.ensureLayout(for: upTo)
        }
        for (mark, location) in marks {
            guard let fragment = layout.textLayoutFragment(for: location) else { continue }
            let offset = content.offset(from: fragment.rangeInElement.location, to: location)
            guard let line = fragment.textLineFragments.last(where: { $0.characterRange.location <= offset })
                ?? fragment.textLineFragments.last else { continue }
            let top = origin.y + fragment.layoutFragmentFrame.minY + line.typographicBounds.maxY + PictureMark.margin
            frames.append((mark, NSRect(x: origin.x + container.lineFragmentPadding, y: top, width: mark.size.width, height: mark.size.height)))
        }
        return frames
    }

    /// The text was laid out: the live views follow their blocks.
    var onLayout: (() -> Void)?

    override func layout() {
        super.layout()
        onLayout?()
    }

    private var indicatorObservation: NSKeyValueObservation?
    private var fittingIndicator = false

    override func didAddSubview(_ subview: NSView) {
        super.didAddSubview(subview)
        if Self.isTextHighlight(subview) { hideTextHighlight() }
        guard let indicator = subview as? NSTextInsertionIndicator else { return }
        indicatorObservation = indicator.observe(\.frame, options: [.new]) { [weak self] indicator, _ in
            self?.fitInsertionIndicator(indicator)
        }
        fitInsertionIndicator(indicator)
    }

    /// The system caret is as tall as the line, which also holds the room the line height and the paragraph spacing
    /// add: shrink it to the letters it stands in, bottom-aligned, as Craft's is (`caretRect`). It follows the text's
    /// size, so it grows and shrinks with the zoom.
    private func fitInsertionIndicator(_ indicator: NSTextInsertionIndicator) {
        guard !fittingIndicator, let storage = textStorage, storage.length > 0 else { return }
        var frame = indicator.frame
        // The system can place the caret from a layout that is a step behind the text (the empty line after a Return
        // that left a quote): where the line really is, the caret is never missing or squeezed. A line found empty
        // (the end of a paragraph, just after typing) says nothing: taken as it was, it left a caret of no height.
        if let line = caretLineRect(), line.height > 1,
           frame.height < line.height * 0.6 || abs(frame.midY - line.midY) > line.height {
            frame = NSRect(x: frame.minX, y: line.minY, width: frame.width, height: line.height)
        }
        guard frame.height > 1 else { return }
        frame = caretRect(frame)
        guard frame != indicator.frame else { return }
        fittingIndicator = true
        indicator.frame = frame
        fittingIndicator = false
    }

    /// The rectangle of the line the caret is on, in view coordinates.
    func caretLineRect() -> NSRect? {
        guard let layout = textLayoutManager, let content = layout.textContentManager,
              let caret = content.location(content.documentRange.location, offsetBy: selectedRange().location) else { return nil }
        var found: NSRect?
        layout.enumerateTextSegments(in: NSTextRange(location: caret), type: .standard, options: []) { _, frame, _, _ in
            found = frame
            return false
        }
        let origin = textContainerOrigin
        return found.map { $0.offsetBy(dx: origin.x, dy: origin.y) }
    }

    /// The live views, for accessibility: the text view's own children are its text, which leaves out subviews.
    private var liveViews: [NSView] {
        subviews.filter { $0 is LiveBlockHostingView || $0 is TableBlockView || ($0 as? NSScrollView)?.documentView is LiveBlockHostingView }
    }

    override func accessibilityChildren() -> [Any]? {
        (super.accessibilityChildren() ?? []) + liveViews
    }

    /// The characters laid out on screen, or all of them before the first layout. Finding where a mark falls lays its
    /// text out, so marks far off screen are left alone: on a long note, measuring them all took most of each redraw.
    func drawnRange() -> NSRange {
        guard let storage = textStorage, let layout = textLayoutManager, let content = layout.textContentManager,
              let viewport = layout.textViewportLayoutController.viewportRange else {
            return NSRange(location: 0, length: textStorage?.length ?? 0)
        }
        let whole = NSRange(location: 0, length: storage.length)
        let start = content.offset(from: content.documentRange.location, to: viewport.location)
        let end = content.offset(from: content.documentRange.location, to: viewport.endLocation)
        var range = NSIntersectionRange(NSRange(location: start, length: max(0, end - start)), whole)
        // The viewport can lag the text (stuck on the first lines after edits in a window in the background): widen it
        // to the lines under the visible rectangle, laying them out, or the cards there would be skipped.
        let origin = textContainerOrigin
        let top = CGPoint(x: origin.x + (textContainer?.lineFragmentPadding ?? 0) + 1, y: max(0, visibleRect.minY - origin.y))
        // Walked back from the viewport's start, not found from the note's start: that walked every fragment above.
        var from = viewport.location
        layout.enumerateTextLayoutFragments(from: viewport.location, options: [.reverse]) { fragment in
            from = fragment.rangeInElement.location
            return fragment.layoutFragmentFrame.minY > top.y
        }
        var covered = range
        layout.enumerateTextLayoutFragments(from: from, options: [.ensuresLayout]) { fragment in
            let offset = content.offset(from: content.documentRange.location, to: fragment.rangeInElement.location)
            let length = content.offset(from: fragment.rangeInElement.location, to: fragment.rangeInElement.endLocation)
            covered = NSUnionRange(covered, NSIntersectionRange(NSRange(location: offset, length: length), whole))
            return fragment.layoutFragmentFrame.maxY + origin.y < visibleRect.maxY
        }
        range = covered
        return range
    }

    /// What the editor draws in place of hidden syntax: a dot for a bullet, a round checkbox for a task, a bar
    /// along a quote, a hairline for a divider, a pill behind a tag.
    private func drawMarks(in whole: NSRange) {
        guard let storage = textStorage else { return }
        let accent = theme.accentColor
        storage.enumerateAttribute(.markdownTag, in: whole) { value, range, _ in
            guard let drawsHash = value as? Bool, let box = rect(for: range),
                  let font = storage.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont else { return }
            let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: theme.tagColor]
            let padding = MarkdownTheme.tagPadding
            let height = ceil(font.ascender - font.descender) + 4
            let y = textMidY(box) - height / 2
            // From the end of the text back by its width: the line segment can also cover the kerned room before it.
            let start = box.maxX - storage.attributedSubstring(from: range).size().width
            let hash = drawsHash ? ("#" as NSString).size(withAttributes: attributes).width : 0
            let inset: CGFloat = drawsHash ? padding : 3
            let pill = NSRect(x: start - hash - inset, y: y, width: box.maxX - start + hash + 2 * inset, height: height)
            (theme.tagBackgroundColor ?? theme.tagColor.withAlphaComponent(0.12)).setFill()
            let radius = theme.capsuleTags ? pill.height / 2 : 5
            NSBezierPath(continuousRoundedRect: pill, radius: Corners.r(radius)).fill()
            if drawsHash {
                ("#" as NSString).draw(at: NSPoint(x: start - hash, y: y + 2), withAttributes: attributes)
            }
        }
        storage.enumerateAttribute(.markdownDate, in: whole) { value, range, _ in
            guard let mark = value as? DatePillMark, let box = rect(for: range) else { return }
            // From the start of the hidden text, which takes no room: the line segment leaves out the kerned room
            // after it, which the pill fills.
            // In the block editor the pill stands a little after its character, so a caret on either side of it
            // stays outside it (the room is in the character's kerning).
            drawDatePill(mark, from: box.minX + (blockMode ? MarkdownTheme.pillGap : 0), midY: textMidY(box))
        }
        storage.enumerateAttribute(.markdownBullet, in: whole) { value, range, _ in
            guard value != nil, let box = rect(for: range) else { return }
            // From the marker's start: its kerning (the room up to the text) widens its box.
            let size: CGFloat = 5.5
            theme.textColor.setFill()
            let y = textMidY(box)
            NSBezierPath(ovalIn: NSRect(x: box.minX + 0.5, y: y - size / 2, width: size, height: size)).fill()
        }
        storage.enumerateAttribute(.markdownTaskBox, in: whole) { value, range, _ in
            guard let checked = value as? Bool, let box = rect(for: range),
                  (storage.attribute(.foregroundColor, at: range.location, effectiveRange: nil) as? NSColor) == .clear
            else { return }
            let size = min(box.height, 16)
            let circle = NSRect(x: box.minX + 1, y: textMidY(box) - size / 2, width: size, height: size)
            // Round, or a square with Things' soft corners.
            let square = theme.squareCheckboxes
            let shape = { (rect: NSRect) in
                square
                    ? NSBezierPath(continuousRoundedRect: rect, radius: Corners.r(rect.width * 0.28))
                    : NSBezierPath(ovalIn: rect)
            }
            if checked {
                (theme.checkboxColor ?? accent).setFill()
                shape(circle).fill()
                let tick = NSBezierPath()
                tick.move(to: NSPoint(x: circle.minX + size * 0.28, y: circle.midY))
                tick.line(to: NSPoint(x: circle.minX + size * 0.44, y: circle.minY + size * 0.68))
                tick.line(to: NSPoint(x: circle.minX + size * 0.74, y: circle.minY + size * 0.32))
                tick.lineWidth = 1.6
                tick.lineCapStyle = .round
                tick.lineJoinStyle = .round
                NSColor.white.setStroke()
                tick.stroke()
            } else {
                let ring = shape(circle.insetBy(dx: 0.75, dy: 0.75))
                ring.lineWidth = 1.5
                (theme.checkboxBorderColor ?? theme.secondaryTextColor.withAlphaComponent(0.6)).setStroke()
                ring.stroke()
            }
        }
        storage.enumerateAttribute(.markdownRule, in: whole) { value, range, _ in
            guard value != nil, let box = rect(for: range), let container = textContainer else { return }
            let x = textContainerOrigin.x + container.lineFragmentPadding
            (theme.ruleColor ?? theme.textColor.withAlphaComponent(0.15)).setFill()
            NSRect(x: x, y: box.midY, width: container.size.width - 2 * container.lineFragmentPadding, height: 1).fill()
        }
    }

    // MARK: The code block bar

    /// The language and copy bar over the code block under the pointer or the caret (`CodeBlockBar`), made the first
    /// time a code block needs it rather than with every note opened.
    private var shownCodeBar: CodeBlockBar?
    var codeBar: CodeBlockBar {
        if let shownCodeBar { return shownCodeBar }
        let bar = CodeBlockBar()
        bar.onSetLanguage = { [weak self] start, language in self?.onSetCodeLanguage?(start, language) }
        bar.onCopy = { [weak self] block in self?.onCopyCode?(block) }
        addSubview(bar)
        shownCodeBar = bar
        return bar
    }
    /// The code bar's language menu and copy button.
    var onSetCodeLanguage: ((Int, String) -> Void)?
    var onCopyCode: ((NSRange) -> Void)?
    /// Where the pointer is over the text, while it is.
    private var pointerInText: NSPoint?

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        pointerInText = nil
        updateCodeBar()
        if !blockHandle.frame.contains(convert(event.locationInWindow, from: nil)) { hideBlockHandle() }
        if !foldChevron.frame.contains(convert(event.locationInWindow, from: nil)) { updateFoldChevron(at: nil) }
        // The I-beam was set on each move, not by a cursor rect, so nothing takes it back once the pointer is out:
        // the SwiftUI views around draw no pointer of their own. Only out of the text view, not out of one of the
        // smaller areas it tracks inside.
        if !visibleRect.contains(convert(event.locationInWindow, from: nil)) {
            keepPointer(false)
            NSCursor.arrow.set()
        }
    }

    // MARK: Keeping the pointer

    /// Puts back the pointer the text wants, while the pointer is over it, once AppKit is done with each turn of the
    /// run loop. AppKit sets the pointer again whenever something moves or changes in the window (the block handle
    /// following the pointer, a frame of an animation), and asks the window's views for it in their order rather than
    /// through SwiftUI's hit testing: the view SwiftUI lays over the editor to draw what is above it (the page's
    /// toolbar, the glass at the edges) took the question and set the arrow, after the I-beam of each move. The pointer
    /// flickered between the two over the text, and stayed an arrow over links.
    private var pointerKeeper: CFRunLoopObserver?
    /// The cursor last found right, so the pointer is looked up again only once something else has set another.
    private var keptCursor: NSCursor?

    private func keepPointer(_ on: Bool) {
        if on, pointerKeeper == nil {
            // Last of the observers before the run loop sleeps: after AppKit's display cycle.
            let observer = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue, true, CFIndex.max) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.restorePointer() }
            }
            CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
            pointerKeeper = observer
        } else if !on, let observer = pointerKeeper {
            CFRunLoopObserverInvalidate(observer)
            pointerKeeper = nil
            keptCursor = nil
        }
    }

    private func restorePointer() {
        guard let window, window.isKeyWindow, NSApp.isActive, NSEvent.pressedMouseButtons == 0,
              NSCursor.current !== keptCursor else { return }
        let location = window.mouseLocationOutsideOfEventStream
        // Over another window (a menu, the format bar) the pointer is that window's.
        guard visibleRect.contains(convert(location, from: nil)),
              NSWindow.windowNumber(at: NSEvent.mouseLocation, belowWindowWithWindowNumber: 0) == window.windowNumber,
              let event = NSEvent.enterExitEvent(
                with: .cursorUpdate, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, trackingNumber: 0, userData: nil
              )
        else { return }
        cursorUpdate(with: event)
        keptCursor = NSCursor.current
    }

    /// The code block whose card holds `point` (text view points): its range, language and card; nil for a block
    /// drawn as a picture or a live view.
    private func codeBlock(at point: NSPoint) -> (range: NSRange, language: String, card: NSRect)? {
        guard let storage = textStorage, storage.length > 0 else { return nil }
        let index = min(characterIndexForInsertion(at: point), storage.length - 1)
        for candidate in [index, index - 1] where candidate >= 0 {
            if let found = codeBlock(containing: candidate), found.card.insetBy(dx: 0, dy: -4).contains(point) { return found }
        }
        return nil
    }

    private func codeBlock(containing index: Int) -> (range: NSRange, language: String, card: NSRect)? {
        guard let storage = textStorage, let container = textContainer, index < storage.length else { return nil }
        var range = NSRange()
        guard let language = storage.attribute(.markdownCodeBlock, at: index, longestEffectiveRange: &range,
                                               in: NSRange(location: 0, length: storage.length)) as? String,
              let box = rect(for: range) else { return nil }
        if NSMaxRange(range) > 0,
           let mark = (storage.attribute(.markdownPicture, at: NSMaxRange(range) - 1, effectiveRange: nil)
               ?? storage.attribute(.markdownLiveBlock, at: NSMaxRange(range) - 1, effectiveRange: nil)) as? BlockMark,
           mark.caret != nil { return nil }
        let left = textContainerOrigin.x + container.lineFragmentPadding
        let width = container.size.width - 2 * container.lineFragmentPadding
        return (range, language, NSRect(x: left, y: box.minY - 2, width: width, height: box.height + 4))
    }

    /// Shows the bar over the block under the pointer, else the one the caret is in, else hides it.
    func updateCodeBar() {
        let selection = selectedRange()
        let found = pointerInText.flatMap(codeBlock(at:))
            ?? (window?.firstResponder === self ? codeBlock(containing: selection.location).flatMap {
                NSLocationInRange(selection.location, $0.range) ? $0 : nil
            } : nil)
        guard let found else { return shownCodeBar?.hide() ?? () }
        codeBar.show(block: found.range, language: found.language, card: found.card)
    }

    /// Craft's column of line numbers down the left of a code block, apart from the code by a hairline.
    /// The line numbers' font and colour, resolved once per size, colour and appearance. The colour is resolved to
    /// plain sRGB: string drawing copies its attributes, and a dynamic colour (a SwiftUI token's) could copy to nil
    /// in the middle of a live resize, which crashed the app in CoreText.
    private func lineNumberAttributes() -> [NSAttributedString.Key: Any] {
        let size = theme.fontSize.isFinite && theme.fontSize > 0 ? theme.fontSize * 0.8 : 12
        let dynamic = theme.secondaryTextColor.withAlphaComponent(0.55)
        let appearance = NSAppearance.currentDrawing().name
        let key = LineNumberStyle(size: size, color: dynamic, appearance: appearance)
        if let cached = lineNumberCache, cached.key == key { return cached.attributes }
        let color = dynamic.usingColorSpace(.sRGB) ?? NSColor.secondaryLabelColor.usingColorSpace(.sRGB) ?? .gray
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: size, weight: .regular),
            .foregroundColor: color,
        ]
        lineNumberCache = (key, attributes)
        return attributes
    }

    private struct LineNumberStyle: Equatable {
        let size: CGFloat
        let color: NSColor
        let appearance: NSAppearance.Name
    }

    private var lineNumberCache: (key: LineNumberStyle, attributes: [NSAttributedString.Key: Any])?

    private func drawLineNumbers(of block: NSRange, in card: NSRect) {
        guard let storage = textStorage else { return }
        let ns = storage.string as NSString
        let first = ns.lineWithoutBreak(at: block.location)
        let opener = ns.substring(with: first).trimmingCharacters(in: .whitespaces)
        let isFenced = opener.hasPrefix("```") || opener.hasPrefix("~~~")
        var lines: [NSRange] = []
        var location = block.location
        while location <= NSMaxRange(block), location <= ns.length {
            let line = ns.lineWithoutBreak(at: min(location, max(ns.length - 1, 0)))
            if let last = lines.last, NSEqualRanges(last, line) { break }
            lines.append(line)
            location = NSMaxRange(line) + 1
            if location > NSMaxRange(block) { break }
        }
        if isFenced, lines.count >= 2 {
            lines.removeFirst()
            let last = ns.substring(with: lines[lines.count - 1]).trimmingCharacters(in: .whitespaces)
            if last.hasPrefix("```") || last.hasPrefix("~~~") { lines.removeLast() }
        }
        guard !lines.isEmpty else { return }
        let gutter = theme.codeGutter(lines: lines.count)
        let line = NSBezierPath()
        line.move(to: NSPoint(x: card.minX + gutter, y: card.minY + 1))
        line.line(to: NSPoint(x: card.minX + gutter, y: card.maxY - 1))
        theme.textColor.withAlphaComponent(0.07).setStroke()
        line.lineWidth = 1
        line.stroke()
        let attributes = lineNumberAttributes()
        for (index, range) in lines.enumerated() {
            guard let box = lineBox(for: NSRange(location: range.location, length: max(range.length, 1))) else { continue }
            let number = "\(index + 1)" as NSString
            let size = number.size(withAttributes: attributes)
            // On the line's first row, at its text's height: a wrapped line has one number.
            let rowHeight = min(box.height, (theme.fontSize * 0.87) * 1.3 + 2)
            let y = box.minY + (rowHeight - size.height) / 2 + 1
            number.draw(at: NSPoint(x: card.minX + gutter - MarkdownTheme.gutterPadding - size.width, y: y), withAttributes: attributes)
        }
    }

    /// What sits behind the text of a block: a rounded card behind a code block (its language at the top right) and
    /// a GitHub alert, a bar along a quote (Craft's focus block), a pill behind inline code. Only the blocks on
    /// screen (`drawn`), each whole even where it goes on past the screen's edge: measuring them all laid the whole
    /// note out on every redraw, a quarter of a second on a long note, so resizing the page stuttered.
    private func drawBlocks(in drawn: NSRange) {
        guard let storage = textStorage, let container = textContainer else { return }
        let whole = NSRange(location: 0, length: storage.length)
        /// The whole block a part found on screen belongs to.
        func block(_ key: NSAttributedString.Key, _ part: NSRange) -> NSRange {
            var block = NSRange()
            return storage.attribute(key, at: part.location, longestEffectiveRange: &block, in: whole) != nil ? block : part
        }
        let left = textContainerOrigin.x + container.lineFragmentPadding
        let width = container.size.width - 2 * container.lineFragmentPadding
        let edge = theme.textColor.withAlphaComponent(0.07)
        storage.enumerateAttribute(.markdownCodeBlock, in: drawn) { value, part, _ in
            guard let language = value as? String else { return }
            let range = block(.markdownCodeBlock, part)
            // In the block editor the code's last line can be empty (just after Return): its line break's line
            // counts, so the card holds it.
            guard let box = blockMode ? lineBox(for: NSRange(location: range.location, length: min(range.length + 1, max(0, (textStorage?.length ?? 0) - range.location))))
                : rect(for: range) else { return }
            // A block drawn as a picture (a diagram) or a live view has no card while its code is hidden.
            if NSMaxRange(range) > 0,
               let mark = (storage.attribute(.markdownPicture, at: NSMaxRange(range) - 1, effectiveRange: nil)
                   ?? storage.attribute(.markdownLiveBlock, at: NSMaxRange(range) - 1, effectiveRange: nil)) as? BlockMark,
               mark.caret != nil { return }
            // The block editor's code has no fence lines: its card takes the paragraph's spacing around the text.
            let pad: CGFloat = blockMode ? MarkdownTheme.codePadding - 4 : 2
            let card = NSRect(x: left, y: box.minY - pad, width: width, height: box.height + 2 * pad)
            // The bar follows its block as the text above it changes; it stands where the language would be drawn.
            let hasBar = shownCodeBar.map { $0.block?.location == range.location && !$0.isHidden } ?? false
            if hasBar, shownCodeBar?.frame.minY != card.minY + 6 {
                DispatchQueue.main.async { [weak self] in self?.updateCodeBar() }
            }
            let path = NSBezierPath(continuousRoundedRect: card, radius: Corners.r(10))
            theme.codeBackgroundColor.setFill()
            path.fill()
            drawLineNumbers(of: range, in: card)
            edge.setStroke()
            path.lineWidth = 1
            path.stroke()
            guard !language.isEmpty, !hasBar else { return }
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: theme.fontSize * 0.73, weight: .medium),
                .foregroundColor: theme.secondaryTextColor.withAlphaComponent(0.8),
            ]
            let label = language as NSString
            let size = label.size(withAttributes: attributes)
            label.draw(at: NSPoint(x: card.maxX - size.width - 12, y: card.minY + 7), withAttributes: attributes)
        }
        storage.enumerateAttribute(.markdownQuote, in: drawn) { value, part, _ in
            guard let kind = value as? String, let box = lineBox(for: block(.markdownQuote, part)) else { return }
            if kind.isEmpty {
                // The line height's extra room sits above the glyphs: the bar starts where the text does.
                let font = theme.bodyFont
                let natural = font.ascender - font.descender + font.leading
                let top = natural * (max(theme.lineHeightMultiple, 1) - 1) * 0.8
                if let background = theme.quoteBackgroundColor {
                    background.setFill()
                    let band = NSRect(x: left + 1, y: box.minY + top - 5, width: width - 1, height: box.height - top + 9)
                    NSBezierPath(continuousRoundedRect: band, radius: Corners.r(4)).fill()
                }
                (theme.quoteBarColor ?? theme.textColor).setFill()
                let bar = NSRect(x: left + 1, y: box.minY + top, width: 3.5, height: box.height - top - 1)
                NSBezierPath(continuousRoundedRect: bar, radius: Corners.r(1.75)).fill()
                // A quote inside a quote: a bar more for each level, along its own lines (the block editor's depth).
                let quoted = block(.markdownQuote, part)
                storage.enumerateAttribute(.blockQuoteDepth, in: quoted) { value, lines, _ in
                    guard let depth = value as? Int, depth > 1, let inner = lineBox(for: lines) else { return }
                    for level in 1..<depth {
                        let bar = NSRect(x: left + 1 + CGFloat(level) * theme.quoteIndent, y: inner.minY + top, width: 3.5, height: inner.height - top - 1)
                        NSBezierPath(continuousRoundedRect: bar, radius: Corners.r(1.75)).fill()
                    }
                }
            } else {
                let tint = MarkdownTheme.alertColor(kind, accent: theme.accentColor)
                var card = NSRect(x: left, y: box.minY - 4, width: width, height: box.height + 14)
                if blockMode {
                    // The callout's label is drawn in the room above its first line, inside the card.
                    let label = theme.calloutLabelHeight + 6
                    card = NSRect(x: left, y: box.minY - label - 6, width: width, height: box.height + label + 6 + 10)
                }
                tint.withAlphaComponent(0.08).setFill()
                NSBezierPath(continuousRoundedRect: card, radius: Corners.r(10)).fill()
                tint.setFill()
                NSBezierPath(continuousRoundedRect: NSRect(x: card.minX, y: card.minY, width: 3.5, height: card.height), radius: Corners.r(1.75)).fill()
            }
        }
        storage.enumerateAttribute(.markdownInlineCode, in: drawn) { value, range, _ in
            guard value != nil, let font = storage.attribute(.font, at: min(range.location + 1, NSMaxRange(range) - 1), effectiveRange: nil) as? NSFont
            else { return }
            let height = ceil(font.ascender - font.descender) + 5
            for segment in segments(for: range) where segment.width > 1 {
                let pill = NSRect(x: segment.minX, y: textMidY(segment) - height / 2, width: segment.width, height: height)
                let path = NSBezierPath(continuousRoundedRect: pill.insetBy(dx: 0.5, dy: 0.5), radius: Corners.r(6))
                theme.codeBackgroundColor.setFill()
                path.fill()
                edge.setStroke()
                path.lineWidth = 1
                path.stroke()
            }
        }
    }

    /// Craft's date pill: a tinted rounded box, a calendar and the day's name, in the room the hidden text keeps.
    private func drawDatePill(_ mark: DatePillMark, from minX: CGFloat, midY: CGFloat) {
        let font = mark.font
        let colour: NSColor = switch mark.pill.tone {
        case .due: theme.linkColor
        case .overdue: .systemRed
        case .done: theme.secondaryTextColor
        }
        let width = mark.pill.width(font: font) - 2
        let height = ceil(font.ascender - font.descender) + 4
        let pill = NSRect(x: minX + 1, y: midY - height / 2, width: width, height: height)
        colour.withAlphaComponent(mark.pill.tone == .done ? 0.1 : 0.12).setFill()
        NSBezierPath(continuousRoundedRect: pill, radius: Corners.r(6)).fill()
        let iconSize = DatePill.iconSize(font)
        let configuration = NSImage.SymbolConfiguration(pointSize: iconSize, weight: .regular)
            .applying(NSImage.SymbolConfiguration(paletteColors: [colour]))
        if let icon = NSImage.symbol(mark.pill.symbol, accessibilityDescription: nil)?.withSymbolConfiguration(configuration) {
            let size = icon.size
            icon.draw(in: NSRect(x: pill.minX + DatePill.padding + (iconSize - size.width) / 2, y: pill.midY - size.height / 2,
                                 width: size.width, height: size.height))
        }
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: colour]
        let textHeight = ceil(font.ascender - font.descender)
        (mark.pill.label as NSString).draw(
            at: NSPoint(x: pill.minX + DatePill.padding + iconSize + DatePill.gap, y: pill.midY - textHeight / 2),
            withAttributes: attributes
        )
    }

    /// The middle of the text in a line rectangle: the line height multiple adds its room above the glyphs, so it
    /// sits below the rectangle's middle.
    func textMidY(_ box: NSRect) -> CGFloat {
        let extra = box.height * (1 - 1 / max(theme.lineHeightMultiple, 1))
        return box.minY + extra + (box.height - extra) / 2
    }

    /// The selected text's highlight, in the theme's accent: a box per line that hugs its letters, as Craft's.
    private func drawTextSelection() {
        guard blockSelection == nil, selectedRange().length > 0 else { return }
        theme.accentColor.withAlphaComponent(0.25).setFill()
        for box in selectionBoxes(for: selectedRange()) {
            NSBezierPath(continuousRoundedRect: box, radius: Corners.r(4)).fill()
        }
    }

    /// The boxes of a range's lines, in view coordinates: as tall as the font's letters, centred where `textMidY` puts
    /// the text, not the line's whole height.
    func selectionBoxes(for range: NSRange) -> [NSRect] {
        guard let storage = textStorage, let layout = textLayoutManager, let content = layout.textContentManager,
              let start = content.location(content.documentRange.location, offsetBy: range.location),
              let end = content.location(start, offsetBy: range.length),
              let textRange = NSTextRange(location: start, end: end) else { return [] }
        let origin = textContainerOrigin
        var boxes: [NSRect] = []
        layout.enumerateTextSegments(in: textRange, type: .standard, options: []) { segment, frame, _, _ in
            guard let segment else { return true }
            let at = content.offset(from: content.documentRange.location, to: segment.location)
            guard at < storage.length else { return true }
            // The tallest letters of the segment: it can start on a note link or hidden syntax, whose character is set
            // in a 0.1 pt font and would make the box a sliver.
            let end = min(content.offset(from: content.documentRange.location, to: segment.endLocation), storage.length)
            var font: NSFont?
            storage.enumerateAttribute(.font, in: NSRange(location: at, length: max(end - at, 1))) { value, _, _ in
                if let candidate = value as? NSFont, candidate.pointSize > (font?.pointSize ?? 1) { font = candidate }
            }
            let line = frame.offsetBy(dx: origin.x, dy: origin.y)
            let letters = font ?? theme.bodyFont
            let height = ceil((letters.ascender - letters.descender) * 1.12)
            // A kern after a line's last character is not part of the segment: a note link ending its line is
            // all kern, so its room is added.
            var width = line.width
            // The segment of a line carries its line break: the link is the character before it.
            var last = end - 1
            while last > at, (storage.string as NSString).character(at: last) == 0x0A { last -= 1 }
            if last >= at, last + 1 >= end - 1,
               let room = storage.attribute(.kern, at: last, effectiveRange: nil) as? CGFloat, room > 1,
               storage.attribute(.blockAtomText, at: last, effectiveRange: nil) != nil {
                width += room
            }
            guard width > 0 else { return true }
            boxes.append(NSRect(x: line.minX, y: textMidY(line) - height / 2, width: width, height: height))
            return true
        }
        return boxes
    }

    /// The union of the line rectangles a character range covers, in view coordinates.
    /// Where the characters of `range` are on screen, for a menu or a bar to open at: from the text's laid out
    /// lines (`firstRect` gave a rect at the screen's corner below a live block, whose room TextKit had only
    /// estimated). `revealing` scrolls them into view first and keeps the rect in the visible part of the page, for
    /// what opens where the caret types. Nil when the editor is not in a window.
    func screenRect(for range: NSRange, revealing: Bool = true) -> NSRect? {
        guard let window, let layout = textLayoutManager, let content = layout.textContentManager,
              let start = content.location(content.documentRange.location, offsetBy: range.location) else { return nil }
        // Everything above it: a fragment not laid out sits where TextKit estimated it, off by a live block's room.
        if let above = NSTextRange(location: content.documentRange.location, end: start) { layout.ensureLayout(for: above) }
        layout.ensureLayout(for: NSTextRange(location: start))
        if revealing { scrollRangeToVisible(NSRange(location: range.location, length: 0)) }
        guard var box = rect(for: range) ?? lineBox(for: range) else { return nil }
        if box.width < 1 { box.size.width = 1 }
        if revealing {
            let visible = visibleRect
            box.origin.y = min(max(box.minY, visible.minY), max(visible.minY, visible.maxY - box.height))
        }
        return window.convertToScreen(convert(box, to: nil))
    }

    private func rect(for range: NSRange) -> NSRect? {
        segments(for: range).reduce(nil) { union, frame in union.map { $0.union(frame) } ?? frame }
    }

    /// The union of the whole lines (their typographic bounds, not just the glyphs') a character range is on, in
    /// view coordinates.
    func lineBox(for range: NSRange) -> NSRect? {
        guard let layout = textLayoutManager, let content = layout.textContentManager,
              let start = content.location(content.documentRange.location, offsetBy: range.location) else { return nil }
        var union: NSRect?
        layout.enumerateTextLayoutFragments(from: start, options: [.ensuresLayout]) { fragment in
            let offset = content.offset(from: content.documentRange.location, to: fragment.rangeInElement.location)
            guard offset < NSMaxRange(range) else { return false }
            let origin = fragment.layoutFragmentFrame.origin
            for line in fragment.textLineFragments {
                let lineStart = offset + line.characterRange.location
                guard lineStart < NSMaxRange(range), lineStart + line.characterRange.length > range.location else { continue }
                let bounds = line.typographicBounds.offsetBy(dx: origin.x, dy: origin.y)
                union = union.map { $0.union(bounds) } ?? bounds
            }
            return true
        }
        let origin = textContainerOrigin
        return union.map { NSRect(x: $0.minX + origin.x, y: $0.minY + origin.y, width: $0.width, height: $0.height) }
    }

    /// The rectangle of each line a character range covers, in view coordinates.
    func segments(for range: NSRange) -> [NSRect] {
        guard let layout = textLayoutManager, let content = layout.textContentManager,
              let start = content.location(content.documentRange.location, offsetBy: range.location),
              let end = content.location(start, offsetBy: range.length),
              let textRange = NSTextRange(location: start, end: end) else { return [] }
        var frames: [NSRect] = []
        layout.enumerateTextSegments(in: textRange, type: .standard, options: []) { _, frame, _, _ in
            frames.append(frame)
            return true
        }
        let origin = textContainerOrigin
        return frames.map { $0.offsetBy(dx: origin.x, dy: origin.y) }
    }

    /// A hairline across the column under the last line of each heading the theme rules (level 1 by default); a
    /// level 1 heading only when the page has no title of its own (which takes the hairline, as in Craft).
    private func drawTitleRules(in drawn: NSRange) {
        guard let storage = textStorage, let layout = textLayoutManager, let content = layout.textContentManager,
              let container = textContainer else { return }
        let origin = textContainerOrigin
        let padding = container.lineFragmentPadding
        let width = container.size.width - 2 * padding
        (theme.ruleColor ?? theme.textColor.withAlphaComponent(0.12)).setFill()
        storage.enumerateAttribute(.markdownTitle, in: drawn) { value, range, _ in
            guard let level = value as? Int, level > 1 || pageTitle == nil,
                  let start = content.location(content.documentRange.location, offsetBy: NSMaxRange(range) - 1),
                  let fragment = layout.textLayoutFragment(for: start) else { return }
            // The line holding the title's last character: after a trailing newline the fragment also holds the
            // empty line below, which must not take the rule.
            let offset = content.offset(from: fragment.rangeInElement.location, to: start)
            guard let line = fragment.textLineFragments.last(where: { $0.characterRange.location <= offset && offset < NSMaxRange($0.characterRange) })
                ?? fragment.textLineFragments.first else { return }
            let y = origin.y + fragment.layoutFragmentFrame.minY + line.typographicBounds.maxY + 8
            NSRect(x: origin.x + padding, y: y, width: width, height: 1).fill()
        }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let folded = foldedHeading(at: point) {
            onToggleFold?(folded)
            return
        }
        // A click on a link opens it, as Craft's: the hand is over it. Option-click puts the caret in its text, to edit
        // it; a drag from it selects, as from any text.
        let modifiers = event.modifierFlags.intersection([.command, .option, .shift])
        if event.clickCount == 1, modifiers != .option, !modifiers.contains(.shift),
           let link: (String, NSRange) = hit(.markdownLink, at: point) {
            if isClick(startingWith: event) {
                onOpenLink?(link.0, event.modifierFlags)
            } else {
                super.mouseDown(with: event)
                onMouseUp?()
            }
            return
        }
        if event.clickCount == 1, let (mark, frame) = selectedResizablePicture(),
           let handle = ResizeHandle.hit(point, on: frame) {
            dragHandle(handle, of: mark, from: frame, startingWith: event)
            return
        }
        // A double click on an embed opens its file; a click on a picture shows its code or link.
        if let picture = pictureFrames().first(where: { $0.1.contains(point) })?.0 {
            if event.clickCount == 2, let destination = picture.destination {
                onOpenLink?(destination, event.modifierFlags)
                return
            }
            // A diagram opens large, to read and zoom; its code is one button away there.
            if picture.zoomable, let image = picture.image, let caret = picture.caret, !event.modifierFlags.contains(.option) {
                openViewer(image, caret: caret)
                return
            }
            if let caret = picture.caret {
                setSelectedRange(NSRange(location: caret, length: 0))
                window?.makeFirstResponder(self)
                return
            }
            // An embed already showing its link stays selected.
            if picture.destination != nil {
                window?.makeFirstResponder(self)
                return
            }
        }
        // Beside a picture, in the room it takes across the page, a click is on no text: the text's own tracking put
        // the caret on the picture's hidden line (the picture stayed selected) or selected that line's break. The
        // caret goes to the line under the picture instead, as Craft's goes to the next block.
        if !event.modifierFlags.contains(.shift), let line = pictureLine(beside: point) {
            window?.makeFirstResponder(self)
            moveCaret(under: line)
            return
        }
        if blockMode, !event.modifierFlags.contains(.shift), let fold = blockFoldTitle(at: point) {
            onToggleBlockFold?(fold)
            return
        }
        if blockMode, !event.modifierFlags.contains(.shift), let task = blockTaskBox(at: point) {
            // A box is a button: a click checks it, a second click of a double click checks it back, never selects text.
            onToggleBlockTask?(task)
            return
        }
        if blockMode, event.clickCount == 1, let component = blockComponentCard(at: point) {
            onOpenBlockComponent?(component)
            return
        }
        if event.clickCount == 1, !event.modifierFlags.contains(.shift),
           let box: (Bool, NSRange) = hit(.markdownTaskBox, at: point) {
            toggleTask(box.1, checked: box.0)
            return
        }
        // A click on a date pill opens that day's note (Cmd: in a new tab). Option-click, or a click when the host
        // opens no days, selects the pill whole instead: its text shows, `@` replaces it with another day, Delete
        // removes it.
        if event.clickCount == 1, !event.modifierFlags.contains(.shift),
           let date: (DatePillMark, NSRange) = datePill(at: point) {
            if let onOpenDate, !event.modifierFlags.contains(.option) {
                onOpenDate(date.0.pill.day, event.modifierFlags)
                return
            }
            window?.makeFirstResponder(self)
            setSelectedRange(date.1)
            return
        }
        // Returns once the mouse is up: AppKit tracks the drag inside.
        super.mouseDown(with: event)
        onMouseUp?()
    }

    /// Whether the mouse goes up about where it went down: a click, not a drag. A drag is put back in the queue, for the
    /// text's own tracking to select from where it started.
    private func isClick(startingWith event: NSEvent) -> Bool {
        guard let window else { return true }
        let start = event.locationInWindow
        while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            if next.type == .leftMouseUp { return true }
            if hypot(next.locationInWindow.x - start.x, next.locationInWindow.y - start.y) > 4 {
                window.postEvent(next, atStart: true)
                return false
            }
        }
        return true
    }

    /// The lines of the picture whose room holds `point`, outside the picture itself: the band the picture takes across
    /// the page with its margins, and all the page under it when it is on the note's last line. Nil elsewhere.
    func pictureLine(beside point: NSPoint) -> NSRange? {
        guard hasPictureMarks, let storage = textStorage else { return nil }
        let ns = storage.string as NSString
        let frames = pictureFrames()
        var found: NSRange?
        storage.enumerateAttribute(.markdownPicture, in: NSRange(location: 0, length: storage.length)) { value, range, stop in
            guard let mark = value as? PictureMark, let frame = frames.first(where: { $0.0 === mark })?.1,
                  !frame.contains(point) else { return }
            let line = ns.lineRange(for: range)
            let isLast = NSMaxRange(line) == ns.length
            let band = NSRect(x: bounds.minX, y: frame.minY - PictureMark.margin, width: bounds.width,
                              height: isLast ? .greatestFiniteMagnitude : frame.height + 2 * PictureMark.margin)
            if band.contains(point) {
                found = line
                stop.pointee = true
            }
        }
        return found
    }

    /// Puts the caret at the start of the line under `line` (a picture's), adding that line when the note ends on the
    /// picture: there is always somewhere to write under a picture, as under Craft's last block.
    func moveCaret(under line: NSRange) {
        guard let storage = textStorage else { return }
        let ns = storage.string as NSString
        var target = min(NSMaxRange(line), ns.length)
        if target == ns.length, target > 0, ![10, 13].contains(ns.character(at: target - 1)) {
            let end = NSRange(location: target, length: 0)
            guard shouldChangeText(in: end, replacementString: "\n") else { return }
            storage.replaceCharacters(in: end, with: "\n")
            didChangeText()
            target += 1
        }
        setSelectedRange(NSRange(location: target, length: 0))
    }

    /// The diagram shown large, while it is (`PictureViewer`).
    weak var viewer: PictureViewer?
    /// The code page of the diagram whose code starts at the given offset: set by the controller.
    var onEditPictureCode: ((Int) -> PictureViewer.CodeEditing?)?
    /// Called with what closes the viewer when it opens, and with nil once it has closed.
    var onViewerChange: ((@MainActor () -> Void)?) -> Void = { _ in }

    /// Over a diagram the pointer is an arrow, not the text's I-beam: a click there opens it, it types nothing.
    /// The text view sets its I-beam again on every move and cursor update anywhere in its visible rect, even under a
    /// view drawn over it: over a picture (a diagram, an image, an embed), a live view's cards and buttons or the
    /// page's toolbar neither reaches it, so the pointer is an arrow there and does not flicker between the two.
    /// A mouse button is down, or the window is being resized: whoever started that sets the pointer.
    private var isPointerBusyElsewhere: Bool {
        NSEvent.pressedMouseButtons != 0 || window?.inLiveResize == true
    }

    override func mouseMoved(with event: NSEvent) {
        pointerInText = convert(event.locationInWindow, from: nil)
        if isPointerBusyElsewhere { return }
        if visibleRect.contains(pointerInText ?? .zero) { keepPointer(true) }
        updateCodeBar()
        updateBlockHandle(at: pointerInText)
        updateFoldChevron(at: pointerInText)
        switch pointer(for: event) {
        case .text: super.mouseMoved(with: event)
        case .arrow: NSCursor.arrow.set()
        case .resize: NSCursor.resizeLeftRight.set()
        case .hand: NSCursor.pointingHand.set()
        case .grab: NSCursor.openHand.set()
        case .field: NSCursor.iBeam.set()
        case .chrome: if NSCursor.current == NSCursor.iBeam { NSCursor.arrow.set() }
        case .other: break
        }
    }

    override func cursorUpdate(with event: NSEvent) {
        // A drag that began elsewhere (a column's or the window's edge being resized) keeps its own pointer while it
        // passes over the text; a selection being dragged in the text already has the I-beam.
        guard !isPointerBusyElsewhere else { return }
        switch pointer(for: event) {
        case .text: super.cursorUpdate(with: event)
        case .arrow: NSCursor.arrow.set()
        case .resize: NSCursor.resizeLeftRight.set()
        case .hand: NSCursor.pointingHand.set()
        case .grab: NSCursor.openHand.set()
        case .field: NSCursor.iBeam.set()
        case .chrome: if NSCursor.current == NSCursor.iBeam { NSCursor.arrow.set() }
        case .other: break
        }
    }

    /// Who sets the pointer at an event's location: the text (its I-beam), an arrow, a selected picture's resize
    /// handle, a text field drawn over the editor (the Assistant's message field: its I-beam, which the animation
    /// redrawing the window would otherwise lose to the arrow), or another view that sets its own (a table).
    /// The block handle and the fold chevron get theirs here, not from cursor rects: they move with the pointer from
    /// line to line, and each move reset the window's cursor rects, flashing another pointer before this one came back.
    private enum Pointer { case text, arrow, resize, hand, grab, field, chrome, other }

    private func pointer(for event: NSEvent) -> Pointer {
        let point = convert(event.locationInWindow, from: nil)
        // A panel over the text (the format bar, the `/` menu) never takes the keyboard, so the moves still come here:
        // its buttons get an arrow, not the I-beam of the text under them.
        if window?.childWindows?.contains(where: { $0.isVisible && $0.frame.contains(NSEvent.mouseLocation) }) == true {
            return .arrow
        }
        if let (_, frame) = selectedResizablePicture(), ResizeHandle.hit(point, on: frame) != nil { return .resize }
        // The page's toolbar band, buttons and the glass between them: the text only scrolls under it.
        // Its buttons set their own pointer (the hand): only an I-beam coming up from the text is taken back.
        if visibleRect.contains(point), point.y < visibleRect.minY + chromeInset { return .chrome }
        // A task's box is a button.
        if blockMode, blockTaskBox(at: point) != nil || blockFoldTitle(at: point) != nil { return .hand }
        // A date pill opens its day: a link's hand, not the I-beam its hidden characters would give.
        if visibleRect.contains(point), datePill(at: point) != nil { return .hand }
        guard visibleRect.contains(point),
              let hit = window?.contentView?.superview?.hitTest(event.locationInWindow), hit !== self
        else { return isOverPicture(event) ? .arrow : .text }
        var view: NSView? = hit
        var child: NSView?
        while let current = view, current !== self {
            if let text = current as? NSText { return text.isSelectable ? .field : .other }
            if let field = current as? NSTextField { return field.isEditable || field.isSelectable ? .field : .other }
            if current is TableBlockView { return .other }
            child = current
            view = current.superview
        }
        // Outside the text view (a view drawn over it), or in one of the views it shows in the text; its other
        // subviews are TextKit's own, which draw the text.
        guard view === self, let child else { return .arrow }
        if child === blockHandle { return .grab }
        if child === foldChevron { return .arrow }
        let shown = child === titleAccessory || child === shownCodeBar || child is LiveBlockHostingView
            || child is NSScrollView || child is EmbedHostView
        return shown ? .arrow : isOverPicture(event) ? .arrow : .text
    }

    /// Over a picture, or over a folded heading's pill: an arrow there, not the I-beam.
    private func isOverPicture(_ event: NSEvent) -> Bool {
        let point = convert(event.locationInWindow, from: nil)
        if foldedHeading(at: point) != nil { return true }
        guard hasPictureMarks else { return false }
        return pictureFrames().contains { $0.1.contains(point) }
    }

    /// Shows `image` large over the editor's pane; "Edit Code" puts the caret at `caret`, in the code.
    func openViewer(_ image: NSImage, caret: Int) {
        guard viewer == nil, let host = enclosingScrollView?.superview ?? enclosingScrollView else { return }
        let viewer = PictureViewer(image: image)
        viewer.background = backgroundColor
        viewer.codeBackground = theme.codeBackgroundColor
        viewer.codeEditing = onEditPictureCode?(caret)
        viewer.onEditCode = { [weak self] in
            guard let self else { return }
            self.window?.makeFirstResponder(self)
            self.setSelectedRange(NSRange(location: caret, length: 0))
            self.scrollRangeToVisible(NSRange(location: caret, length: 0))
        }
        viewer.onClose = { [weak self] in
            guard let self else { return }
            self.window?.makeFirstResponder(self)
            self.onViewerChange(nil)
        }
        viewer.show(over: host)
        self.viewer = viewer
        onViewerChange { [weak viewer] in viewer?.close() }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if window?.firstResponder === self, moveBlock(for: event) { return true }
        if window?.firstResponder === self, modifiers == .command {
            let action: FormatAction? = switch event.charactersIgnoringModifiers {
            case "b": .toggle(.bold)
            case "i": .toggle(.italic)
            case "k": .link
            default: nil
            }
            if let action, onFormatShortcut?(action) == true { return true }
        }
        // ⌘⇧H highlights the selection, as in Craft.
        if window?.firstResponder === self, modifiers == [.command, .shift], event.charactersIgnoringModifiers?.lowercased() == "h",
           onFormatShortcut?(.toggle(.highlight)) == true {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    /// The date pill drawn under `point`. Found by where it is drawn, not by a character index: the pill's room is
    /// a kern after hidden text, which character lookups at that point miss.
    private func datePill(at point: NSPoint) -> (DatePillMark, NSRange)? {
        guard let storage = textStorage else { return nil }
        var found: (DatePillMark, NSRange)?
        storage.enumerateAttribute(.markdownDate, in: NSRange(location: 0, length: storage.length)) { value, range, stop in
            guard let mark = value as? DatePillMark, let box = rect(for: range) else { return }
            let pill = NSRect(x: box.minX, y: box.minY, width: mark.pill.width(font: mark.font), height: box.height)
            if pill.contains(point) {
                found = (mark, range)
                stop.pointee = true
            }
        }
        return found
    }

    /// The value of `key` on the character under `point`, and the range it covers.
    func hit<Value>(_ key: NSAttributedString.Key, at point: NSPoint) -> (Value, NSRange)? {
        let index = characterIndexForInsertion(at: point)
        if let run: (Value, NSRange) = attributeRun(key, at: index) { return run }
        // A click on a character's right half puts the caret after it: the character before the caret is the one under
        // the pointer, when the pointer is over its room. Beside the text (past a line's last character, under the
        // note's last line) it is over none, and must not open what merely ends there: an address ending its line
        // opened from a click in the empty room after it, once the space typed after the link was not saved.
        let before = index - 1
        guard covers(before, point), let run: (Value, NSRange) = attributeRun(key, at: before) else { return nil }
        return run
    }

    /// Whether `point` is over the room the character at `index` takes on its line, not merely nearest to it: as wide
    /// as the character draws (a hidden one's room being the kern the styling gives it, which is where its chip is
    /// drawn) and as tall as the line, so that a task's box, drawn larger than its characters, still takes a click.
    private func covers(_ index: Int, _ point: NSPoint) -> Bool {
        guard index >= 0, let storage = textStorage, index < storage.length else { return false }
        let range = NSRange(location: index, length: 1)
        var box = rect(for: range) ?? .zero
        if box.width < 1, let room = storage.attribute(.kern, at: index, effectiveRange: nil) as? CGFloat, room > 0 {
            box.size.width = room
        }
        guard box.width > 0 else { return false }
        if let line = lineBox(for: range) {
            box.origin.y = line.minY
            box.size.height = line.height
        }
        return box.insetBy(dx: -1, dy: 0).contains(point)
    }

    /// The value of `key` on the character at `index`, and the whole run it covers.
    func attributeRun<Value>(_ key: NSAttributedString.Key, at index: Int) -> (Value, NSRange)? {
        guard let storage = textStorage, index >= 0, index < storage.length else { return nil }
        var range = NSRange()
        // The longest range, not the effective one: other attributes change inside a task box, and a partial
        // range would make the toggle replace the wrong characters.
        guard let value = storage.attribute(key, at: index, longestEffectiveRange: &range,
                                            in: NSRange(location: 0, length: storage.length)) as? Value else { return nil }
        return (value, range)
    }

    private func toggleTask(_ range: NSRange, checked: Bool) {
        let replacement = checked ? "[ ]" : "[x]"
        guard range.length == 3, let storage = textStorage, shouldChangeText(in: range, replacementString: replacement) else { return }
        storage.replaceCharacters(in: range, with: replacement)
        didChangeText()
        Sounds.taskChecked(done: !checked)
    }
}

/// The title field's keys and edits: Return, Tab or Down go to the text, Escape puts the name back, and leaving the
/// field renames the note.
private final class TitleFieldDelegate: NSObject, NSTextFieldDelegate {
    weak var owner: EditorTextView?

    init(owner: EditorTextView) {
        self.owner = owner
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard let owner else { return false }
        switch selector {
        case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertTab(_:)), #selector(NSResponder.moveDown(_:)):
            owner.onLeaveTitle?()
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            owner.titleField.stringValue = owner.pageTitle ?? ""
            owner.onLeaveTitle?()
            return true
        default:
            return false
        }
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        guard let owner, let old = owner.pageTitle else { return }
        // A name cannot hold a folder separator; blank keeps the old name.
        let name = owner.titleField.stringValue
            .replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != old, owner.onRenameTitle?(name) == true else {
            owner.titleField.stringValue = old
            return
        }
        owner.pageTitle = name
    }
}
