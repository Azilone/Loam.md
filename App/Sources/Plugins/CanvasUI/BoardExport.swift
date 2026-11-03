import AppKit
import CanvasPlugin
import PDFKit
import PluginKitUI
import SwiftUI
import UniformTypeIdentifiers

/// A board as a picture or a PDF: the whole board, the selection, or its slides one page each. The cards are drawn
/// flat (no glass), at 100 %, in an offscreen window (`ImageRenderer` cannot draw the AppKit views some cards hold),
/// at twice their size; a PDF's pages are those pictures (AppKit's PDF drawing leaves SwiftUI's layers out).
@MainActor
enum BoardExport {
    enum Format: String {
        case png, pdf
    }

    /// The room left round the cards.
    static let margin = 48.0
    /// A picture is drawn at twice its size, less when that would pass this many pixels a side.
    static let maxPixels = 12_000.0

    /// What a menu exports: the selection if there is one, else the whole board.
    static func area(of model: BoardModel) -> CanvasRect? {
        let nodes = model.selection.isEmpty ? model.document.nodes : model.document.nodes.filter {
            model.document.expandingGroups(model.selection).contains($0.id)
        }
        return CanvasRect.bounds(nodes.map(\.frame))?.insetBy(-margin)
    }

    /// The board's area `rect` drawn as a page.
    static func page(_ model: BoardModel, _ rect: CanvasRect, theme: ThemeTokens, scheme: ColorScheme) -> NSView {
        let view = BoardExportPage(model: model, rect: rect)
            .environment(\.themeTokens, theme)
            .environment(\.colorScheme, scheme)
        let hosting = NSHostingView(rootView: view)
        hosting.frame = CGRect(x: 0, y: 0, width: rect.width, height: rect.height)
        let window = NSWindow(contentRect: CGRect(x: -20_000, y: -20_000, width: rect.width, height: rect.height),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        hosting.display()
        return hosting
    }

    static func png(_ model: BoardModel, _ rect: CanvasRect, theme: ThemeTokens, scheme: ColorScheme) -> Data? {
        bitmap(model, rect, theme: theme, scheme: scheme)?.representation(using: .png, properties: [:])
    }

    /// The area drawn at twice its size (less for a huge one), its size in points kept.
    static func bitmap(_ model: BoardModel, _ rect: CanvasRect, theme: ThemeTokens, scheme: ColorScheme) -> NSBitmapImageRep? {
        let view = page(model, rect, theme: theme, scheme: scheme)
        defer { view.window?.close() }
        let scale = min(2, maxPixels / max(rect.width, rect.height, 1))
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(rect.width * scale), pixelsHigh: Int(rect.height * scale),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0
        ) else { return nil }
        bitmap.size = view.bounds.size
        view.cacheDisplay(in: view.bounds, to: bitmap)
        return bitmap
    }

    /// One page per area, in order.
    static func pdf(_ model: BoardModel, _ rects: [CanvasRect], theme: ThemeTokens, scheme: ColorScheme) -> Data? {
        let document = PDFDocument()
        for rect in rects {
            guard let bitmap = bitmap(model, rect, theme: theme, scheme: scheme) else { continue }
            let image = NSImage(size: CGSize(width: rect.width, height: rect.height))
            image.addRepresentation(bitmap)
            guard let page = PDFPage(image: image) else { continue }
            document.insert(page, at: document.pageCount)
        }
        return document.pageCount > 0 ? document.dataRepresentation() : nil
    }

    /// The slides, each its frame, in the presentation's order.
    static func slides(of model: BoardModel) -> [CanvasRect] {
        model.document.slides().compactMap { model.node($0)?.frame }
    }

    /// Asks where to save, then writes the export there.
    static func save(_ model: BoardModel, format: Format, slides: Bool, theme: ThemeTokens, scheme: ColorScheme) {
        model.commitEditing()
        let rects = slides ? Self.slides(of: model) : area(of: model).map { [$0] } ?? []
        guard !rects.isEmpty else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [format == .png ? .png : .pdf]
        panel.nameFieldStringValue = model.title + (slides ? " slides" : "") + "." + format.rawValue
        panel.directoryURL = model.store.vault.rootURL.appendingPathComponent((model.path as NSString).deletingLastPathComponent)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let data = format == .png ? png(model, rects[0], theme: theme, scheme: scheme)
            : pdf(model, rects, theme: theme, scheme: scheme)
        try? data?.write(to: url)
    }
}

/// The board's area `rect` as the export draws it: groups and frames, arrows, then the cards in their order.
struct BoardExportPage: View {
    let model: BoardModel
    let rect: CanvasRect
    /// Maps reuse the board's own views (a slide leaving the screen), so their pictures are there at once.
    var reusesLiveViews = false
    @Environment(\.themeTokens) private var theme

    var body: some View {
        let area = CGRect(rect)
        let nodes = model.document.nodes.filter { CGRect($0.frame).intersects(area) }
        let groups = nodes.filter { $0.kind == .group }
        let cards = nodes.filter { $0.kind != .group }
        ZStack(alignment: .topLeading) {
            theme.background
            ForEach(groups, id: \.id) { group($0).offset(x: $0.x - rect.x, y: $0.y - rect.y) }
            edges
            ForEach(cards, id: \.id) { node in
                card(node)
                    .frame(width: node.width, height: node.height, alignment: .topLeading)
                    .offset(x: node.x - rect.x, y: node.y - rect.y)
            }
        }
        .frame(width: rect.width, height: rect.height, alignment: .topLeading)
        .clipped()
    }

    private func group(_ node: CanvasNode) -> some View {
        let tint = BoardStyle.color(node.color) ?? theme.secondaryText
        let isFrame = node.ratio != nil
        let shape = RoundedRectangle(cornerRadius: Corners.r(isFrame ? 10 : BoardStyle.cornerRadius), style: .continuous)
        return ZStack(alignment: .topLeading) {
            shape.fill(isFrame ? AnyShapeStyle(theme.background) : AnyShapeStyle(tint.opacity(0.07)))
            shape.strokeBorder(tint.opacity(0.4), lineWidth: 1.25)
            if let label = node.label, !label.isEmpty, !isFrame || rect.height != node.height {
                Text(label.uiLocalized)
                    .font(.ui(size: BoardStyle.groupLabelSize, weight: .semibold))
                    .foregroundStyle(theme.text)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 3)
                    .background(ThemeCapsule().fill(tint.opacity(0.14)))
                    .offset(y: -BoardStyle.groupLabelSize * 1.5 - 6)
            }
        }
        .frame(width: node.width, height: node.height, alignment: .topLeading)
    }

    private var edges: some View {
        let curves = model.document.edges.compactMap { edge in
            CanvasGeometry.curve(of: edge, in: model.document).map { (edge, $0) }
        }
        let secondary = theme.secondaryText, text = theme.text, background = theme.background
        let origin = CanvasPoint(x: rect.x, y: rect.y)
        return Canvas { context, _ in
            func point(_ p: CanvasPoint) -> CGPoint { CGPoint(x: p.x - origin.x, y: p.y - origin.y) }
            for (edge, curve) in curves {
                let color = BoardStyle.color(edge.color) ?? secondary.opacity(0.7)
                var line = Path()
                line.move(to: point(curve.start))
                line.addCurve(to: point(curve.end), control1: point(curve.control1), control2: point(curve.control2))
                context.stroke(line, with: .color(color), style: StrokeStyle(
                    lineWidth: BoardStyle.edgeWidth, lineCap: .round,
                    dash: edge.isDashed ? [BoardStyle.edgeWidth * 2.6, BoardStyle.edgeWidth * 2.4] : []))
                for (shown, atStart) in [(edge.endsWithArrow, false), (edge.startsWithArrow, true)] where shown {
                    let (left, right) = curve.arrowHead(atStart: atStart, size: BoardStyle.arrowSize)
                    var head = Path()
                    head.move(to: point(atStart ? curve.start : curve.end))
                    head.addLine(to: point(left))
                    head.addLine(to: point(right))
                    head.closeSubpath()
                    context.fill(head, with: .color(color))
                }
                if let label = edge.label, !label.isEmpty {
                    let resolved = context.resolve(Text(label.uiLocalized).font(.ui(size: 13, weight: .medium)).foregroundStyle(text))
                    let size = resolved.measure(in: CGSize(width: 240, height: 80))
                    let center = point(curve.middle)
                    let box = CGRect(x: center.x - size.width / 2 - 8, y: center.y - size.height / 2 - 3.5,
                                     width: size.width + 16, height: size.height + 7)
                    context.fill(Path(roundedRect: box, cornerRadius: Corners.r(box.height / 2)), with: .color(background))
                    context.draw(resolved, in: box.insetBy(dx: 8, dy: 3.5))
                }
            }
        }
        .frame(width: rect.width, height: rect.height)
    }

    @ViewBuilder private func card(_ node: CanvasNode) -> some View {
        let shape = BoardShape(node.kind == .text ? node.shape : nil, radius: node.isSticky ? 4 : BoardStyle.cornerRadius)
        if let ink = model.store.ink(node) {
            BoardInkView(node: node, ink: ink)
        } else if node.isTable, let table = node.table,
                  let layout = model.store.tableLayout(node.text ?? "", fontSize: node.effectiveFontSize) {
            BoardTableView(model: model, node: node, table: table, layout: layout)
        } else if model.isBare(node), let file = node.file, let type = model.store.embeddedViewType(for: file) {
            type.makeView((reusesLiveViews ? model.embedContext(for: node) : nil)
                ?? ViewContext(resource: .file(file), presentation: .embedded))
        } else if node.kind == .link {
            BoardLinkCard(model: model, node: node, isActive: false)
                .modifier(BoardCardSurface(tint: BoardStyle.color(node.color), shape: shape, glass: false, paper: 0.7,
                                           lifted: false))
        } else {
            BoardCardBody(node: node, frame: node.frame, store: model.store, version: model.store.previewVersion)
                .clipShape(shape)
                .modifier(BoardCardSurface(tint: BoardStyle.color(node.color), shape: shape, border: node.border,
                                           glass: false, paper: 1, lifted: false, sticky: node.isSticky))
        }
    }
}
