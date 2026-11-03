import AppKit
import CanvasPlugin
import PluginKitUI
import SwiftUI
import WebKit

/// A card showing a file through the view meant for it, live: a header with the file's name, then the view in the
/// `.embedded` presentation. That is a note with its own view (a mindmap, a Kanban board) or a PDF, a video, a sound.
/// Until the card is entered (double-click) or, for media, selected, the view only shows and the card moves like
/// any other; then the view takes clicks, keys and scrolling.
struct BoardEmbedCard: View {
    let model: BoardModel
    let node: CanvasNode
    let type: ViewType
    let context: ViewContext
    /// The view answers clicks.
    let isActive: Bool
    /// The card was entered with a double-click: the keyboard is the view's too.
    let isLive: Bool
    /// 1 when the card is laid out in board units and scaled as a whole; the zoom when it is laid out as shown.
    var scale: CGFloat = 1
    @Environment(\.themeTokens) private var theme

    var body: some View {
        let tint = BoardStyle.color(node.color)
        if type.sizesToContent {
            // As big as its content: the view alone, nothing round it.
            type.makeView(context)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .allowsHitTesting(isActive)
        } else {
            VStack(spacing: 0) {
                HStack(spacing: 8 * scale) {
                    Image(symbol: type.symbol ?? "doc.text")
                        .font(.ui(size: 15 * scale))
                        .foregroundStyle(tint ?? theme.secondaryText)
                    Text(CardFile.title(of: node.file ?? ""))
                        .font(.ui(size: 15 * scale, weight: .semibold))
                        .foregroundStyle(theme.text)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    if isLive {
                        Text("Click the board to leave")
                            .font(.ui(size: 12))
                            .foregroundStyle(theme.secondaryText)
                    }
                }
                .padding(.horizontal, 14 * scale)
                .frame(height: 40 * scale)
                Rectangle().fill(theme.text.opacity(0.07)).frame(height: 1)
                type.makeView(context)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .allowsHitTesting(isActive)
                    .clipped()
            }
        }
    }
}

/// A web address: a rich preview of it (`BoardRichLink`), and a double-click plays the video or browses the page in the
/// card itself.
struct BoardLinkCard: View {
    let model: BoardModel
    let node: CanvasNode
    let isActive: Bool
    @Environment(\.themeTokens) private var theme

    private var url: URL? { node.url.flatMap(URL.init(string:)) }

    var body: some View {
        if isActive, let url {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Image(symbol: "globe").foregroundStyle(theme.secondaryText)
                    Text(url.host() ?? url.absoluteString)
                        .font(.ui(size: 15, weight: .semibold))
                        .foregroundStyle(theme.text)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Text("Click the board to leave")
                        .font(.ui(size: 12))
                        .foregroundStyle(theme.secondaryText)
                }
                .padding(.horizontal, 14)
                .frame(height: 40)
                Rectangle().fill(theme.text.opacity(0.07)).frame(height: 1)
                BoardWebView(url: CanvasLinkKind(url).embedURL(for: url))
            }
        } else if let url {
            BoardRichLink(links: model.store.links, url: url, tint: BoardStyle.color(node.color),
                          interactive: model.selection == [node.id])
                .allowsHitTesting(CanvasLinkKind(url) == .pdf && model.selection == [node.id])
                .onAppear { model.fitLink(node.id) }
                .onChange(of: model.store.links.version) { model.fitLink(node.id) }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Image(symbol: "globe")
                    .font(.ui(size: 26, weight: .light))
                    .foregroundStyle(BoardStyle.color(node.color) ?? theme.accent)
                Text(url?.host() ?? node.url ?? "Link")
                    .font(.ui(size: BoardStyle.titleSize, weight: .bold))
                    .foregroundStyle(theme.text)
                    .lineLimit(2)
                Text(node.url ?? "")
                    .font(.ui(size: 13))
                    .foregroundStyle(theme.link)
                    .lineLimit(3)
                Spacer(minLength: 0)
                Text("Double-click to browse")
                    .font(.ui(size: 12))
                    .foregroundStyle(theme.secondaryText)
            }
            .padding(BoardStyle.textPadding)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }
}

/// A web page in a card, loaded when the card is entered and gone when it is left.
struct BoardWebView: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> WKWebView {
        let view = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        view.load(URLRequest(url: url))
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        if view.url == nil || view.url?.host != url.host { view.load(URLRequest(url: url)) }
    }
}

/// A board drawn small on a card: its groups, cards and arrows as shapes, scaled to fit.
struct BoardThumbnail: View {
    let document: CanvasDocument?
    @Environment(\.themeTokens) private var theme

    var body: some View {
        let text = theme.text, secondary = theme.secondaryText
        Canvas { context, size in
            guard let document, let bounds = CanvasRect.bounds(document.nodes.map(\.frame)), bounds.width > 0,
                  bounds.height > 0 else { return }
            let scale = min(size.width / bounds.width, size.height / bounds.height)
            let dx = (size.width - bounds.width * scale) / 2 - bounds.x * scale
            let dy = (size.height - bounds.height * scale) / 2 - bounds.y * scale
            func rect(_ frame: CanvasRect) -> CGRect {
                CGRect(x: frame.x * scale + dx, y: frame.y * scale + dy, width: frame.width * scale,
                       height: frame.height * scale)
            }
            for node in document.nodes where node.kind == .group {
                let color = BoardStyle.color(node.color) ?? secondary
                context.fill(Path(roundedRect: rect(node.frame), cornerRadius: Corners.r(4)), with: .color(color.opacity(0.08)))
                context.stroke(Path(roundedRect: rect(node.frame), cornerRadius: Corners.r(4)), with: .color(color.opacity(0.3)),
                               lineWidth: 0.5)
            }
            for edge in document.edges {
                guard let curve = CanvasGeometry.curve(of: edge, in: document) else { continue }
                var path = Path()
                path.move(to: CGPoint(x: curve.start.x * scale + dx, y: curve.start.y * scale + dy))
                path.addLine(to: CGPoint(x: curve.end.x * scale + dx, y: curve.end.y * scale + dy))
                context.stroke(path, with: .color(secondary.opacity(0.5)), lineWidth: 0.75)
            }
            for node in document.nodes where node.kind != .group {
                let color = BoardStyle.color(node.color)
                let shape = Path(roundedRect: rect(node.frame), cornerRadius: Corners.r(max(1, 6 * scale)))
                context.fill(shape, with: .color(color?.opacity(0.35) ?? text.opacity(0.08)))
                context.stroke(shape, with: .color(color ?? text.opacity(0.25)), lineWidth: 0.5)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
