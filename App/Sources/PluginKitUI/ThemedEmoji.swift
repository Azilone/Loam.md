import AppKit
import SwiftUI

/// An emoji in Loam's print look: dithered in the accent, its darker parts as dots, its light parts left clear. SwiftUI's colour effects do not reach an emoji's glyphs, so the
/// emoji is drawn to a picture first. Each emoji is dithered once per size and accent.
public struct ThemedEmoji: View {
    let emoji: String
    let size: CGFloat
    /// Redraws the printed dots in this colour (white on a filled selection); the accent when nil.
    let ink: Color?
    @Environment(\.themeTokens) private var theme

    public init(emoji: String, size: CGFloat) {
        self.init(emoji: emoji, size: size, ink: nil)
    }

    public init(emoji: String, size: CGFloat, ink: Color?) {
        self.emoji = emoji
        self.size = size
        self.ink = ink
    }

    public var body: some View {
        if let image = Self.printed(emoji, size: size, theme: theme) {
            if let ink {
                Image(nsImage: image).renderingMode(.template).interpolation(.none).foregroundStyle(ink)
            } else {
                Image(nsImage: image).interpolation(.none)
            }
        } else {
            Text(emoji).font(.ui(size: size))
        }
    }

    @MainActor private static var cache: [String: NSImage] = [:]

    @MainActor
    static func printed(_ emoji: String, size: CGFloat, theme: ThemeTokens) -> NSImage? {
        let ink = theme.dither.ink
        let key = "\(emoji)@\(size)#\(ink.hex)"
        if let known = cache[key] { return known }
        let text = NSAttributedString(string: emoji, attributes: [.font: NSFont.systemFont(ofSize: size)])
        let bounds = text.size()
        guard bounds.width > 0 else { return nil }
        // Two pixels a point: the emoji drawn, then each pixel inside it ink or clear by a Bayer threshold. The shape
        // stays whole (every pixel of it is at least half likely to be ink) and its darker parts come out denser.
        let width = Int(ceil(bounds.width * 2)), height = Int(ceil(bounds.height * 2))
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let info = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        guard let context = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: space, bitmapInfo: info) else { return nil }
        context.scaleBy(x: 2, y: 2)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        text.draw(at: .zero)
        NSGraphicsContext.restoreGraphicsState()
        let bayer: [Double] = [0, 8, 2, 10, 12, 4, 14, 6, 3, 11, 1, 9, 15, 7, 13, 5].map { ($0 + 0.5) / 16 }
        let r = UInt8(ink.red * 255), g = UInt8(ink.green * 255), b = UInt8(ink.blue * 255)
        for y in 0..<height {
            for x in 0..<width {
                let i = (y * width + x) * 4
                let alpha = Double(pixels[i + 3]) / 255
                guard alpha > 0.4 else { pixels[i] = 0; pixels[i + 1] = 0; pixels[i + 2] = 0; pixels[i + 3] = 0; continue }
                let lum = (0.2126 * Double(pixels[i]) + 0.7152 * Double(pixels[i + 1]) + 0.0722 * Double(pixels[i + 2])) / 255 / alpha
                let density = 0.5 + 0.5 * (1 - min(lum, 1))
                if density > bayer[(y % 4) * 4 + x % 4] {
                    pixels[i] = r; pixels[i + 1] = g; pixels[i + 2] = b; pixels[i + 3] = 255
                } else {
                    pixels[i] = 0; pixels[i + 1] = 0; pixels[i + 2] = 0; pixels[i + 3] = 0
                }
            }
        }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let dithered = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                                     space: space, bitmapInfo: CGBitmapInfo(rawValue: info), provider: provider, decode: nil,
                                     shouldInterpolate: false, intent: .defaultIntent) else { return nil }
        let image = NSImage(cgImage: dithered, size: bounds)
        cache[key] = image
        return image
    }
}
