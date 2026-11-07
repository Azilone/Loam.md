import AppKit
import CoreText
import PluginKitUI
import SwiftUI

/// The curve from a topic's parent (or the topic before it on a timeline) to the topic, in the map's own
/// coordinates: the canvas strokes it in shape layers, a picture of the map (`MindmapSketch`) with Core Graphics.
struct MindmapEdgeCurve: Sendable {
    var from, c1, c2, to: CGPoint
    var width: CGFloat

    init?(_ topic: MindmapSceneTopic) {
        guard let parent = topic.source else { return nil }
        self.init(child: topic.placement, source: parent)
    }

    /// Between two placements: the canvas gives those its layers show while they move.
    init(child: MindmapPlacement, source parent: MindmapPlacement) {
        let a = Self.anchor(parent, side: child.fromSide, outgoing: true)
        let b = Self.anchor(child, side: child.toSide, outgoing: false)
        let dx = abs(b.x - a.x)
        let dy = abs(b.y - a.y)
        func control(_ point: CGPoint, _ side: MindmapPlacement.Side) -> CGPoint {
            switch side {
            case .left: CGPoint(x: point.x - dx / 2, y: point.y)
            case .right: CGPoint(x: point.x + dx / 2, y: point.y)
            case .top: CGPoint(x: point.x, y: point.y - max(dy * 0.8, 12))
            case .bottom: CGPoint(x: point.x, y: point.y + max(dy * 0.8, 12))
            }
        }
        from = a
        c1 = control(a, child.fromSide)
        c2 = control(b, child.toSide)
        to = b
        width = child.depth == 1 ? 3 : child.depth == 2 ? 2 : 1.5
    }

    /// Where an edge meets a topic: under a boxed topic's edge, on an underlined topic's line.
    private static func anchor(_ p: MindmapPlacement, side: MindmapPlacement.Side, outgoing: Bool) -> CGPoint {
        let inset: CGFloat = p.depth == 0 ? (outgoing ? 12 : 0) : p.depth == 1 ? 3 : 0
        let y = p.depth >= 2 ? p.frame.maxY - 1 : p.frame.midY
        switch side {
        case .left: return CGPoint(x: p.frame.minX + inset, y: y)
        case .right: return CGPoint(x: p.frame.maxX - inset, y: y)
        case .top: return CGPoint(x: p.frame.midX, y: p.frame.minY + inset)
        case .bottom: return CGPoint(x: p.frame.midX, y: p.frame.maxY - inset)
        }
    }
}

/// The pictures of maps, by note, change of the map and appearance; dropped first when memory runs short. A map shown
/// in another view while it is not in use (a card of a folder page, a board's card before it is entered) shows one:
/// live, every topic was a view that a scroll or a sidebar's slide moved on every frame.
@MainActor
final class MindmapPictures {
    static let shared = MindmapPictures()

    struct Key: Hashable {
        let path: String
        let revision: Int
        let dark: Bool
    }

    private let cache: NSCache<NSString, CGImage> = {
        let cache = NSCache<NSString, CGImage>()
        cache.totalCostLimit = 150_000_000
        return cache
    }()

    func image(for key: Key) -> CGImage? { cache.object(forKey: Self.name(key)) }

    func store(_ image: CGImage, for key: Key) {
        cache.setObject(image, forKey: Self.name(key), cost: image.bytesPerRow * image.height)
    }

    private static func name(_ key: Key) -> NSString { "\(key.path)|\(key.revision)|\(key.dark)" as NSString }
}

/// What a picture of a map needs, taken from the model on the main thread, then drawn with Core Graphics on any
/// thread: the topics' boxes and texts as the canvas draws them (`MindmapTopicArt`), and the edges.
struct MindmapSketch: @unchecked Sendable {
    struct Topic {
        let frame: CGRect
        let depth: Int
        let color: CGColor
        let text: String
    }

    struct Edge {
        let curve: MindmapEdgeCurve
        let color: CGColor
    }

    /// In points: the map with the room an embedded map keeps around it.
    let size: CGSize
    private let origin: CGPoint
    private let topics: [Topic]
    private let edges: [Edge]
    private let accent: CGColor
    private let background: CGColor
    private let text: CGColor
    private let dark: Bool
    /// Pixels per point: twice, unless the map is so big that the picture would pass `maxPixels` on a side.
    private let scale: CGFloat
    static let maxPixels: CGFloat = 2400

    @MainActor init?(model: MindmapTabModel, theme: ThemeTokens, dark: Bool) {
        let bounds = MindmapLayout.bounds(model.placements)
        guard !bounds.isNull else { return nil }
        let padded = bounds.insetBy(dx: -MindmapTabModel.contentPadding, dy: -MindmapTabModel.contentPadding)
        size = padded.size
        origin = padded.origin
        scale = min(2, Self.maxPixels / max(padded.width, padded.height, 1))
        self.dark = dark
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        func resolved(_ color: Color) -> CGColor {
            var result = NSColor(color).cgColor
            appearance?.performAsCurrentDrawingAppearance { result = NSColor(color).cgColor }
            return result
        }
        accent = resolved(theme.accent)
        background = resolved(theme.background)
        text = resolved(theme.text)
        let accentColor = theme.accent
        topics = model.scene.map { item in
            Topic(
                frame: item.placement.frame, depth: item.placement.depth,
                color: resolved(MindmapStyle.color(branch: item.placement.branch, accent: accentColor)),
                text: MindmapStyle.plain(item.text)
            )
        }
        edges = model.scene.compactMap { item in
            MindmapEdgeCurve(item).map {
                Edge(curve: $0, color: resolved(MindmapStyle.color(branch: item.placement.branch, accent: accentColor)))
            }
        }
    }

    /// The picture, drawn from the top left as the map is (y going down).
    func draw() -> CGImage? {
        let width = Int(ceil(size.width * scale)), height = Int(ceil(size.height * scale))
        guard width > 0, height > 0, let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        // Map coordinates, y down, as the layout's frames are.
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: scale, y: -scale)
        context.translateBy(x: -origin.x, y: -origin.y)
        context.setLineCap(.round)
        for edge in edges {
            context.setStrokeColor(edge.color)
            context.setLineWidth(edge.curve.width)
            context.move(to: edge.curve.from)
            context.addCurve(to: edge.curve.to, control1: edge.curve.c1, control2: edge.curve.c2)
            context.strokePath()
        }
        for topic in topics { drawTopic(topic, in: context) }
        return context.makeImage()
    }

    private func drawTopic(_ topic: Topic, in context: CGContext) {
        let frame = topic.frame
        switch topic.depth {
        case 0:
            let path = CGPath(roundedRect: frame, cornerWidth: 15, cornerHeight: 15, transform: nil)
            context.addPath(path)
            context.setFillColor(accent)
            context.fillPath()
        case 1:
            let path = CGPath(roundedRect: frame, cornerWidth: 10, cornerHeight: 10, transform: nil)
            context.addPath(path)
            context.setFillColor(background)
            context.fillPath()
            context.addPath(path)
            context.setFillColor(topic.color.copy(alpha: dark ? 0.22 : 0.13) ?? topic.color)
            context.fillPath()
            let ring = CGPath(roundedRect: frame.insetBy(dx: 0.75, dy: 0.75), cornerWidth: 9.25, cornerHeight: 9.25,
                              transform: nil)
            context.addPath(ring)
            context.setStrokeColor(topic.color.copy(alpha: 0.55) ?? topic.color)
            context.setLineWidth(1.5)
            context.strokePath()
        default:
            context.setFillColor(topic.color)
            context.fill(CGRect(x: frame.minX, y: frame.maxY - 2, width: frame.width, height: 2))
        }
        drawText(topic, in: context)
    }

    /// The topic's text in its box less the padding, as `MindmapTopicArt` lays it out.
    private func drawText(_ topic: Topic, in context: CGContext) {
        guard !topic.text.isEmpty else { return }
        let padding = MindmapStyle.padding(depth: topic.depth)
        let box = CGRect(
            x: topic.frame.minX + padding.leading, y: topic.frame.minY + padding.top,
            width: topic.frame.width - padding.leading - padding.trailing + 4,
            height: topic.frame.height - padding.top - padding.bottom + 2
        )
        let font = MindmapStyle.font(depth: topic.depth) as CTFont
        let color = topic.depth == 0 ? CGColor(gray: 1, alpha: 1) : text
        let string = NSAttributedString(string: topic.text, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
        ])
        let framesetter = CTFramesetterCreateWithAttributedString(string)
        // Core Text lays out with y up: flip around the box.
        context.saveGState()
        context.translateBy(x: box.minX, y: box.maxY)
        context.scaleBy(x: 1, y: -1)
        let frame = CTFramesetterCreateFrame(
            framesetter, CFRange(location: 0, length: string.length),
            CGPath(rect: CGRect(origin: .zero, size: box.size), transform: nil), nil
        )
        CTFrameDraw(frame, context)
        context.restoreGState()
    }
}
