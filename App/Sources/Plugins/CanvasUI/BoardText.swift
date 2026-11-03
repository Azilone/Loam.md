import AppKit
import CanvasPlugin
import PluginKitUI

/// How tall a text card's Markdown is at a font size and width: what a card needs to show it all, measured the
/// way `NotePreviewView` lays it out in its roomy style.
enum BoardText {
    private static let headingScales: [CGFloat] = [1.75, 1.45, 1.25, 1.1]

    /// How tall a card of `shape` must be to show its text in the part of it text goes in.
    static func height(of text: String, fontSize: Double, width: Double, shape: CanvasNodeShape?) -> Double {
        guard let shape, shape != .rectangle else { return height(of: text, fontSize: fontSize, width: width) }
        let inset = shape.textInsets
        let needed = height(of: text, fontSize: fontSize, width: width * (1 - inset.left - inset.right))
        return (needed / max(0.2, 1 - inset.top - inset.bottom)).rounded(.up)
    }

    static func height(of text: String, fontSize: Double, width: Double,
                       padding: CGFloat = BoardStyle.textPadding) -> Double {
        let size = CGFloat(fontSize)
        let inner = max(40, CGFloat(width) - padding * 2)
        let preview = NotePreview.parse(text, title: "", limit: 100_000)
        var total: CGFloat = 0
        if preview.blocks.isEmpty { total = lineHeight(size) }
        for (index, block) in preview.blocks.enumerated() {
            if index > 0 { total += size * 0.4 }
            switch block {
            case .heading(let level, let content):
                let scale = headingScales[min(max(level, 1), 4) - 1]
                total += size * 0.25 + wrapped(content, size: size * scale, width: inner, weight: .bold)
            case .paragraph(let content):
                total += wrapped(content, size: size, width: inner)
            case .quote(let content):
                total += wrapped(content, size: size, width: inner - 7)
            case .bullet(let depth, let content), .ordered(_, let depth, let content):
                total += wrapped(content, size: size, width: inner - CGFloat(depth) * 10 - size * 1.3)
            case .task(let depth, _, let content):
                total += wrapped(content, size: size, width: inner - CGFloat(depth) * 10 - size * 1.3)
            case .code:
                total += lineHeight(size * 0.9) + 2
            case .fenced(_, let code):
                // Shown as its lines on a board (`NotePreviewView` with `roomy`), at most 16.
                let lines = CGFloat(min(16, code.split(separator: "\n", omittingEmptySubsequences: false).count))
                total += lines * (lineHeight(size * 0.9) + 2) + (lines - 1) * size * 0.3
            case .tableRow:
                total += lineHeight(size * 0.95) + 6
            }
        }
        return (total + padding * 2).rounded(.up)
    }

    /// The size of free text: as wide as its longest line (long lines wrap past `maxLineWidth` times the size,
    /// in ems), as tall as its lines.
    static func freeSize(of text: String, fontSize: Double, maxLineWidth: Double = 40) -> (width: Double, height: Double) {
        let size = CGFloat(fontSize)
        let pad = BoardStyle.freeTextPadding
        let preview = NotePreview.parse(text, title: "", limit: 100_000)
        var widest: CGFloat = size * 1.5
        for block in preview.blocks {
            switch block {
            case .heading(let level, let content):
                let scale = headingScales[min(max(level, 1), 4) - 1]
                widest = max(widest, line(content, size: size * scale, weight: .bold))
            case .paragraph(let content):
                widest = max(widest, line(content, size: size))
            case .quote(let content):
                widest = max(widest, line(content, size: size) + 7)
            case .bullet(let depth, let content), .ordered(_, let depth, let content), .task(let depth, _, let content):
                widest = max(widest, line(content, size: size) + CGFloat(depth) * 10 + size * 1.3)
            case .code(let content):
                widest = max(widest, line(content, size: size * 0.9) * 1.1)
            case .fenced(_, let code):
                for content in code.split(separator: "\n") {
                    widest = max(widest, line(String(content), size: size * 0.9) * 1.1)
                }
            case .tableRow(let cells, _):
                widest = max(widest, cells.map { line($0, size: size * 0.95) + 10 }.reduce(0, +))
            }
        }
        // Hugs the text: two points so a drawn line never wraps; the editor takes its own room past the outline
        // (`BoardTextEditor`).
        let width = (min(widest, size * CGFloat(maxLineWidth)) + pad * 2 + 2).rounded(.up)
        return (Double(width), height(of: text, fontSize: fontSize, width: Double(width), padding: pad))
    }

    /// The width of one line of inline Markdown, without its marks.
    private static func line(_ text: String, size: CGFloat, weight: NSFont.Weight = .regular) -> CGFloat {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        let plain = (try? AttributedString(markdown: text, options: options)).map { String($0.characters) } ?? text
        let font = NSFont.systemFont(ofSize: size, weight: weight)
        // Bold runs are measured regular: a few percent more covers them, only where there are marks.
        let marked = plain.count < text.count
        return ceil((plain as NSString).size(withAttributes: [.font: font]).width * (marked ? 1.04 : 1))
    }

    private static func lineHeight(_ size: CGFloat) -> CGFloat {
        let font = NSFont.systemFont(ofSize: size)
        return (font.ascender - font.descender + font.leading) + size * 0.2
    }

    private static func wrapped(_ text: String, size: CGFloat, width: CGFloat,
                                weight: NSFont.Weight = .regular) -> CGFloat {
        let font = NSFont.systemFont(ofSize: size, weight: weight)
        let bounds = (text as NSString).boundingRect(
            with: CGSize(width: max(20, width), height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: font]
        )
        let natural = font.ascender - font.descender + font.leading
        let lines = max(1, (bounds.height / natural).rounded())
        return lines * natural + (lines) * size * 0.2
    }
}
