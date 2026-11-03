import AppKit
import SwiftUI

/// Smooth value noise for the theme's halftones: their edges follow it, so they are ragged rather than straight.
public enum HalftoneNoise {
    /// A repeatable pseudo-random number in 0...1 for a pair of integers.
    public static func hash(_ x: Int, _ y: Int) -> Double {
        var h = UInt64(bitPattern: Int64(x &* 374_761_393 &+ y &* 668_265_263))
        h = (h ^ (h >> 13)) &* 1_274_126_177
        return Double((h ^ (h >> 16)) & 0xFFFF) / 65535
    }

    static func noise(_ x: Double, _ y: Double) -> Double {
        let xi = Int(floor(x)), yi = Int(floor(y))
        let xf = x - floor(x), yf = y - floor(y)
        let u = xf * xf * (3 - 2 * xf), v = yf * yf * (3 - 2 * yf)
        let a = hash(xi, yi), b = hash(xi + 1, yi), c = hash(xi, yi + 1), d = hash(xi + 1, yi + 1)
        return (a * (1 - u) + b * u) * (1 - v) + (c * (1 - u) + d * u) * v
    }

    /// Three octaves of `noise`, 0...1.
    static func fbm(_ x: Double, _ y: Double) -> Double {
        0.55 * noise(x, y) + 0.3 * noise(x * 2.1, y * 2.1) + 0.15 * noise(x * 4.3, y * 4.3)
    }

    static func smooth(_ e0: Double, _ e1: Double, _ x: Double) -> Double {
        let t = min(max((x - e0) / (e1 - e0), 0), 1)
        return t * t * (3 - 2 * t)
    }

    static let bayer: [Double] = [
        0, 32, 8, 40, 2, 34, 10, 42, 48, 16, 56, 24, 50, 18, 58, 26,
        12, 44, 4, 36, 14, 46, 6, 38, 60, 28, 52, 20, 62, 30, 54, 22,
        3, 35, 11, 43, 1, 33, 9, 41, 51, 19, 59, 27, 49, 17, 57, 25,
        15, 47, 7, 39, 13, 45, 5, 37, 63, 31, 55, 23, 61, 29, 53, 21,
    ].map { ($0 + 0.5) / 64 }
}

/// Loam's halftone: square dots of the accent, large in a corner and shrinking away from it
/// along a ragged edge, then a fringe of loose dots that thins out. It fades out well inside its frame, so it never
/// shows a straight edge. Decoration only: no clicks, skipped by VoiceOver.
public struct HalftoneCloud: View, Animatable {
    public enum Corner: Sendable { case topLeading, topTrailing, bottomLeading, bottomTrailing }

    public var corner: Corner
    /// The grid of the dots, in points.
    public var step: CGFloat
    /// Changes the pattern, so two clouds side by side differ.
    public var seed: Int
    /// The dots' colour; the accent when nil.
    public var color: Color?
    /// How far the cloud has grown out of its corner, 0 (nothing) to 1. Animating it spreads the dots from the
    /// corner, as ink soaking into paper.
    public var progress: Double
    @Environment(\.themeTokens) private var theme

    public init(corner: Corner, step: CGFloat = 3, seed: Int = 0, color: Color? = nil, progress: Double = 1) {
        self.corner = corner
        self.step = step
        self.seed = seed
        self.color = color
        self.progress = progress
    }

    nonisolated public var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    public var body: some View {
        Canvas { context, size in
            guard progress > 0.01 else { return }
            var path = Path()
            for dot in Self.dots(in: size, corner: corner, step: step, seed: seed, progress: progress) { path.addRect(dot) }
            context.fill(path, with: .color(color ?? theme.accent))
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// The shape of a cloud: seed 0 is the sidebar's; any other seed draws its own, so clouds side by side
    /// differ in outline, reach and grain, not only in where their dots fall.
    struct Shape: Equatable {
        /// 1 is a straight diagonal edge, 2 a quarter circle.
        var roundness = 1.6
        /// How far the dots reach, as a share of the frame.
        var reach = 0.78
        /// How much the noise bends the edge.
        var roughness = 0.45
        /// The size of the noise's features, per cell.
        var grain = 0.09
        /// How much of the fringe past the edge gets a dot.
        var fringe = 0.55
        /// Above 1 the cloud runs along the top or bottom side, below 1 along the left or right one.
        var stretch = 1.0

        init() {}

        init(seed: Int) {
            guard seed != 0 else { return }
            func pick(_ salt: Int) -> Double { HalftoneNoise.hash(seed &* 92_821 &+ salt, salt &* 31) }
            roundness = 1.15 + 1.1 * pick(1)
            reach = 0.62 + 0.3 * pick(2)
            roughness = 0.35 + 0.55 * pick(3)
            grain = 0.06 + 0.1 * pick(4)
            fringe = 0.35 + 0.55 * pick(5)
            stretch = 0.7 + 0.8 * pick(6)
        }
    }

    /// The dots of a cloud filling `size`.
    static func dots(in size: CGSize, corner: Corner, step: CGFloat, seed: Int, progress: Double = 1) -> [CGRect] {
        let columns = Int(size.width / step), rows = Int(size.height / step)
        guard columns > 1, rows > 1 else { return [] }
        let shape = Shape(seed: seed)
        let offset = Double(seed) * 17.3
        var dots: [CGRect] = []
        for row in 0..<rows {
            for column in 0..<columns {
                var x = (Double(column) + 0.5) / Double(columns), y = (Double(row) + 0.5) / Double(rows)
                if corner == .topTrailing || corner == .bottomTrailing { x = 1 - x }
                if corner == .bottomLeading || corner == .bottomTrailing { y = 1 - y }
                // How far from the corner, 0 there and about 1 at the far sides, on a rounded square.
                x /= sqrt(shape.stretch)
                y *= sqrt(shape.stretch)
                let distance = pow(pow(x, shape.roundness) + pow(y, shape.roundness), 1 / shape.roundness)
                let n = HalftoneNoise.fbm(Double(column) * shape.grain + 7 + offset, Double(row) * shape.grain + 3 + offset * 0.5)
                let raw = 1 - HalftoneNoise.smooth(0, shape.reach * max(progress, 0.01), distance + (n - 0.5) * shape.roughness * progress)
                let inside = HalftoneNoise.smooth(0, 0.3, 1 - distance)
                var density = raw * inside
                if density < 0.14 {
                    let fringe = HalftoneNoise.smooth(0, 0.14, raw) * inside
                    density = HalftoneNoise.hash(column &* 7 &+ seed, row &* 13) < fringe * shape.fringe ? 0.16 : 0
                }
                guard density > 0.05 else { continue }
                // Sides and origins on half points, whole pixels on a Retina screen: no blurred, uneven dots.
                // Never a full cell, so the dense corner stays a halftone rather than a solid block.
                let side = max(0.5, ((step * (0.25 + 0.5 * pow(density, 0.8))) * 2).rounded() / 2)
                let x0 = ((CGFloat(column) + 0.5) * step - side / 2) * 2, y0 = ((CGFloat(row) + 0.5) * step - side / 2) * 2
                dots.append(CGRect(x: x0.rounded() / 2, y: y0.rounded() / 2, width: side, height: side))
            }
        }
        return dots
    }
}

/// A landscape drawn in dither, the home page's footer: ridges of mountains in the accent on the page, made from
/// noise rather than a photo, dissolving into the page at its edges.
public struct DitherLandscape: View {
    /// The side of one dot, in points.
    public var dot: CGFloat
    @Environment(\.themeTokens) private var theme
    @Environment(\.colorScheme) private var colorScheme

    public init(dot: CGFloat = 1.5) {
        self.dot = dot
    }

    public var body: some View {
        GeometryReader { proxy in
            let columns = max(1, Int(proxy.size.width / dot)), rows = max(1, Int(proxy.size.height / dot))
            if let image = Self.image(columns: columns, rows: rows, ink: theme.accent, dark: colorScheme == .dark) {
                Image(decorative: image, scale: 1)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: proxy.size.width, height: proxy.size.height)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private struct Key: Hashable {
        let columns: Int, rows: Int, ink: String, dark: Bool
    }

    @MainActor private static var cache: [Key: CGImage] = [:]

    /// One pixel per dot: ink where the landscape is darker than the Bayer threshold, clear elsewhere.
    @MainActor
    static func image(columns: Int, rows: Int, ink: Color, dark: Bool) -> CGImage? {
        let resolved = NSColor(ink).usingColorSpace(.sRGB) ?? .systemBlue
        let key = Key(columns: columns, rows: rows, ink: "\(resolved)", dark: dark)
        if let known = cache[key] { return known }
        let r = UInt8(resolved.redComponent * 255), g = UInt8(resolved.greenComponent * 255), b = UInt8(resolved.blueComponent * 255)
        var pixels = [UInt8](repeating: 0, count: columns * rows * 4)
        // Ridged noise: sharp peaks, as mountains have.
        func ridge(_ x: Double, _ seed: Double) -> Double {
            let n = HalftoneNoise.fbm(x, seed)
            return 1 - abs(2 * n - 1)
        }
        for column in 0..<columns {
            let x = Double(column) / Double(columns)
            // Four ridges, far to near: the height of each crest from the top (0...1). Nearer ones are lower on
            // the page and climb to the right, as in a valley seen from its side.
            let crests = [
                0.40 - 0.32 * ridge(x * 2.2 + 11, 0.5) + 0.04 * x,
                0.56 - 0.30 * ridge(x * 3.0 + 3, 1.5) - 0.12 * x,
                0.72 - 0.26 * ridge(x * 3.8 + 7, 2.5) - 0.26 * pow(x, 1.5),
                0.90 - 0.14 * ridge(x * 5.0 + 1, 3.5) - 0.10 * x,
            ]
            // How dark each ridge is at its crest: the far ones pale with the haze.
            let tones = [0.30, 0.48, 0.70, 0.92]
            for row in 0..<rows {
                let y = Double(row) / Double(rows)
                // The nearest ridge whose crest is above this point; nothing above the farthest: sky.
                var ink = 0.0
                for layer in stride(from: crests.count - 1, through: 0, by: -1) where y >= crests[layer] {
                    // Dark at the crest, paling into the mist of the valley below it.
                    let depth = (y - crests[layer]) / 0.16
                    ink = tones[layer] * (1 - 0.55 * min(depth, 1))
                    break
                }
                let grain = HalftoneNoise.fbm(Double(column) * 0.11, Double(row) * 0.11)
                ink = max(0, ink + (grain - 0.5) * 0.12 * (ink > 0 ? 1 : 0))
                // Dissolves into the page at the edges.
                let edge = min(x, 1 - x, y * 1.4, (1 - y) * 3)
                let n = HalftoneNoise.fbm(Double(column) * 0.05 + 5, Double(row) * 0.05 + 9)
                ink *= HalftoneNoise.smooth(0, 0.14, edge + (n - 0.5) * 0.12)
                // The Bayer matrix alone draws regular rows where the ink is thin; a little noise in the threshold
                // breaks them up, as the grain of a print does.
                let threshold = 0.65 * HalftoneNoise.bayer[(row % 8) * 8 + column % 8] + 0.35 * HalftoneNoise.hash(column, row &+ 101)
                guard ink > 0.03, ink > threshold else { continue }
                let i = (row * columns + column) * 4
                pixels[i] = r; pixels[i + 1] = g; pixels[i + 2] = b; pixels[i + 3] = 255
            }
        }
        let data = Data(pixels)
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        let image = CGImage(
            width: columns, height: rows, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: columns * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        )
        if cache.count > 8 { cache.removeAll() }
        cache[key] = image
        return image
    }
}
