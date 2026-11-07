import AppKit
import MarkdownEditor
import Observation
import PluginKitUI
import SwiftUI

/// The `editor` service and what the plugin's views share: the open documents, the slash items other plugins
/// added, the editor of the active tab, and link handling.
///
/// Observable, so the open editors pick up a slash item as soon as a plugin adds it.
@MainActor
@Observable
public final class MarkdownEditorService: EditorService {
    private var entries: [(token: Int, item: SlashItem)] = []
    private var sources: [(token: Int, source: MentionSource)] = []
    private var renderers: [(token: Int, renderer: CodeBlockRenderer)] = []
    private var dropHandlers: [(token: Int, handler: FileDropHandler)] = []
    private var embedRenderers: [(token: Int, renderer: EmbedRenderer)] = []
    private var blockViews: [(token: Int, view: CodeBlockView)] = []
    private var overlays: [(token: Int, overlay: PageOverlay)] = []
    @ObservationIgnored private var nextToken = 0
    /// The editor of the active tab, set by the views. Weak: a view that goes away takes it with it.
    @ObservationIgnored private weak var activeController: EditorController?
    /// The document the active editor shows, so `reveal` knows which note it is.
    @ObservationIgnored private weak var activeDocument: Document?
    /// Sends `EditorSelectionChanged`; set by the plugin.
    @ObservationIgnored var selectionChanged: ((_ path: String, _ text: String) -> Void)?
    @ObservationIgnored private var lastSelection: (path: String, text: String)?

    @ObservationIgnored let documents: DocumentStore
    /// Where other plugins' bands above a note's text come from; nil without the shell.
    @ObservationIgnored var noteHeaders: (any NoteHeaderRegistry)?
    /// The daily notes, which a date pill opens; nil without that plugin. Set by the plugin.
    @ObservationIgnored var dailyNotes: @MainActor () -> DailyNotesService? = { nil }
    /// Moves a note (old path, new path), rewriting the links to it when the note graph is on. Set by the plugin.
    @ObservationIgnored var moveNote: @MainActor (String, String) throws -> Void = { _, _ in }
    /// The view types, so a link to a file some plugin opens (a `.canvas` board) opens in Loam. Set by the plugin.
    @ObservationIgnored var views: @MainActor () -> (any ViewRegistry)? = { nil }
    /// The note graph, for the titles the `@` and `[[` menus list notes by; nil without it. Set by the plugin.
    @ObservationIgnored var noteGraph: @MainActor () -> NoteGraphService? = { nil }
    /// The files the `@` and `[[` menus link, read when one first needs them, until files come or go.
    @ObservationIgnored private var fileStamps: [String: FileStamp]?
    /// The heading a note link (`[[Note#Heading]]`) asked for, by note path, until its page shows and scrolls there.
    @ObservationIgnored private var pendingHeadings: [String: String] = [:]
    /// How the open pages scroll to a heading, by note path: a link to a note already shown scrolls it at once.
    @ObservationIgnored private var headingScrollers: [String: @MainActor (String) -> Bool] = [:]
    @ObservationIgnored private let workspace: @MainActor () -> (any Workspace)?
    @ObservationIgnored private let openURL: @MainActor (URL) -> Void

    init(
        documents: DocumentStore,
        workspace: @escaping @MainActor () -> (any Workspace)?,
        openURL: @escaping @MainActor (URL) -> Void = { url in NSWorkspace.shared.open(url) }
    ) {
        self.documents = documents
        self.workspace = workspace
        self.openURL = openURL
        documents.beforeSave = { [weak self] in self?.activeController?.flushChange() }
    }

    // MARK: EditorService

    /// The items other plugins added, in the order they were added.
    public var slashItems: [SlashItem] { entries.map(\.item) }

    public func addSlashItem(_ item: SlashItem) -> @MainActor () -> Void {
        let token = nextToken
        nextToken += 1
        entries.append((token, item))
        return { [weak self] in self?.entries.removeAll { $0.token == token } }
    }

    public func addMentionSource(_ source: MentionSource) -> @MainActor () -> Void {
        let token = nextToken
        nextToken += 1
        sources.append((token, source))
        return { [weak self] in self?.sources.removeAll { $0.token == token } }
    }

    public func addCodeBlockRenderer(_ renderer: CodeBlockRenderer) -> @MainActor () -> Void {
        let token = nextToken
        nextToken += 1
        renderers.append((token, renderer))
        return { [weak self] in self?.renderers.removeAll { $0.token == token } }
    }

    public func addFileDropHandler(_ handler: FileDropHandler) -> @MainActor () -> Void {
        let token = nextToken
        nextToken += 1
        dropHandlers.append((token, handler))
        return { [weak self] in self?.dropHandlers.removeAll { $0.token == token } }
    }

    public func addEmbedRenderer(_ renderer: EmbedRenderer) -> @MainActor () -> Void {
        let token = nextToken
        nextToken += 1
        embedRenderers.append((token, renderer))
        return { [weak self] in self?.embedRenderers.removeAll { $0.token == token } }
    }

    public func addCodeBlockView(_ view: CodeBlockView) -> @MainActor () -> Void {
        let token = nextToken
        nextToken += 1
        blockViews.append((token, view))
        return { [weak self] in self?.blockViews.removeAll { $0.token == token } }
    }

    public func addPageOverlay(_ overlay: PageOverlay) -> @MainActor () -> Void {
        let token = nextToken
        nextToken += 1
        overlays.append((token, overlay))
        return { [weak self] in self?.overlays.removeAll { $0.token == token } }
    }

    /// The overlays plugins laid over pages, in the order they were added.
    var pageOverlays: [PageOverlay] { overlays.map(\.overlay) }

    @discardableResult
    public func insertAtCaret(_ text: String) -> Bool {
        activeController?.insertAtCaret(text) ?? false
    }

    public func text(of path: String) -> String? {
        activeController?.flushChange()
        return documents.document(at: path)?.text
    }

    /// Runs a `/` menu entry at the caret of the focused note (the right sidebar's Insert tiles).
    @discardableResult
    func insert(_ item: SlashMenuItem) -> Bool {
        activeController?.insert(item) ?? false
    }

    @discardableResult
    public func reveal(line: Int, in path: String) -> Bool {
        guard let activeController, activeDocument?.path == path else { return false }
        return activeController.reveal(line: line)
    }

    public func beginDraft(at path: String, text: String) { documents.beginDraft(path, text: text) }

    public func isDraft(_ path: String) -> Bool { documents.isDraft(path) }

    // MARK: For the views

    /// What the `/` menu offers: the engine's standard items, then the ones plugins added.
    var menuItems: [SlashMenuItem] { SlashMenu.standardItems + slashItems.map(Self.menuItem) }

    /// The languages plugins draw as pictures, for the engine; the last renderer added for a language wins.
    var pictureRenderers: [String: PictureRenderer] {
        var result: [String: PictureRenderer] = [:]
        for (_, renderer) in renderers {
            for language in renderer.languages { result[language] = Self.pictureRenderer(renderer) }
        }
        return result
    }

    /// A plugin's renderer as the engine's: the same request, and the image at its size in points.
    static func pictureRenderer(_ renderer: CodeBlockRenderer) -> PictureRenderer {
        let render = renderer.render
        return { request in
            let rendered = await render(CodeBlockRequest(
                language: request.language, code: request.code, isDark: request.isDark,
                text: request.colors.text, secondaryText: request.colors.secondaryText, accent: request.colors.accent,
                background: request.colors.background, codeBackground: request.colors.codeBackground,
                separator: request.colors.separator, fontFamily: request.fontFamily, fontSize: Double(request.fontSize)
            ))
            return rendered.map { NSImage(cgImage: $0.image, size: $0.size) }
        }
    }

    /// How the editor of the note at `notePath` shows image links alone on their line: the plugins' embed renderers
    /// for the file's extension (the last added wins), on files inside the vault; nil when no plugin shows any.
    /// What `embedProvider`'s `identify` found for a note's link, and when.
    @ObservationIgnored private var embedKeys: [String: (key: String?, at: TimeInterval)] = [:]

    func embedProvider(for notePath: String, theme: EmbedTheme = EmbedTheme()) -> EmbedProvider? {
        guard !embedRenderers.isEmpty else { return nil }
        var byExtension: [String: EmbedRenderer] = [:]
        for (_, renderer) in embedRenderers {
            for ext in renderer.extensions { byExtension[ext] = renderer }
        }
        let id = embedRenderers.map { $0.renderer.id + ":" + $0.renderer.extensions.joined(separator: ",") }.joined(separator: ";")
        let vault = documents.vault
        return EmbedProvider(
            id: id,
            identify: { [weak self] link in
                // Asked at every restyle, so on each keystroke: a link's key is kept until the vault changes, for a
                // second at most, where it cost two file system calls per embed per keystroke.
                let memo = notePath + "\n" + link.destination
                let now = ProcessInfo.processInfo.systemUptime
                if let known = self?.embedKeys[memo], now - known.at < 1 { return known.key }
                var key: String?
                if let path = NoteLinks.embeddedFile(link.destination, from: notePath, vault: vault),
                   byExtension[(path as NSString).pathExtension.lowercased()] != nil {
                    let attributes = try? FileManager.default.attributesOfItem(atPath: vault.rootURL.appendingPathComponent(path).path)
                    let modified = (attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
                    key = "\(path)|\(modified)|\(attributes?[.size] as? Int ?? 0)"
                }
                if self?.embedKeys.count ?? 0 > 2000 { self?.embedKeys = [:] }
                self?.embedKeys[memo] = (key, now)
                return key
            },
            render: { link in
                guard let path = NoteLinks.embeddedFile(link.destination, from: notePath, vault: vault),
                      let renderer = byExtension[(path as NSString).pathExtension.lowercased()],
                      let rendered = await renderer.render(EmbedRequest(
                          destination: link.destination, alt: link.alt, path: path,
                          file: vault.rootURL.appendingPathComponent(path), notePath: notePath
                      )) else { return nil }
                return Self.embed(rendered, theme: theme)
            }
        )
    }

    /// A plugin's embed as the engine's: the picture as an image, the view in a hosting view with the page's theme.
    static func embed(_ rendered: RenderedEmbed, theme: EmbedTheme = EmbedTheme()) -> Embed {
        switch rendered.content {
        case .image(let image):
            return Embed(content: .image(NSImage(cgImage: image, size: rendered.size)), size: rendered.size)
        case .view(let makeView):
            return Embed(
                content: .view { NSHostingView(rootView: ThemedEmbedRoot(content: AnyView(makeView()), theme: theme)) },
                size: rendered.size, keepsHeight: rendered.keepsHeight, isInteractive: rendered.isInteractive
            )
        }
    }

    /// What the editor of the note at `notePath` does with dropped and pasted files: each plugin's handler in turn,
    /// until one returns Markdown; nil when no plugin takes files.
    func fileDrop(for notePath: String) -> (@MainActor ([DroppedFile]) async -> String?)? {
        guard !dropHandlers.isEmpty else { return nil }
        return { [weak self] files in
            guard let self else { return nil }
            let items = files.map { file -> DroppedFiles.Item in
                switch file {
                case .file(let url): .file(url)
                case .data(let data, let ext): .data(data, pathExtension: ext)
                }
            }
            for (_, handler) in self.dropHandlers {
                if let markdown = await handler.handle(DroppedFiles(items: items, notePath: notePath)) { return markdown }
            }
            return nil
        }
    }

    /// Adds `markdown` as a block at the end of the note at `path`, which no editor is showing.
    func append(_ markdown: String, toNoteAt path: String) {
        guard let document = documents.acquire(path) else { return }
        defer { documents.release(document) }
        let body = document.text.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
        document.edit((body.isEmpty ? "" : body + "\n\n") + markdown + "\n", from: UUID())
    }

    /// The languages plugins show as live views in the note at `notePath`, for the engine; the last view added for a
    /// language wins. Each view gets the page's theme.
    func liveBlocks(notePath: String, theme: EmbedTheme = EmbedTheme()) -> [String: LiveBlockProvider] {
        var result: [String: LiveBlockProvider] = [:]
        for (_, view) in blockViews {
            for language in view.languages { result[language] = Self.liveBlock(view, notePath: notePath, theme: theme) }
        }
        return result
    }

    /// A plugin's view as the engine's: a context that follows the engine's handle of the block.
    static func liveBlock(_ view: CodeBlockView, notePath: String, theme: EmbedTheme) -> LiveBlockProvider {
        let makeView = view.makeView
        return { handle in
            let context = CodeBlockContext(
                notePath: notePath, language: handle.language, code: handle.code, isEditingCode: handle.isEditingCode,
                replaceCode: { [weak handle] code in handle?.replaceCode(code) },
                editCode: { [weak handle] in handle?.editCode() }
            )
            handle.onChange = { [weak context, weak handle] in
                guard let context, let handle else { return }
                context.update(code: handle.code, isEditingCode: handle.isEditingCode)
            }
            return AnyView(ThemedEmbedRoot(content: AnyView(makeView(context)), theme: theme))
        }
    }

    /// A plugin's item as the engine's: `TextChange` and `TextEdit` have the same shape.
    static func menuItem(_ item: SlashItem) -> SlashMenuItem {
        let makeChange = item.makeChange
        return SlashMenuItem(id: item.id, title: item.title, symbol: item.symbol, keywords: item.keywords) { text, trigger in
            let change = makeChange(text, trigger)
            return TextEdit(range: change.range, replacement: change.replacement, selection: change.selection)
        }
    }

    /// What the `@` menu offers for `query` in the note at `notePath`: each source's entries, under its section, in
    /// the order the sources were added, then the notes to link.
    func mentionItems(_ query: String, from notePath: String) -> [SlashMenuItem] {
        let fromSources = sources.flatMap { entry in
            entry.source.suggestions(query).map { item in
                let makeChange = item.makeChange
                return SlashMenuItem(id: entry.source.id + "/" + item.id, title: item.title, symbol: item.symbol, section: entry.source.section) { text, trigger in
                    let change = makeChange(text, trigger)
                    return TextEdit(range: change.range, replacement: change.replacement, selection: change.selection)
                }
            }
        }
        return fromSources + noteItems(query, from: notePath, fuzzy: false, limit: NoteMentions.mentionLimit)
    }

    /// What the `[[` menu offers for `query` in the note at `notePath`: the notes to link.
    func linkItems(_ query: String, from notePath: String) -> [SlashMenuItem] {
        noteItems(query, from: notePath, fuzzy: true, limit: NoteMentions.linkLimit)
    }

    private func noteItems(_ query: String, from notePath: String, fuzzy: Bool, limit: Int) -> [SlashMenuItem] {
        let views = views()
        let stamps = fileStamps ?? ((try? documents.vault.stamps()) ?? [:]).filter { NoteMentions.isPage($0.key, views: views) }
        fileStamps = stamps
        let candidates = NoteMentions.candidates(stamps: stamps, graph: noteGraph())
        let ranked = NoteMentions.rank(query, in: candidates, excluding: notePath, fuzzy: fuzzy, limit: limit)
        let names = NoteMentions.displayNames(ranked)
        return ranked.map { note in
            SlashMenuItem(
                id: "notes/" + note.path, title: names[note.path] ?? note.title,
                symbol: views?.symbol(for: .file(note.path)) ?? "doc.text", section: NoteMentions.section
            ) { text, trigger in
                NoteMentions.change(in: text, trigger: trigger, linking: note.path, titled: note.title, from: notePath)
            }
        }
    }

    /// Files came or went: the menus read the vault's files again next time.
    func forgetFileStamps() { fileStamps = nil }

    /// Files changed: an embed's file may be another now (`embedProvider`).
    func forgetEmbedKeys() { embedKeys = [:] }

    /// The editor of the tab that became active, and the document it shows.
    func activate(_ controller: EditorController?, document: Document?) {
        guard let controller else { return }
        activeController = controller
        activeDocument = document
    }

    /// The editor's tab is no longer active or its view went away.
    func resign(_ controller: EditorController?) {
        controller?.flushChange()
        if let controller, activeController === controller {
            activeController = nil
            activeDocument = nil
        }
    }

    var hasActiveEditor: Bool { activeController != nil }

    /// Switches the active editor between the page (no Markdown syntax visible) and the Markdown as written. Returns
    /// whether it shows the source now; nil when no editor is active.
    @discardableResult
    func toggleSource() -> Bool? {
        guard let activeController else { return nil }
        activeController.syntaxMode = activeController.syntaxMode == .source ? .rendered : .source
        return activeController.syntaxMode == .source
    }

    /// Cmd-click on a link in the note at `notePath`: a note, or another file a view type opens (a `.canvas`
    /// board), opens in place of the tab (beside it with Option); anything else in its own app.
    func openLink(_ destination: String, from notePath: String, beside: Bool) {
        let placement: Placement = beside ? .beside : .replace
        switch NoteLinks.resolve(destination, from: notePath, vault: documents.vault) {
        case .note(let path):
            let heading = NoteLinks.heading(of: destination)
            if let heading, path == notePath, !beside, headingScrollers[path]?(heading) == true { return }
            if let heading { pendingHeadings[path] = heading }
            workspace()?.open(.file(path), placement: placement)
            if let heading, let scroll = headingScrollers[path], scroll(heading) { pendingHeadings[path] = nil }
        case .file(let path):
            if let workspace = workspace(), views()?.viewTypes(for: .file(path)).isEmpty == false {
                workspace.open(.file(path), placement: placement)
            } else {
                openURL(documents.vault.rootURL.appendingPathComponent(path))
            }
        case .external(let url):
            openURL(url)
        case nil:
            NSSound.beep()
        }
    }

    /// A page showing the note at `path` scrolls to a heading with `scroll` (false when the note has no such heading);
    /// a heading a link asked for before the page showed is scrolled to now.
    func registerHeadingScroller(_ path: String, _ scroll: @escaping @MainActor (String) -> Bool) {
        headingScrollers[path] = scroll
        if let heading = pendingHeadings.removeValue(forKey: path) { _ = scroll(heading) }
    }

    /// Whether a date pill can open its day: a daily notes plugin is there.
    var canOpenDays: Bool { dailyNotes() != nil }

    /// A click on a date pill: the daily note of `day` opens in place of the tab (in a new tab with Command). A day
    /// without a note opens as a draft: the file appears once text is typed in it.
    func openDay(_ day: String, newTab: Bool) {
        guard let daily = dailyNotes(), let path = try? daily.path(for: day) else {
            NSSound.beep()
            return
        }
        if (try? daily.read(date: day)) == nil {
            documents.beginDraft(path, text: (try? daily.startingText(for: day)) ?? "")
        }
        workspace()?.open(.file(path), placement: newTab ? .newTab : .replace)
    }

    /// Renames the note at `path` to `name` (without `.md`) in its folder: the editor's title. False when the name
    /// is taken or the move fails.
    func rename(_ path: String, to name: String) -> Bool {
        let folder = (path as NSString).deletingLastPathComponent
        let destination = (folder.isEmpty ? "" : folder + "/") + name + ".md"
        guard destination != path, !documents.vault.exists(destination) else { return destination == path }
        documents.saveAll()
        do {
            try moveNote(path, destination)
            return true
        } catch {
            return false
        }
    }

    /// The selection of a note's editor, after each move of the caret: told on only when it changed.
    func noteSelection(_ path: String, _ text: String?) {
        let text = text ?? ""
        guard lastSelection?.path != path || lastSelection?.text != text else { return }
        lastSelection = (path, text)
        selectionChanged?(path, text)
    }
}
