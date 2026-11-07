import PluginKitUI

/// An `EditorService` with no editor behind it: it lists the slash items currently added, records the text
/// inserted at the caret and the lines revealed, and serves the "open" texts a test puts in `texts`.
@MainActor
public final class RecordingEditor: EditorService {
    private var entries: [(token: Int, item: SlashItem)] = []
    private var nextToken = 0
    public private(set) var inserted: [String] = []
    /// What `insertAtCaret` returns: set it to false to simulate no focused note.
    public var hasFocusedNote = true

    /// The live text of the notes "open" in this editor, by path: what `text(of:)` returns.
    public var texts: [String: String] = [:]
    /// Every `reveal(line:in:)` call, in order.
    public private(set) var revealed: [(line: Int, path: String)] = []
    /// What `reveal` returns: set it to false to simulate an editor that does not show the note.
    public var canReveal = true
    private var renderers: [(token: Int, renderer: CodeBlockRenderer)] = []
    /// The code block renderers currently added, in order.
    public var codeBlockRenderers: [CodeBlockRenderer] { renderers.map(\.renderer) }

    public init() {}

    /// The items currently in the `/` menu, in the order they were added.
    public var slashItems: [SlashItem] { entries.map(\.item) }

    public func addSlashItem(_ item: SlashItem) -> @MainActor () -> Void {
        let token = nextToken
        nextToken += 1
        entries.append((token, item))
        return { [weak self] in self?.entries.removeAll { $0.token == token } }
    }

    private var sources: [(token: Int, source: MentionSource)] = []

    /// The sections currently in the `@` menu, in the order they were added.
    public var mentionSources: [MentionSource] { sources.map(\.source) }

    public func addMentionSource(_ source: MentionSource) -> @MainActor () -> Void {
        let token = nextToken
        nextToken += 1
        sources.append((token, source))
        return { [weak self] in self?.sources.removeAll { $0.token == token } }
    }

    @discardableResult
    public func insertAtCaret(_ text: String) -> Bool {
        guard hasFocusedNote else { return false }
        inserted.append(text)
        return true
    }

    public func text(of path: String) -> String? { texts[path] }

    /// Every `beginDraft(at:text:)` call, in order.
    public private(set) var drafts: [(path: String, text: String)] = []

    public func beginDraft(at path: String, text: String) { drafts.append((path, text)) }

    public func isDraft(_ path: String) -> Bool { drafts.contains { $0.path == path } }

    @discardableResult
    public func reveal(line: Int, in path: String) -> Bool {
        revealed.append((line, path))
        return canReveal
    }

    public func addCodeBlockRenderer(_ renderer: CodeBlockRenderer) -> @MainActor () -> Void {
        let token = nextToken
        nextToken += 1
        renderers.append((token, renderer))
        return { [weak self] in self?.renderers.removeAll { $0.token == token } }
    }

    private var dropHandlers: [(token: Int, handler: FileDropHandler)] = []
    /// The file drop handlers currently added, in order.
    public var fileDropHandlers: [FileDropHandler] { dropHandlers.map(\.handler) }

    public func addFileDropHandler(_ handler: FileDropHandler) -> @MainActor () -> Void {
        let token = nextToken
        nextToken += 1
        dropHandlers.append((token, handler))
        return { [weak self] in self?.dropHandlers.removeAll { $0.token == token } }
    }

    /// Files dropped on `notePath`, as the editor would hand them over: each handler in turn until one takes them.
    public func drop(_ items: [DroppedFiles.Item], on notePath: String) async -> String? {
        for handler in fileDropHandlers {
            if let markdown = await handler.handle(DroppedFiles(items: items, notePath: notePath)) { return markdown }
        }
        return nil
    }

    private var embeds: [(token: Int, renderer: EmbedRenderer)] = []
    /// The embed renderers currently added, in order.
    public var embedRenderers: [EmbedRenderer] { embeds.map(\.renderer) }

    public func addEmbedRenderer(_ renderer: EmbedRenderer) -> @MainActor () -> Void {
        let token = nextToken
        nextToken += 1
        embeds.append((token, renderer))
        return { [weak self] in self?.embeds.removeAll { $0.token == token } }
    }

    private var views: [(token: Int, view: CodeBlockView)] = []
    /// The live code block views currently added, in order.
    public var codeBlockViews: [CodeBlockView] { views.map(\.view) }

    public func addCodeBlockView(_ view: CodeBlockView) -> @MainActor () -> Void {
        let token = nextToken
        nextToken += 1
        views.append((token, view))
        return { [weak self] in self?.views.removeAll { $0.token == token } }
    }
}
