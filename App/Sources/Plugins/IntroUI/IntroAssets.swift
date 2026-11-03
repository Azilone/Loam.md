import AppKit
import CoreText
import SwiftUI

/// The pictures and the music of the intro, bundled in `Resources/Brand/Intro`: seven landscapes, two cloud layers,
/// the pole, the welcome window's picture, the music and the title serif. A missing one is nil and the scene draws its
/// own stand-in, a plain sky and Loam's icon. The onboarding's cards draw Loam's own art (`OnboardingKit`); the
/// welcome card shows the first landscape.
@MainActor
final class IntroAssets {
    static let shared = IntroAssets()

    let landscapes: [NSImage]
    let clouds: [NSImage]
    let pole: NSImage?
    let welcome: NSImage?
    let music: URL?
    /// Loam's own icon, the one the Dock shows: risen at the end of the intro, and on the import card.
    var appIcon: NSImage? {
        NSApp?.applicationIconImage ?? NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath)
    }
    /// "THE SECOND BRAIN that becomes ANYTHING" and "an open-source notebook": drawn once into pictures, so the intro
    /// scales pictures instead of laying text out again every frame.
    let company: NSImage?
    let tagline: NSImage?
    /// The serif of the welcome window's titles and the wordmark; nil uses the onboarding's own.
    let titleFontName: String?

    private init() {
        func url(_ file: String) -> URL? {
            let name = (file as NSString).deletingPathExtension, ext = (file as NSString).pathExtension
            return Self.bundle?.url(forResource: name, withExtension: ext, subdirectory: "Brand/Intro")
        }
        func image(_ file: String, scale: CGFloat = 1) -> NSImage? {
            guard let url = url(file), let image = NSImage(contentsOf: url) else { return nil }
            if let rep = image.representations.first {
                image.size = NSSize(width: CGFloat(rep.pixelsWide) / scale, height: CGFloat(rep.pixelsHigh) / scale)
            }
            return image
        }
        landscapes = (1...7).compactMap { image("landscape-\($0).jpg") }
        clouds = ["clouds-1.png", "clouds-2.png"].compactMap { image($0) }
        pole = image("pole.png")
        welcome = image("welcome.png", scale: 2)
        music = url("music.m4a")
        titleFontName = url("title.ttf").flatMap(Self.registerFont)
        company = Self.lockup([
            [Run(text: "THE SECOND BRAIN")],
            [Run(text: "that becomes ", italic: true), Run(text: "ANYTHING")],
        ])
        tagline = Self.lockup([[Run(text: "an open-source notebook", italic: true)]], size: 96, thinning: 0)
    }

    /// The intro's wordmark font at `size`: the bundled serif, else the onboarding's.
    func title(size: CGFloat) -> Font {
        titleFontName.map { .custom($0, size: size) } ?? OnbType.title(size)
    }

    private static func registerFont(_ url: URL) -> String? {
        guard let descriptors = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor],
              let first = descriptors.first
        else { return nil }
        CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        return CTFontDescriptorCopyAttribute(first, kCTFontNameAttribute) as? String
    }

    /// A run of the lockup: Didot capitals, or Didot italic for the small words between them.
    struct Run {
        let text: String
        var italic = false
    }

    /// `lines` as a lockup: wide-spaced Didot, thinned a little by clearing a stroke round every letter, one line
    /// under the other, centred. A template picture, 2x, drawn white by the scene. `size` is the capitals' size.
    static func lockup(_ lines: [[Run]], size: CGFloat = 96, thinning: CGFloat = 0.5) -> NSImage? {
        let scale: CGFloat = 2
        guard let didot = NSFont(name: "Didot", size: size * scale),
              let italic = NSFont(name: "Didot-Italic", size: size * 0.92 * scale) ?? NSFont(name: "Didot", size: size * scale)
        else { return nil }
        let ctLines = lines.map { runs -> CTLine in
            let string = NSMutableAttributedString()
            for run in runs {
                string.append(NSAttributedString(string: run.text, attributes: [
                    .font: run.italic ? italic : didot, .kern: (run.italic ? 1 : 0.09 * size) * scale,
                ]))
            }
            return CTLineCreateWithAttributedString(string)
        }
        let bounds = ctLines.map { CTLineGetBoundsWithOptions($0, .useGlyphPathBounds) }
        let leading = size * 0.32 * scale
        let lineHeight = size * scale
        let pad = 6 * scale
        let width = Int(ceil((bounds.map(\.width).max() ?? 0) + pad * 2))
        let height = Int(ceil(lineHeight * CGFloat(ctLines.count) + leading * CGFloat(ctLines.count - 1) + pad * 2))
        guard width > 0, let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.setFillColor(.black)
        func draw(mode: CGTextDrawingMode) {
            context.setTextDrawingMode(mode)
            for (index, line) in ctLines.enumerated() {
                let box = bounds[index]
                // Lines from the top; baselines sit on the capitals' bottom.
                let baseline = CGFloat(height) - pad - lineHeight * CGFloat(index + 1) - leading * CGFloat(index) + size * 0.06 * scale
                context.textPosition = CGPoint(x: (CGFloat(width) - box.width) / 2 - box.minX, y: baseline)
                CTLineDraw(line, context)
            }
        }
        draw(mode: .fill)
        if thinning > 0 {
            context.setBlendMode(.clear)
            context.setLineWidth(thinning * scale)
            draw(mode: .stroke)
        }
        guard let cgImage = context.makeImage() else { return nil }
        let image = NSImage(cgImage: cgImage, size: NSSize(width: CGFloat(width) / scale, height: CGFloat(height) / scale))
        image.isTemplate = true
        return image
    }

    /// This module's resources, looked up where SwiftPM's `Bundle.module` looks (the app's resources, next to the
    /// library, the build folder) without its `fatalError` when they are missing.
    static let bundle: Bundle? = {
        let name = "LoamApp_IntroUI.bundle"
        let library = Bundle(for: IntroAssets.self)
        let places = [Bundle.main.resourceURL, library.resourceURL, Bundle.main.bundleURL, library.bundleURL.deletingLastPathComponent()]
        for case let place? in places {
            if let bundle = Bundle(url: place.appendingPathComponent(name)) { return bundle }
        }
        return nil
    }()
}
