import AppKit

/// How Loam draws the pictures on cards (docs/THEMES.md): ordered dots of `ink` on `paper`, the halftone
/// look of a print. Built from the tokens of the window's appearance, so a dark theme gets its own colours.
public struct DitherStyle: Hashable, Sendable {
    public var ink: ThemeColor
    public var paper: ThemeColor
    /// The side of one dot in points.
    public var dotSize: Double

    public init(ink: ThemeColor, paper: ThemeColor, dotSize: Double = 2) {
        self.ink = ink
        self.paper = paper
        self.dotSize = dotSize
    }
}

public extension ThemeTokens {
    /// The dither the pictures on cards are drawn with, in the theme's colours.
    var dither: DitherStyle {
        DitherStyle(
            ink: palette.ditherInk ?? palette.accent ?? ImageDither.defaultInk,
            paper: palette.ditherPaper ?? palette.background ?? ImageDither.defaultPaper,
            dotSize: 1.5
        )
    }
}

/// Turns a picture into two colours with an 8x8 Bayer matrix: the picture is brought down to one cell per dot, each
/// cell is ink where it is darker than its threshold, paper elsewhere. Transparent parts stay transparent.
public enum ImageDither {
    /// The design's blue, and a white page, for a theme that sets neither accent nor background.
    static let defaultInk = ThemeColor(red: 0x2F / 255, green: 0x62 / 255, blue: 0xE0 / 255)
    static let defaultPaper = ThemeColor(red: 1, green: 1, blue: 1)

    /// The widest a picture is dithered for, in points: the widest editor column. A wider one gets bigger dots.
    static let maxWidth: Double = 2400

    private static let bayer: [UInt8] = [
        0, 32, 8, 40, 2, 34, 10, 42,
        48, 16, 56, 24, 50, 18, 58, 26,
        12, 44, 4, 36, 14, 46, 6, 38,
        60, 28, 52, 20, 62, 30, 54, 22,
        3, 35, 11, 43, 1, 33, 9, 41,
        51, 19, 59, 27, 49, 17, 57, 25,
        15, 47, 7, 39, 13, 45, 5, 37,
        63, 31, 55, 23, 61, 29, 53, 21,
    ]

    /// `image` shown `pointSize` big, dithered: one dot per `style.dotSize` points, two pixels per point so it stays
    /// sharp on a Retina screen. Nil when the picture cannot be read.
    public static func dither(_ image: CGImage, pointSize: CGSize, style: DitherStyle) -> CGImage? {
        guard pointSize.width >= 1, pointSize.height >= 1 else { return nil }
        let dot = max(style.dotSize, 1)
        let columns = max(1, Int((min(pointSize.width, maxWidth) / dot).rounded()))
        let rows = max(1, Int((Double(columns) * pointSize.height / pointSize.width).rounded()))
        guard let cells = pixels(of: image, width: columns, height: rows) else { return nil }

        // Whole pixels per dot: two per point, as on a Retina screen.
        let scale = max(1, Int((dot * 2).rounded()))
        let width = columns * scale, height = rows * scale
        let ink = packed(style.ink), paper = packed(style.paper)
        // Ink goes where the picture stands out from the paper: on the dark parts on a light page, on the light
        // parts on a dark one, so a photo never comes out as its negative.
        // A clear paper counts as white.
        let inkIsLighter = style.paper.alpha > 0.5 && luminance(style.ink) > luminance(style.paper)
        var out = [UInt32](repeating: 0, count: width * height)
        out.withUnsafeMutableBufferPointer { out in
            cells.withUnsafeBufferPointer { cells in
                for row in 0..<rows {
                    for column in 0..<columns {
                        let pixel = cells[row * columns + column]
                        let alpha = Double(pixel >> 24)
                        // Mostly transparent cells stay empty, so a logo keeps its shape.
                        guard alpha >= 128 else { continue }
                        // Premultiplied, so divided back by the alpha.
                        let r = Double(pixel & 0xFF), g = Double((pixel >> 8) & 0xFF), b = Double((pixel >> 16) & 0xFF)
                        let luminance = (0.2126 * r + 0.7152 * g + 0.0722 * b) / alpha
                        // Lifted, so a photo reads as dots on paper rather than a block of ink, as in the halftones
                        // of a print.
                        let toned = pow(min(max(inkIsLighter ? 1 - luminance : luminance, 0), 1), 0.6)
                        // The Bayer matrix alone tiles the mid-tones in a visible grid; some noise in the threshold
                        // breaks it into grain, as on a print.
                        let threshold = 0.7 * (Double(bayer[(row % 8) * 8 + column % 8]) + 0.5) / 64
                            + 0.3 * HalftoneNoise.hash(column, row &+ 57)
                        let color = toned < threshold ? ink : paper
                        for y in (row * scale)..<((row + 1) * scale) {
                            let start = y * width + column * scale
                            for x in start..<(start + scale) { out[x] = color }
                        }
                    }
                }
            }
        }
        let data = out.withUnsafeBytes { Data($0) }
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        return CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: bitmapInfo, provider: provider,
            decode: nil, shouldInterpolate: false, intent: .defaultIntent
        )
    }

    /// `image` dithered at its own size in points, kept while `image` lives: a picture redrawn on every keystroke
    /// is dithered once per style.
    @MainActor
    public static func dithered(_ image: NSImage, style: DitherStyle) -> NSImage {
        if let done = cache.object(forKey: image)?.images[style] { return done }
        var rect = NSRect(origin: .zero, size: image.size)
        guard let source = image.cgImage(forProposedRect: &rect, context: nil, hints: nil),
              let result = dither(source, pointSize: image.size, style: style) else { return image }
        let done = NSImage(cgImage: result, size: image.size)
        let entry = cache.object(forKey: image) ?? Entry()
        entry.images[style] = done
        cache.setObject(entry, forKey: image)
        return done
    }

    private final class Entry {
        var images: [DitherStyle: NSImage] = [:]
    }

    @MainActor private static let cache = NSMapTable<NSImage, Entry>.weakToStrongObjects()

    /// Bytes red, green, blue, alpha in memory, which a `UInt32` reads as 0xAABBGGRR on Apple silicon and Intel.
    private static let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)

    private static func luminance(_ color: ThemeColor) -> Double {
        0.2126 * color.red + 0.7152 * color.green + 0.0722 * color.blue
    }

    private static func packed(_ color: ThemeColor) -> UInt32 {
        func byte(_ value: Double) -> UInt32 { UInt32((min(max(value, 0), 1) * 255).rounded()) }
        // Premultiplied, as the picture is: a clear paper leaves the cell empty.
        let a = min(max(color.alpha, 0), 1)
        return byte(color.red * a) | byte(color.green * a) << 8 | byte(color.blue * a) << 16 | byte(a) << 24
    }

    /// The picture drawn `width` x `height`, as premultiplied pixels laid out as `bitmapInfo` says.
    private static func pixels(of image: CGImage, width: Int, height: Int) -> [UInt32]? {
        var pixels = [UInt32](repeating: 0, count: width * height)
        let drawn = pixels.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(
                data: bytes.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: bitmapInfo.rawValue
            ) else { return false }
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return drawn ? pixels : nil
    }
}
