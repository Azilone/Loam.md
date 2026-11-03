import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import PDFKit

/// Reads what the embeds show from the files, off the main thread: pictures downsampled to what a column needs, a
/// video's size, a PDF's first page.
enum MediaLoader {
    /// A picture as the editor draws it: decoded once at most `maxPixels` on its long side (a 12-megapixel photo is
    /// not kept whole), its size in points (pixels at the picture's resolution, 72 dpi by default), and its frame
    /// count (an animated GIF has several).
    struct Picture: @unchecked Sendable {
        let image: CGImage
        let size: CGSize
        let frames: Int
    }

    static func picture(at url: URL, maxPixels: Int = 2400) -> Picture? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(source) > 0 else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue ?? Double(image.width)
        let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue ?? Double(image.height)
        // The thumbnail is upright (the transform applied): its long side matches the original's.
        let scale = max(width, height) / Double(max(image.width, image.height, 1))
        let dpi = (properties[kCGImagePropertyDPIWidth] as? NSNumber)?.doubleValue ?? 72
        let points = 72 / max(dpi, 1) * scale
        return Picture(
            image: image,
            size: CGSize(width: (Double(image.width) * points).rounded(), height: (Double(image.height) * points).rounded()),
            frames: CGImageSourceGetCount(source)
        )
    }

    /// A video's size as shown (rotation applied), in points; nil when the file has no video track.
    static func videoSize(at url: URL) async -> CGSize? {
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let (natural, transform) = try? await track.load(.naturalSize, .preferredTransform) else { return nil }
        let shown = natural.applying(transform)
        let size = CGSize(width: abs(shown.width), height: abs(shown.height))
        return size.width > 0 && size.height > 0 ? size : nil
    }

    /// Whether the file has sound AVFoundation can play.
    static func hasAudio(at url: URL) async -> Bool {
        let asset = AVURLAsset(url: url)
        return (try? await asset.loadTracks(withMediaType: .audio).isEmpty == false) ?? false
    }

    /// A PDF's first page as a picture `maxSize` at most, at 2x; nil when the file is not a readable PDF.
    static func pdfThumbnail(at url: URL, maxSize: CGSize) -> CGImage? {
        guard let page = PDFDocument(url: url)?.page(at: 0) else { return nil }
        let thumbnail = page.thumbnail(of: CGSize(width: maxSize.width * 2, height: maxSize.height * 2), for: .cropBox)
        return thumbnail.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }

    /// The file's size as Finder writes it, "2 MB", "263 KB"; empty when it cannot be read.
    static func formattedSize(of url: URL) -> String {
        guard let bytes = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int else { return "" }
        return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}
