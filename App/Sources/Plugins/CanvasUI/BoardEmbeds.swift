import AppKit
import CanvasPlugin
import PDFKit
import PluginKitUI
import SwiftUI
import WebKit

/// The live views over a board's cards: a note with a view of its own (a mindmap, a Kanban board), a PDF, a video,
/// a sound, a web page entered, a PDF link selected. Only the few near the middle of the screen are views
/// (`BoardModel.liveEmbeds`); the others are drawn. Each is laid out in board units and scaled to its card by its
/// container's bounds, so a pan or a zoom moves and scales it without laying it out again. Until it is entered (a
/// double-click) or, for media, selected, it only shows: clicks go to the board.
@MainActor
final class BoardEmbeds {
    private weak var board: BoardCanvasView?
    private var hosts: [String: BoardEmbedContainer] = [:]
    private var theme: ThemeTokens = .standard

    init(board: BoardCanvasView) {
        self.board = board
    }

    func isLive(_ id: String) -> Bool { hosts[id] != nil }

    func themeChanged(_ theme: ThemeTokens) {
        self.theme = theme
        for host in hosts.values { host.themeChanged(theme) }
    }

    /// Makes the views of the cards that should be live and lets the others go. While the camera moves the set is
    /// kept: views are made once it rests.
    func update() {
        guard let board else { return }
        let model = board.model
        var wanted: Set<String> = []
        if model.camera.scale >= BoardModel.farScale {
            let cards = model.visibleNodes().filter { $0.kind != .group }
            if model.isNavigating {
                wanted = Set(hosts.keys).filter { model.node($0) != nil }
            } else {
                wanted = model.liveEmbeds(among: cards)
            }
            if let active = model.activeEmbed { wanted.insert(active) }
            // A selected PDF link scrolls its pages; an entered link browses its page.
            if model.selection.count == 1, let id = model.selection.first, let node = model.node(id), node.kind == .link,
               let url = node.url.flatMap(URL.init(string:)), CanvasLinkKind(url) == .pdf, model.store.links.pdf(url) != nil {
                wanted.insert(id)
            }
        }
        var changed = false
        for (id, host) in hosts where !wanted.contains(id) || host.kind != kind(id) {
            host.removeFromSuperview()
            hosts[id] = nil
            changed = true
        }
        for id in wanted where hosts[id] == nil {
            guard let node = model.node(id), let kind = kind(id),
                  let host = BoardEmbedContainer(model: model, node: node, kind: kind, theme: theme) else { continue }
            board.embedsView.addSubview(host)
            hosts[id] = host
            changed = true
        }
        for (id, host) in hosts {
            host.isInteractive = model.activeEmbed == id || (model.selection == [id] && host.answersWhenSelected)
        }
        place()
        if changed { board.renderItems(settled: true) }
    }

    private func kind(_ id: String) -> BoardEmbedContainer.Kind? {
        guard let model = board?.model, let node = model.node(id) else { return nil }
        if node.kind == .link {
            guard let url = node.url.flatMap(URL.init(string:)) else { return nil }
            if model.activeEmbed == id { return .web(url) }
            if CanvasLinkKind(url) == .pdf { return .pdf(url) }
            return nil
        }
        guard let file = node.file else { return nil }
        if let type = model.store.embeddedViewType(for: file) { return .view(type.id, media: false) }
        if let type = model.store.mediaViewType(for: file) { return .view(type.id, media: true) }
        return nil
    }

    /// Puts each view over its card, as the camera shows it.
    func place() {
        guard let board else { return }
        for (id, host) in hosts {
            guard let node = board.model.node(id) else { continue }
            host.place(board.model.frame(of: node), camera: board.model.camera)
        }
    }
}

/// One live view over its card, scaled from board units to the screen by its bounds.
@MainActor
final class BoardEmbedContainer: NSView {
    enum Kind: Equatable {
        /// A plugin's view type for the file (`media`: a PDF, a video or a sound, which answers once selected).
        case view(String, media: Bool)
        case web(URL)
        case pdf(URL)
    }

    let kind: Kind
    private let content: NSView
    private let bare: Bool
    private let header: CGFloat
    private var follow: Follow<CGRect?>?
    /// A map's content, at its own size: drawn scaled to its card.
    private var natural: CGSize?
    var isInteractive = false
    var answersWhenSelected: Bool {
        switch kind {
        case .view(_, let media): return media
        case .pdf: return true
        case .web: return false
        }
    }

    init?(model: BoardModel, node: CanvasNode, kind: Kind, theme: ThemeTokens) {
        self.kind = kind
        switch kind {
        case .view:
            guard let file = node.file, let type = model.store.embeddedViewType(for: file) ?? model.store.mediaViewType(for: file),
                  let context = model.embedContext(for: node) else { return nil }
            bare = type.sizesToContent
            if let make = type.makeNSView {
                content = make(context)
                (content as? NativeHostedView)?.hostEnvironmentChanged(NativeViewEnvironment(theme: theme))
            } else {
                let host = NSHostingView(rootView: AnyView(type.makeView(context).environment(\.themeTokens, theme)))
                host.sizingOptions = []
                host.safeAreaRegions = []
                content = host
            }
            header = bare ? 0 : 41
            super.init(frame: .zero)
            if bare {
                let id = node.id
                follow = Follow({ [weak context] in context?.contentBounds }) { [weak model, weak self] bounds in
                    if let size = bounds?.size, size.width > 0, size.height > 0 { self?.natural = size }
                    model?.embedContentChanged(id, bounds: bounds)
                }
            }
        case .web(let url):
            let web = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
            web.load(URLRequest(url: CanvasLinkKind(url).embedURL(for: url)))
            content = web
            bare = false
            header = 41
            super.init(frame: .zero)
        case .pdf(let url):
            guard let document = model.store.links.pdf(url) else { return nil }
            let pdf = PDFView()
            pdf.document = document
            pdf.autoScales = true
            pdf.displayMode = .singlePageContinuous
            pdf.displaysPageBreaks = true
            pdf.backgroundColor = .clear
            content = pdf
            bare = false
            header = 0
            super.init(frame: .zero)
        }
        wantsLayer = true
        layer?.masksToBounds = true
        addSubview(content)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        isInteractive ? super.hitTest(point) : nil
    }

    func themeChanged(_ theme: ThemeTokens) {
        (content as? NativeHostedView)?.hostEnvironmentChanged(NativeViewEnvironment(theme: theme))
        if let host = content as? NSHostingView<AnyView>, case .view = kind {
            _ = host
        }
    }

    /// Over its card: the frame on screen, the bounds the card's size in board units (a map: its content's own),
    /// so the view is laid out once and scaled.
    func place(_ frame: CanvasRect, camera: CanvasCamera) {
        let screen = camera.screenRect(CGRect(frame))
        let media: Bool
        if case .view(_, let isMedia) = kind { media = isMedia } else { media = false }
        if self.frame != screen { self.frame = screen }
        // PDF, video and sound views are AppKit's: laid out at the size they are shown at.
        let size = media || {
            if case .pdf = kind { return true }
            return false
        }() ? screen.size : bare ? natural ?? CGSize(width: frame.width, height: frame.height) : CGSize(width: frame.width, height: frame.height)
        if bounds.size != size { setBoundsSize(size) }
        let top = media ? header * camera.scale : header
        let contentFrame = CGRect(x: 0, y: top, width: size.width, height: max(0, size.height - top))
        if content.frame != contentFrame { content.frame = contentFrame }
    }
}
