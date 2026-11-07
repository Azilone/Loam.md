import AppKit
import CanvasPlugin
import PDFKit
import PluginKitUI
import SwiftUI
import UniformTypeIdentifiers

/// A board as a picture or a PDF: the whole board, the selection, or its slides one page each. The cards are drawn
/// as the board draws them (`BoardDrawing`), flat, at 100 %, at twice their size; a PDF's pages are those pictures.
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

    static func png(_ model: BoardModel, _ rect: CanvasRect, theme: ThemeTokens, scheme: ColorScheme) -> Data? {
        bitmap(model, rect, theme: theme, scheme: scheme)?.representation(using: .png, properties: [:])
    }

    /// The area drawn at twice its size (less for a huge one), its size in points kept: the same drawings as the
    /// board's (`BoardDrawing`), flat, at 100 %.
    static func bitmap(_ model: BoardModel, _ rect: CanvasRect, theme: ThemeTokens, scheme: ColorScheme) -> NSBitmapImageRep? {
        let appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua) ?? NSAppearance.currentDrawing()
        let palette = BoardPalette(theme: theme, appearance: appearance)
        let scale = min(2, maxPixels / max(rect.width, rect.height, 1))
        guard let context = CGContext(data: nil, width: Int(rect.width * scale), height: Int(rect.height * scale), bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.translateBy(x: 0, y: rect.height * scale)
        context.scaleBy(x: scale, y: -scale)
        appearance.performAsCurrentDrawingAppearance {
            draw(model, rect, in: context, palette: palette, theme: theme, pixels: scale)
        }
        guard let image = context.makeImage() else { return nil }
        let bitmap = NSBitmapImageRep(cgImage: image)
        bitmap.size = CGSize(width: rect.width, height: rect.height)
        return bitmap
    }

    /// The board's area `rect` in a y-down context in points: groups and frames, arrows, then the cards in their order.
    static func draw(_ model: BoardModel, _ rect: CanvasRect, in context: CGContext, palette: BoardPalette, theme: ThemeTokens,
                     pixels: CGFloat) {
        let area = CGRect(rect)
        context.setFillColor(palette.background.cgColor)
        context.fill(CGRect(origin: .zero, size: area.size))
        context.translateBy(x: -area.minX, y: -area.minY)
        let nodes = model.document.nodes.filter { CGRect($0.frame).intersects(area) }
        for node in nodes where node.kind == .group {
            let frame = CGRect(node.frame)
            let tint = BoardStyle.nsColor(node.color) ?? palette.secondary
            let isFrame = node.ratio != nil
            let radius = Corners.r(isFrame ? 10 : BoardStyle.cornerRadius)
            let path = CGPath(roundedRect: frame.insetBy(dx: 0.625, dy: 0.625), cornerWidth: radius, cornerHeight: radius, transform: nil)
            context.addPath(path)
            context.setFillColor((isFrame ? palette.background : tint.withAlphaComponent(0.07)).cgColor)
            context.fillPath()
            context.addPath(path)
            context.setStrokeColor(tint.withAlphaComponent(0.4).cgColor)
            context.setLineWidth(1.25)
            context.strokePath()
            if let label = node.label, !label.isEmpty, !isFrame || rect.height != node.height {
                let (image, size) = BoardCanvasView.groupLabel(label, number: nil, named: true, size: BoardStyle.groupLabelSize,
                                                               selected: false, tint: tint, palette: palette, pixels: pixels)
                if let image {
                    BoardDrawing.drawImage(image, in: CGRect(x: frame.minX, y: frame.minY - BoardStyle.groupLabelSize * 1.5 - 6
                                                             + (BoardStyle.groupLabelSize * 1.5 - size.height) / 2,
                                                             width: size.width, height: size.height), context: context)
                }
            }
        }
        for edge in model.document.edges {
            guard let curve = CanvasGeometry.curve(of: edge, in: model.document) else { continue }
            let color = BoardStyle.nsColor(edge.color) ?? palette.secondary.withAlphaComponent(0.7)
            context.saveGState()
            context.setStrokeColor(color.cgColor)
            context.setLineWidth(BoardStyle.edgeWidth)
            context.setLineCap(.round)
            if edge.isDashed { context.setLineDash(phase: 0, lengths: [BoardStyle.edgeWidth * 2.6, BoardStyle.edgeWidth * 2.4]) }
            context.addPath(BoardEdgesLayer.path(curve))
            context.strokePath()
            context.restoreGState()
            context.setFillColor(color.cgColor)
            for (shown, atStart) in [(edge.endsWithArrow, false), (edge.startsWithArrow, true)] where shown {
                let (left, right) = curve.arrowHead(atStart: atStart, size: BoardStyle.arrowSize)
                context.move(to: CGPoint(atStart ? curve.start : curve.end))
                context.addLine(to: CGPoint(left))
                context.addLine(to: CGPoint(right))
                context.closePath()
                context.fillPath()
            }
            if let label = edge.label, !label.isEmpty {
                let (image, size) = BoardEdgesLayer.labelImage(label, selected: false, palette: palette, pixels: pixels)
                let middle = CGPoint(curve.middle)
                if let image {
                    BoardDrawing.drawImage(image, in: CGRect(x: middle.x - size.width / 2, y: middle.y - size.height / 2,
                                                             width: size.width, height: size.height), context: context)
                }
            }
        }
        for node in nodes where node.kind != .group {
            context.saveGState()
            context.translateBy(x: node.x, y: node.y)
            if model.isBare(node), let file = node.file, let type = model.store.embeddedViewType(for: file),
               let image = liveImage(type, file: file, size: CGSize(width: node.width, height: node.height), theme: theme,
                                     appearance: NSAppearance.currentDrawing(), pixels: pixels) {
                BoardDrawing.drawImage(image, in: CGRect(x: 0, y: 0, width: node.width, height: node.height), context: context)
            } else {
                let spec = model.spec(of: node, frame: node.frame, mode: .near, scale: 1)
                BoardDrawing.draw(spec, in: context, lineScale: 1, palette: palette, pixelScale: pixels)
            }
            context.restoreGState()
        }
    }

    /// A live view (a mindmap) drawn once, laid out at its card's size in an offscreen window.
    private static func liveImage(_ type: ViewType, file: String, size: CGSize, theme: ThemeTokens, appearance: NSAppearance,
                                  pixels: CGFloat) -> CGImage? {
        let view = type.makeView(ViewContext(resource: .file(file), presentation: .embedded))
            .environment(\.themeTokens, theme)
        let hosting = NSHostingView(rootView: AnyView(view))
        hosting.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: CGRect(x: -20_000, y: -20_000, width: size.width, height: size.height),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = appearance
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        defer { window.close() }
        guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return nil }
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        return bitmap.cgImage
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

