import AppKit
import CanvasPlugin
import PluginKitUI
import QuartzCore

/// A layer whose property changes never animate by themselves: the board moves its layers at each event, and an
/// implicit quarter-second animation would make them trail the hand. Explicit animations (`add(_:forKey:)`) still run.
class QuietLayer: CALayer {
    override init() { super.init() }
    override init(layer: Any) { super.init(layer: layer) }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override func action(forKey event: String) -> (any CAAction)? { nil }
}

final class QuietShapeLayer: CAShapeLayer {
    override init() { super.init() }
    override init(layer: Any) { super.init(layer: layer) }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override func action(forKey event: String) -> (any CAAction)? { nil }
}

final class QuietGradientLayer: CAGradientLayer {
    override init() { super.init() }
    override init(layer: Any) { super.init(layer: layer) }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override func action(forKey event: String) -> (any CAAction)? { nil }
}

/// What an item's bitmap shows: drawn again when any of it changes.
struct BoardRenderKey: Equatable {
    var node: CanvasNode
    var size: CGSize
    var version: Int
    var mode: Mode
    /// The zoom it is drawn for, in steps of 15 %: edges and far-out titles are sized for the screen.
    var scaleStep: Int
    var palette: BoardPalette

    enum Mode: Equatable { case near, far, editing, live }
}

/// Springs as Core Animation plays them, from `Motion`'s tokens; under Reduce Motion a short fade's ease.
enum BoardSprings {
    static func animation(_ keyPath: String, _ spring: Motion.Spring, from: Any?, to: Any?, additive: Bool = false) -> CAAnimation {
        if Motion.reduceMotion {
            let fade = CABasicAnimation(keyPath: keyPath)
            fade.fromValue = from
            fade.toValue = to
            fade.duration = 0.12
            fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
            fade.isAdditive = additive
            return fade
        }
        let animation = CASpringAnimation(perceptualDuration: spring.duration, bounce: spring.bounce)
        animation.keyPath = keyPath
        animation.fromValue = from
        animation.toValue = to
        animation.duration = animation.settlingDuration
        animation.isAdditive = additive
        return animation
    }

    static func fade(_ layer: CALayer, to opacity: Float, duration: Double = 0.18) {
        let from = layer.presentation()?.opacity ?? layer.opacity
        layer.opacity = opacity
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = from
        fade.toValue = opacity
        fade.duration = Motion.reduceMotion ? 0.12 : duration
        fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.add(fade, forKey: "fade")
    }
}

/// One card, shape, picture, table or drawing of a board: its bitmap (`BoardDrawing`) in board units, placed by the
/// board's world layer, with its shadow, its selection ring and its hover outline as layers of their own.
final class BoardItemLayer: QuietLayer {
    var id = ""
    /// What the contents show, and what is being drawn for them.
    var shown: BoardRenderKey?
    var drawing: BoardRenderKey?
    /// Asked again while a drawing was being made: drawn once that one is in.
    var redraw = false
    let ring = QuietShapeLayer()
    let outline = QuietShapeLayer()
    private(set) var specular: QuietGradientLayer?
    var isLifted = false

    override init() {
        super.init()
        contentsGravity = .resize
        ring.fillColor = nil
        ring.opacity = 0
        ring.shadowOpacity = 1
        ring.shadowOffset = .zero
        outline.fillColor = nil
        outline.opacity = 0
        addSublayer(ring)
        addSublayer(outline)
    }

    override init(layer: Any) { super.init(layer: layer) }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// The light on the card under the pointer: a soft glow following it, a brighter rim on its side.
    func showSpecular(at point: CGPoint?, path: CGPath?, dark: Bool) {
        guard let point, let path else {
            if let specular { BoardSprings.fade(specular, to: 0) }
            return
        }
        let layer: QuietGradientLayer
        if let specular { layer = specular } else {
            layer = QuietGradientLayer()
            layer.type = .radial
            layer.opacity = 0
            let mask = QuietShapeLayer()
            layer.mask = mask
            insertSublayer(layer, below: ring)
            specular = layer
        }
        layer.frame = bounds
        (layer.mask as? CAShapeLayer)?.frame = bounds
        (layer.mask as? CAShapeLayer)?.path = path
        layer.colors = [NSColor.white.withAlphaComponent(dark ? 0.12 : 0.55).cgColor, NSColor.white.withAlphaComponent(0).cgColor]
        let reach = max(bounds.width, bounds.height) * 0.65
        let start = CGPoint(x: point.x / max(bounds.width, 1), y: point.y / max(bounds.height, 1))
        layer.startPoint = start
        layer.endPoint = CGPoint(x: start.x + reach / max(bounds.width, 1), y: start.y + reach / max(bounds.height, 1))
        if layer.opacity < 1 { BoardSprings.fade(layer, to: 1) }
    }
}

/// A group or a frame: a tinted area (a page of paper for a frame) under its cards, its label above it.
final class BoardGroupLayer: QuietLayer {
    var id = ""
    let body = QuietShapeLayer()
    let label = QuietLayer()
    var labelKey: String?

    override init() {
        super.init()
        addSublayer(body)
        label.contentsGravity = .resize
        addSublayer(label)
    }

    override init(layer: Any) { super.init(layer: layer) }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

// MARK: - Reading items on the main thread

@MainActor
extension BoardModel {
    /// What an item's drawing needs now. `mode` is how it is shown.
    func spec(of node: CanvasNode, frame: CanvasRect, mode: BoardRenderKey.Mode, scale: CGFloat) -> BoardItemSpec {
        let size = CGSize(width: frame.width, height: frame.height)
        let isText = node.kind == .text
        var spec = BoardItemSpec(
            content: .editing, size: size, shape: isText ? node.shape : nil,
            radius: node.isSticky ? 4 : node.isFreeText ? 6 : BoardStyle.cornerRadius,
            tint: BoardStyle.nsColor(node.color), border: isBare(node) ? .invisible : node.border,
            invisible: node.border == .invisible || isBare(node) || node.isDrawing, sticky: node.isSticky,
            paper: isText ? 0.92 : 0.7
        )
        if let ink = store.ink(node), mode != .far {
            var shown = ink
            var natural = CGSize(width: node.width, height: node.height)
            if let ends = lineEnds(of: node), !shown.strokes.isEmpty {
                // Drawn in the frame that spans both ends (`drawnFrame`), one unit a point.
                let origin = CGPoint(x: frame.x - node.x, y: frame.y - node.y)
                if lineEnd?.id == node.id {
                    let sx = node.width / max(natural.width, 1)
                    shown = shown.scaledBy(sx, sx)
                    natural = size
                }
                shown.strokes[0].points = [CanvasPoint(x: ends.0.x - node.x - origin.x, y: ends.0.y - node.y - origin.y),
                                           CanvasPoint(x: ends.1.x - node.x - origin.x, y: ends.1.y - node.y - origin.y)]
            }
            spec.content = .ink(shown, natural: natural)
            return spec
        }
        switch mode {
        case .editing:
            spec.content = .editing
        case .live:
            let file = node.file ?? ""
            let type = store.embeddedViewType(for: file) ?? store.mediaViewType(for: file)
            spec.content = .live(title: CardFile.title(of: file), symbol: type?.symbol ?? "doc.text", bare: isBare(node))
        case .far:
            spec.content = .far(farSpec(of: node, frame: frame, scale: scale))
        case .near:
            spec.content = nearContent(of: node, frame: frame)
        }
        return spec
    }

    /// Where an item is drawn: its frame, or for a line whose end is dragged, the frame spanning both ends.
    func drawnFrame(of node: CanvasNode) -> CanvasRect {
        let frame = frame(of: node)
        guard lineEnd?.id == node.id, let ends = lineEnds(of: node) else { return frame }
        let margin = CanvasInk.headSize(node.drawing?.strokes.first?.width ?? 2) + 8
        let area = CGRect(frame).union(CGRect(x: min(ends.0.x, ends.1.x), y: min(ends.0.y, ends.1.y),
                                              width: abs(ends.1.x - ends.0.x), height: abs(ends.1.y - ends.0.y)))
            .insetBy(dx: -margin, dy: -margin)
        return CanvasRect(area)
    }

    private func farSpec(of node: CanvasNode, frame: CanvasRect, scale: CGFloat) -> BoardItemSpec.FarSpec {
        var picture: URL?
        if node.kind == .file, let file = node.file, CardFile.kind(of: file) == .image {
            picture = store.vault.rootURL.appendingPathComponent(file)
        }
        let heading = BoardFarText.headingScale(node.text)
        return BoardItemSpec.FarSpec(
            title: !node.isTable && !node.isDrawing && picture == nil ? store.title(of: node) : "",
            picture: picture, table: node.isTable, ink: store.ink(node),
            natural: CGSize(width: node.width, height: node.height),
            textSize: node.isFreeText ? CGFloat(node.effectiveFontSize) * heading : nil,
            textBold: heading > 1, centred: node.kind == .text && node.centresText
        )
    }

    private func nearContent(of node: CanvasNode, frame: CanvasRect) -> BoardItemSpec.Content {
        switch node.kind {
        case .text:
            if node.isTable, let table = node.table,
               let layout = store.tableLayout(node.text ?? "", fontSize: node.effectiveFontSize) {
                return .table(table, layout, fontSize: CGFloat(node.effectiveFontSize))
            }
            var shown = node
            // A label card being resized: its text follows the size, live.
            if resizing?.id == node.id, !node.isFreeText, let size = scaledFontSize(of: node, in: frame) { shown.fontSize = size }
            let text = shown.text ?? ""
            let inner = (shown.shape ?? .rectangle).textRect(in: CanvasRect(x: 0, y: 0, width: frame.width, height: frame.height))
            let free = shown.isFreeText
            let fontSize = CGFloat(shown.effectiveFontSize) * (free && resizing?.id == node.id ? frame.height / max(node.height, 1) : 1)
            let needed = free ? 0 : store.textHeight(text, fontSize: shown.effectiveFontSize, width: inner.width)
            return .text(store.preview(ofText: text), fontSize: fontSize, align: shown.effectiveTextAlign,
                         centred: shown.centresText, free: free, overflows: needed > inner.height + 1)
        case .file:
            let file = store.file(node.file ?? "")
            switch file.kind {
            case .image where file.exists: return .image(store.vault.rootURL.appendingPathComponent(file.path))
            case _ where !file.exists: return .missing(title: file.title, path: file.path)
            case .note: return .note(title: file.title, preview: file.preview)
            case .board: return .board(title: file.title, thumbnail: store.thumbnail(file.path))
            case .image, .pdf, .audio, .video, .other: return .file(symbol: BoardItemSpec.symbol(for: file.kind), title: file.title)
            }
        case .link:
            guard let url = node.url.flatMap(URL.init(string:)) else { return .missing(title: node.url ?? "Link", path: "") }
            let links = store.links
            let preview = links.preview(for: url)
            let kind = CanvasLinkKind(url)
            var pdfPage: CGImage?
            if kind == .pdf, let page = links.pdf(url)?.page(at: 0) {
                pdfPage = page.thumbnail(of: CGSize(width: 900, height: 1200), for: .mediaBox)
                    .cgImage(forProposedRect: nil, context: nil, hints: nil)
            }
            return .link(BoardLinkSpec(
                url: url, kind: kind, preview: preview,
                picture: preview?.image.flatMap { links.image($0) }?.cgImage(forProposedRect: nil, context: nil, hints: nil),
                icon: preview?.icon.flatMap { links.image($0) }?.cgImage(forProposedRect: nil, context: nil, hints: nil),
                pdfPage: pdfPage
            ))
        case .group, .other:
            return .editing
        }
    }
}

extension BoardItemSpec {
    static func symbol(for kind: CardFile.Kind) -> String {
        switch kind {
        case .pdf: return "doc.richtext"
        case .audio: return "waveform"
        case .video: return "play.rectangle"
        case .image: return "photo"
        case .note: return "doc.text"
        case .board: return CanvasUIPlugin.symbol
        case .other: return "doc"
        }
    }

    static func label(_ node: CanvasNode) -> String {
        switch node.kind {
        case .text: return node.text ?? "Text card"
        case .file: return "Card: " + CardFile.title(of: node.file ?? "")
        case .link: return "Link: " + (node.url ?? "")
        case .group: return "Group: " + (node.label ?? "")
        case .other(let type): return "Card of type \(type)"
        }
    }
}

/// Text of the far-away cards.
enum BoardFarText {
    /// How much larger the first line of a text is drawn when it is a heading (as the board's previews draw them).
    static func headingScale(_ text: String?) -> CGFloat {
        let hashes = (text ?? "").prefix { $0 == "#" }.count
        guard (1...4).contains(hashes), (text ?? "").dropFirst(hashes).first == " " else { return 1 }
        return [1.75, 1.45, 1.25, 1.1][hashes - 1]
    }
}

extension BoardStore {
    /// A card's first line without its Markdown marks: what a far-away card says.
    func title(of node: CanvasNode) -> String {
        switch node.kind {
        case .file: return CardFile.title(of: node.file ?? "")
        case .link: return URL(string: node.url ?? "")?.host() ?? ""
        case .text:
            let text = node.text ?? ""
            if let known = titles[text] { return known }
            if titles.count > 4000 { titles.removeAll() }
            let first = text.split(separator: "\n", omittingEmptySubsequences: true).first.map {
                $0.trimmingCharacters(in: CharacterSet(charactersIn: "#*-> ").union(.whitespaces))
            } ?? ""
            titles[text] = first
            return first
        default: return ""
        }
    }
}

// MARK: - Drawing off the main thread

/// Draws items' bitmaps on the card-drawing threads, many at once, and hands them back together.
enum BoardRenderer {
    struct Job: @unchecked Sendable {
        let layer: BoardItemLayer
        let key: BoardRenderKey
        let spec: BoardItemSpec
        let pixelScale: CGFloat
        let lineScale: CGFloat
        let palette: BoardPalette
        let appearance: NSAppearance
        let space: CGColorSpace
    }

    private struct Done: @unchecked Sendable {
        let job: Job
        let image: CGImage?
    }

    static let queue = DispatchQueue(label: "loam.board-drawing", qos: .userInitiated)

    /// Draws `jobs`: at once, spread over the cores, when `now` (layers that show nothing yet); else in the
    /// background, the old pictures shown until the new ones are in. `done` runs on the main thread.
    @MainActor static func render(_ jobs: [Job], now: Bool, done: @escaping @MainActor () -> Void = {}) {
        guard !jobs.isEmpty else { return }
        for job in jobs { job.layer.drawing = job.key }
        if now {
            let images = UnsafeImages(count: jobs.count)
            DispatchQueue.concurrentPerform(iterations: jobs.count) { index in images.set(index, image(for: jobs[index])) }
            for (index, job) in jobs.enumerated() { apply(Done(job: job, image: images.get(index))) }
            done()
            return
        }
        let box = UncheckedJobs(jobs: jobs)
        queue.async {
            let images = UnsafeImages(count: box.jobs.count)
            DispatchQueue.concurrentPerform(iterations: box.jobs.count) { index in images.set(index, image(for: box.jobs[index])) }
            let results = UncheckedDone(done: box.jobs.enumerated().map { Done(job: $1, image: images.get($0)) })
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    for result in results.done { apply(result) }
                    done()
                }
            }
        }
    }

    @MainActor private static func apply(_ result: Done) {
        let layer = result.job.layer
        guard layer.drawing == result.job.key else { return }
        layer.drawing = nil
        layer.shown = result.job.key
        layer.contentsScale = result.job.pixelScale
        layer.contents = result.image
    }

    private final class UncheckedJobs: @unchecked Sendable {
        let jobs: [Job]
        init(jobs: [Job]) { self.jobs = jobs }
    }

    private final class UncheckedDone: @unchecked Sendable {
        let done: [Done]
        init(done: [Done]) { self.done = done }
    }

    /// Results written by several threads, each to its own index.
    private final class UnsafeImages: @unchecked Sendable {
        private var images: [CGImage?]
        private let lock = NSLock()
        init(count: Int) { images = Array(repeating: nil, count: count) }
        func set(_ index: Int, _ image: CGImage?) { lock.withLock { images[index] = image } }
        func get(_ index: Int) -> CGImage? { lock.withLock { images[index] } }
    }

    static func image(for job: Job) -> CGImage? {
        let size = job.spec.size
        let width = Int(ceil(size.width * job.pixelScale)), height = Int(ceil(size.height * job.pixelScale))
        guard width > 0, height > 0, let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: job.space,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: job.pixelScale, y: -job.pixelScale)
        job.appearance.performAsCurrentDrawingAppearance {
            BoardDrawing.draw(job.spec, in: context, lineScale: job.lineScale, palette: job.palette, pixelScale: job.pixelScale)
        }
        return context.makeImage()
    }

    /// The pixels per board unit to draw an item of `size` at for a zoom: the display's, rounded up to a power of
    /// two of the zoom so a zoom reuses it, at most 16 million pixels.
    static func pixelScale(for size: CGSize, scale: CGFloat, backing: CGFloat) -> CGFloat {
        var bucket: CGFloat = 1.0 / 32
        while bucket < min(scale, 4) { bucket *= 2 }
        var pixels = backing * bucket
        let area = max(size.width * size.height, 1)
        if area * pixels * pixels > 16_000_000 { pixels = (16_000_000 / area).squareRoot() }
        return pixels
    }

    static func scaleStep(_ scale: CGFloat) -> Int { Int((log(max(scale, 0.01)) / log(1.15)).rounded()) }
}
