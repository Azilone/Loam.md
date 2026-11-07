import AppKit
import PDFKit

/// A PDF's first page as a picture (the panel's thumbnail, the note's cover) and the text of its first pages for
/// the agent, read before the import: Media compression may later turn a big PDF into pictures without text.
enum PDFPreview {
    static func firstPage(_ data: Data) -> NSImage? {
        guard let page = PDFDocument(data: data)?.page(at: 0) else { return nil }
        return page.thumbnail(of: NSSize(width: 480, height: 640), for: .mediaBox)
    }

    /// PNG bytes of the first page, for the cover.
    static func coverPNG(_ data: Data) -> Data? {
        guard let image = firstPage(data), let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff) else { return nil }
        return bitmap.representation(using: .png, properties: [:])
    }

    static func text(_ data: Data, limit: Int = 12_000) -> String {
        guard let document = PDFDocument(data: data) else { return "" }
        var text = ""
        for index in 0..<min(document.pageCount, 20) {
            text += (document.page(at: index)?.string ?? "") + "\n"
            if text.count > limit { break }
        }
        return String(text.prefix(limit))
    }

    static func pageCount(_ data: Data) -> Int {
        PDFDocument(data: data)?.pageCount ?? 0
    }
}
