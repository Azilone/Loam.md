import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

/// A picture of the vault on a card, dithered in the theme's colours (`ImageDither`). The file is decoded at the size
/// a card shows it and dithered off the main thread, then kept: a grid of cards scrolls without decoding a photo in a
/// frame. Empty until the picture is ready.
public struct DitheredThumbnail: View {
    let url: URL
    @Environment(\.themeTokens) private var theme
    @State private var loaded: (key: String, image: NSImage)?

    public init(url: URL) {
        self.url = url
    }

    public var body: some View {
        let style = theme.dither
        let key = DitheredThumbnails.key(url, style)
        let image = loaded?.key == key ? loaded?.image : DitheredThumbnails.cached(key)
        Group {
            if let image {
                Image(nsImage: image).resizable().scaledToFill()
            } else {
                Color.clear
            }
        }
        .task(id: key) {
            guard image == nil else { return }
            let url = url
            let made = await Task.detached(priority: .userInitiated) { DitheredThumbnails.make(url, style: style) }.value
            guard !Task.isCancelled, let made else { return }
            let shown = NSImage(cgImage: made.image, size: made.size)
            DitheredThumbnails.keep(shown, for: key)
            loaded = (key, shown)
        }
    }
}

/// The dithered pictures of the cards, made once per file and style.
public enum DitheredThumbnails {
    /// The longest side a card's picture is decoded at, in pixels: two per point on a card about 450 points wide.
    static let maxPixels = 900

    @MainActor private static let cache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 400
        return cache
    }()

    /// Whether a file is a picture a card can show, by its extension, without reading it.
    public static func isPicture(_ url: URL) -> Bool {
        UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) ?? false
    }

    static func key(_ url: URL, _ style: DitherStyle) -> String {
        "\(url.path)|\(style)"
    }

    @MainActor static func cached(_ key: String) -> NSImage? {
        cache.object(forKey: key as NSString)
    }

    @MainActor static func keep(_ image: NSImage, for key: String) {
        cache.setObject(image, forKey: key as NSString)
    }

    /// The file decoded at `maxPixels` at most and dithered, with its size in points (half its pixels, for a Retina
    /// screen); nil when it is not a picture.
    static func make(_ url: URL, style: DitherStyle) -> (image: CGImage, size: CGSize)? {
        guard let picture = decode(url) else { return nil }
        let size = CGSize(width: picture.width / 2, height: picture.height / 2)
        guard !Task.isCancelled else { return nil }
        return (ImageDither.dither(picture, pointSize: size, style: style) ?? picture, size)
    }

    /// The file at `maxPixels` on its long side at most. ImageIO reads bitmaps; an SVG is drawn by AppKit.
    private static func decode(_ url: URL) -> CGImage? {
        if let source = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(source) > 0,
           let picture = CGImageSourceCreateThumbnailAtIndex(source, 0, [
               kCGImageSourceCreateThumbnailFromImageAlways: true,
               kCGImageSourceCreateThumbnailWithTransform: true,
               kCGImageSourceThumbnailMaxPixelSize: maxPixels,
           ] as CFDictionary) {
            return picture
        }
        guard let image = NSImage(contentsOf: url), image.size.width > 0, image.size.height > 0 else { return nil }
        let scale = min(Double(maxPixels) / max(image.size.width, image.size.height), 4)
        var rect = NSRect(x: 0, y: 0, width: (image.size.width * scale).rounded(), height: (image.size.height * scale).rounded())
        return image.cgImage(forProposedRect: &rect, context: nil, hints: nil)
    }
}
