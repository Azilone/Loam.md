import AppKit
import ImageIO
import PDFKit
import PluginKit

/// Draws each page of a PDF as a JPEG and writes a PDF made of those pictures, at the pages' size. The JPEG bytes go
/// into the file as they are (Core Graphics keeps a JPEG-backed image as one), so the file's size is the pictures'.
final class PDFKitRasterizer: PDFRasterizing, @unchecked Sendable {
    enum Failure: Error, LocalizedError {
        case unreadable
        case emptyDocument
        case cannotWrite

        var errorDescription: String? {
            switch self {
            case .unreadable: "the PDF cannot be opened (it may be encrypted)"
            case .emptyDocument: "the PDF has no pages"
            case .cannotWrite: "the optimized PDF cannot be written"
            }
        }
    }

    /// No page is drawn larger than this on its long side, whatever the resolution asks.
    static let longestSide: CGFloat = 3200

    func rasterize(_ input: URL, to output: URL, dpi: Int, jpegQuality: Int) async throws {
        guard let document = PDFDocument(url: input), !document.isLocked else { throw Failure.unreadable }
        guard document.pageCount > 0 else { throw Failure.emptyDocument }
        var pages: [(jpeg: Data, size: CGSize)] = []
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { continue }
            try autoreleasepool {
                pages.append(try Self.render(page, dpi: dpi, quality: jpegQuality))
            }
            try Task.checkCancellation()
        }
        try Self.write(pages, to: output)
    }

    private static func render(_ page: PDFPage, dpi: Int, quality: Int) throws -> (jpeg: Data, size: CGSize) {
        var box = page.bounds(for: .cropBox)
        if page.rotation % 180 != 0 { box = CGRect(x: 0, y: 0, width: box.height, height: box.width) }
        let scale = min(CGFloat(dpi) / 72, longestSide / max(box.width, box.height, 1))
        let pixels = CGSize(width: (box.width * scale).rounded(.up), height: (box.height * scale).rounded(.up))
        // The thumbnail is the page as the viewer draws it: rotation applied, on white.
        let image = page.thumbnail(of: pixels, for: .cropBox)
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { throw Failure.unreadable }
        let bitmap = NSBitmapImageRep(cgImage: cgImage)
        guard let jpeg = bitmap.representation(using: .jpeg, properties: [.compressionFactor: CGFloat(quality) / 100]) else {
            throw Failure.unreadable
        }
        return (jpeg, box.size)
    }

    private static func write(_ pages: [(jpeg: Data, size: CGSize)], to output: URL) throws {
        var first = CGRect(origin: .zero, size: pages[0].size)
        guard let context = CGContext(output as CFURL, mediaBox: &first, nil) else { throw Failure.cannotWrite }
        for page in pages {
            var box = CGRect(origin: .zero, size: page.size)
            let info = [kCGPDFContextMediaBox as String: Data(bytes: &box, count: MemoryLayout<CGRect>.size)] as CFDictionary
            context.beginPDFPage(info)
            // A JPEG data provider image is embedded without being decoded and encoded again.
            if let provider = CGDataProvider(data: page.jpeg as CFData),
               let image = CGImage(jpegDataProviderSource: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) {
                context.draw(image, in: box)
            }
            context.endPDFPage()
        }
        context.closePDF()
    }
}
