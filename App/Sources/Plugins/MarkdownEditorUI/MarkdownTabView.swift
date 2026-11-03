import MarkdownEditor
import PluginKitUI
import SwiftUI

/// What an editor tab saves in its `ViewContext`: the caret (a UTF-16 offset) and the scroll position.
public struct EditorTabState: Codable, Equatable, Sendable {
    public var caret: Int
    public var scrollY: Double
    /// Where the lines of the folded headings start.
    public var folded: [Int]

    public init(caret: Int, scrollY: Double, folded: [Int] = []) {
        self.caret = caret
        self.scrollY = scrollY
        self.folded = folded
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        caret = try container.decode(Int.self, forKey: .caret)
        scrollY = try container.decode(Double.self, forKey: .scrollY)
        // Saved before headings folded.
        folded = try container.decodeIfPresent([Int].self, forKey: .folded) ?? []
    }
}

/// One tab's hold on its document, kept in the view's `@State`: it takes the document when created and gives
/// it back when released, so the store knows when the last view of a note is gone. SwiftUI may build and drop
/// extra copies while it re-creates the view; each takes and gives back once, so the count stays right.
@MainActor
final class EditorTab {
    let document: Document?
    let editorID = UUID()
    weak var controller: EditorController?
    private let store: DocumentStore
    private(set) weak var viewContext: ViewContext?
    private var latestState: EditorTabState?
    private var commitTask: Task<Void, Never>?

    init(store: DocumentStore, viewContext: ViewContext, allowMissing: Bool = false) {
        self.store = store
        self.viewContext = viewContext
        document = viewContext.resource.kind == .file ? store.acquire(viewContext.resource.path, allowMissing: allowMissing) : nil
    }

    isolated deinit {
        commitTask?.cancel()
        if let document { store.release(document) }
    }

    /// The caret moved, the text scrolled or a heading folded: saved in the tab a moment after it settles, so scrolling does not
    /// rewrite the layout on every frame.
    func record(_ state: EditorViewState) {
        latestState = EditorTabState(caret: state.caret, scrollY: state.scrollY, folded: state.folded)
        commitTask?.cancel()
        commitTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            self?.commit()
        }
    }

    /// Saves the last recorded state in the tab now.
    func commit() {
        commitTask?.cancel()
        commitTask = nil
        guard let latestState, let viewContext, viewContext.state(EditorTabState.self) != latestState else { return }
        viewContext.setState(latestState)
    }
}

/// The tab's hold on the note it shows, kept in the view's `@State`. The shell keeps the view when a link or a sidebar
/// row puts another note in the tab (`ViewType.followsResource`): the hold then moves to the new note, the editor
/// staying the same.
@MainActor
final class EditorTabHolder {
    private var current: EditorTab?

    /// The hold on `viewContext`'s note, taken the first time it is asked for.
    func tab(for viewContext: ViewContext, service: MarkdownEditorService) -> EditorTab {
        if let current, current.viewContext === viewContext { return current }
        // A note a plugin gives a header that may not exist yet (a day's daily note) opens blank when missing.
        let allowMissing = service.noteHeaders?.headers(for: viewContext.resource).contains(where: \.createsOnEdit) ?? false
        let tab = EditorTab(store: service.documents, viewContext: viewContext, allowMissing: allowMissing)
        // The same editor shows the new note. What the old tab had not yet saved of the caret is dropped: its
        // context is gone, and saving it would write into the tab's new note.
        tab.controller = current?.controller
        current = tab
        return tab
    }
}

/// The view of one Markdown tab.
struct MarkdownTabView: View {
    let viewContext: ViewContext
    let service: MarkdownEditorService
    @State private var holder = EditorTabHolder()

    var body: some View {
        let tab = holder.tab(for: viewContext, service: service)
        if let document = tab.document {
            VStack(spacing: 0) {
                // The bands other plugins put above this note, such as the week above a daily note, and under its
                // title, such as a collection entry's fields.
                let all = service.noteHeaders?.headers(for: viewContext.resource) ?? []
                let headers = all.filter { $0.placement == .aboveNote }
                let underTitle = all.filter { $0.placement == .underTitle }
                ForEach(headers) { header in
                    header.makeView(viewContext)
                }
                // A band above the note (a daily note's week) carries its own title.
                DocumentEditorView(
                    document: document, tab: tab, viewContext: viewContext, service: service, showsTitle: headers.isEmpty,
                    underTitle: underTitle
                )
            }
        } else {
            ContentUnavailableView(
                "Cannot read this note", symbol: "doc.questionmark",
                description: Text(viewContext.resource.path)
            )
        }
    }
}

/// The editor on a document. Several tabs on one note share the document; each editor keeps its own
/// `EditorContent` and refreshes only for changes it did not type itself, so typing never round-trips.
private struct DocumentEditorView: View {
    let document: Document
    let tab: EditorTab
    let viewContext: ViewContext
    let service: MarkdownEditorService
    let showsTitle: Bool
    let underTitle: [NoteHeader]
    /// What the editor is given to show, for the note it shows (`ShownNote`).
    @State private var shown = ShownNote()
    /// Bumped when the shown text is replaced by a change from outside, to draw it.
    @State private var reloads = 0
    /// How far the glass at the top and bottom edge has come in (`Motion.EdgeGlass`), following the scroll.
    @State private var glass = (top: 0.0, bottom: 0.0)
    /// What other plugins' page overlays see of this page, made once the editor is ready.
    @State private var page: PageContext?
    @Environment(\.themeTokens) private var tokens
    @Environment(\.pageChromeInset) private var chromeInset

    init(
        document: Document, tab: EditorTab, viewContext: ViewContext, service: MarkdownEditorService, showsTitle: Bool,
        underTitle: [NoteHeader]
    ) {
        self.document = document
        self.underTitle = underTitle
        self.tab = tab
        self.viewContext = viewContext
        self.service = service
        self.showsTitle = showsTitle
    }

    /// The note's name, its file name without `.md`.
    private var title: String {
        ((document.path as NSString).lastPathComponent as NSString).deletingPathExtension
    }

    var body: some View {
        let content = shown.content(for: document, in: viewContext)
        let _ = reloads
        // Up under the page's toolbar, so the text scrolls under its glass; the text starts below it. Under a band
        // (a daily note's week) the editor is not at the top, and stays below it.
        if showsTitle {
            editor(content, chromeInset: chromeInset).ignoresSafeArea(.container, edges: .top)
        } else {
            editor(content, chromeInset: 0)
        }
    }

    private func editor(_ content: EditorContent, chromeInset: CGFloat) -> some View {
        MarkdownEditorView(
            content: content,
            theme: MarkdownTheme(tokens: tokens),
            slashItems: service.menuItems,
            mentionItems: { [path = document.path] query in service.mentionItems(query, from: path) },
            linkItems: { [path = document.path] query in service.linkItems(query, from: path) },
            pictureRenderers: service.pictureRenderers,
            embeds: service.embedProvider(for: document.path),
            onDropFiles: service.fileDrop(for: document.path),
            onLostDrop: { [path = document.path] markdown in service.append(markdown, toNoteAt: path) },
            liveBlocks: service.liveBlocks(notePath: document.path, tokens: tokens),
            onChange: { text in document.edit(text, from: tab.editorID) },
            onOpenLink: { destination, modifiers in
                service.openLink(destination, from: document.path, beside: modifiers.contains(.option))
            },
            onOpenDate: service.canOpenDays ? { day, modifiers in
                service.openDay(day, newTab: modifiers.contains(.command))
            } : nil,
            onViewStateChange: { [path = document.path] state in
                tab.record(state)
                service.noteSelection(path, tab.controller?.selectedText)
            },
            title: showsTitle ? title : nil,
            onRenameTitle: { name in service.rename(document.path, to: name) },
            onTitleHiddenChange: { hidden in
                viewContext.toolbarTitle = hidden ? ToolbarTitle(title: title) : nil
            },
            onViewerChange: { close in viewContext.back = close },
            titleAccessory: titleAccessory,
            chromeInset: chromeInset,
            onReady: { controller in ready(controller) }
        )
        // The text scrolls under the toolbar, so the glass at the top reaches past it and the toolbar's own (which
        // shows from the start) is its first part; under a band (a daily note's week) it is the editor's own edge.
        .overlay(alignment: .top) {
            EdgeGlassBand(
                edge: .top, progress: glass.top,
                length: showsTitle ? chromeInset + Motion.EdgeGlass.length / 2 : Motion.EdgeGlass.length,
                tint: tokens.background
            )
        }
        .overlay(alignment: .bottom) {
            EdgeGlassBand(edge: .bottom, progress: glass.bottom, tint: tokens.background)
        }
        .overlay {
            if let page {
                ZStack {
                    ForEach(service.pageOverlays) { overlay in PageOverlayHost(overlay: overlay, page: page) }
                }
            }
        }
        .overlay(alignment: .bottom) {
            if let message = statusMessage {
                Text(message.uiLocalized)
                    .font(.ui(.label))
                    .padding(8)
                    .background(.regularMaterial, in: .rect(cornerRadius: Corners.r(8)))
                    .padding()
            }
        }
        .task {
            // After a turn of the run loop, so the text view is in its window and can take the focus.
            await Task.yield()
            if viewContext.isActive { becomeActive() }
        }
        .onDisappear {
            tab.commit()
            service.resign(tab.controller)
        }
        .onChange(of: viewContext.isActive) {
            if viewContext.isActive {
                becomeActive()
            } else {
                tab.commit()
                service.resign(tab.controller)
            }
        }
        // A `[[Note#Heading]]` link scrolls the page to that heading: for each note the tab shows, once its editor is
        // there and its text laid out.
        .task(id: document.path) {
            for _ in 0..<100 where tab.controller == nil { try? await Task.sleep(for: .milliseconds(20)) }
            let document = document
            service.registerHeadingScroller(document.path) { [weak tab] heading in
                guard let line = NoteLinks.line(ofHeading: heading, in: document.text) else { return false }
                // Once now, and again once the components above it (tables, pictures) have their height.
                for delay in [0.15, 0.6] {
                    DispatchQueue.main.asyncAfter(deadline: .now() + delay) { tab?.controller?.scroll(toLine: line) }
                }
                return true
            }
        }
        // Overlays follow the text when typing pauses, as `DocumentTextChanged` does.
        .task(id: PageTextKey(document: ObjectIdentifier(document), revision: document.revision)) {
            guard let page else { return }
            if page.notePath != document.path { page.update(notePath: document.path, text: document.text); return }
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            page.update(notePath: document.path, text: document.text)
        }
        .onChange(of: document.revision) {
            if shown.isShowing(document), document.revision != shown.revision, document.lastEditor != tab.editorID {
                reload()
            }
        }
        // Another note in the same editor (a link or a sidebar row): it takes the keyboard as a new page would.
        .onChange(of: ObjectIdentifier(document)) {
            if viewContext.isActive { becomeActive() }
        }
    }

    /// The views under the title, in the editor's own hosting view, which does not inherit this one's environment.
    private var titleAccessory: AnyView? {
        guard showsTitle, !underTitle.isEmpty else { return nil }
        return AnyView(
            VStack(alignment: .leading, spacing: 8) {
                ForEach(underTitle) { header in header.makeView(viewContext) }
            }
            .environment(\.themeTokens, tokens)
        )
    }

    private var statusMessage: String? {
        if document.isClosed { return "This note was deleted." }
        return document.errorMessage
    }

    private func ready(_ controller: EditorController) {
        tab.controller = controller
        let page = self.page ?? PageContext(
            notePath: document.path, text: document.text,
            linesY: { [weak tab] lines in tab?.controller?.ys(ofLines: lines) ?? lines.map { _ in nil } },
            scrollToLine: { [weak tab] line in tab?.controller?.scroll(toLine: line) }
        )
        // Called while the editor's view is being made, when SwiftUI ignores state changes: set on the next turn.
        if self.page == nil { Task { @MainActor in self.page = page } }
        controller.onScrollEdges = { [weak controller] edges in
            glass = (Motion.EdgeGlass.steppedProgress(distance: edges.top), Motion.EdgeGlass.steppedProgress(distance: edges.bottom))
            guard let viewport = controller?.viewport else { return }
            page.update(
                scroll: PageScroll(
                    offset: edges.top, visibleHeight: viewport.height,
                    contentHeight: edges.top + viewport.height + edges.bottom
                ),
                topInset: viewport.topInset
            )
        }
        if viewContext.isActive { service.activate(controller, document: document) }
    }

    private func becomeActive() {
        service.activate(tab.controller, document: document)
        tab.controller?.focus()
    }

    private func reload() {
        shown.reload(document)
        reloads += 1
    }
}

/// What makes a page's overlays read its text again: another note in the editor, or a new revision of it.
private struct PageTextKey: Equatable {
    let document: ObjectIdentifier
    let revision: Int
}

/// One plugin's overlay on a page, its view built once for the editor's life.
private struct PageOverlayHost: View {
    let overlay: PageOverlay
    let page: PageContext
    @State private var view: AnyView?

    var body: some View {
        Group {
            if let view { view } else { Color.clear.allowsHitTesting(false) }
        }
        .onAppear { if view == nil { view = overlay.makeView(page) } }
    }
}

/// The note an editor shows and what it was given for it: a new note (the tab followed a link) gets new content
/// with the next id, which the editor shows as another note; a change from outside replaces the text in place.
@MainActor
final class ShownNote {
    private weak var document: Document?
    private var content: EditorContent?
    /// The note's revision when its text was last given to the editor.
    private(set) var revision = 0

    func isShowing(_ document: Document) -> Bool { self.document === document }

    func content(for document: Document, in viewContext: ViewContext) -> EditorContent {
        if let content, self.document === document { return content }
        let saved = viewContext.state(EditorTabState.self)
        let initial = saved.map { EditorViewState(caret: $0.caret, scrollY: $0.scrollY, folded: $0.folded) }
        let new = EditorContent(id: (content?.id ?? 0) + 1, text: document.text, initialState: initial)
        self.document = document
        content = new
        revision = document.revision
        return new
    }

    func reload(_ document: Document) {
        content = EditorContent(id: (content?.id ?? 0) + 1, text: document.text, keepsSelection: true)
        self.document = document
        revision = document.revision
    }
}
