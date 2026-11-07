import AppKit
import PluginKitUI
import SwiftUI

/// The colours a map is drawn with, resolved for one appearance: what the drawing off the main thread needs.
struct MindmapPalette: Equatable, @unchecked Sendable {
    let accent: CGColor
    let background: CGColor
    let text: CGColor
    let secondaryText: CGColor
    let dark: Bool
    /// The branch colours, in `MindmapStyle.branchColors` order.
    let branches: [CGColor]
    /// The window's colour space: Core Animation shows a bitmap in it as it is, any other converted pixel by pixel
    /// when committed.
    let space: CGColorSpace

    @MainActor init(theme: ThemeTokens, appearance: NSAppearance, space: CGColorSpace?) {
        var accent = CGColor(gray: 0, alpha: 1), background = accent, text = accent, secondary = accent
        var branches: [CGColor] = []
        appearance.performAsCurrentDrawingAppearance {
            accent = NSColor(theme.accent).cgColor
            background = NSColor(theme.background).cgColor
            text = NSColor(theme.text).cgColor
            secondary = NSColor(theme.secondaryText).cgColor
            branches = MindmapStyle.branchColors.map { NSColor($0).cgColor }
        }
        self.accent = accent
        self.background = background
        self.text = text
        secondaryText = secondary
        self.branches = branches
        dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        self.space = space ?? CGColorSpace(name: CGColorSpace.sRGB)!
    }

    func color(branch: Int) -> CGColor {
        branch < 0 ? accent : branches[branch % branches.count]
    }
}

/// How one topic's body looks (`MindmapTopicArt.draw`): a filled pill for the central topic, a tinted box for main
/// branches, text on a coloured underline below them. The selection ring, the hover tint and the fold toggle are
/// layers of their own, so selecting or hovering draws nothing again.
struct MindmapTopicLook: Hashable, @unchecked Sendable {
    let text: String
    /// 0, 1, or 2 for every deeper level: they look the same.
    let depth: Int
    let size: CGSize
    let branch: Int
    /// Being edited: the text field draws the text.
    let hidesText: Bool
    let palette: Int
    /// Pixels per point.
    let scale: CGFloat

    /// Room round the body for the central topic's shadow.
    var margin: CGFloat { depth == 0 ? 30 : 0 }
}

/// Draws topic bodies into bitmaps, on any thread, and keeps them by look.
final class MindmapTopicArt: @unchecked Sendable {
    static let shared = MindmapTopicArt()

    private let lock = NSLock()
    private let cache: NSCache<NSString, CGImage> = {
        let cache = NSCache<NSString, CGImage>()
        cache.totalCostLimit = 120_000_000
        return cache
    }()
    private var palettes: [MindmapPalette] = []

    /// A number for a palette, so looks stay small and hashable.
    func index(of palette: MindmapPalette) -> Int {
        lock.lock()
        defer { lock.unlock() }
        if let index = palettes.firstIndex(of: palette) { return index }
        palettes.append(palette)
        return palettes.count - 1
    }

    private func palette(_ index: Int) -> MindmapPalette {
        lock.lock()
        defer { lock.unlock() }
        return palettes[index]
    }

    func cached(_ look: MindmapTopicLook) -> CGImage? { cache.object(forKey: Self.key(look)) }

    /// The body's bitmap: from the cache, or drawn now on the calling thread.
    func image(_ look: MindmapTopicLook) -> CGImage? {
        if let known = cached(look) { return known }
        guard let image = draw(look) else { return nil }
        cache.setObject(image, forKey: Self.key(look), cost: image.bytesPerRow * image.height)
        return image
    }

    /// Draws the looks not cached yet, on every core, and returns them all by look.
    func images(_ looks: [MindmapTopicLook]) -> [MindmapTopicLook: CGImage] {
        let missing = Array(Set(looks.filter { cached($0) == nil }))
        if !missing.isEmpty {
            DispatchQueue.concurrentPerform(iterations: missing.count) { i in _ = image(missing[i]) }
        }
        var result: [MindmapTopicLook: CGImage] = [:]
        for look in looks { if let image = cached(look) ?? image(look) { result[look] = image } }
        return result
    }

    private static func key(_ look: MindmapTopicLook) -> NSString {
        "\(look.palette)|\(look.depth)|\(look.branch)|\(look.hidesText)|\(look.scale)|\(look.size.width)x\(look.size.height)|\(look.text)" as NSString
    }

    // MARK: - Drawing

    private func draw(_ look: MindmapTopicLook) -> CGImage? {
        let palette = palette(look.palette)
        let margin = look.margin
        let width = Int(ceil((look.size.width + margin * 2) * look.scale))
        let height = Int(ceil((look.size.height + margin * 2) * look.scale))
        guard width > 0, height > 0, width * height < 40_000_000,
              let context = CGContext(
                  data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: palette.space,
                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
              ) else { return nil }
        // Points, y down, the body's top left at (0, 0).
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: look.scale, y: -look.scale)
        context.translateBy(x: margin, y: margin)
        let frame = CGRect(origin: .zero, size: look.size)
        let branch = palette.color(branch: look.branch)
        switch look.depth {
        case 0: drawCentral(frame, palette, scale: look.scale, context)
        case 1: drawMain(frame, branch, palette, context)
        default:
            context.setFillColor(branch)
            context.fill(CGRect(x: 0, y: frame.maxY - 2, width: frame.width, height: 2))
        }
        if !look.hidesText { drawText(look, in: frame, palette, context) }
        return context.makeImage()
    }

    private func roundedPath(_ rect: CGRect, _ radius: CGFloat) -> CGPath {
        Path(roundedRect: rect, cornerRadius: max(0, min(Corners.r(radius), rect.width / 2, rect.height / 2)),
             style: .continuous).cgPath
    }

    /// Ink on paper: the accent, a shade lighter toward the top left, a fine grain of light, a halftone cloud in
    /// the bottom right, a lit top edge and a soft shadow of the accent.
    private func drawCentral(_ frame: CGRect, _ palette: MindmapPalette, scale: CGFloat, _ context: CGContext) {
        let path = roundedPath(frame, 15)
        let accent = NSColor(cgColor: palette.accent) ?? .controlAccentColor
        // The shadows: under the filled shape, drawn by filling it once per shadow. A shadow's offset and blur are in
        // pixels, y up.
        context.saveGState()
        context.setShadow(offset: CGSize(width: 0, height: -6 * scale), blur: 14 * scale,
                          color: palette.accent.copy(alpha: 0.22))
        context.addPath(path)
        context.setFillColor(palette.accent)
        context.fillPath()
        context.restoreGState()
        context.saveGState()
        context.setShadow(offset: CGSize(width: 0, height: -1 * scale), blur: 1 * scale,
                          color: palette.accent.copy(alpha: 0.18))
        context.addPath(path)
        context.setFillColor(palette.accent)
        context.fillPath()
        context.restoreGState()

        context.saveGState()
        context.addPath(path)
        context.clip()
        let colors = [accent.blended(withFraction: 0.14, of: .white) ?? accent, accent,
                      accent.blended(withFraction: 0.12, of: .black) ?? accent].map(\.cgColor) as CFArray
        if let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.displayP3), colors: colors,
                                     locations: [0, 0.5, 1]) {
            context.drawLinearGradient(gradient, start: CGPoint(x: frame.minX, y: frame.minY),
                                       end: CGPoint(x: frame.maxX, y: frame.maxY), options: [])
        }
        Self.grain(in: frame, color: CGColor(gray: 1, alpha: 0.16), seed: 3, context)
        Self.halftone(in: frame, color: CGColor(gray: 1, alpha: 0.22), context)
        // The lit top edge: a white line fading out by the middle.
        context.addPath(roundedPath(frame.insetBy(dx: 0.5, dy: 0.5), 14.5))
        context.setLineWidth(1)
        context.replacePathWithStrokedPath()
        context.clip()
        if let lit = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                                colors: [CGColor(gray: 1, alpha: 0.4), CGColor(gray: 1, alpha: 0)] as CFArray,
                                locations: [0, 1]) {
            context.drawLinearGradient(lit, start: CGPoint(x: 0, y: frame.minY), end: CGPoint(x: 0, y: frame.midY),
                                       options: [])
        }
        context.restoreGState()
    }

    /// A tint of the branch's colour, fading down, with a grain of it: a pastel print rather than a flat fill.
    private func drawMain(_ frame: CGRect, _ branch: CGColor, _ palette: MindmapPalette, _ context: CGContext) {
        let path = roundedPath(frame, 10)
        context.saveGState()
        context.addPath(path)
        context.setFillColor(palette.background)
        context.fillPath()
        context.addPath(path)
        context.clip()
        let top = branch.copy(alpha: palette.dark ? 0.26 : 0.15) ?? branch
        let bottom = branch.copy(alpha: palette.dark ? 0.14 : 0.07) ?? branch
        if let gradient = CGGradient(colorsSpace: branch.colorSpace, colors: [top, bottom] as CFArray, locations: [0, 1]) {
            context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: frame.minY), end: CGPoint(x: 0, y: frame.maxY),
                                       options: [])
        }
        Self.grain(in: frame, color: branch.copy(alpha: 0.22) ?? branch, seed: 12, context)
        context.restoreGState()
        context.addPath(roundedPath(frame.insetBy(dx: 0.5, dy: 0.5), 9.5))
        context.setStrokeColor(branch.copy(alpha: 0.45) ?? branch)
        context.setLineWidth(1)
        context.strokePath()
    }

    /// Tiny dots at random places, the same on every draw, as the grain of printed paper.
    static func grain(in frame: CGRect, color: CGColor, seed: Int, _ context: CGContext) {
        let count = Int(frame.width * frame.height / 14)
        context.setFillColor(color)
        for i in 0..<count {
            let x = HalftoneNoise.hash(i &* 3 &+ seed, seed) * frame.width
            let y = HalftoneNoise.hash(i &* 7 &+ seed, seed &+ 1) * frame.height
            let r = 0.35 + 0.35 * HalftoneNoise.hash(i, seed &+ 2)
            context.addEllipse(in: CGRect(x: frame.minX + x - r, y: frame.minY + y - r, width: 2 * r, height: 2 * r))
        }
        context.fillPath()
    }

    /// The central topic's halftone cloud in its bottom right corner (`HalftoneCloud`, step 2, seed 9), drawn once
    /// per size by SwiftUI on the main thread and kept (`MindmapTopicArt.prepareHalftone`).
    static func halftone(in frame: CGRect, color: CGColor, _ context: CGContext) {
        guard let dots = halftoneDots(frame.size) else { return }
        context.saveGState()
        context.translateBy(x: frame.minX, y: frame.minY)
        context.setFillColor(color)
        context.addPath(dots)
        context.fillPath()
        context.restoreGState()
    }

    private static let halftoneLock = NSLock()
    nonisolated(unsafe) private static var halftones: [CGSize: CGPath] = [:]

    private static func halftoneDots(_ size: CGSize) -> CGPath? {
        halftoneLock.lock()
        defer { halftoneLock.unlock() }
        return halftones[size]
    }

    /// The cloud's dots for a central topic of `size`, read from the SwiftUI view that draws them (its dots are not
    /// public): a picture of it in pure white, turned into a path of the lit pixels.
    @MainActor static func prepareHalftone(_ size: CGSize) {
        guard halftoneDots(size) == nil, size.width > 0, size.height > 0 else { return }
        let renderer = ImageRenderer(content: HalftoneCloud(corner: .bottomTrailing, step: 2, seed: 9, color: .white)
            .frame(width: size.width, height: size.height))
        renderer.scale = 2
        let path = CGMutablePath()
        if let image = renderer.cgImage, let data = image.dataProvider?.data, let bytes = CFDataGetBytePtr(data) {
            let perRow = image.bytesPerRow, perPixel = image.bitsPerPixel / 8
            let alpha = image.alphaInfo
            let alphaOffset = alpha == .premultipliedFirst || alpha == .first ? 0 : perPixel - 1
            for y in 0..<image.height {
                var x = 0
                while x < image.width {
                    guard bytes[y * perRow + x * perPixel + alphaOffset] > 127 else { x += 1; continue }
                    let start = x
                    while x < image.width, bytes[y * perRow + x * perPixel + alphaOffset] > 127 { x += 1 }
                    path.addRect(CGRect(x: CGFloat(start) / 2, y: CGFloat(y) / 2, width: CGFloat(x - start) / 2, height: 0.5))
                }
            }
        }
        halftoneLock.lock()
        halftones[size] = path
        halftoneLock.unlock()
    }

    /// The text in the box less the padding: centred in the boxed topics, from the line's start below them.
    private func drawText(_ look: MindmapTopicLook, in frame: CGRect, _ palette: MindmapPalette, _ context: CGContext) {
        let string = MindmapStyle.drawnText(look.text, depth: look.depth,
                                            color: look.depth == 0 ? CGColor(gray: 1, alpha: 1) : palette.text)
        let padding = MindmapStyle.padding(depth: look.depth)
        // The measured width has 4 points of slack (`MindmapStyle.size`): centred text keeps it on both sides.
        let box = CGRect(x: padding.leading - (look.depth <= 1 ? 2 : 0), y: padding.top,
                         width: frame.width - padding.leading - padding.trailing + 4,
                         height: frame.height - padding.top - padding.bottom)
        let options: NSString.DrawingOptions = [.usesLineFragmentOrigin, .usesFontLeading]
        let measured = string.boundingRect(with: CGSize(width: box.width, height: 10_000), options: options)
        let rect = CGRect(x: box.minX, y: box.midY - ceil(measured.height) / 2, width: box.width, height: ceil(measured.height) + 2)
        NSGraphicsContext.saveGraphicsState()
        // The context's y already goes down: flipped, so the text is drawn upright.
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        string.draw(with: rect, options: options)
        NSGraphicsContext.restoreGraphicsState()
    }
}

extension MindmapStyle {
    /// A topic's text as drawn: its inline Markdown (bold, italics, code, strikethrough) in the depth's font, the
    /// placeholder "Topic" when empty.
    static func drawnText(_ text: String, depth: Int, color: CGColor) -> NSAttributedString {
        let font = font(depth: depth)
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = depth <= 1 ? .center : .left
        paragraph.lineBreakMode = .byWordWrapping
        let nsColor = NSColor(cgColor: color) ?? .labelColor
        guard !text.isEmpty else {
            return NSAttributedString(string: "Topic", attributes: [
                .font: font, .foregroundColor: nsColor.withAlphaComponent(0.45), .paragraphStyle: paragraph,
            ])
        }
        let result = NSMutableAttributedString()
        let parsed = attributed(text)
        for run in parsed.runs {
            let piece = String(parsed[run.range].characters)
            var runFont = font
            var attributes: [NSAttributedString.Key: Any] = [.foregroundColor: nsColor, .paragraphStyle: paragraph]
            if let intent = run.inlinePresentationIntent {
                if intent.contains(.code) {
                    runFont = .monospacedSystemFont(ofSize: font.pointSize * 0.92, weight: .regular)
                }
                var traits: NSFontDescriptor.SymbolicTraits = []
                if intent.contains(.stronglyEmphasized) { traits.insert(.bold) }
                if intent.contains(.emphasized) { traits.insert(.italic) }
                if !traits.isEmpty {
                    let descriptor = runFont.fontDescriptor.withSymbolicTraits(runFont.fontDescriptor.symbolicTraits.union(traits))
                    runFont = NSFont(descriptor: descriptor, size: runFont.pointSize) ?? runFont
                }
                if intent.contains(.strikethrough) { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            }
            attributes[.font] = runFont
            result.append(NSAttributedString(string: piece, attributes: attributes))
        }
        return result
    }
}

// MARK: - Edges

extension MindmapEdgeCurve {
    /// The point at `t` of the curve and the two halves it cuts it into (de Casteljau).
    func split(at t: CGFloat) -> (MindmapEdgeCurve, MindmapEdgeCurve) {
        func lerp(_ a: CGPoint, _ b: CGPoint) -> CGPoint { CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t) }
        let ab = lerp(from, c1), bc = lerp(c1, c2), cd = lerp(c2, to)
        let abc = lerp(ab, bc), bcd = lerp(bc, cd)
        let mid = lerp(abc, bcd)
        var first = self, second = self
        first.c1 = ab; first.c2 = abc; first.to = mid
        second.from = mid; second.c1 = bcd; second.c2 = cd
        return (first, second)
    }

    /// The curve cut into `count` pieces of equal parameter, from the parent's end.
    func pieces(_ count: Int) -> [MindmapEdgeCurve] {
        var result: [MindmapEdgeCurve] = []
        var rest = self
        for i in 0..<(count - 1) {
            let (head, tail) = rest.split(at: 1 / CGFloat(count - i))
            result.append(head)
            rest = tail
        }
        result.append(rest)
        return result
    }
}
