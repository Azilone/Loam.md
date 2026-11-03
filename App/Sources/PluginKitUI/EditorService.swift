import CoreGraphics
import Foundation
import Observation
import SwiftUI

/// One replacement in the editor's text, in UTF-16 offsets (`NSRange`, as TextKit uses), and where the
/// selection goes afterwards. The same shape as the editor engine's own edits, so the editor plugin passes it
/// through unchanged.
public struct TextChange: Sendable, Equatable {
    public let range: NSRange
    public let replacement: String
    /// The selection after the change, in the changed text.
    public let selection: NSRange

    public init(range: NSRange, replacement: String, selection: NSRange) {
        self.range = range
        self.replacement = replacement
        self.selection = selection
    }

    /// The text after the change. For tests; the editor applies changes through its text view.
    public func applied(to text: String) -> String {
        (text as NSString).replacingCharacters(in: range, with: replacement)
    }
}

/// An entry a plugin adds to the editor's `/` menu. It only ever inserts standard Markdown.
public struct SlashItem: Identifiable, Sendable {
    public let id: String
    public let title: String
    /// SF Symbol name.
    public let symbol: String
    /// Extra words the menu's filter matches.
    public let keywords: [String]
    /// Builds the change from the note's text. `trigger` is the `/` and the filter typed after it; the change
    /// usually replaces it. A pure function of its inputs, so it is tested without an editor.
    public let makeChange: @Sendable (_ text: String, _ trigger: NSRange) -> TextChange

    public init(
        id: String,
        title: String,
        symbol: String,
        keywords: [String] = [],
        makeChange: @escaping @Sendable (_ text: String, _ trigger: NSRange) -> TextChange
    ) {
        self.id = id
        self.title = title
        self.symbol = symbol
        self.keywords = keywords
        self.makeChange = makeChange
    }
}

/// One entry of the `@` menu, from a `MentionSource`. It only ever inserts standard Markdown.
public struct MentionItem: Identifiable, Sendable {
    public let id: String
    public let title: String
    /// SF Symbol name.
    public let symbol: String
    /// Builds the change from the note's text. `trigger` is the `@` and the words typed after it; the change
    /// usually replaces it.
    public let makeChange: @Sendable (_ text: String, _ trigger: NSRange) -> TextChange

    public init(
        id: String,
        title: String,
        symbol: String,
        makeChange: @escaping @Sendable (_ text: String, _ trigger: NSRange) -> TextChange
    ) {
        self.id = id
        self.title = title
        self.symbol = symbol
        self.makeChange = makeChange
    }
}

/// A section of the `@` menu ("Days"), Craft's: typing `@` then a few words ("tomorrow", "21oct") asks every
/// source for its entries, and the menu lists them under the source's `section`.
public struct MentionSource: Identifiable, Sendable {
    public let id: String
    public let section: String
    /// The entries for the words typed after `@` (empty right after it), best first; none hides the section.
    public let suggestions: @MainActor @Sendable (_ query: String) -> [MentionItem]

    public init(id: String, section: String, suggestions: @escaping @MainActor @Sendable (_ query: String) -> [MentionItem]) {
        self.id = id
        self.section = section
        self.suggestions = suggestions
    }
}

/// Draws the fenced code blocks of some languages as pictures, such as ` ```mermaid ` as a diagram. The note keeps
/// the code: the editor shows the picture in its place, and the code again (the picture under it) while the caret is
/// in the block.
public struct CodeBlockRenderer: Identifiable, Sendable {
    /// Dotted and owned by the plugin, such as `diagrams.mermaid`.
    public let id: String
    /// The languages written after the opening fence, lowercased.
    public let languages: [String]
    /// The picture of a block; nil when its code cannot be drawn (a syntax error), and the block stays code. Called
    /// again only when the code or the page's look changes.
    public let render: @MainActor @Sendable (CodeBlockRequest) async -> RenderedCodeBlock?

    public init(
        id: String,
        languages: [String],
        render: @escaping @MainActor @Sendable (CodeBlockRequest) async -> RenderedCodeBlock?
    ) {
        self.id = id
        self.languages = languages.map { $0.lowercased() }
        self.render = render
    }
}

/// One block to draw, with the page's look, so the picture matches the text around it.
public struct CodeBlockRequest: Hashable, Sendable {
    public var language: String
    /// The text between the fences.
    public var code: String
    public var isDark: Bool
    /// CSS colours (`#1f2225`, `rgba(...)`) of the page, resolved for its appearance.
    public var text: String
    public var secondaryText: String
    public var accent: String
    public var background: String
    public var codeBackground: String
    public var separator: String
    /// A CSS font family (`-apple-system`, `ui-serif`, a quoted family name) and the body's size in points.
    public var fontFamily: String
    public var fontSize: Double

    public init(
        language: String, code: String, isDark: Bool = false,
        text: String = "#1f2225", secondaryText: String = "#6e6e73", accent: String = "#2f6fde",
        background: String = "#ffffff", codeBackground: String = "#f2f2f4", separator: String = "#d4d4d8",
        fontFamily: String = "-apple-system", fontSize: Double = 15
    ) {
        self.language = language
        self.code = code
        self.isDark = isDark
        self.text = text
        self.secondaryText = secondaryText
        self.accent = accent
        self.background = background
        self.codeBackground = codeBackground
        self.separator = separator
        self.fontFamily = fontFamily
        self.fontSize = fontSize
    }
}

/// A drawn block: the image, and the size it is shown at, in points (the image itself may be at 2x).
public struct RenderedCodeBlock: @unchecked Sendable {
    public let image: CGImage
    public let size: CGSize

    public init(image: CGImage, size: CGSize) {
        self.image = image
        self.size = size
    }
}

/// Shows the fenced code blocks of some languages as a live, interactive view, such as ` ```base ` as a table of
/// notes. The note keeps the code: the editor shows the view in its place, and the code again (the view under it)
/// while the caret is in the block. The view edits the block only through its `CodeBlockContext`.
public struct CodeBlockView: Identifiable, Sendable {
    /// Dotted and owned by the plugin, such as `collections.base`.
    public let id: String
    /// The languages written after the opening fence, lowercased.
    public let languages: [String]
    /// The view of one block, built once while the block stays in the note; it follows `context.code`.
    public let makeView: @MainActor @Sendable (CodeBlockContext) -> AnyView

    public init(id: String, languages: [String], makeView: @escaping @MainActor @Sendable (CodeBlockContext) -> AnyView) {
        self.id = id
        self.languages = languages.map { $0.lowercased() }
        self.makeView = makeView
    }
}

/// One block shown by a `CodeBlockView`: where it is, its code, live, and the edits its view may make.
@MainActor
@Observable
public final class CodeBlockContext {
    /// The vault-relative path of the note holding the block.
    public let notePath: String
    /// Lowercased, as written after the opening fence.
    public let language: String
    /// The text between the fences, following the note's typing and undo.
    public private(set) var code: String
    /// Whether the caret is in the block, which then shows its code above the view.
    public private(set) var isEditingCode: Bool
    @ObservationIgnored private let replace: @MainActor (String) -> Void
    @ObservationIgnored private let edit: @MainActor () -> Void

    /// For editors: a view gets its context from the editor.
    public init(
        notePath: String, language: String, code: String, isEditingCode: Bool = false,
        replaceCode: @escaping @MainActor (String) -> Void, editCode: @escaping @MainActor () -> Void
    ) {
        self.notePath = notePath
        self.language = language
        self.code = code
        self.isEditingCode = isEditingCode
        replace = replaceCode
        edit = editCode
    }

    /// Replaces the code between the fences, as one edit (one step of undo), and saves the note as typing does.
    public func replaceCode(_ code: String) { replace(code) }

    /// Puts the caret at the start of the code, which shows it.
    public func editCode() { edit() }

    /// For editors: the block's code or caret changed.
    public func update(code: String, isEditingCode: Bool) {
        if code != self.code { self.code = code }
        if isEditingCode != self.isEditingCode { self.isEditingCode = isEditingCode }
    }
}

/// A view a plugin lays over every note's page, beside the text, such as the outline's ticks at the right edge. It
/// draws nothing in the note: the editor gives it the note's text and scroll position through a `PageContext`, and
/// scrolls when it asks.
public struct PageOverlay: Identifiable, Sendable {
    /// Dotted and owned by the plugin, such as `outline.ticks`.
    public let id: String
    /// The view over one page, built once per editor; it follows `context`. It fills the page, under the toolbar
    /// (`PageContext.topInset`), and lets the pointer through where it draws nothing.
    public let makeView: @MainActor @Sendable (PageContext) -> AnyView

    public init(id: String, makeView: @escaping @MainActor @Sendable (PageContext) -> AnyView) {
        self.id = id
        self.makeView = makeView
    }
}

/// How far a page has scrolled, in points.
public struct PageScroll: Equatable, Sendable {
    /// How much of the text is above the visible part.
    public var offset: CGFloat
    /// The height of the visible part.
    public var visibleHeight: CGFloat
    /// The height of the whole text.
    public var contentHeight: CGFloat

    public init(offset: CGFloat = 0, visibleHeight: CGFloat = 0, contentHeight: CGFloat = 0) {
        self.offset = offset
        self.visibleHeight = visibleHeight
        self.contentHeight = contentHeight
    }
}

/// One page shown by an editor, as a `PageOverlay` sees it: its note, its text, live, its scroll position, and how
/// to move it.
@MainActor
@Observable
public final class PageContext {
    /// The vault-relative path of the note shown; changes when the tab follows a link.
    public private(set) var notePath: String
    /// The note's text, unsaved typing included, updated when typing pauses.
    public private(set) var text: String
    /// Follows the scroll on every frame: read it only for what has to move with it.
    public private(set) var scroll = PageScroll()
    /// The height covered by the toolbar's glass at the top of the page, which the text scrolls under.
    public private(set) var topInset: CGFloat = 0
    @ObservationIgnored private let linesY: @MainActor ([Int]) -> [CGFloat?]
    @ObservationIgnored private let scrollToLine: @MainActor (Int) -> Void

    /// For editors: an overlay gets its context from the editor.
    public init(
        notePath: String, text: String,
        linesY: @escaping @MainActor ([Int]) -> [CGFloat?], scrollToLine: @escaping @MainActor (Int) -> Void
    ) {
        self.notePath = notePath
        self.text = text
        self.linesY = linesY
        self.scrollToLine = scrollToLine
    }

    /// Where `line` (1-based) starts in the text, in points from its top, as `scroll.offset` counts; nil when there
    /// is no such line or no layout yet. Lays the text out up to that line: call it when the text changes, not per
    /// frame.
    public func y(ofLine line: Int) -> CGFloat? { linesY([line]).first ?? nil }

    /// `y(ofLine:)` for several lines at once, in their order: one pass over the text and its layout, however many.
    public func ys(ofLines lines: [Int]) -> [CGFloat?] { linesY(lines) }

    /// Scrolls the page so `line` (1-based) comes to the top, under the toolbar, without moving the caret.
    public func scroll(toLine line: Int) { scrollToLine(line) }

    /// For editors.
    public func update(notePath: String, text: String) {
        if notePath != self.notePath { self.notePath = notePath }
        if text != self.text { self.text = text }
    }

    /// For editors.
    public func update(scroll: PageScroll, topInset: CGFloat) {
        if scroll != self.scroll { self.scroll = scroll }
        if topInset != self.topInset { self.topInset = topInset }
    }
}

/// The `editor` service, provided by the Markdown editor plugin (not by the shell), so another editor can
/// replace it. Plugins list `editor` in `optionalRequires`: without an editor they still work, minus their
/// slash items.
@MainActor
public protocol EditorService: AnyObject {
    /// Adds an item to the `/` menu; the returned function removes it.
    func addSlashItem(_ item: SlashItem) -> @MainActor () -> Void
    /// Adds a section to the `@` menu; the returned function removes it. Optional: the default ignores it.
    func addMentionSource(_ source: MentionSource) -> @MainActor () -> Void
    /// Inserts `text` at the caret of the focused note. False when no note has the focus.
    @discardableResult func insertAtCaret(_ text: String) -> Bool
    /// The current text of the note at `path` while an editor has it open, unsaved typing included; nil when no
    /// editor has it open (read the vault instead). Optional: the default returns nil.
    func text(of path: String) -> String?
    /// Puts the caret at the start of `line` (1-based) in the active editor and scrolls to it, when that editor
    /// shows the note at `path`. False otherwise (no editor, another note, no such line). Optional: the default
    /// returns false.
    @discardableResult func reveal(line: Int, in path: String) -> Bool
    /// Draws fenced code blocks of `renderer.languages` as pictures; the returned function removes it. Optional: the
    /// default draws nothing.
    func addCodeBlockRenderer(_ renderer: CodeBlockRenderer) -> @MainActor () -> Void
    /// Announces a new note at `path`, which has no file: open it with the workspace and the editor shows it with
    /// `text` (a template; usually empty), writing the file only once the note holds something else. A note made
    /// this way and left empty is gone again when its tab closes or the app quits (an empty note never stays on
    /// disk). Does nothing for a path that exists. Optional: the default does nothing, and a plugin then writes
    /// the file itself.
    func beginDraft(at path: String, text: String)
    /// True while `path` is a new note announced with `beginDraft` that is shown or waiting to be and has no
    /// file yet, so a plugin picking a name for another new note skips it. Optional: the default returns false.
    func isDraft(_ path: String) -> Bool
    /// Takes the files dropped or pasted into notes; the returned function removes it. Handlers are asked in the
    /// order they were added. Optional: the default ignores it, and files dropped on that editor do nothing.
    func addFileDropHandler(_ handler: FileDropHandler) -> @MainActor () -> Void
    /// Shows image links alone on their line, to files of `renderer.extensions`, as embeds; the returned function
    /// removes it. The last renderer added for an extension wins. Optional: the default shows the links as text.
    func addEmbedRenderer(_ renderer: EmbedRenderer) -> @MainActor () -> Void
    /// Shows fenced code blocks of `view.languages` as live views; the returned function removes it. Wins over a
    /// renderer of the same language. Optional: the default shows nothing.
    func addCodeBlockView(_ view: CodeBlockView) -> @MainActor () -> Void
    /// Lays `overlay` over every note's page; the returned function removes it. Optional: the default shows nothing.
    func addPageOverlay(_ overlay: PageOverlay) -> @MainActor () -> Void
}

public extension EditorService {
    func beginDraft(at path: String, text: String) {}
    /// A new, blank note: see `beginDraft(at:text:)`.
    func beginDraft(at path: String) { beginDraft(at: path, text: "") }
    func isDraft(_ path: String) -> Bool { false }
    func addMentionSource(_ source: MentionSource) -> @MainActor () -> Void { {} }
    func text(of path: String) -> String? { nil }
    @discardableResult func reveal(line: Int, in path: String) -> Bool { false }
    func addCodeBlockRenderer(_ renderer: CodeBlockRenderer) -> @MainActor () -> Void { {} }
    func addFileDropHandler(_ handler: FileDropHandler) -> @MainActor () -> Void { {} }
    func addEmbedRenderer(_ renderer: EmbedRenderer) -> @MainActor () -> Void { {} }
    func addCodeBlockView(_ view: CodeBlockView) -> @MainActor () -> Void { {} }
    func addPageOverlay(_ overlay: PageOverlay) -> @MainActor () -> Void { {} }
}

/// Sent by the editor plugin, about 300 ms after typing stops, when the text of an open note changed, so a panel
/// (outline, word count) can follow the unsaved text with `EditorService.text(of:)`. Saving to disk sends
/// `VaultChanged` as usual; this event comes first and more often.
public struct DocumentTextChanged: PluginEvent, Sendable, Equatable {
    public let path: String

    public init(path: String) {
        self.path = path
    }
}
