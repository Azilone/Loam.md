import AppKit
import CanvasPlugin
import ImageIO
import PDFKit
import PluginKitUI
import SwiftUI

// How a board's items are drawn: each card, shape, picture, table or drawing into a bitmap in board units, on any
// thread (`BoardItemLayer` shows it; the export draws the same pictures). What a drawing needs is read on the main
// thread into a `BoardItemSpec`; drawing it touches nothing else.

/// The board's colours for one theme and appearance, read on the main thread.
struct BoardPalette: @unchecked Sendable, Equatable {
    let theme: ThemeTokens
    let dark: Bool
    let background: NSColor
    let text: NSColor
    let secondary: NSColor
    let accent: NSColor
    let link: NSColor
    let codeBackground: NSColor
    /// The colour the system draws "primary" in: black, or white in the dark.
    let primary: NSColor

    @MainActor init(theme: ThemeTokens, appearance: NSAppearance) {
        self.theme = theme
        let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        self.dark = dark
        var colors: [NSColor] = []
        appearance.performAsCurrentDrawingAppearance {
            colors = [theme.background, theme.text, theme.secondaryText, theme.accent, theme.link, theme.codeBackground]
                .map { NSColor(cgColor: NSColor($0).cgColor) ?? .gray }
        }
        background = colors[0]
        text = colors[1]
        secondary = colors[2]
        accent = colors[3]
        link = colors[4]
        codeBackground = colors[5]
        primary = dark ? .white : .black
    }

    static func == (lhs: BoardPalette, rhs: BoardPalette) -> Bool {
        lhs.theme == rhs.theme && lhs.dark == rhs.dark
    }

    /// The floor under the cards: a shade apart from their paper.
    var floor: NSColor {
        background.blended(withFraction: 0.03, of: primary) ?? background
    }
}

extension BoardStyle {
    /// `color(_:)` for AppKit drawing.
    static func nsColor(_ value: String?) -> NSColor? {
        guard let value else { return nil }
        let presets: [String: (Double, Double, Double)] = [
            "1": (0.91, 0.29, 0.29), "2": (0.94, 0.55, 0.2), "3": (0.92, 0.75, 0.13),
            "4": (0.27, 0.69, 0.4), "5": (0.2, 0.67, 0.79), "6": (0.6, 0.4, 0.85),
        ]
        if let rgb = presets[value] { return NSColor(srgbRed: rgb.0, green: rgb.1, blue: rgb.2, alpha: 1) }
        let hex = value.hasPrefix("#") ? String(value.dropFirst()) : value
        guard hex.count == 6, let number = UInt32(hex, radix: 16) else { return nil }
        return NSColor(srgbRed: Double((number >> 16) & 0xFF) / 255, green: Double((number >> 8) & 0xFF) / 255,
                       blue: Double(number & 0xFF) / 255, alpha: 1)
    }
}

/// Everything a card's drawing needs, read on the main thread: what it is and what it shows.
struct BoardItemSpec: @unchecked Sendable {
    enum Content {
        /// A text card or shape: its Markdown at its size, in the part of its shape text goes in.
        case text(NotePreview, fontSize: CGFloat, align: CanvasTextAlign, centred: Bool, free: Bool, overflows: Bool)
        case note(title: String, preview: NotePreview?)
        case image(URL)
        case missing(title: String, path: String)
        case file(symbol: String, title: String)
        case board(title: String, thumbnail: CanvasDocument?)
        case table(CanvasTable, BoardTableLayout, fontSize: CGFloat)
        case ink(CanvasInk, natural: CGSize)
        case link(BoardLinkSpec)
        /// A live view covers it (a mindmap, a PDF, a video): only its header, the view draws the rest.
        case live(title: String, symbol: String, bare: Bool)
        /// The text is being written in an editor over the card.
        case editing
        /// Far out: a tinted sheet with its title, as small as it is drawn.
        case far(FarSpec)
    }

    struct FarSpec {
        var title: String
        var picture: URL?
        var table: Bool
        var ink: CanvasInk?
        var natural: CGSize
        var textSize: CGFloat?
        var textBold: Bool
        var centred: Bool
    }

    var content: Content
    var size: CGSize
    var shape: CanvasNodeShape?
    var radius: CGFloat
    var tint: NSColor?
    var border: CanvasBorder?
    /// No paper or edge: free text, a map drawn at its own size, a drawing.
    var invisible: Bool
    var sticky: Bool
    var paper: Double

    var boardShape: BoardShape { BoardShape(shape, radius: radius) }

    /// Whether drawing it decodes a picture from the disk: done in the background, never while a frame waits.
    var decodesPicture: Bool {
        switch content {
        case .image: return true
        case .far(let far): return far.picture != nil
        default: return false
        }
    }
}

/// What a link card shows, its pictures read.
struct BoardLinkSpec {
    let url: URL
    let kind: CanvasLinkKind
    let preview: CanvasLinkPreview?
    let picture: CGImage?
    let icon: CGImage?
    let pdfPage: CGImage?
}

enum BoardDrawing {
    /// Draws `spec` in a context in board units (y down), the card's top-left at the origin. `lineScale` turns the
    /// screen points of edges and rings into board units (1 / the zoom it is drawn for).
    static func draw(_ spec: BoardItemSpec, in context: CGContext, lineScale: CGFloat, palette: BoardPalette,
                     pixelScale: CGFloat) {
        let rect = CGRect(origin: .zero, size: spec.size)
        let path = spec.boardShape.path(in: rect).cgPath
        if case .ink(let ink, let natural) = spec.content {
            drawInk(ink, natural: natural, in: rect.size, context: context, text: palette.text)
            return
        }
        if case .far(let far) = spec.content {
            drawFar(far, spec: spec, rect: rect, path: path, context: context, lineScale: lineScale, palette: palette)
            return
        }
        drawPaper(spec, path: path, context: context, palette: palette)
        context.saveGState()
        context.addPath(path)
        context.clip()
        drawContent(spec, rect: rect, context: context, palette: palette, pixelScale: pixelScale)
        context.restoreGState()
        drawEdge(spec, rect: rect, context: context, lineScale: lineScale, palette: palette)
    }

    // MARK: Surface

    static func drawPaper(_ spec: BoardItemSpec, path: CGPath, context: CGContext, palette: BoardPalette) {
        if spec.sticky {
            context.addPath(path)
            context.setFillColor(palette.background.cgColor)
            context.fillPath()
            let tint = spec.tint ?? BoardStyle.nsColor("3")!
            context.addPath(path)
            context.setFillColor(tint.withAlphaComponent(palette.dark ? 0.5 : 0.78).cgColor)
            context.fillPath()
            return
        }
        guard !spec.invisible else { return }
        context.addPath(path)
        context.setFillColor(palette.background.cgColor)
        context.fillPath()
        if let tint = spec.tint {
            context.addPath(path)
            context.setFillColor(tint.withAlphaComponent(palette.dark ? 0.2 : 0.12).cgColor)
            context.fillPath()
        }
    }

    /// The hairline round a card, at the same width on screen whatever the zoom.
    static func drawEdge(_ spec: BoardItemSpec, rect: CGRect, context: CGContext, lineScale: CGFloat,
                         palette: BoardPalette) {
        guard !spec.invisible, !spec.sticky else { return }
        let width = (spec.tint == nil ? (spec.border == nil ? 1 : 1.5) : 1.75) * lineScale
        let line = spec.tint?.withAlphaComponent(0.8)
            ?? palette.primary.withAlphaComponent(palette.dark ? 0.2 : spec.border == nil ? 0.14 : 0.35)
        let inset = spec.boardShape.inset(by: width / 2)
        context.saveGState()
        context.setStrokeColor(line.cgColor)
        context.setLineWidth(width)
        context.setLineCap(.round)
        let dash = spec.border?.dash(width) ?? []
        if !dash.isEmpty { context.setLineDash(phase: 0, lengths: dash) }
        context.addPath(inset.path(in: rect).cgPath)
        if inset.hasDetails { context.addPath(inset.details(in: rect).cgPath) }
        context.strokePath()
        context.restoreGState()
    }

    // MARK: Content

    private static func drawContent(_ spec: BoardItemSpec, rect: CGRect, context: CGContext, palette: BoardPalette,
                                    pixelScale: CGFloat) {
        switch spec.content {
        case .text(let preview, let fontSize, let align, let centred, let free, let overflows):
            let inner = CGRect((spec.shape ?? .rectangle).textRect(in: CanvasRect(rect)))
            let padding = free ? BoardStyle.freeTextPadding : BoardStyle.textPadding
            let box = inner.insetBy(dx: padding, dy: padding)
            let text = BoardTextLayout.attributed(preview, size: fontSize, align: align, palette: palette)
            var drawn = box
            if centred {
                let height = BoardTextLayout.height(text, width: box.width)
                if height < box.height { drawn.origin.y += (box.height - height) / 2 }
            }
            fading(overflows, in: rect, context: context, from: 0.82) {
                BoardTextLayout.draw(text, in: drawn, context: context)
            }
        case .note(let title, let preview):
            let padding = BoardStyle.textPadding
            let width = rect.width - padding * 2
            fading(true, in: rect, context: context, from: 0.86) {
                let heading = NSAttributedString(string: title, attributes: [
                    .font: NSFont.ui(size: BoardStyle.titleSize, weight: .bold), .foregroundColor: palette.text,
                    .paragraphStyle: BoardTextLayout.paragraph(lineBreak: .byTruncatingTail),
                ])
                let titleHeight = min(BoardTextLayout.height(heading, width: width),
                                      ceil(NSFont.ui(size: BoardStyle.titleSize, weight: .bold).boundingRectForFont.height * 2))
                BoardTextLayout.draw(heading, in: CGRect(x: padding, y: padding, width: width, height: titleHeight + 2),
                                     context: context)
                guard let preview, !preview.blocks.isEmpty else { return }
                let line = padding + titleHeight + 10
                context.setFillColor(palette.text.withAlphaComponent(0.08).cgColor)
                context.fill(CGRect(x: padding, y: line, width: width, height: 1))
                let body = BoardTextLayout.attributed(preview, size: 15, align: .left, palette: palette)
                BoardTextLayout.draw(body, in: CGRect(x: padding, y: line + 11, width: width,
                                                      height: max(0, rect.height - line - 11)), context: context)
            }
        case .image(let url):
            let pixels = max(rect.width, rect.height) * pixelScale
            guard let image = BoardImages.image(url, maxPixels: pixels) else {
                drawMissing(title: url.lastPathComponent, path: "", rect: rect, context: context, palette: palette)
                return
            }
            drawFilling(image, in: rect, context: context)
        case .missing(let title, let path):
            drawMissing(title: title, path: path, rect: rect, context: context, palette: palette)
        case .file(let symbol, let title):
            drawFileIcon(symbol: symbol, title: title, rect: rect, context: context, palette: palette)
        case .board(let title, let thumbnail):
            let padding = BoardStyle.textPadding
            let font = NSFont.ui(size: BoardStyle.titleSize, weight: .bold)
            let icon = tintedSymbol(CanvasUIPlugin.symbol, size: BoardStyle.titleSize * 0.85, weight: .bold, color: palette.text)
            var x = padding
            if let icon {
                drawSymbol(icon, at: CGPoint(x: x, y: padding + (font.ascender - font.capHeight) / 2), context: context)
                x += icon.size.width + 8
            }
            let heading = NSAttributedString(string: title, attributes: [
                .font: font, .foregroundColor: palette.text,
                .paragraphStyle: BoardTextLayout.paragraph(lineBreak: .byTruncatingTail),
            ])
            let lineHeight = ceil(font.ascender - font.descender + font.leading)
            BoardTextLayout.draw(heading, in: CGRect(x: x, y: padding, width: rect.width - x - padding, height: lineHeight + 2),
                                 context: context, maxLines: 1)
            let top = padding * 2 + lineHeight
            drawThumbnail(thumbnail, in: CGRect(x: padding, y: top, width: rect.width - padding * 2,
                                                height: max(0, rect.height - top - padding)), context: context, palette: palette)
        case .table(let table, let layout, let fontSize):
            drawTable(table, layout: layout, fontSize: fontSize, tint: spec.tint, size: rect.size, context: context,
                      palette: palette)
        case .link(let link):
            BoardLinkDrawing.draw(link, tint: spec.tint, rect: rect, context: context, palette: palette)
        case .live(let title, let symbol, let bare):
            guard !bare else { return }
            drawLiveHeader(title: title, symbol: symbol, tint: spec.tint, width: rect.width, context: context, palette: palette)
        case .editing, .ink, .far:
            break
        }
    }

    /// Draws `body`, faded out over the bottom of `rect` from `from` (0-1 of its height) when `fades`.
    private static func fading(_ fades: Bool, in rect: CGRect, context: CGContext, from: CGFloat, _ body: () -> Void) {
        guard fades else { return body() }
        context.saveGState()
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        body()
        let colors = [CGColor(gray: 0, alpha: 0), CGColor(gray: 0, alpha: 1)] as CFArray
        if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceGray(), colors: colors, locations: [0, 1]) {
            context.setBlendMode(.destinationOut)
            context.clip(to: CGRect(x: rect.minX, y: rect.minY + rect.height * from, width: rect.width,
                                    height: rect.height * (1 - from)))
            context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: rect.minY + rect.height * from),
                                       end: CGPoint(x: 0, y: rect.maxY), options: [.drawsAfterEndLocation])
        }
        context.endTransparencyLayer()
        context.restoreGState()
    }

    /// A picture filling `rect`, cut to it, as `scaledToFill` does.
    static func drawFilling(_ image: CGImage, in rect: CGRect, context: CGContext) {
        let ratio = CGFloat(image.width) / max(CGFloat(image.height), 1)
        var drawn = rect
        if rect.width / max(rect.height, 1) > ratio {
            drawn.size.height = rect.width / ratio
            drawn.origin.y = rect.midY - drawn.height / 2
        } else {
            drawn.size.width = rect.height * ratio
            drawn.origin.x = rect.midX - drawn.width / 2
        }
        drawImage(image, in: drawn, context: context)
    }

    /// A picture in a y-down context, upright.
    static func drawImage(_ image: CGImage, in rect: CGRect, context: CGContext) {
        context.saveGState()
        context.interpolationQuality = .high
        context.translateBy(x: rect.minX, y: rect.maxY)
        context.scaleBy(x: 1, y: -1)
        context.draw(image, in: CGRect(origin: .zero, size: rect.size))
        context.restoreGState()
    }

    static func drawSymbol(_ image: NSImage, at point: CGPoint, context: CGContext) {
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        image.draw(in: CGRect(origin: point, size: image.size), from: .zero, operation: .sourceOver, fraction: 1,
                   respectFlipped: true, hints: nil)
        NSGraphicsContext.restoreGraphicsState()
    }

    private static func drawMissing(title: String, path: String, rect: CGRect, context: CGContext, palette: BoardPalette) {
        let text = NSMutableAttributedString(string: title, attributes: [
            .font: NSFont.ui(size: BoardStyle.titleSize - 2, weight: .semibold), .foregroundColor: palette.secondary,
        ])
        if !path.isEmpty {
            text.append(NSAttributedString(string: "\n" + "Not found: \(path)".uiLocalized, attributes: [
                .font: NSFont.ui(size: 13), .foregroundColor: palette.secondary,
                .paragraphStyle: BoardTextLayout.paragraph(spacingBefore: 6),
            ]))
        }
        BoardTextLayout.draw(text, in: rect.insetBy(dx: 16, dy: 16), context: context)
    }

    private static func drawFileIcon(symbol: String, title: String, rect: CGRect, context: CGContext, palette: BoardPalette) {
        let icon = tintedSymbol(symbol, size: 38, weight: .light, color: palette.secondary)
        let paragraph = BoardTextLayout.paragraph(lineBreak: .byTruncatingTail)
        paragraph.alignment = .center
        let name = NSAttributedString(string: title, attributes: [
            .font: NSFont.ui(size: BoardStyle.titleSize - 2, weight: .semibold), .foregroundColor: palette.text,
            .paragraphStyle: paragraph,
        ])
        let width = rect.width - 32
        let font = NSFont.ui(size: BoardStyle.titleSize - 2, weight: .semibold)
        let nameHeight = min(BoardTextLayout.height(name, width: width), ceil((font.ascender - font.descender + font.leading) * 2))
        let iconSize = icon?.size ?? .zero
        let total = iconSize.height + 10 + nameHeight
        var y = rect.midY - total / 2
        if let icon { drawSymbol(icon, at: CGPoint(x: rect.midX - iconSize.width / 2, y: y), context: context) }
        y += iconSize.height + 10
        BoardTextLayout.draw(name, in: CGRect(x: 16, y: y, width: width, height: nameHeight + 2), context: context, maxLines: 2)
    }

    /// The header of a card showing a live view: the view's symbol and the file's name over a hairline.
    static func drawLiveHeader(title: String, symbol: String, tint: NSColor?, width: CGFloat, context: CGContext,
                               palette: BoardPalette) {
        let font = NSFont.ui(size: 15, weight: .semibold)
        var x: CGFloat = 14
        if let icon = tintedSymbol(symbol, size: 15, color: tint ?? palette.secondary) {
            drawSymbol(icon, at: CGPoint(x: x, y: 20 - icon.size.height / 2), context: context)
            x += icon.size.width + 8
        }
        let name = NSAttributedString(string: title, attributes: [
            .font: font, .foregroundColor: palette.text, .paragraphStyle: BoardTextLayout.paragraph(lineBreak: .byTruncatingTail),
        ])
        let lineHeight = ceil(font.ascender - font.descender)
        BoardTextLayout.draw(name, in: CGRect(x: x, y: 20 - lineHeight / 2 - 1, width: width - x - 14, height: lineHeight + 4),
                             context: context, maxLines: 1)
        context.setFillColor(palette.text.withAlphaComponent(0.07).cgColor)
        context.fill(CGRect(x: 0, y: 40, width: width, height: 1))
    }

    /// A board drawn small: its groups, cards and arrows as shapes, scaled to fit.
    static func drawThumbnail(_ document: CanvasDocument?, in area: CGRect, context: CGContext, palette: BoardPalette) {
        guard let document, let bounds = CanvasRect.bounds(document.nodes.map(\.frame)), bounds.width > 0,
              bounds.height > 0, area.width > 0, area.height > 0 else { return }
        let scale = min(area.width / bounds.width, area.height / bounds.height)
        let dx = area.minX + (area.width - bounds.width * scale) / 2 - bounds.x * scale
        let dy = area.minY + (area.height - bounds.height * scale) / 2 - bounds.y * scale
        func rect(_ frame: CanvasRect) -> CGRect {
            CGRect(x: frame.x * scale + dx, y: frame.y * scale + dy, width: frame.width * scale, height: frame.height * scale)
        }
        for node in document.nodes where node.kind == .group {
            let color = BoardStyle.nsColor(node.color) ?? palette.secondary
            let path = CGPath(roundedRect: rect(node.frame), cornerWidth: 4, cornerHeight: 4, transform: nil)
            context.addPath(path)
            context.setFillColor(color.withAlphaComponent(0.08).cgColor)
            context.fillPath()
            context.addPath(path)
            context.setStrokeColor(color.withAlphaComponent(0.3).cgColor)
            context.setLineWidth(0.5)
            context.strokePath()
        }
        context.setStrokeColor(palette.secondary.withAlphaComponent(0.5).cgColor)
        context.setLineWidth(0.75)
        for edge in document.edges {
            guard let curve = CanvasGeometry.curve(of: edge, in: document) else { continue }
            context.move(to: CGPoint(x: curve.start.x * scale + dx, y: curve.start.y * scale + dy))
            context.addLine(to: CGPoint(x: curve.end.x * scale + dx, y: curve.end.y * scale + dy))
        }
        context.strokePath()
        for node in document.nodes where node.kind != .group {
            let color = BoardStyle.nsColor(node.color)
            let corner = max(1, 6 * scale)
            let r = rect(node.frame)
            let path = CGPath(roundedRect: r, cornerWidth: min(corner, r.width / 2), cornerHeight: min(corner, r.height / 2),
                              transform: nil)
            context.addPath(path)
            context.setFillColor((color?.withAlphaComponent(0.35) ?? palette.text.withAlphaComponent(0.08)).cgColor)
            context.fillPath()
            context.addPath(path)
            context.setStrokeColor((color ?? palette.text.withAlphaComponent(0.25)).cgColor)
            context.setLineWidth(0.5)
            context.strokePath()
        }
    }

    // MARK: Tables

    /// A table: a coloured header (the card's colour, else the accent) over plain rows, hairlines between the cells.
    static func drawTable(_ table: CanvasTable, layout: BoardTableLayout, fontSize size: CGFloat, tint: NSColor?,
                          size frame: CGSize, context: CGContext, palette: BoardPalette, skipping: (row: Int, column: Int)? = nil) {
        let natural = layout.size
        context.saveGState()
        // A table being resized grows as a picture would.
        context.scaleBy(x: frame.width / max(natural.width, 1), y: frame.height / max(natural.height, 1))
        let bounds = CGRect(origin: .zero, size: natural)
        let shape = CGPath(roundedRect: bounds, cornerWidth: Corners.r(size * 0.4), cornerHeight: Corners.r(size * 0.4), transform: nil)
        context.addPath(shape)
        context.clip()
        context.setFillColor(palette.background.cgColor)
        context.fill(bounds)
        context.setFillColor((tint ?? palette.accent).cgColor)
        context.fill(CGRect(x: 0, y: 0, width: natural.width, height: layout.rows.first ?? 0))
        let padding = size * BoardTableLayout.padding.horizontal
        for row in 0..<table.rowCount {
            for column in 0..<table.columnCount where skipping.map({ $0 != (row, column) }) ?? true {
                let cell = layout.rect(row: row, column: column)
                let font = NSFont.ui(size: size, weight: row == 0 ? .semibold : .regular)
                let paragraph = BoardTextLayout.paragraph()
                paragraph.alignment = switch table.alignments[column] {
                case .center: .center
                case .right: .right
                case .left, .none: .left
                }
                let text = NotePreviewText.inline(table[row, column], font: font, color: row == 0 ? .white : palette.text,
                                                  theme: palette.theme)
                text.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: text.length))
                let box = cell.insetBy(dx: padding, dy: 0)
                let height = BoardTextLayout.height(text, width: box.width)
                BoardTextLayout.draw(text, in: CGRect(x: box.minX, y: cell.midY - height / 2, width: box.width, height: height + 1),
                                     context: context)
            }
        }
        context.setStrokeColor(palette.text.withAlphaComponent(0.14).cgColor)
        context.setLineWidth(1)
        var x: CGFloat = 0
        for width in layout.columns.dropLast() {
            x += width
            context.move(to: CGPoint(x: x, y: 0))
            context.addLine(to: CGPoint(x: x, y: natural.height))
        }
        var y: CGFloat = 0
        for height in layout.rows.dropLast() {
            y += height
            context.move(to: CGPoint(x: 0, y: y))
            context.addLine(to: CGPoint(x: natural.width, y: y))
        }
        context.strokePath()
        context.resetClip()
        context.addPath(CGPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), cornerWidth: Corners.r(size * 0.4),
                               cornerHeight: Corners.r(size * 0.4), transform: nil))
        context.setStrokeColor(palette.text.withAlphaComponent(0.18).cgColor)
        context.strokePath()
        context.restoreGState()
    }

    // MARK: Drawings

    static func inkPath(_ points: [CanvasPoint], transform: (CanvasPoint) -> CGPoint) -> CGPath {
        BoardInkPath.path(points, transform: transform).cgPath
    }

    /// Strokes the drawing `ink` (relative to its node, `natural` as written) at `size`.
    static func drawInk(_ ink: CanvasInk, natural: CGSize, in size: CGSize, context: CGContext, text: NSColor,
                        lineScale: CGFloat = 1) {
        let sx = size.width / max(natural.width, 1), sy = size.height / max(natural.height, 1)
        func transform(_ point: CanvasPoint) -> CGPoint { CGPoint(x: point.x * sx, y: point.y * sy) }
        let scale = min(sx, sy) * lineScale
        context.saveGState()
        context.setLineCap(.round)
        context.setLineJoin(.round)
        for stroke in ink.strokes {
            let color = (BoardStyle.nsColor(stroke.color) ?? text).withAlphaComponent(stroke.opacity)
            let width = max(0.5, stroke.width * scale)
            context.setStrokeColor(color.cgColor)
            context.setLineWidth(width)
            context.setLineDash(phase: 0, lengths: stroke.dashed ? [width * 3, width * 2.5] : [])
            context.addPath(inkPath(stroke.points, transform: transform))
            context.strokePath()
        }
        context.setLineDash(phase: 0, lengths: [])
        if ink.kind == .line, let stroke = ink.strokes.first, let (start, end) = ink.ends {
            let color = (BoardStyle.nsColor(stroke.color) ?? text).withAlphaComponent(stroke.opacity)
            context.setStrokeColor(color.cgColor)
            context.setLineWidth(max(0.5, stroke.width * scale))
            for (tip, from, shown) in [(end, stroke.points.dropLast().last ?? start, ink.endArrow),
                                       (start, stroke.points.dropFirst().first ?? end, ink.startArrow)] where shown {
                let (left, right) = CanvasInk.arrowHead(tip: tip, from: from, size: CanvasInk.headSize(stroke.width))
                context.move(to: transform(left))
                context.addLine(to: transform(tip))
                context.addLine(to: transform(right))
                context.strokePath()
            }
        }
        context.restoreGState()
    }

    // MARK: Far out

    /// A card far out, as `BoardFarCards` drew them: a tinted sheet with its title, a small picture, a table's header
    /// band, a drawing's strokes. The title is sized for the screen (`lineScale`).
    private static func drawFar(_ far: BoardItemSpec.FarSpec, spec: BoardItemSpec, rect: CGRect, path: CGPath,
                                context: CGContext, lineScale: CGFloat, palette: BoardPalette) {
        let scale = 1 / lineScale
        let edge = palette.text.withAlphaComponent(0.22)
        if let picture = far.picture, let image = BoardImages.image(picture, maxPixels: 192) {
            context.saveGState()
            context.addPath(path)
            context.clip()
            drawImage(image, in: rect, context: context)
            context.restoreGState()
            context.addPath(path)
            context.setStrokeColor(edge.cgColor)
            context.setLineWidth(0.5 * lineScale)
            context.strokePath()
            return
        }
        if let ink = far.ink {
            drawInk(ink, natural: far.natural, in: rect.size, context: context, text: palette.text)
            return
        }
        if far.table {
            context.addPath(path)
            context.setFillColor(palette.background.cgColor)
            context.fillPath()
            context.saveGState()
            context.addPath(path)
            context.clip()
            context.setFillColor((spec.tint ?? palette.accent).cgColor)
            context.fill(CGRect(x: 0, y: 0, width: rect.width, height: max(1 * lineScale, rect.height / 5)))
            context.restoreGState()
            context.addPath(path)
            context.setStrokeColor(edge.cgColor)
            context.setLineWidth(0.75 * lineScale)
            context.strokePath()
            return
        }
        if !spec.invisible {
            context.addPath(path)
            context.setFillColor(palette.background.cgColor)
            context.fillPath()
            if let tint = spec.tint {
                context.addPath(path)
                context.setFillColor(tint.withAlphaComponent(spec.sticky ? 0.78 : 0.28).cgColor)
                context.fillPath()
            }
            context.addPath(path)
            context.setStrokeColor((spec.tint?.withAlphaComponent(0.8) ?? edge).cgColor)
            context.setLineWidth(0.75 * lineScale)
            context.strokePath()
        }
        guard !far.title.isEmpty, rect.width * scale >= 36 || far.textSize != nil else { return }
        if let size = far.textSize {
            guard size * scale >= 3 else { return }
            let text = NSAttributedString(string: far.title, attributes: [
                .font: NSFont.ui(size: size, weight: far.textBold ? .bold : .regular), .foregroundColor: palette.text,
            ])
            BoardTextLayout.draw(text, in: rect.insetBy(dx: BoardStyle.freeTextPadding, dy: 0), context: context)
            return
        }
        guard rect.height * scale >= 18 else { return }
        let fontSize = min(14, 9 + scale * 20).rounded() * lineScale
        let paragraph = BoardTextLayout.paragraph(lineBreak: .byTruncatingTail)
        if far.centred { paragraph.alignment = .center }
        let text = NSAttributedString(string: far.title, attributes: [
            .font: NSFont.ui(size: fontSize, weight: .semibold), .foregroundColor: palette.text, .paragraphStyle: paragraph,
        ])
        let room = rect.insetBy(dx: 6 * lineScale, dy: 5 * lineScale)
        if far.centred {
            let height = min(BoardTextLayout.height(text, width: room.width), room.height)
            BoardTextLayout.draw(text, in: CGRect(x: room.minX, y: room.midY - height / 2, width: room.width, height: height + 1),
                                 context: context)
        } else {
            BoardTextLayout.draw(text, in: room, context: context)
        }
    }
}

// MARK: - Text

/// A card's Markdown as attributed text, as the board's roomy previews lay it out: document-like headings, lists
/// with bullets or numbers, tasks with a box, quotes with a bar, code in the mono face. `BoardText.height` measures
/// the same layout.
enum BoardTextLayout {
    static func paragraph(lineBreak: NSLineBreakMode = .byWordWrapping, spacingBefore: CGFloat = 0) -> NSMutableParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = lineBreak
        style.paragraphSpacingBefore = spacingBefore
        return style
    }

    static func attributed(_ preview: NotePreview, size: CGFloat, align: CanvasTextAlign, palette: BoardPalette) -> NSAttributedString {
        let k = size / 10
        let result = NSMutableAttributedString()
        let body = NSFont.ui(size: size)
        let text = palette.text.withAlphaComponent(0.92)
        let secondary = palette.secondary
        let alignment: NSTextAlignment = switch align {
        case .left: .left
        case .center: .center
        case .right: .right
        }
        let theme = palette.theme
        if preview.blocks.isEmpty {
            return NSAttributedString(string: " ", attributes: [.font: body])
        }
        for (index, block) in preview.blocks.enumerated() {
            let style = NSMutableParagraphStyle()
            style.lineSpacing = size * 0.2
            style.paragraphSpacingBefore = index == 0 ? 0 : size * 0.4
            style.alignment = alignment
            var line = NSMutableAttributedString()
            switch block {
            case .heading(let level, let content):
                let scales: [CGFloat] = [1.75, 1.45, 1.25, 1.1]
                let font = NSFont.ui(size: size * scales[min(max(level, 1), 4) - 1], weight: level <= 2 ? .bold : .semibold)
                line = NotePreviewText.inline(content, font: font, color: palette.text, theme: theme)
                style.paragraphSpacingBefore += size * 0.25
            case .bullet(let depth, let content):
                line = marked("\u{2022}", depth: depth, content, font: body, color: text, marker: secondary, k: k, style: style, theme: theme)
            case .ordered(let number, let depth, let content):
                line = marked(number + ".", depth: depth, content, font: body, color: text, marker: secondary, k: k, style: style, theme: theme)
            case .task(let depth, let done, let content):
                let color = done ? secondary.withAlphaComponent(0.7) : text
                line = marked("\u{2022}", depth: depth, content, font: body, color: color, marker: secondary, k: k, style: style, theme: theme)
                let box = NSTextAttachment()
                let side = 8 * k
                let accent = palette.accent
                box.image = NSImage(size: CGSize(width: side, height: side), flipped: false) { rect in
                    let path = NSBezierPath(roundedRect: rect.insetBy(dx: max(1, k) / 2, dy: max(1, k) / 2),
                                            xRadius: 2.5 * k, yRadius: 2.5 * k)
                    path.lineWidth = max(1, k)
                    if done {
                        accent.setFill()
                        path.fill()
                        accent.setStroke()
                    } else {
                        secondary.setStroke()
                    }
                    path.stroke()
                    return true
                }
                box.bounds = CGRect(x: 0, y: (body.capHeight - side) / 2, width: side, height: side)
                line.replaceCharacters(in: NSRange(location: 0, length: 1), with: NSAttributedString(attachment: box))
                if done {
                    line.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue,
                                      range: NSRange(location: 2, length: max(0, line.length - 2)))
                }
            case .quote(let content):
                line = NSMutableAttributedString(string: "\u{258F} ", attributes: [.font: body, .foregroundColor: palette.text.withAlphaComponent(0.7)])
                line.append(NotePreviewText.inline(content, font: body, color: palette.text.withAlphaComponent(0.75), theme: theme))
            case .code(let content):
                line = code(content, size: size * 0.9, palette: palette)
            case .fenced(_, let content):
                for (number, codeLine) in content.split(separator: "\n", omittingEmptySubsequences: false).prefix(16).enumerated() {
                    if number > 0 { line.append(NSAttributedString(string: "\n")) }
                    line.append(code(String(codeLine), size: size * 0.9, palette: palette))
                }
                style.lineSpacing = size * 0.3
            case .tableRow(let cells, let header):
                let font = NSFont.ui(size: size * 0.95, weight: header ? .semibold : .regular)
                for (number, cell) in cells.enumerated() {
                    if number > 0 {
                        line.append(NSAttributedString(string: "  \u{2502}  ", attributes: [
                            .font: font, .foregroundColor: secondary.withAlphaComponent(0.5),
                        ]))
                    }
                    line.append(NotePreviewText.inline(cell, font: font, color: text, theme: theme))
                }
                style.lineBreakMode = .byTruncatingTail
            case .paragraph(let content):
                line = NotePreviewText.inline(content, font: body, color: text, theme: theme)
            }
            if index > 0 { result.append(NSAttributedString(string: "\n", attributes: [.font: body])) }
            line.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: line.length))
            result.append(line)
        }
        return result
    }

    private static func marked(_ marker: String, depth: Int, _ content: String, font: NSFont, color: NSColor,
                               marker markerColor: NSColor, k: CGFloat, style: NSMutableParagraphStyle,
                               theme: ThemeTokens) -> NSMutableAttributedString {
        let line = NSMutableAttributedString(string: marker + " ", attributes: [.font: font, .foregroundColor: markerColor])
        line.append(NotePreviewText.inline(content, font: font, color: color, theme: theme))
        let indent = CGFloat(depth) * 10 * k
        style.firstLineHeadIndent = indent
        style.headIndent = indent + ((marker + " ") as NSString).size(withAttributes: [.font: font]).width
        return line
    }

    private static func code(_ content: String, size: CGFloat, palette: BoardPalette) -> NSMutableAttributedString {
        NSMutableAttributedString(string: content.isEmpty ? " " : content, attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: size, weight: .regular),
            .foregroundColor: palette.accent.withAlphaComponent(0.85),
            .backgroundColor: palette.codeBackground,
        ])
    }

    static func height(_ text: NSAttributedString, width: CGFloat) -> CGFloat {
        guard width > 0 else { return 0 }
        return ceil(text.boundingRect(with: CGSize(width: width, height: .greatestFiniteMagnitude),
                                      options: [.usesLineFragmentOrigin, .usesFontLeading]).height)
    }

    /// Draws `text` wrapped in `rect` of a y-down context, cut at its bottom (or after `maxLines`).
    static func draw(_ text: NSAttributedString, in rect: CGRect, context: CGContext, maxLines: Int = 0) {
        guard rect.width > 0, rect.height > 0, text.length > 0 else { return }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        let storage = NSTextStorage(attributedString: text)
        let manager = NSLayoutManager()
        let container = NSTextContainer(size: CGSize(width: rect.width, height: rect.height))
        container.lineFragmentPadding = 0
        container.maximumNumberOfLines = maxLines
        if maxLines > 0 { container.lineBreakMode = .byTruncatingTail }
        manager.addTextContainer(container)
        storage.addLayoutManager(manager)
        let glyphs = manager.glyphRange(for: container)
        manager.drawBackground(forGlyphRange: glyphs, at: rect.origin)
        manager.drawGlyphs(forGlyphRange: glyphs, at: rect.origin)
        NSGraphicsContext.restoreGraphicsState()
    }
}

// MARK: - Pictures

/// Pictures of the vault decoded at the size they are drawn, off the main thread, kept a while.
enum BoardImages {
    private final class Box: @unchecked Sendable {
        let image: CGImage?
        init(_ image: CGImage?) { self.image = image }
    }

    nonisolated(unsafe) private static let cache: NSCache<NSString, Box> = {
        let cache = NSCache<NSString, Box>()
        cache.totalCostLimit = 512 * 1024 * 1024
        return cache
    }()

    /// The picture at `url`, at most `maxPixels` on its longer side (rounded up to a power of two, so a zoom reuses it).
    static func image(_ url: URL, maxPixels: CGFloat) -> CGImage? {
        var bucket: CGFloat = 64
        while bucket < min(maxPixels, 4096) { bucket *= 2 }
        let key = "\(Int(bucket))|" + url.path as NSString
        if let known = cache.object(forKey: key) { return known.image }
        var image: CGImage?
        if let source = CGImageSourceCreateWithURL(url as CFURL, nil) {
            image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: Int(bucket),
            ] as CFDictionary)
        }
        cache.setObject(Box(image), forKey: key, cost: (image?.bytesPerRow ?? 0) * (image?.height ?? 0))
        return image
    }

    /// The size of the picture at `url`, in pixels, from its header.
    static func pixelSize(_ url: URL) -> CGSize? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? CGFloat,
              let height = properties[kCGImagePropertyPixelHeight] as? CGFloat else { return nil }
        return CGSize(width: width, height: height)
    }
}

// MARK: - Links

/// A link card, as Notion and Whimsical show one (`BoardRichLink` drew the same): a video with its picture and a
/// play button, a post with its text and author, a PDF's first page, a page with its picture, site, title and summary.
enum BoardLinkDrawing {
    static func draw(_ link: BoardLinkSpec, tint: NSColor?, rect: CGRect, context: CGContext, palette: BoardPalette) {
        switch link.kind {
        case .youtube, .vimeo: video(link, rect: rect, context: context)
        case .tweet: post(link, rect: rect, context: context, palette: palette)
        case .pdf:
            if let page = link.pdfPage {
                context.setFillColor(NSColor.white.cgColor)
                context.fill(rect)
                let ratio = CGFloat(page.width) / max(CGFloat(page.height), 1)
                let width = min(rect.width, rect.height * ratio)
                BoardDrawing.drawImage(page, in: CGRect(x: rect.midX - width / 2, y: 0, width: width, height: width / ratio),
                                       context: context)
                pill(link.preview?.title ?? link.url.lastPathComponent, rect: rect, context: context)
            } else {
                document(link, tint: tint, rect: rect, context: context, palette: palette)
            }
        case .page: page(link, tint: tint, rect: rect, context: context, palette: palette)
        }
    }

    private static func text(_ string: String, size: CGFloat, weight: NSFont.Weight = .regular, color: NSColor,
                             lines: Int = 0) -> NSAttributedString {
        NSAttributedString(string: string, attributes: [
            .font: NSFont.ui(size: size, weight: weight), .foregroundColor: color,
            .paragraphStyle: BoardTextLayout.paragraph(lineBreak: lines > 0 ? .byTruncatingTail : .byWordWrapping),
        ])
    }

    /// Draws `string` from `y`, at most `lines` lines, and returns where it ends.
    @discardableResult
    private static func lines(_ string: NSAttributedString, x: CGFloat, y: CGFloat, width: CGFloat, lines: Int,
                              context: CGContext) -> CGFloat {
        guard string.length > 0 else { return y }
        let font = string.attribute(.font, at: 0, effectiveRange: nil) as? NSFont ?? .systemFont(ofSize: 13)
        let lineHeight = ceil(font.ascender - font.descender + font.leading)
        let height = min(BoardTextLayout.height(string, width: width), lineHeight * CGFloat(max(lines, 1)) + 1)
        BoardTextLayout.draw(string, in: CGRect(x: x, y: y, width: width, height: height + 2), context: context, maxLines: lines)
        return y + height
    }

    private static func video(_ link: BoardLinkSpec, rect: CGRect, context: CGContext) {
        context.setFillColor(NSColor.black.cgColor)
        context.fill(rect)
        if let picture = link.picture { BoardDrawing.drawFilling(picture, in: rect, context: context) }
        let colors = [NSColor.black.withAlphaComponent(0.7).cgColor, NSColor.black.withAlphaComponent(0).cgColor] as CFArray
        if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1]) {
            context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 0, y: rect.midY), options: [])
        }
        let youtube = link.kind != .vimeo
        let button = CGRect(x: rect.midX - 34, y: rect.midY - 24, width: 68, height: 48)
        context.saveGState()
        context.setShadow(offset: CGSize(width: 0, height: 3), blur: 10, color: NSColor.black.withAlphaComponent(0.35).cgColor)
        context.addPath(CGPath(roundedRect: button, cornerWidth: Corners.r(14), cornerHeight: Corners.r(14), transform: nil))
        context.setFillColor((youtube ? NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)
            : NSColor(srgbRed: 0.1, green: 0.72, blue: 0.92, alpha: 1)).cgColor)
        context.fillPath()
        context.restoreGState()
        context.move(to: CGPoint(x: button.midX - 7.5, y: button.midY - 11))
        context.addLine(to: CGPoint(x: button.midX + 11.5, y: button.midY))
        context.addLine(to: CGPoint(x: button.midX - 7.5, y: button.midY + 11))
        context.closePath()
        context.setFillColor(NSColor.white.cgColor)
        context.fillPath()
        let width = rect.width - 28
        let end = lines(text(link.preview?.site ?? "Video", size: 12, weight: .semibold, color: NSColor.white.withAlphaComponent(0.8), lines: 1),
                        x: 14, y: 14, width: width, lines: 1, context: context)
        lines(text(link.preview?.title ?? link.url.absoluteString, size: 16, weight: .bold, color: .white, lines: 1),
              x: 14, y: end + 3, width: width, lines: 1, context: context)
    }

    private static func post(_ link: BoardLinkSpec, rect: CGRect, context: CGContext, palette: BoardPalette) {
        let padding = BoardStyle.textPadding
        let width = rect.width - padding * 2
        lines(text("𝕏", size: 20, weight: .black, color: palette.text), x: padding, y: padding + 4, width: 30, lines: 1, context: context)
        var y = lines(text(link.preview?.title ?? "Post", size: 15, weight: .bold, color: palette.text, lines: 1),
                      x: padding + 30, y: padding, width: width - 30, lines: 1, context: context)
        if let author = link.preview?.author {
            y = lines(text(author, size: 13, color: palette.secondary, lines: 1), x: padding + 30, y: y, width: width - 30,
                      lines: 1, context: context)
        }
        y = max(y, padding + 40) + 10
        let body = NSMutableAttributedString(attributedString: text(link.preview?.summary ?? link.url.absoluteString,
                                                                    size: 16, color: palette.text))
        let style = BoardTextLayout.paragraph()
        style.lineSpacing = 2
        body.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: body.length))
        BoardTextLayout.draw(body, in: CGRect(x: padding, y: y, width: width, height: rect.height - y - padding), context: context)
    }

    private static func pill(_ title: String, rect: CGRect, context: CGContext) {
        let label = text(title, size: 12, weight: .semibold, color: .white, lines: 1)
        let icon = tintedSymbol("doc.richtext.fill", size: 12, weight: .semibold, color: .white)
        let textWidth = min(ceil(label.size().width), rect.width - 60)
        let iconWidth = (icon?.size.width ?? 0) + 6
        let box = CGRect(x: 10, y: rect.height - 10 - 24, width: textWidth + iconWidth + 20, height: 24)
        context.addPath(CGPath(roundedRect: box, cornerWidth: Corners.r(12), cornerHeight: Corners.r(12), transform: nil))
        context.setFillColor(NSColor.black.withAlphaComponent(0.6).cgColor)
        context.fillPath()
        if let icon { BoardDrawing.drawSymbol(icon, at: CGPoint(x: box.minX + 10, y: box.midY - icon.size.height / 2), context: context) }
        lines(label, x: box.minX + 10 + iconWidth, y: box.minY + 4, width: textWidth, lines: 1, context: context)
    }

    private static func document(_ link: BoardLinkSpec, tint: NSColor?, rect: CGRect, context: CGContext, palette: BoardPalette) {
        let padding = BoardStyle.textPadding
        let icon = tintedSymbol("doc.richtext.fill", size: 40, color: tint ?? NSColor.systemRed.withAlphaComponent(0.85))
        let iconWidth = icon?.size.width ?? 0
        let width = rect.width - padding * 2 - iconWidth - 14
        let title = text(link.preview?.title ?? link.url.lastPathComponent, size: 17, weight: .bold, color: palette.text, lines: 3)
        let subtitle = text("PDF · " + (link.url.host() ?? ""), size: 13, color: palette.secondary, lines: 1)
        let titleHeight = min(BoardTextLayout.height(title, width: width), 3 * 22)
        let total = titleHeight + 4 + 17
        if let icon {
            BoardDrawing.drawSymbol(icon, at: CGPoint(x: padding, y: rect.midY - icon.size.height / 2), context: context)
        }
        let x = padding + iconWidth + 14
        let end = lines(title, x: x, y: rect.midY - total / 2, width: width, lines: 3, context: context)
        lines(subtitle, x: x, y: end + 4, width: width, lines: 1, context: context)
    }

    private static func page(_ link: BoardLinkSpec, tint: NSColor?, rect: CGRect, context: CGContext, palette: BoardPalette) {
        var y: CGFloat = 0
        let hasImage = link.picture != nil
        if let picture = link.picture {
            // Social pictures are 1.91:1.
            let area = CGRect(x: 0, y: 0, width: rect.width, height: rect.width / 1.91)
            context.saveGState()
            context.clip(to: area)
            BoardDrawing.drawFilling(picture, in: area, context: context)
            context.restoreGState()
            y = area.maxY
        }
        let x: CGFloat = 14
        let width = rect.width - 28
        y += 14
        var siteX = x
        if let icon = link.icon {
            context.saveGState()
            context.addPath(CGPath(roundedRect: CGRect(x: x, y: y, width: 16, height: 16), cornerWidth: Corners.r(4),
                                   cornerHeight: Corners.r(4), transform: nil))
            context.clip()
            BoardDrawing.drawImage(icon, in: CGRect(x: x, y: y, width: 16, height: 16), context: context)
            context.restoreGState()
            siteX += 22
        } else if let globe = tintedSymbol("globe", size: 13, color: tint ?? palette.accent) {
            BoardDrawing.drawSymbol(globe, at: CGPoint(x: x, y: y + 8 - globe.size.height / 2), context: context)
            siteX += globe.size.width + 6
        }
        lines(text(link.preview?.site ?? link.url.host() ?? "", size: 12, weight: .semibold, color: palette.secondary, lines: 1),
              x: siteX, y: y, width: width - (siteX - x), lines: 1, context: context)
        y += 18 + 6
        y = lines(text(link.preview?.title ?? link.url.host() ?? link.url.absoluteString,
                       size: hasImage ? 17 : BoardStyle.titleSize, weight: .bold, color: palette.text, lines: hasImage ? 2 : 3),
                  x: x, y: y, width: width, lines: hasImage ? 2 : 3, context: context)
        if let summary = link.preview?.summary {
            y = lines(text(summary, size: 13, color: palette.secondary, lines: hasImage ? 2 : 5), x: x, y: y + 6, width: width,
                      lines: hasImage ? 2 : 5, context: context)
        }
        if !hasImage {
            lines(text(link.url.absoluteString, size: 12, color: palette.link, lines: 1), x: x, y: y + 6, width: width,
                  lines: 1, context: context)
        }
    }
}
