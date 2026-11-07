import AppKit
import PluginKitUI
import SwiftUI
import UniformTypeIdentifiers

/// The text the editor shows. Changing `id` replaces the editor's text with `text`; the editor never reads
/// `text` otherwise, so typing does not round-trip through SwiftUI.
public struct EditorContent: Equatable, Sendable {
    public var id: Int
    public var text: String
    /// Keep the caret and scroll position (a reload of the same note after an outside change), instead of
    /// starting at the top (another note).
    public var keepsSelection: Bool
    /// Put the keyboard focus in the editor.
    public var focus: Bool
    /// Where the caret and the scroll position start when `keepsSelection` is false (a tab restored with its
    /// saved state); nil starts at the top.
    public var initialState: EditorViewState?
    /// The folded headings the note had when it was last shown, for a tab with no `initialState` (it was opened
    /// afresh in the tab); `initialState`'s own folds win.
    public var initialFolds: [Int]

    public init(
        id: Int,
        text: String,
        keepsSelection: Bool = false,
        focus: Bool = false,
        initialState: EditorViewState? = nil,
        initialFolds: [Int] = []
    ) {
        self.initialFolds = initialFolds
        self.id = id
        self.text = text
        self.keepsSelection = keepsSelection
        self.focus = focus
        self.initialState = initialState
    }
}

/// The caret (a UTF-16 offset) and the vertical scroll position of an editor, so a host can save and restore them.
public struct EditorViewState: Codable, Equatable, Sendable {
    public var caret: Int
    public var scrollY: Double
    /// Where the lines of the folded headings start (`HeadingFolds`).
    public var folded: [Int]

    public init(caret: Int, scrollY: Double, folded: [Int] = []) {
        self.caret = caret
        self.scrollY = scrollY
        self.folded = folded
    }
}

/// A plain Markdown editor, styled live as you type, with a `/` menu that inserts standard Markdown.
public struct MarkdownEditorView: NSViewRepresentable {
    public var content: EditorContent
    public var theme: MarkdownTheme
    public var slashItems: [SlashMenuItem]
    /// The entries of the `@` menu for the words typed after `@`, each with its section ("Days").
    public var mentionItems: @MainActor (_ query: String) -> [SlashMenuItem]
    /// The entries of the `[[` menu for the words typed after `[[`: the notes to link.
    public var linkItems: @MainActor (_ query: String) -> [SlashMenuItem]
    /// The languages of fenced code blocks the host draws as pictures (` ```mermaid `), lowercased.
    public var pictureRenderers: [String: PictureRenderer]
    /// How the host shows image links alone on their line (pictures, players); nil shows them as text.
    public var embeds: EmbedProvider?
    /// Files dropped on the text or pasted into it: the Markdown to insert for them, where they were dropped (at the
    /// caret for a paste), on lines of their own; nil inserts nothing. Without it, the editor takes no files.
    public var onDropFiles: (@MainActor ([DroppedFile]) async -> String?)?
    /// The Markdown of files whose import ended after the editor moved on to another note: the host puts it in the
    /// note it was dropped on, which this editor no longer shows.
    public var onLostDrop: (@MainActor (String) -> Void)?
    /// The languages of fenced code blocks the host shows as live views (` ```base `), lowercased.
    public var liveBlocks: [String: LiveBlockProvider]
    public var onChange: (String) -> Void
    /// A click on a link: its destination as written, and the modifier keys held (Command-Option opens beside;
    /// Option alone puts the caret in the link instead).
    public var onOpenLink: (_ destination: String, _ modifiers: NSEvent.ModifierFlags) -> Void
    /// A click on a date pill: the day as `YYYY-MM-DD` and the modifier keys held (Command opens in a new tab). Nil
    /// makes a click select the pill, as Option-click always does.
    public var onOpenDate: ((_ day: String, _ modifiers: NSEvent.ModifierFlags) -> Void)?
    /// The caret moved or the text scrolled.
    public var onViewStateChange: (EditorViewState) -> Void
    /// The note's title, shown above the text and edited in place; nil shows none.
    public var title: String?
    /// The title was edited: renames the note. False when it could not, which puts the old title back.
    public var onRenameTitle: (String) -> Bool
    /// Whether the title has scrolled under the top `chromeInset` (the toolbar), so the host can show it there.
    public var onTitleHiddenChange: (Bool) -> Void
    /// Called with what closes the diagram shown large when it opens, and with nil once it has closed, so the host's
    /// Back can close it before leaving the page.
    public var onViewerChange: ((@MainActor () -> Void)?) -> Void
    /// A view under the title, scrolling with the text (a collection entry's fields); nil shows none.
    public var titleAccessory: AnyView?
    /// Room at the top covered by the host's toolbar: the text starts below it and scrolls under it.
    public var chromeInset: CGFloat
    /// Called once with the controller when the text view is created, so a host can insert text or focus it.
    public var onReady: (EditorController) -> Void

    public init(
        content: EditorContent,
        theme: MarkdownTheme = MarkdownTheme(),
        slashItems: [SlashMenuItem] = SlashMenu.standardItems,
        mentionItems: @escaping @MainActor (_ query: String) -> [SlashMenuItem] = { _ in [] },
        linkItems: @escaping @MainActor (_ query: String) -> [SlashMenuItem] = { _ in [] },
        pictureRenderers: [String: PictureRenderer] = [:],
        embeds: EmbedProvider? = nil,
        onDropFiles: (@MainActor ([DroppedFile]) async -> String?)? = nil,
        onLostDrop: (@MainActor (String) -> Void)? = nil,
        liveBlocks: [String: LiveBlockProvider] = [:],
        onChange: @escaping (String) -> Void,
        onOpenLink: @escaping (_ destination: String, _ modifiers: NSEvent.ModifierFlags) -> Void = { _, _ in },
        onOpenDate: ((_ day: String, _ modifiers: NSEvent.ModifierFlags) -> Void)? = nil,
        onViewStateChange: @escaping (EditorViewState) -> Void = { _ in },
        title: String? = nil,
        onRenameTitle: @escaping (String) -> Bool = { _ in false },
        onTitleHiddenChange: @escaping (Bool) -> Void = { _ in },
        onViewerChange: @escaping ((@MainActor () -> Void)?) -> Void = { _ in },
        titleAccessory: AnyView? = nil,
        chromeInset: CGFloat = 0,
        onReady: @escaping (EditorController) -> Void = { _ in }
    ) {
        self.title = title
        self.onRenameTitle = onRenameTitle
        self.onTitleHiddenChange = onTitleHiddenChange
        self.onViewerChange = onViewerChange
        self.titleAccessory = titleAccessory
        self.chromeInset = chromeInset
        self.content = content
        self.theme = theme
        self.slashItems = slashItems
        self.mentionItems = mentionItems
        self.linkItems = linkItems
        self.pictureRenderers = pictureRenderers
        self.embeds = embeds
        self.onDropFiles = onDropFiles
        self.onLostDrop = onLostDrop
        self.liveBlocks = liveBlocks
        self.onChange = onChange
        self.onOpenLink = onOpenLink
        self.onOpenDate = onOpenDate
        self.onViewStateChange = onViewStateChange
        self.onReady = onReady
    }

    public func makeCoordinator() -> EditorController { EditorController() }

    public func makeNSView(context: Context) -> NSScrollView {
        let controller = context.coordinator
        let scrollView = EditorScrollView()
        scrollView.contentView = EditorClipView()
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = theme.backgroundColor

        let textView = EditorTextView(usingTextLayoutManager: true)
        // Its clip view gives it its width and centres it.
        textView.autoresizingMask = []
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.isContinuousSpellCheckingEnabled = true
        // Substitutions would change the Markdown itself (`---` into an em dash, quotes inside code).
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        // Nor may the first letter of a line (`let a = 1` in a code block) turn into a capital, or a word be corrected.
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticTextCompletionEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.drawsBackground = false
        scrollView.documentView = textView

        controller.attach(textView)
        if BlockSession.isOn { controller.useBlocks(in: textView) }
        update(controller)
        onReady(controller)
        return scrollView
    }

    public func updateNSView(_ scrollView: NSScrollView, context: Context) {
        update(context.coordinator)
    }

    /// The editor goes away with its page: its floating menus must not outlive it.
    public static func dismantleNSView(_ scrollView: NSScrollView, coordinator: EditorController) {
        coordinator.closePanels()
    }

    private func update(_ controller: EditorController) {
        // The typing not yet written goes to the note it was typed in, before `onChange` is another note's.
        if !controller.isShowing(content) { controller.flushChange() }
        controller.theme = theme
        controller.slashItems = slashItems
        controller.mentionItems = mentionItems
        controller.linkItems = linkItems
        controller.pictureRenderers = pictureRenderers
        controller.embeds = embeds
        controller.onDropFiles = onDropFiles
        controller.onLostDrop = onLostDrop
        controller.liveBlockProviders = liveBlocks
        controller.onChange = onChange
        controller.onViewStateChange = onViewStateChange
        controller.textView?.onOpenLink = onOpenLink
        controller.textView?.onOpenDate = onOpenDate
        controller.textView?.onRenameTitle = onRenameTitle
        controller.textView?.onViewerChange = onViewerChange
        controller.onTitleHiddenChange = onTitleHiddenChange
        controller.textView?.chromeInset = chromeInset
        let titleChanged = controller.textView?.pageTitle != title
        controller.textView?.pageTitle = title
        controller.setTitleAccessory(titleAccessory)
        // A new text is styled whole with the new title already: no second pass for the title.
        let shown = controller.show(content)
        if titleChanged, !shown { controller.restyle(everything: true) }
    }
}

/// Keeps the text view styled and handles the keyboard: list continuation, Tab nesting, the `/` and `@` menus.
@MainActor
public final class EditorController: NSObject, NSTextViewDelegate {
    /// A new theme restyles the text, the column and the colours around it.
    var theme = MarkdownTheme() {
        didSet {
            guard theme != oldValue else { return }
            applyThemeToViews()
            restyle(everything: true)
        }
    }
    var slashItems = SlashMenu.standardItems
    var mentionItems: @MainActor (String) -> [SlashMenuItem] = { _ in [] }
    var linkItems: @MainActor (String) -> [SlashMenuItem] = { _ in [] }
    /// A new set of languages restyles; new closures for the same languages do not (SwiftUI passes them again on
    /// every update).
    var pictureRenderers: [String: PictureRenderer] = [:] {
        didSet {
            guard Set(pictureRenderers.keys) != Set(oldValue.keys) else { return }
            if blockSession != nil { componentLanguagesChanged() } else { restyle(everything: true) }
        }
    }
    /// The pictures drawn for fenced code blocks (`applyPictures`), the ones on their way, and the last one shown for
    /// each block, by its rank among them.
    var pictures = PictureCache.shared
    var drawingPictures: Set<PictureRequest> = []
    var lastPictures: [Int: NSImage] = [:]
    /// A host that shows other kinds of files asks again for every embed; new closures for the same kinds do not
    /// restyle (SwiftUI passes them again on every update).
    var embeds: EmbedProvider? {
        didSet {
            guard embeds?.id != oldValue?.id else { return }
            embedCache = EmbedCache()
            restyle(everything: true)
        }
    }
    var embedCache = EmbedCache()
    /// The picture whose width is being dragged (`resizePicture`).
    var resizing: Resizing?
    /// What the host does with dropped and pasted files; the text view takes files only while there is one.
    var onDropFiles: (@MainActor ([DroppedFile]) async -> String?)? {
        didSet { if (onDropFiles == nil) != (oldValue == nil) { connectFileDrops() } }
    }
    var onLostDrop: (@MainActor (String) -> Void)?
    /// Where the files dropped and still being imported go, kept in step with the edits made meanwhile.
    private var dropAnchors: [DropAnchor] = []
    /// The scroll position a restored tab asked for, kept while its embeds load.
    private var restoredScrollY: Double?
    private var settlingEmbeds = false
    /// The languages shown as live views; a new set restyles, as `pictureRenderers`.
    var liveBlockProviders: [String: LiveBlockProvider] = [:] {
        didSet {
            guard Set(liveBlockProviders.keys) != Set(oldValue.keys) else { return }
            if blockSession != nil { componentLanguagesChanged() } else { restyle(everything: true) }
        }
    }
    /// How the text shows Markdown: as a page (no syntax visible whatever the caret does), or as its source.
    public var syntaxMode: SyntaxMode = .rendered {
        didSet {
            guard syntaxMode != oldValue else { return }
            if blockSession != nil || parkedBlockSession != nil { return switchBlockSource() }
            restyle(everything: true)
            textView?.keepCaretInView()
        }
    }
    /// The live blocks of the last restyle, in the order of the text (`applyLiveBlocks`).
    var liveBlocks: [LiveBlock] = []
    /// The tables of the last restyle, shown as components (`applyTableBlocks`).
    var tableBlocks: [TableBlock] = []
    /// The theme the block editor's tables were last shown with.
    var tablesTheme: MarkdownTheme?
    /// The link each embed block makes, by its attribute (`applyBlockEmbeds`).
    var embedLinks: [ObjectIdentifier: (attribute: BlockAttribute, link: EmbedLink?)] = [:]
    /// A table is writing its cells to the text: the guard that keeps the text's own editing out of tables lets it pass.
    var applyingTableEdit = false
    /// The editor moves the text's selection itself, which is not a caret reaching a table.
    var movingSelectionForTable = false
    var lastTableTyping: TableTyping?
    var onChange: (String) -> Void = { _ in }
    var onViewStateChange: (EditorViewState) -> Void = { _ in }
    var onTitleHiddenChange: (Bool) -> Void = { _ in }
    private var titleHidden = false
    private(set) weak var textView: EditorTextView?
    /// Called as the text scrolls or changes height, with how much of it is beyond the top and bottom of the view:
    /// what the glass at the edges follows. Not called for a change that leaves both distances as they were.
    public var onScrollEdges: ((EditorScrollEdges) -> Void)? {
        didSet { lastScrollEdges = nil; publishScrollEdges() }
    }
    private var lastScrollEdges: EditorScrollEdges?

    let undo = UndoManager()
    private var shownID: Int?
    /// The `/` or `@` just typed, which opens its menu once the text has changed.
    private var pendingMenu: MenuTrigger?
    /// The open menu's trigger character. An `@` menu stays tracked while nothing matches the words typed after
    /// it, so "@next" can still become "@next week".
    private var menu: MenuTrigger?
    private var slashPanel: SlashMenuPanel?
    private var panel: SlashMenuPanel {
        if let slashPanel { return slashPanel }
        let panel = SlashMenuPanel()
        panel.model.onChoose = { [weak self] item in self?.choose(item) }
        slashPanel = panel
        return panel
    }
    private var formatBarPanel: FormatBarPanel?
    var formatBar: FormatBarPanel {
        if let formatBarPanel { return formatBarPanel }
        let bar = FormatBarPanel()
        bar.model.onAction = { [weak self] action in self?.perform(action) }
        formatBarPanel = bar
        return bar
    }
    /// Hides the format bar if it was ever shown: the panel is made only when a selection needs it, not by every
    /// note opened (making it costs a window and a hosting view).
    func hideFormatBar() {
        formatBarPanel?.hide()
    }
    /// The fenced and indented code blocks, from the last restyle: the format bar stays away from them.
    private var codeBlocks: [NSRange] = []

    func attach(_ textView: EditorTextView) {
        self.textView = textView
        // A selection only highlights: it keeps each character's own colour, so the characters drawn clear (a task's
        // `[ ]`, a bullet's `-`, a divider's `---`) stay invisible instead of coming back in the selection's text colour.
        // The highlight is `drawTextSelection`'s, in the theme's accent: the system's stays clear.
        textView.selectedTextAttributes = [.backgroundColor: NSColor.clear]
        // No system button floating over a selection's start (Writing Tools): the page's own format bar is the one tool.
        textView.writingToolsBehavior = .none
        textView.delegate = self
        textView.onLeaveTitle = { [weak self] in self?.focusBody() }
        // The pictures scale to the column and follow light and dark mode; a note without any is not restyled.
        textView.onLayoutChange = { [weak self] widthOnly in self?.layoutChanged(widthOnly: widthOnly) }
        connectFileDrops()
        textView.onLayout = { [weak self] in self?.positionLiveViews() }
        textView.onMouseUp = { [weak self] in self?.updateFormatBar() }
        textView.onResizePicture = { [weak self, weak textView] line, width, finished in
            if finished {
                textView?.keepingOnScreen(line, then: { line }) { self?.finishResizingPicture(line: line, width: width) }
            } else if let width { self?.resizePicture(line: line, to: width) }
        }
        textView.onFormatShortcut = { [weak self] action in self?.perform(action) ?? false }
        textView.onEditPictureCode = { [weak self] start in self?.codeEditing(at: start) }
        textView.onSetCodeLanguage = { [weak self] start, language in self?.setCodeLanguage(ofBlockAt: start, to: language) }
        textView.onCopyCode = { [weak self] block in self?.copyCode(of: block) }
        textView.foldingDelegate.textView = textView
        (textView.textLayoutManager?.textContentManager as? NSTextContentStorage)?.delegate = textView.foldingDelegate
        textView.onToggleFold = { [weak self] section in self?.toggleFold(section) }
        textView.onMoveBlock = { [weak self] block, target in self?.moveBlock(block, before: target) }
        textView.onMoveBlockByKey = { [weak self] up in self?.moveBlockAtCaret(up: up) ?? false }
        // The menus are child windows of the text view's window, so they stay on screen unless closed explicitly when
        // the editor goes away (another page or tab), loses the focus, or its window or the app is deactivated.
        textView.onDetach = { [weak self] in self?.closePanels() }
        textView.onWindowChange = { [weak self] window in self?.watch(window) }
        watch(textView.window)
        applyThemeToViews()
        textView.typingAttributes = theme.baseAttributes
        // Undo and redo restyle even when the text view does not report them as a change (outside a key window), so
        // the live views follow.
        for name in [Notification.Name.NSUndoManagerDidUndoChange, .NSUndoManagerDidRedoChange] {
            NotificationCenter.default.addObserver(self, selector: #selector(undoManagerDidChange(_:)), name: name, object: undo)
        }
        if let clip = textView.enclosingScrollView?.contentView {
            clip.postsBoundsChangedNotifications = true
            NotificationCenter.default.addObserver(
                self, selector: #selector(clipViewDidScroll(_:)), name: NSView.boundsDidChangeNotification, object: clip
            )
            // The text growing or shrinking moves the bottom edge without any scrolling.
            textView.postsFrameChangedNotifications = true
            NotificationCenter.default.addObserver(
                self, selector: #selector(textViewDidResize(_:)), name: NSView.frameDidChangeNotification, object: textView
            )
        }
    }

    private var watchedWindow: NSWindow?

    /// Closes the menus when `window` stops being key, closes or is minimised, or the app is deactivated.
    private func watch(_ window: NSWindow?) {
        guard window !== watchedWindow else { return }
        let center = NotificationCenter.default
        if let old = watchedWindow {
            for name in Self.windowEvents { center.removeObserver(self, name: name, object: old) }
        }
        center.removeObserver(self, name: NSApplication.didResignActiveNotification, object: nil)
        watchedWindow = window
        guard let window else { return closePanels() }
        for name in Self.windowEvents {
            center.addObserver(self, selector: #selector(windowLostFocus(_:)), name: name, object: window)
        }
        center.addObserver(self, selector: #selector(windowLostFocus(_:)), name: NSApplication.didResignActiveNotification, object: nil)
    }

    private static let windowEvents: [Notification.Name] = [
        NSWindow.didResignKeyNotification, NSWindow.willCloseNotification, NSWindow.didMiniaturizeNotification,
        NSWindow.didChangeScreenNotification,
    ]

    @objc private func windowLostFocus(_ notification: Notification) { closePanels() }

    /// Closes the `/` and `@` menu and the format bar.
    func closePanels() {
        flushChange()
        closeMenu()
        formatBarPanel?.hide()
    }

    /// The caret, the scroll position and the folded headings now.
    public var viewState: EditorViewState {
        EditorViewState(
            caret: textView?.selectedRange().location ?? 0,
            scrollY: Double(textView?.enclosingScrollView?.contentView.bounds.origin.y ?? 0),
            folded: folds.folded.sorted()
        )
    }

    /// Puts the keyboard focus in the editor: in the title of a new, empty "Untitled" note, as Craft starts a page
    /// by naming it; in the text otherwise.
    public func focus() {
        guard let textView else { return }
        if let title = textView.pageTitle, title.hasPrefix("Untitled"),
           textView.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            textView.window?.makeFirstResponder(textView.titleField)
            textView.titleField.currentEditor()?.selectAll(nil)
            return
        }
        textView.window?.makeFirstResponder(textView)
    }

    /// Replaces the selection with `text` as typing would (undoable, saved), and puts the caret after it. False
    /// when the editor is gone.
    @discardableResult
    public func insertAtCaret(_ text: String) -> Bool {
        guard let textView else { return false }
        if let blockSession { return blockSession.insert(markdown: text) }
        let selection = textView.selectedRange()
        apply(TextEdit(
            range: selection,
            replacement: text,
            selection: NSRange(location: selection.location + (text as NSString).length, length: 0)
        ))
        return true
    }

    /// Runs a `/` menu entry at the caret, as if `/` had been typed there and the entry chosen (the right
    /// sidebar's tiles), then gives the text the keyboard back. False when the editor is gone.
    @discardableResult
    public func insert(_ item: SlashMenuItem) -> Bool {
        guard let textView else { return false }
        closeMenu()
        let caret = textView.selectedRange().location
        run(item, replacing: NSRange(location: caret, length: 0))
        textView.window?.makeFirstResponder(textView)
        return true
    }

    /// Applies `item` over `trigger`. An entry that picks pictures removes the trigger and opens Finder's Open panel
    /// on the window; the files chosen go in at the caret, as if dropped there (copied next to the note). `delay`
    /// lets the menu draw its "Opening Finder…" row before the panel's launch holds up the main thread.
    private func run(_ item: SlashMenuItem, replacing trigger: NSRange, after delay: TimeInterval = 0) {
        if let blockSession, !(item.picksImages && onDropFiles != nil) {
            blockSession.run(item, replacing: trigger, isBlockEntry: slashItems.contains { $0.id == item.id })
            // A link made from the menu: its address is typed in the link field at once.
            if item.id == "link" { _ = beginBlockLinkEdit() }
            return
        }
        guard item.picksImages, onDropFiles != nil, let textView, let window = textView.window else {
            apply(item.makeEdit(textView?.string ?? "", trigger))
            return
        }
        apply(TextEdit(range: trigger, replacement: "", selection: NSRange(location: trigger.location, length: 0)))
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            let panel = NSOpenPanel()
            panel.allowedContentTypes = [.image]
            panel.allowsMultipleSelection = true
            panel.canChooseDirectories = false
            panel.prompt = "Insert".uiLocalized
            panel.beginSheetModal(for: window) { [weak self] response in
                guard let self, let textView = self.textView else { return }
                self.closeMenu()
                window.makeFirstResponder(textView)
                guard response == .OK, !panel.urls.isEmpty else { return }
                self.dropFiles(panel.urls.map { .file($0) }, at: textView.selectedRange().location)
            }
            self?.closeMenu(whenShown: panel)
        }
    }

    /// Closes the menu still saying "Opening Finder…" once `sheet` is on the screen. The sheet taking the keyboard
    /// does it too, but a window in the background never had it.
    private func closeMenu(whenShown sheet: NSWindow) {
        guard menu == nil, slashPanel?.isVisible == true else { return }
        if sheet.isVisible { return closeMenu() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in self?.closeMenu(whenShown: sheet) }
    }

    /// Puts the caret at the start of `line` (1-based) and scrolls so that line is near the top. False when the
    /// editor is gone or the text has no such line.
    @discardableResult
    public func reveal(line: Int) -> Bool {
        guard let textView, let offset = offset(ofLine: line) else { return false }
        let range = NSRange(location: offset, length: 0)
        textView.setSelectedRange(range)
        if let y = y(ofLine: line) {
            textView.scroll(NSPoint(x: 0, y: max(0, y - 8)))
            if let scrollView = textView.enclosingScrollView {
                scrollView.reflectScrolledClipView(scrollView.contentView)
            }
        } else {
            textView.scrollRangeToVisible(range)
        }
        focus()
        return true
    }

    /// Where `line` (1-based) starts in the text view, in points from its top; nil past the last line or before the
    /// text has a layout. Lays the text out up to it.
    public func y(ofLine line: Int) -> CGFloat? {
        blockSession?.finishStyling()
        guard let textView, let offset = offset(ofLine: line),
              let layout = textView.textLayoutManager, let content = layout.textContentManager,
              let location = content.location(content.documentRange.location, offsetBy: offset),
              let upTo = NSTextRange(location: content.documentRange.location, end: location) else { return nil }
        layout.ensureLayout(for: upTo)
        guard let fragment = layout.textLayoutFragment(for: location) else { return nil }
        return fragment.layoutFragmentFrame.minY + textView.textContainerOrigin.y
    }

    /// `y(ofLine:)` for several lines: the text is read once and what shows is laid out once, up to the last of them
    /// or the end of what shows, whichever comes first. Elsewhere the heights are TextKit's estimate: laying out a long
    /// note to its last heading after each pause in typing took up to a second.
    public func ys(ofLines lines: [Int]) -> [CGFloat?] {
        blockSession?.finishStyling()
        guard let textView, let layout = textView.textLayoutManager, let content = layout.textContentManager else {
            return lines.map { _ in nil }
        }
        let offsets = blockSession?.offsets(ofLines: lines) ?? Self.offsets(ofLines: lines, in: textView.string)
        let start = content.documentRange.location
        if let last = offsets.compactMap({ $0 }).max(), var location = content.location(start, offsetBy: last) {
            let viewport = layout.textViewportLayoutController.viewportRange
            if let shown = viewport?.endLocation, shown.compare(location) == .orderedAscending {
                location = shown
            }
            // From what shows: above it too the heights are TextKit's, laid out or estimated, in the same order as
            // the text. Laying out from the note's start took 20-30 ms after each pause in typing at its end.
            let from = viewport.map { $0.location.compare(location) == .orderedAscending ? $0.location : location } ?? start
            if let upTo = NSTextRange(location: from, end: location) { layout.ensureLayout(for: upTo) }
        }
        return offsets.map { offset in
            guard let offset, let location = content.location(start, offsetBy: offset),
                  let fragment = layout.textLayoutFragment(for: location) else { return nil }
            return fragment.layoutFragmentFrame.minY + textView.textContainerOrigin.y
        }
    }

    /// Scrolls so `line` (1-based) comes to the top, under the toolbar, gliding there (`Motion.Spring.smooth`'s
    /// length; a jump under "Reduce motion"). The caret stays where it is.
    public func scroll(toLine line: Int) {
        guard let textView, let scrollView = textView.enclosingScrollView, let y = y(ofLine: line) else { return }
        let clip = scrollView.contentView
        let maxY = max(0, textView.frame.height - clip.bounds.height)
        let target = NSPoint(x: clip.bounds.origin.x, y: min(max(0, y - textView.chromeInset - 12), maxY))
        guard !Motion.reduceMotion else {
            clip.setBoundsOrigin(target)
            scrollView.reflectScrolledClipView(clip)
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Motion.Spring.smooth.duration
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.8, 0.2, 1)
            clip.animator().setBoundsOrigin(target)
            scrollView.reflectScrolledClipView(clip)
        }
    }

    /// Where `line` (1-based) of the note starts in the text view: in the Markdown, or in the block editor's page.
    private func offset(ofLine line: Int) -> Int? {
        if let blockSession { return blockSession.offsets(ofLines: [line]).first ?? nil }
        return textView.flatMap { Self.offset(ofLine: line, in: $0.string) }
    }

    /// The height of the visible part of the text, and of the toolbar's glass over its top.
    public var viewport: (height: CGFloat, topInset: CGFloat) {
        (textView?.enclosingScrollView?.contentView.bounds.height ?? 0, textView?.chromeInset ?? 0)
    }

    /// The UTF-16 offset of the start of `line` (1-based, lines split on `\n`) in `text`; nil past the last line.
    public static func offset(ofLine line: Int, in text: String) -> Int? {
        guard line >= 1 else { return nil }
        if line == 1 { return 0 }
        var current = 1
        for (index, unit) in text.utf16.enumerated() where unit == 10 {
            current += 1
            if current == line { return index + 1 }
        }
        return nil
    }

    /// `offset(ofLine:in:)` for several lines, in one pass over the text.
    public static func offsets(ofLines lines: [Int], in text: String) -> [Int?] {
        guard let highest = lines.max(), highest >= 1 else { return lines.map { _ in nil } }
        var starts = [0]
        if highest > 1 {
            for (index, unit) in text.utf16.enumerated() where unit == 10 {
                starts.append(index + 1)
                if starts.count == highest { break }
            }
        }
        return lines.map { $0 >= 1 && $0 <= starts.count ? starts[$0 - 1] : nil }
    }

    @objc private func undoManagerDidChange(_ notification: Notification) {
        if let blockSession { return blockSession.undoDidChange() }
        restyle()
    }

    @objc private func clipViewDidScroll(_ notification: Notification) {
        positionLiveViews()
        if formatBarPanel?.isVisible == true { updateFormatBar(animated: false) }
        onViewStateChange(viewState)
        updateTitleHidden()
        publishScrollEdges()
    }

    @objc private func textViewDidResize(_ notification: Notification) {
        publishScrollEdges()
    }

    /// Tells the host how much text is beyond each edge now, when that changed.
    private func publishScrollEdges() {
        guard let onScrollEdges, let clip = textView?.enclosingScrollView?.contentView as? EditorClipView else { return }
        let edges = clip.edges
        guard edges != lastScrollEdges else { return }
        lastScrollEdges = edges
        onScrollEdges(edges)
    }

    /// Tells the host when the title passes under the toolbar, or comes back.
    private func updateTitleHidden() {
        guard let textView, let clip = textView.enclosingScrollView?.contentView else { return }
        let hidden = textView.pageTitle != nil && textView.titleField.frame.maxY < clip.bounds.minY + textView.chromeInset + 4
        guard hidden != titleHidden else { return }
        titleHidden = hidden
        onTitleHiddenChange(hidden)
    }

    /// Where the note's text starts: after its frontmatter, and after a first heading that repeats the title.
    private var bodyStart: Int {
        guard let textView, blockSession == nil else { return 0 }
        if let heading = Self.titleHeading(in: textView.string, title: textView.pageTitle) { return NSMaxRange(heading) }
        return MarkdownStyler.frontmatterRange(in: textView.string as NSString).map(NSMaxRange) ?? 0
    }

    /// The note's first line, with the blank line after it, when it is a level 1 heading saying `title` (as most
    /// notes start); nil otherwise.
    static func titleHeading(in text: String, title: String?) -> NSRange? {
        guard let title, !title.isEmpty else { return nil }
        let ns = text as NSString
        let start = MarkdownStyler.frontmatterRange(in: ns).map(NSMaxRange) ?? 0
        guard start < ns.length else { return nil }
        // Blank lines between the frontmatter and the heading go with it.
        var first = start
        var line = ns.lineRange(for: NSRange(location: first, length: 0))
        while ns.substring(with: line).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, NSMaxRange(line) < ns.length {
            line = ns.lineRange(for: NSRange(location: NSMaxRange(line), length: 0))
        }
        let heading = ns.substring(with: line).trimmingCharacters(in: .whitespacesAndNewlines)
        guard heading.hasPrefix("# "),
              heading.dropFirst(2).trimmingCharacters(in: .whitespaces).caseInsensitiveCompare(title) == .orderedSame
        else { return nil }
        if NSMaxRange(line) < ns.length {
            let next = ns.lineRange(for: NSRange(location: NSMaxRange(line), length: 0))
            if ns.substring(with: next).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                line.length += next.length
            }
        }
        first = min(first, line.location)
        return NSRange(location: first, length: NSMaxRange(line) - first)
    }

    /// The caret at the start of the text, from the title.
    func focusBody() {
        guard let textView else { return }
        textView.window?.makeFirstResponder(textView)
        textView.setSelectedRange(NSRange(location: bodyStart, length: 0))
    }

    /// Shows `content` unless it is already shown; true when it did (the text is restyled whole).
    @discardableResult
    /// Whether `content` is what the editor shows already.
    func isShowing(_ content: EditorContent) -> Bool { content.id == shownID }

    func show(_ content: EditorContent) -> Bool {
        guard let textView, content.id != shownID else { return false }
        shownID = content.id
        if let parked = parkedBlockSession, !content.keepsSelection {
            // Another note: the page again, not the source.
            leavingSource = true
            syntaxMode = .rendered
            leavingSource = false
            parkedBlockSession = nil
            blockSession = parked
            textView.blockMode = true
            hiddenSyntax = .none
        }
        if let blockSession {
            closeMenu()
            hideFormatBar()
            if !content.keepsSelection {
                removeTableBlocks()
                removeLiveBlocks()
                // The headings it had folded, as it was left.
                folds = HeadingFolds(folded: content.initialState?.folded ?? content.initialFolds)
            }
            blockSession.theme = theme
            // A restored scroll position needs the whole page's heights: styled at once then.
            blockSession.show(content.text, title: textView.pageTitle, keepsSelection: content.keepsSelection,
                              caret: content.initialState?.caret, stylesFirstScreen: (content.initialState?.scrollY ?? 0) <= 0)
            if !content.keepsSelection {
                textView.scroll(.zero)
                if let scrollY = content.initialState?.scrollY, scrollY > 0 { restoreScroll(scrollY) }
            }
            undo.removeAllActions()
            if content.focus { focus() }
            return true
        }
        // Files still being imported for another note are not inserted into this one.
        if !content.keepsSelection {
            dropAnchors = []
            restoredScrollY = nil
        }
        closeMenu()
        hideFormatBar()
        if content.keepsSelection {
            // A change from outside (a field set under the title, an agent): only the part that differs is replaced,
            // so the caret keeps its place in the text around it and nothing else is laid out again.
            let selection = textView.selectedRange()
            let visible = textView.enclosingScrollView?.contentView.bounds.origin
            let change = Self.difference(from: textView.string, to: content.text)
            textView.textStorage?.replaceCharacters(in: change.old, with: change.new)
            restyle(everything: true)
            let length = (content.text as NSString).length
            let caret = Self.shifted(selection.location, by: change)
            textView.setSelectedRange(NSRange(location: min(caret, length), length: 0))
            if let visible { textView.enclosingScrollView?.contentView.scroll(to: visible) }
        } else {
            // Another note, maybe in the same editor (its tab followed a link): its blocks get views of their own,
            // it opens as a page with its title in view, and no picture of the last note stands in for its own.
            removeLiveBlocks()
            removeTableBlocks()
            // The headings it had folded, as it was left; any that are no longer headings drop at the restyle.
            folds = HeadingFolds(folded: content.initialState?.folded ?? content.initialFolds)
            lastPictures = [:]
            if syntaxMode != .rendered { syntaxMode = .rendered }
            titleHidden = false
            textView.string = content.text
            restyle(everything: true)
            let length = (content.text as NSString).length
            // A note opens with the caret after its frontmatter, which stays hidden until the caret goes up into it.
            let caret = min(max(content.initialState?.caret ?? bodyStart, 0), length)
            textView.setSelectedRange(NSRange(location: caret, length: 0))
            textView.scroll(.zero)
            if let scrollY = content.initialState?.scrollY, scrollY > 0 { restoreScroll(scrollY) }
        }
        undo.removeAllActions()
        if content.focus { focus() }
        return true
    }

    /// Scrolls to `y` once the view has its size: the text is laid out first so the position exists. Embeds still on
    /// their way make the text taller when they come: the position is put back then (`settleAfterEmbeds`).
    private func restoreScroll(_ y: Double) {
        restoredScrollY = y
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.scrollToRestored() }
        }
    }

    /// Lays the whole text out, so the page has its height, and scrolls to the restored position, or as near as the
    /// text reaches; never past the end of the page.
    private func scrollToRestored() {
        guard let textView, let scrollView = textView.enclosingScrollView else { return }
        if let layout = textView.textLayoutManager { layout.ensureLayout(for: layout.documentRange) }
        let clip = scrollView.contentView
        let bottom = max(0, textView.frame.height - clip.bounds.height)
        let y = min(restoredScrollY.map { CGFloat($0) } ?? clip.bounds.minY, bottom)
        if y != clip.bounds.minY { clip.scroll(to: NSPoint(x: clip.bounds.minX, y: y)) }
        scrollView.reflectScrolledClipView(clip)
    }

    /// An embed came in and the text grew: once all that came in this turn are styled, put back the position a restored
    /// tab asked for, which the shorter text could not reach, or bring back a page scrolled past its end. Laying the
    /// whole text out costs on a long note, so it happens only then.
    func settleAfterEmbeds() {
        guard !settlingEmbeds else { return }
        settlingEmbeds = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.settlingEmbeds = false
                guard let textView = self.textView, let clip = textView.enclosingScrollView?.contentView else { return }
                if self.restoredScrollY != nil || clip.bounds.maxY > textView.frame.height + 1 { self.scrollToRestored() }
                if self.embedCache.pending.isEmpty { self.restoredScrollY = nil }
            }
        }
    }

    private func applyThemeToViews() {
        guard let textView else { return }
        textView.theme = theme
        textView.insertionPointColor = theme.accentColor
        textView.enclosingScrollView?.backgroundColor = theme.backgroundColor
    }

    /// The one range of `old` (UTF-16) that differs from `new`, and what replaces it: the text between their common
    /// start and common end.
    static func difference(from old: String, to new: String) -> (old: NSRange, new: String) {
        let a = Array(old.utf16), b = Array(new.utf16)
        var prefix = 0
        while prefix < a.count, prefix < b.count, a[prefix] == b[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < a.count - prefix, suffix < b.count - prefix, a[a.count - 1 - suffix] == b[b.count - 1 - suffix] {
            suffix += 1
        }
        // Not in the middle of a surrogate pair.
        if prefix > 0, prefix < a.count, UTF16.isTrailSurrogate(a[prefix]) { prefix -= 1 }
        if suffix > 0, a.count - suffix < a.count, UTF16.isTrailSurrogate(a[a.count - suffix]) { suffix -= 1 }
        let replaced = String(utf16CodeUnits: Array(b[prefix..<(b.count - suffix)]), count: b.count - suffix - prefix)
        return (NSRange(location: prefix, length: a.count - suffix - prefix), replaced)
    }

    /// Where `location` is after `change`: moved by its length change when after it, at its end when inside it.
    static func shifted(_ location: Int, by change: (old: NSRange, new: String)) -> Int {
        let newLength = (change.new as NSString).length
        if location >= NSMaxRange(change.old) { return location + newLength - change.old.length }
        if location > change.old.location { return change.old.location + newLength }
        return location
    }

    /// The column's width or the appearance changed: the pictures, tables and live blocks are sized and coloured
    /// again. A width changes on every frame of a window resize, a split divider's drag or a sidebar's slide: in the
    /// block editor only what is sized to the column follows it, since restyling every paragraph on each frame was
    /// the largest cost of a resize. An appearance change restyles it all (colours).
    private func layoutChanged(widthOnly: Bool) {
        guard let textView,
              !lastPictures.isEmpty || textView.hasPictureMarks || !liveBlocks.isEmpty || !tableBlocks.isEmpty
        else { return }
        if widthOnly, let blockSession {
            blockSession.columnWidthChanged()
        } else {
            restyle(everything: true)
        }
    }

    /// Restyles the text. The spans are found again in the whole text, but only the paragraphs whose spans or
    /// revealed syntax changed since the last restyle get new attributes: restyling all of a long note on each
    /// keystroke takes tens of milliseconds and lays it all out again. `everything` restyles it all (a new text or
    /// theme).
    func restyle(everything: Bool = false) {
        guard let textView, let storage = textView.textStorage, !textView.hasMarkedText() else { return }
        if let blockSession {
            blockSession.theme = theme
            blockSession.restyle()
            return
        }
        // Copied out of the storage at once: `Array(textView.string.utf16)` walks the bridged string a unit at a time.
        let storageText = storage.string as NSString
        var units = [UInt16](repeating: 0, count: storageText.length)
        units.withUnsafeMutableBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            storageText.getCharacters(base, range: NSRange(location: 0, length: buffer.count))
        }
        let text = String(decoding: units, as: UTF16.self)
        nativeText = text
        // Typing parses only the paragraph it is in (`IncrementalSpans`); a new text, theme or mode parses it all.
        let parsed = (everything ? nil : parsedStyling.flatMap {
            IncrementalSpans.spans(for: text, units: units, after: IncrementalSpans.Base(units: $0.units, spans: $0.spans))
        }) ?? MarkdownStyler.spans(in: text)
        parsedStyling = (units, parsed)
        var spans = parsed
        if let heading = Self.titleHeading(in: text, title: textView.pageTitle) {
            // The page title already says it: the `# Title` line (and the blank line after it) takes no room
            // until the caret goes into it.
            spans.removeAll { NSIntersectionRange($0.range, heading).length > 0 || $0.range.location == heading.location }
            spans.append(StyleSpan(.concealedOutside(block: heading), heading))
        }
        if syntaxMode == .rendered, let frontmatter = MarkdownStyler.frontmatterRange(in: text as NSString) {
            // A page shows no YAML: the frontmatter takes no room and the caret never goes into it. A collection
            // entry's fields show under the title instead (`titleAccessory`); the source mode shows the YAML.
            spans.removeAll { if case .tag(let frontmatter) = $0.style { frontmatter != nil } else { false } }
            spans.append(StyleSpan(.concealedOutside(block: frontmatter), frontmatter))
        }
        let selection = textView.selectedRange()
        let newHideable = spans.filter { span in
            switch span.style {
            case .fencedCode, .embed: true
            default: false
            }
        }.compactMap(\.revealRange)
        let newRevealed = Self.revealed(newHideable, by: selection)
        let limit = everything ? nil : styled.map {
            Self.restyleRange(
                from: ($0.units, $0.spans, revealed), to: (units, spans, newRevealed), in: text as NSString
            )
        }
        styled = (units, spans)
        hiddenSyntax = syntaxMode == .rendered ? HiddenSyntax(spans: spans, text: text) : .none
        hideable = newHideable
        codeBlocks = spans.filter { $0.style == .codeBlock || $0.style == .frontmatter }.map(\.range)
        revealed = newRevealed
        updateFolds(spans: spans, text: text as NSString)
        if limit?.length == 0 { return }
        theme.apply(spans, to: storage, revealing: MarkdownTheme.revealing(syntaxMode), in: limit)
        applyPictures(spans, to: storage, revealing: selection)
        applyEmbeds(spans, to: storage, revealing: selection)
        applyLiveBlocks(spans, to: storage, revealing: selection)
        applyTableBlocks(spans, to: storage, limit: limit)
        textView.typingAttributes = theme.baseAttributes
        textView.needsDisplay = true
        // Once the text is laid out again.
        if !liveBlocks.isEmpty || !tableBlocks.isEmpty {
            DispatchQueue.main.async { [weak self] in MainActor.assumeIsolated { self?.positionLiveViews() } }
        }
    }

    /// The syntax the page hides at the last restyle: what the caret, the selection and the delete keys keep clear of
    /// (`HiddenSyntax`). Empty when showing the source.
    var hiddenSyntax = HiddenSyntax.none
    /// The block editor, when it is on (`BlockSession.isOn`): the page holds blocks, not Markdown, and the session
    /// handles the text view's changes and keys instead of the hidden-syntax machinery.
    var blockSession: BlockSession?
    /// The block editor set aside while the note's Markdown shows as it is written (View Markdown Source).
    var parkedBlockSession: BlockSession?
    /// While the source mode is left from `show` (another note): the session comes back without showing the source.
    private var leavingSource = false

    /// View Markdown Source in the block editor: the whole file, frontmatter included, as text (the old editor's
    /// source mode); back to the page, the text is read into blocks again.
    private func switchBlockSource() {
        guard let textView, !leavingSource else { return }
        if syntaxMode == .source, let session = blockSession {
            let markdown = session.currentMarkdown()
            parkedBlockSession = session
            blockSession = nil
            textView.blockMode = false
            removeTableBlocks()
            removeLiveBlocks()
            textView.embedViews = [:]
            folds.removeAll()
            textView.string = markdown
            restyle(everything: true)
            textView.setSelectedRange(NSRange(location: 0, length: 0))
            undo.removeAllActions()
        } else if syntaxMode == .rendered, let session = parkedBlockSession {
            let markdown = textView.string
            parkedBlockSession = nil
            blockSession = session
            textView.blockMode = true
            hiddenSyntax = .none
            session.show(markdown, title: textView.pageTitle, keepsSelection: false, caret: 0)
            undo.removeAllActions()
        }
        textView.keepCaretInView()
    }

    /// Turns the block editor on for `textView`.
    func useBlocks(in textView: EditorTextView) {
        let session = BlockSession(textView: textView)
        session.onLateMarkdown = { [weak self] markdown in self?.onChange(markdown) }
        session.onStyled = { [weak self] in
            guard let self, let storage = textView.textStorage else { return }
            var scan = PageScan(storage)
            if let end = blockSession?.styledEnd {
                // A long note just opened: the components of its first screen now, the others with the rest.
                scan.embeds.removeAll { $0.paragraph.location >= end }
                scan.tables.removeAll { $0.content.location >= end }
                scan.components.removeAll { $0.content.location >= end }
            }
            applyBlockEmbeds(scan)
            applyBlockTables(scan)
            applyBlockPictures(scan)
            applyBlockLiveBlocks(scan)
            updateBlockFolds(scan)
        }
        textView.onOpenBlockComponent = { [weak self] location in self?.openBlockCodePage(at: location) }
        BlockStorage.componentLanguages = componentLanguages
        blockSession = session
    }
    /// The folded headings (`HeadingFolds`), and the headings that can fold at the last restyle.
    var folds = HeadingFolds()
    var foldSections: [HeadingFolds.Section] = []
    private var balancingEdit = false
    /// The link field, once it was shown.
    var linkEditorPanel: LinkEditorPanel?
    /// The text as a native Swift string, made by the last restyle: the text view's own string is a bridged NSString,
    /// which is slow to compare and copy once it is long. Nil until a restyle runs.
    private var nativeText: String?
    /// The text (UTF-16) of the last restyle and the spans the parser found in it, before the page's own changes.
    private var parsedStyling: (units: [UInt16], spans: [StyleSpan])?
    /// The spans of the last restyle.
    var styledSpans: [StyleSpan] { styled?.spans ?? [] }
    /// The text (UTF-16) and spans of the last restyle.
    private var styled: (units: [UInt16], spans: [StyleSpan])?
    /// The ranges of the syntax the editor hides, from the last restyle.
    private var hideable: [NSRange] = []
    /// Which of them the selection showed at the last restyle; a selection that shows others restyles.
    private var revealed: [NSRange] = []

    private static func revealed(_ ranges: [NSRange], by selection: NSRange) -> [NSRange] {
        ranges.filter { MarkdownTheme.enters(selection, $0) }
    }

    typealias Styling = (units: [UInt16], spans: [StyleSpan], revealed: [NSRange])

    /// What must be restyled, in `new`'s offsets, going from `old` to `new`: the edited characters, the spans that
    /// appeared or went away, the syntax revealed before or now, widened to whole paragraphs and whole tables. Empty
    /// when nothing changed.
    static func restyleRange(from old: Styling, to new: Styling, in text: NSString) -> NSRange {
        let length = new.units.count
        // The edit: what lies between the common prefix and the common suffix.
        let shortest = min(old.units.count, length)
        var prefix = 0
        while prefix < shortest, old.units[prefix] == new.units[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < shortest - prefix, old.units[old.units.count - 1 - suffix] == new.units[length - 1 - suffix] {
            suffix += 1
        }
        let oldEdit = NSRange(location: prefix, length: old.units.count - prefix - suffix)
        let newEdit = NSRange(location: prefix, length: length - prefix - suffix)
        let delta = newEdit.length - oldEdit.length

        /// An old range in the new text: shifted when after the edit, stretched to it when it overlaps it.
        func moved(_ range: NSRange) -> NSRange {
            let moved: NSRange
            if NSMaxRange(range) <= oldEdit.location {
                moved = range
            } else if range.location >= NSMaxRange(oldEdit) {
                moved = NSRange(location: range.location + delta, length: range.length)
            } else {
                let start = min(range.location, newEdit.location)
                moved = NSRange(location: start, length: max(NSMaxRange(range) + delta, NSMaxRange(newEdit)) - start)
            }
            let start = min(max(moved.location, 0), length)
            return NSRange(location: start, length: max(0, min(NSMaxRange(moved), length) - start))
        }

        /// A style whose payload holds an offset (the code of a fenced block, the block of a concealed run), moved as
        /// the span is: otherwise every such span after the edit looks changed and the restyle runs to the end.
        func moved(_ style: MarkdownStyle) -> MarkdownStyle {
            switch style {
            case .fencedCode(let language, let code): .fencedCode(language: language, code: moved(code))
            case .concealedOutside(let block): .concealedOutside(block: moved(block))
            case .tag(let frontmatter?): .tag(frontmatter: moved(frontmatter))
            default: style
            }
        }

        var dirty: NSRange?
        func add(_ range: NSRange) { dirty = dirty.map { NSUnionRange($0, range) } ?? range }
        if oldEdit.length > 0 || newEdit.length > 0 { add(newEdit) }
        let before = Set(old.spans.map { StyleSpan(moved($0.style), moved($0.range)) })
        for span in before.symmetricDifference(Set(new.spans)) { add(moved(span.range)) }
        let shownBefore = Set(old.revealed.map(moved))
        for range in shownBefore.symmetricDifference(Set(new.revealed)) { add(range) }
        guard var range = dirty else { return NSRange(location: 0, length: 0) }
        // Within the text: what a picture on the last line reveals reaches past its end (the break it has not got),
        // and asking for the paragraph there raised an exception in the middle of a click.
        func clamped(_ range: NSRange) -> NSRange {
            let start = min(max(range.location, 0), length)
            return NSRange(location: start, length: max(0, min(NSMaxRange(range), length) - start))
        }
        range = clamped(range)
        if range.length == 0, range.location == length, length > 0 {
            // Text taken off the end (an empty last item's `- `) leaves no paragraph there: the one before is
            // restyled, which redraws the marks the text view drew over what went (its bullet).
            range = NSRange(location: length - 1, length: 0)
        }

        // Whole paragraphs (paragraph styles, list indents), and whole blocks: a table's columns line up together,
        // and a code block or a quote is one card or bar, which a line restyled alone would cut in pieces.
        range = text.paragraphRange(for: range)
        for span in new.spans where Self.isWholeBlock(span.style)
            && span.range.location <= NSMaxRange(range) && NSMaxRange(span.range) >= range.location {
            range = NSUnionRange(range, span.range)
        }
        return text.paragraphRange(for: clamped(range))
    }

    /// Writes `language` in the opening fence of the code block starting at `start` (` ```swift `); "" leaves none.
    func setCodeLanguage(ofBlockAt start: Int, to language: String) {
        guard let textView else { return }
        if let blockSession, let storage = textView.textStorage, start < storage.length {
            let paragraph = (storage.string as NSString).paragraphRange(for: NSRange(location: start, length: 0))
            guard var block = BlockStorage.block(in: storage, paragraph: paragraph), case .code(let current) = block.kind,
                  current != language else { return }
            block.kind = .code(language: language)
            blockSession.apply(BlockEdit(range: paragraph, replacement: BlockStorage.paragraph(of: block), selection: textView.selectedRange()))
            return
        }
        let ns = textView.string as NSString
        guard start < ns.length else { return }
        let line = ns.lineWithoutBreak(at: start)
        let text = ns.substring(with: line)
        guard let fence = text.firstMatch(of: /^([ \t]*(?:`{3,}|~{3,}))/) else { return }
        let replacement = String(fence.1) + language
        guard replacement != text else { return }
        apply(TextEdit(range: line, replacement: replacement, selection: textView.selectedRange()), reveal: false)
    }

    /// Puts the code of a block (without its fences) on the pasteboard.
    func copyCode(of block: NSRange) {
        guard let textView else { return }
        let ns = textView.string as NSString
        var lines = ns.substring(with: NSIntersectionRange(block, NSRange(location: 0, length: ns.length)))
            .replacingOccurrences(of: String(InlineText.lineBreak), with: "\n")
            .components(separatedBy: "\n")
        let isFence: (String) -> Bool = { $0.trimmingCharacters(in: .whitespaces).hasPrefix("```") || $0.trimmingCharacters(in: .whitespaces).hasPrefix("~~~") }
        if let first = lines.first, isFence(first) {
            lines.removeFirst()
            if let last = lines.last, isFence(last) { lines.removeLast() }
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
        Sounds.play(.copied)
    }

    /// The styles restyled whole when an edit reaches into them.
    static func isWholeBlock(_ style: MarkdownStyle) -> Bool {
        switch style {
        case .table, .codeBlock, .quote, .fencedCode: true
        default: false
        }
    }

    private var flushPending = false

    /// A long note's Markdown is written a moment after the keystroke (`BlockSession.deferredLength`), out of its
    /// frame: between two keys when typing fast, once for several when they come quicker.
    private func flushChangeSoon() {
        guard !flushPending else { return }
        flushPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { [weak self] in
            MainActor.assumeIsolated {
                self?.flushPending = false
                self?.flushChange()
            }
        }
    }

    /// Sends the typing not yet written (a long note's) to `onChange` now: before another note is shown, when the
    /// editor goes away, before a save.
    public func flushChange() {
        if let markdown = blockSession?.flushMarkdown() { onChange(markdown) }
    }

    // MARK: NSTextViewDelegate

    public func undoManager(for view: NSTextView) -> UndoManager? { undo }

    public func textDidChange(_ notification: Notification) {
        guard let textView else { return }
        if let blockSession {
            if let markdown = blockSession.didChange() { onChange(markdown) } else { flushChangeSoon() }
            if let pending = pendingMenu {
                pendingMenu = nil
                menu = pending
            }
            updateMenu()
            DispatchQueue.main.async { [weak textView] in
                MainActor.assumeIsolated { textView?.keepCaretInView() }
            }
            return
        }
        if !applyingTableEdit { lastTableTyping = nil }
        nativeText = nil
        restyle()
        if let pending = pendingMenu {
            pendingMenu = nil
            menu = pending
        }
        updateMenu()
        onChange(nativeText ?? textView.string)
        // After the text view's own scrolling, which leaves the caret on the page's last line.
        DispatchQueue.main.async { [weak textView] in
            MainActor.assumeIsolated { textView?.keepCaretInView() }
        }
    }

    public func textView(_ textView: NSTextView, shouldChangeTextIn range: NSRange, replacementString: String?) -> Bool {
        if let blockSession {
            noteMenuTrigger(range, replacementString, in: textView)
            if let replacementString, !folds.isEmpty { folds.follow(range, replacementLength: (replacementString as NSString).length) }
            return blockSession.shouldChange(range, replacement: replacementString)
        }
        // The lines of a table belong to its component: typing or pasting into them would break the table.
        if !applyingTableEdit, isInsideTable(range) != nil {
            // A line break after the last row starts what follows the table (a dropped file's link goes there).
            let after = tableBlocks.contains { range.length == 0 && range.location == NSMaxRange($0.range) }
            if !(after && replacementString?.hasPrefix("\n") == true) { return false }
        }
        if let replacementString, !balancingEdit, self.textView?.isUserEdit == true {
            balancingEdit = true
            defer { balancingEdit = false }
            if balancing(range, replacement: replacementString) { return false }
        }
        if let replacementString {
            for anchor in dropAnchors { anchor.follow(range, replacementLength: (replacementString as NSString).length) }
            if !folds.isEmpty { folds.follow(range, replacementLength: (replacementString as NSString).length) }
        }
        noteMenuTrigger(range, replacementString, in: textView)
        return true
    }

    /// `/`, `@` or `[[` typed where a word starts: the menu opens once the text has changed.
    private func noteMenuTrigger(_ range: NSRange, _ replacementString: String?, in textView: NSTextView) {
        if let replacementString, let kind = MenuTrigger.Kind(rawValue: replacementString), !textView.hasMarkedText(),
           SlashMenu.opensMenu(in: textView.string, at: range.location), !isInCode(range.location) {
            // Over a selection too, so `@` typed on a selected date replaces it with another.
            pendingMenu = MenuTrigger(location: range.location, kind: kind)
        } else if replacementString == "[", range.location > 0, !textView.hasMarkedText(),
                  (textView.string as NSString).character(at: range.location - 1) == 91,
                  SlashMenu.opensMenu(in: textView.string, at: range.location - 1), !isInCode(range.location) {
            // `[[`, as in Obsidian: the menu of notes to link.
            pendingMenu = MenuTrigger(location: range.location - 1, kind: .link)
        }
    }

    /// Hidden syntax is never marked misspelled: the mark would show as a red dot where the text takes no room (the
    /// file name of a picture's link).
    public func textView(_ textView: NSTextView, shouldSetSpellingState value: Int, range: NSRange) -> Int {
        guard value != 0, let storage = textView.textStorage, range.location < storage.length,
              let font = storage.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont else { return value }
        return font.pointSize < 1 ? 0 : value
    }

    public func textView(
        _ textView: NSTextView, willChangeSelectionFromCharacterRange oldSelectedCharRange: NSRange,
        toCharacterRange newSelectedCharRange: NSRange
    ) -> NSRange {
        if blockSession != nil { return adjustSelectionForTables(from: oldSelectedCharRange, to: newSelectedCharRange) }
        let adjusted = adjustSelectionForTables(from: oldSelectedCharRange, to: newSelectedCharRange)
        // After a restyle only: while the text changes, the syntax found is of the text before.
        guard !hiddenSyntax.runs.isEmpty || !hiddenSyntax.prefixes.isEmpty, hiddenSyntax.text.isEqual(to: textView.string) else {
            return adjusted
        }
        return hiddenSyntax.snap(adjusted, from: oldSelectedCharRange)
    }

    public func textViewDidChangeSelection(_ notification: Notification) {
        if let blockSession {
            blockSession.selectionDidChange()
            updateTableSelection()
            unfoldAroundSelection()
            if menu != nil { updateMenu() }
            updateFormatBar()
            onViewStateChange(viewState)
            return
        }
        updateTableSelection()
        unfoldAroundSelection()
        if let textView, Self.revealed(hideable, by: textView.selectedRange()) != revealed { restyle() }
        if menu != nil { updateMenu() }
        updateFormatBar()
        textView?.updateCodeBar()
        onViewStateChange(viewState)
    }

    public func textDidEndEditing(_ notification: Notification) {
        closeMenu()
        hideFormatBar()
    }

    public func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if menu != nil, panel.isVisible {
            switch selector {
            case #selector(NSResponder.moveUp(_:)):
                panel.model.move(-1)
                return true
            case #selector(NSResponder.moveDown(_:)):
                panel.model.move(1)
                return true
            case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertTab(_:)):
                if let item = panel.model.current { choose(item) }
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                closeMenu()
                return true
            default:
                break
            }
        } else if menu != nil, selector == #selector(NSResponder.cancelOperation(_:)) || selector == #selector(NSResponder.insertNewline(_:)) {
            closeMenu()
        }
        if selector == #selector(NSResponder.cancelOperation(_:)), formatBarPanel?.isVisible == true {
            hideFormatBar()
            return true
        }

        if let blockSession { return blockSession.command(selector) }
        let text = textView.string
        let selection = textView.selectedRange()
        // A block selected by its handle goes whole, lines and all, as Craft's does.
        if let block = self.textView?.blockSelection?.block,
           [#selector(NSResponder.deleteBackward(_:)), #selector(NSResponder.deleteForward(_:))].contains(selector) {
            apply(BlockMoving.delete(block, in: text))
            return true
        }
        if selection.length == 0, deleteNextToHiddenSyntax(selector) { return true }
        let edit: TextEdit?
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            edit = isInCode(selection.location) ? nil
                : ListEditing.newline(in: text, selection: selection) ?? QuoteEditing.newline(in: text, selection: selection)
        case #selector(NSResponder.insertTab(_:)):
            edit = ListEditing.indent(in: text, selection: selection, outdent: false)
        case #selector(NSResponder.insertBacktab(_:)):
            edit = ListEditing.indent(in: text, selection: selection, outdent: true)
        default:
            edit = nil
        }
        guard let edit else { return false }
        apply(edit)
        return true
    }

    // MARK: Hidden syntax

    /// Backspace and forward delete with a caret next to hidden syntax: they remove what shows (`HiddenSyntax`).
    /// False when the key does its usual work.
    private func deleteNextToHiddenSyntax(_ selector: Selector) -> Bool {
        guard let textView, isHiddenSyntaxCurrent, !textView.hasMarkedText(),
              !tableBlocks.contains(where: { NSIntersectionRange($0.range, textView.selectedRange()).length > 0 || NSLocationInRange(textView.selectedRange().location, $0.range) })
        else { return false }
        let caret = textView.selectedRange().location
        let deletion: HiddenSyntax.Deletion?
        switch selector {
        case #selector(NSResponder.deleteBackward(_:)): deletion = hiddenSyntax.deleteBackward(caret: caret)
        case #selector(NSResponder.deleteForward(_:)): deletion = hiddenSyntax.deleteForward(caret: caret)
        default: return false
        }
        // Nothing to take: the key does nothing, as at the start of the note.
        guard let deletion else { return true }
        // The key's usual work when only a character that shows, next to no syntax, goes.
        if deletion.ranges.count == 1, deletion.ranges[0].length == 1, !touchesHiddenSyntax(caret) { return false }
        // Nothing removed, only the caret moves (up past a hidden line).
        if deletion.ranges.isEmpty {
            let target = NSRange(location: min(max(deletion.caret, 0), (textView.string as NSString).length), length: 0)
            textView.setSelectedRange(target)
            textView.scrollRangeToVisible(target)
            return true
        }
        remove(deletion.ranges, replacingWith: "", caret: deletion.caret)
        return true
    }

    /// Whether the syntax found is of the text now shown (the text may have changed since the last restyle).
    private var isHiddenSyntaxCurrent: Bool {
        guard let textView, !hiddenSyntax.runs.isEmpty || !hiddenSyntax.prefixes.isEmpty || !hiddenSyntax.pairs.isEmpty else { return false }
        return hiddenSyntax.text.isEqual(to: textView.string)
    }

    private func touchesHiddenSyntax(_ caret: Int) -> Bool {
        hiddenSyntax.runs.contains { $0.location <= caret && caret <= NSMaxRange($0) }
            || hiddenSyntax.prefixes.contains { NSMaxRange($0.range) == caret }
            || hiddenSyntax.pairs.contains { NSMaxRange($0.open) >= caret - 1 && $0.close.location <= caret + 1 }
    }

    /// The range of a keyboard, paste or cut edit, with the marker of every pair it breaks (a half of `**bold**`
    /// selected and deleted leaves no lone `**` showing). Nil when the edit is whole as it is.
    func balancing(_ range: NSRange, replacement: String) -> Bool {
        guard let textView, textView.isUserEdit, range.length > 0, isHiddenSyntaxCurrent, !textView.hasMarkedText() else { return false }
        let orphans = hiddenSyntax.orphans(of: range)
        guard !orphans.isEmpty else { return false }
        let before = orphans.filter { NSMaxRange($0) <= range.location }.reduce(0) { $0 + $1.length }
        let caret = range.location - before + (replacement as NSString).length
        var ranges = orphans + [range]
        ranges.sort { $0.location < $1.location }
        remove(ranges, replacingWith: nil, caret: caret, replacement: (range, replacement))
        return true
    }

    /// Removes `ranges` (ascending) as one edit the user can undo, `replacement` standing in for its range, and puts the
    /// caret at `caret` in the new text.
    private func remove(_ ranges: [NSRange], replacingWith filler: String?, caret: Int, replacement: (NSRange, String)? = nil) {
        guard !ranges.isEmpty, let textView, let storage = textView.textStorage else { return }
        let strings = ranges.map { range in
            replacement.map { NSEqualRanges($0.0, range) ? $0.1 : "" } ?? ""
        }
        guard textView.shouldChangeText(inRanges: ranges.map { NSValue(range: $0) }, replacementStrings: strings) else { return }
        undo.beginUndoGrouping()
        storage.beginEditing()
        for (range, string) in zip(ranges, strings).reversed() { storage.replaceCharacters(in: range, with: string) }
        storage.endEditing()
        textView.didChangeText()
        undo.endUndoGrouping()
        let target = NSRange(location: min(max(caret, 0), storage.length), length: 0)
        textView.setSelectedRange(target)
        textView.scrollRangeToVisible(target)
    }

    // MARK: Editing

    func applyEdit(_ edit: TextEdit) { apply(edit) }

    private func apply(_ edit: TextEdit, reveal: Bool = true) {
        guard let textView else { return }
        if edit.range.length == 0, edit.replacement.isEmpty {
            // Only the caret moves (Tab from cell to cell).
            textView.setSelectedRange(edit.selection)
            textView.scrollRangeToVisible(edit.selection)
            return
        }
        guard let storage = textView.textStorage,
              textView.shouldChangeText(in: edit.range, replacementString: edit.replacement) else { return }
        storage.replaceCharacters(in: edit.range, with: edit.replacement)
        textView.didChangeText()
        textView.setSelectedRange(edit.selection)
        guard reveal else { return }
        textView.scrollRangeToVisible(edit.selection)
        textView.keepCaretInView()
    }

    // MARK: Moving blocks

    /// A block dragged by its handle lands before `target` (nil: at the end), as one edit the user can undo.
    private func moveBlock(_ block: MarkdownBlock, before target: MarkdownBlock?) {
        if let blockSession, let textView, let storage = textView.textStorage {
            let destination = target?.range.location ?? storage.length
            guard let edit = PageBlocks.move(block.range, before: destination, in: storage) else { return }
            textView.keepingOnScreen(destination, then: { edit.selection.location }) { blockSession.apply(edit) }
            return
        }
        guard let textView, let edit = BlockMoving.move(block, before: target, in: textView.string) else { return }
        // The block lands on the line it was dropped on, and the page stays put around it.
        let dropped = target?.range.location ?? (textView.string as NSString).length
        textView.keepingOnScreen(dropped, then: { edit.selection.location }) { apply(edit, reveal: false) }
    }

    /// Option-Command-Up or Down: the block at the caret goes over its neighbour, the caret keeping its place in it.
    private func moveBlockAtCaret(up: Bool) -> Bool {
        guard let textView else { return false }
        if let blockSession, let storage = textView.textStorage {
            let caret = textView.selectedRange()
            let blocks = PageBlocks.blocks(in: storage)
            let paragraph = (storage.string as NSString).paragraphRange(for: NSRange(location: min(caret.location, max(storage.length - 1, 0)), length: 0))
            guard let block = blocks.first(where: { $0.range.location == paragraph.location }) else { return false }
            guard let destination = PageBlocks.keyboardDestination(for: block, up: up, in: blocks, length: storage.length),
                  let edit = PageBlocks.move(block.range, before: destination, in: storage) else { return true }
            let offset = caret.location - block.range.location
            blockSession.apply(BlockEdit(range: edit.range, replacement: edit.replacement,
                                         selection: NSRange(location: edit.selection.location + offset, length: caret.length)))
            return true
        }
        let text = textView.string
        let caret = textView.selectedRange()
        guard let block = BlockMoving.block(at: caret.location, in: BlockMoving.blocks(in: text), text: text) else { return false }
        // At the top or the bottom already: nothing moves, the key does nothing else either.
        guard let target = BlockMoving.keyboardTarget(for: block, up: up, in: text),
              let edit = BlockMoving.move(block, before: target, in: text) else { return true }
        let offset = caret.location - block.range.location
        let moved = TextEdit(range: edit.range, replacement: edit.replacement,
                             selection: NSRange(location: edit.selection.location + offset, length: caret.length))
        let length = (moved.applied(to: text) as NSString).length
        apply(NSMaxRange(moved.selection) <= length ? moved : edit)
        return true
    }

    // MARK: Dropped and pasted files

    private func connectFileDrops() {
        textView?.fileDropHandler = onDropFiles == nil ? nil : { [weak self] files, location in
            self?.dropFiles(files, at: location)
        }
    }

    /// Hands files dropped at `location` (a paste: the caret) to the host, and inserts its Markdown there, on lines of
    /// their own, when it comes: undoable, saved, as typing.
    func dropFiles(_ files: [DroppedFile], at location: Int) {
        guard let onDropFiles else { return }
        let anchor = DropAnchor(location: location)
        dropAnchors.append(anchor)
        let lost = onLostDrop
        Task { [weak self] in
            let markdown = await onDropFiles(files)
            // The editor closed during the import: the link still goes to the note, as when it shows another one.
            guard let self else {
                if let markdown, !markdown.isEmpty { lost?(markdown) }
                return
            }
            guard self.dropAnchors.contains(where: { $0 === anchor }) else {
                // The editor shows another note now: the files are in the vault, their link goes where they were dropped.
                if let markdown, !markdown.isEmpty { lost?(markdown) }
                return
            }
            self.dropAnchors.removeAll { $0 === anchor }
            guard let markdown, !markdown.isEmpty, let textView = self.textView else { return }
            if let blockSession = self.blockSession {
                let caret = textView.selectedRange()
                textView.setSelectedRange(NSRange(location: min(anchor.location, textView.string.utf16.count), length: 0))
                blockSession.insert(markdown: markdown)
                if caret.location < anchor.location { textView.setSelectedRange(caret) }
                return
            }
            let edit = Self.blockInsertion(markdown, at: anchor.location, in: textView.string)
            self.apply(Self.keepingCaret(edit, caret: textView.selectedRange(), droppedAt: anchor.location))
        }
    }

    private func isInCode(_ location: Int) -> Bool {
        guard let storage = textView?.textStorage else { return false }
        return [location - 1, location].contains { index in
            index >= 0 && index < storage.length && storage.attribute(.markdownCode, at: index, effectiveRange: nil) != nil
        }
    }

    // MARK: The format bar

    /// Shows the format bar over a selection, once the mouse is up, and hides it otherwise.
    private func updateFormatBar(animated: Bool = true) {
        guard let textView, let window = textView.window, let scrollView = textView.enclosingScrollView else { return }
        let selection = textView.selectedRange()
        guard selection.length > 0, menu == nil, window.firstResponder === textView, !textView.hasMarkedText(),
              !codeBlocks.contains(where: { NSIntersectionRange($0, selection).length > 0 })
        else { return hideFormatBar() }
        // While dragging, the bar waits for the mouse to come up (`onMouseUp`), as Craft's does.
        // A press on the bar itself is not a drag: the bar stays as it is until the click is done.
        guard NSEvent.pressedMouseButtons & 1 == 0 else { return formatBarPanel?.isPointerOver == true ? () : hideFormatBar() }
        let first = textView.screenRect(for: NSRange(location: selection.location, length: 1), revealing: false)
            ?? textView.firstRect(forCharacterRange: NSRange(location: selection.location, length: 1), actualRange: nil)
        let last = textView.screenRect(for: NSRange(location: NSMaxRange(selection) - 1, length: 1), revealing: false)
            ?? textView.firstRect(forCharacterRange: NSRange(location: NSMaxRange(selection) - 1, length: 1), actualRange: nil)
        let visible = window.convertToScreen(scrollView.convert(scrollView.bounds, to: nil))
        // The selection scrolled out of sight.
        guard visible.intersects(first.union(last)) else { return hideFormatBar() }
        let text = textView.string
        formatBar.model.active = blockSession?.activeFormats(in: selection) ?? Set(InlineFormat.allCases.filter {
            InlineFormatting.isActive($0, in: text, selection: selection)
        })
        formatBar.model.themeHighlight = theme.highlightColor
        formatBar.show(above: first, below: last, within: visible, in: window, animated: animated)
    }

    /// Applies a button of the bar, or Cmd+B, Cmd+I, Cmd+K, to the selection. False when nothing changed.
    @discardableResult
    func perform(_ action: FormatAction) -> Bool {
        guard let textView else { return false }
        // Rewriting the line puts the caret at its end for a moment, which can be a table's: with the click or the key
        // as the current event, that was taken for the caret entering the table, and the table took the keyboard.
        let wasMoving = movingSelectionForTable
        movingSelectionForTable = true
        defer { movingSelectionForTable = wasMoving }
        if blockSession != nil, action == .link {
            formatBarPanel?.model.showsColors = false
            return beginBlockLinkEdit()
        }
        if let blockSession, action != .link {
            formatBarPanel?.model.showsColors = false
            let done = blockSession.perform(action)
            updateFormatBar(animated: false)
            return done
        }
        let text = textView.string
        let selection = textView.selectedRange()
        let edit: TextEdit? = switch action {
        case .toggle(let format): InlineFormatting.toggle(format, in: text, selection: selection)
        case .highlight(let color): InlineFormatting.highlight(color, in: text, selection: selection)
        case .link: nil
        }
        if case .link = action {
            formatBarPanel?.model.showsColors = false
            return beginLinkEdit()
        }
        formatBarPanel?.model.showsColors = false
        guard let edit else { return false }
        // The selection was on screen for the bar to be there: formatting it never scrolls the page.
        apply(edit, reveal: false)
        return true
    }

    // MARK: The `/` and `@` menus

    private func updateMenu() {
        guard let textView, let trigger = menu else { return }
        let start = trigger.location
        let ns = textView.string as NSString
        let caret = textView.selectedRange()
        let opener = trigger.kind.rawValue.utf16.count
        guard caret.length == 0, caret.location >= start + opener, start + opener <= ns.length,
              ns.substring(with: NSRange(location: start, length: opener)) == trigger.kind.rawValue else {
            return closeMenu()
        }
        let query = ns.substring(with: NSRange(location: start + opener, length: caret.location - start - opener))
        let items: [SlashMenuItem]
        switch trigger.kind {
        case .slash:
            guard query.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else { return closeMenu() }
            items = SlashMenu.filter(slashItems, query: query)
            guard !items.isEmpty else { return closeMenu() }
        case .mention:
            // Words, as "next week" or "in 3 days"; a new line or a sentence ends it.
            guard query.rangeOfCharacter(from: .newlines) == nil, !query.hasPrefix(" "),
                  query.utf16.count <= MenuTrigger.longestMention else { return closeMenu() }
            items = mentionItems(query)
            if items.isEmpty {
                slashPanel?.hide()
                return
            }
        case .link:
            // A note's name; a new line or `]` ends it.
            guard query.rangeOfCharacter(from: CharacterSet.newlines.union(["]"])) == nil,
                  query.utf16.count <= MenuTrigger.longestLink else { return closeMenu() }
            items = linkItems(query)
            if items.isEmpty {
                slashPanel?.hide()
                return
            }
        }
        // A menu only belongs to an editor that is on screen and has the keyboard.
        guard let window = textView.window, window.firstResponder === textView else { return closeMenu() }
        let anchor = textView.screenRect(for: NSRange(location: start, length: 1))
            ?? textView.firstRect(forCharacterRange: NSRange(location: start, length: 1), actualRange: nil)
        let grouped = trigger.kind == .mention || (trigger.kind == .slash && query.isEmpty)
        panel.show(items, grouped: grouped, below: anchor, in: window)
    }

    private func choose(_ item: SlashMenuItem) {
        guard let textView, let start = menu?.location else { return }
        let caret = textView.selectedRange().location
        let trigger = NSRange(location: start, length: max(0, caret - start))
        if item.picksImages, onDropFiles != nil {
            // Finder's Open panel takes a second or two to come up: until it does, the menu stays with the chosen
            // row saying so; it closes once the sheet is up.
            menu = nil
            pendingMenu = nil
            panel.model.loading = item.id
            run(item, replacing: trigger, after: 0.05)
            return
        }
        closeMenu()
        run(item, replacing: trigger)
    }

    private func closeMenu() {
        menu = nil
        pendingMenu = nil
        // Always: the panel can be a child window while not reported visible (window hidden or occluded).
        slashPanel?.hide()
    }
}

/// Where a menu's `/` or `@` was typed.
struct MenuTrigger: Equatable {
    enum Kind: String {
        case slash = "/"
        case mention = "@"
        case link = "[["
    }

    let location: Int
    let kind: Kind

    /// Past this many characters after `@` without a match, it was not a date being typed.
    static let longestMention = 24
    /// Past this many characters after `[[`, it was not a note's name being typed.
    static let longestLink = 80
}

/// Where dropped files go while they are imported: an offset that follows the edits made before it.
final class DropAnchor {
    var location: Int

    init(location: Int) {
        self.location = location
    }

    /// `range` is replaced by `replacementLength` characters: an edit before the anchor moves it, one around it puts
    /// it at the edit's end; one at the anchor or after leaves it.
    func follow(_ range: NSRange, replacementLength: Int) {
        if NSMaxRange(range) <= location, range.location < location {
            location += replacementLength - range.length
        } else if range.location < location {
            location = range.location + replacementLength
        }
    }
}

/// The editor's scroll view. A page that moves by fractions of a point, as it does while a sidebar slides, hands its
/// view sizes a pixel apart from one frame to the next, and each laid the visible text out again; a change of under
/// `jitter` points from the size last applied is ignored (a real resize accumulates past it).
final class EditorScrollView: NSScrollView {
    static let jitter: CGFloat = 1.5

    override func setFrameSize(_ newSize: NSSize) {
        let old = frame.size
        if old.width > 0, abs(newSize.width - old.width) < Self.jitter, abs(newSize.height - old.height) < Self.jitter,
           newSize != old, !inLiveResize {
            return
        }
        super.setFrameSize(newSize)
    }
}
