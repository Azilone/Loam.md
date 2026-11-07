import AppKit
import PluginKitUI

extension NSAttributedString.Key {
    /// On highlighted text (`==mark==`, `<mark>`): the colour of the marker stroke the text view draws under it. Not
    /// a background colour, which TextKit would fill as a flat box.
    static let markdownHighlight = NSAttributedString.Key("Loam.markdownHighlight")
}

/// A highlight drawn as a felt marker on paper: a band a little thinner than the letters, with edges that wander by
/// a fraction of a point, slanted chisel ends and a touch more ink where the stroke starts and lifts. The wobble is
/// seeded by the highlighted words, so a highlight keeps its shape while the page is edited around it.
///
/// Applying one plays the stroke: it is revealed from left to right, line after line, as a hand would draw it
/// (`HighlightReveal`), with the marker's sound.
enum HighlighterStroke {
    /// How far the edges wander, in points.
    static let wobble: CGFloat = 0.9
    /// The distance between two wobble points along an edge.
    static let step: CGFloat = 14
    /// How much the chisel tip slants: the top of an end is this far from its bottom.
    static let slant: CGFloat = 3

    /// The marker band over `box` (a line of highlighted letters, in a flipped view).
    static func path(for box: NSRect, seed: UInt64) -> NSBezierPath {
        var random = SeededRandom(seed: seed)
        let band = box.insetBy(dx: -1.5, dy: box.height * 0.08)
        // A slight tilt over the line, as a hand does not draw perfectly level.
        let tilt = random.next(in: -0.5...0.5)
        let count = max(Int((band.width / step).rounded(.up)), 1)
        func edge(_ y: CGFloat) -> [NSPoint] {
            (0...count).map { index in
                let t = CGFloat(index) / CGFloat(count)
                let x = band.minX + slant / 2 + t * (band.width - slant)
                return NSPoint(x: x, y: y + tilt * t + random.next(in: -wobble...wobble))
            }
        }
        let top = edge(band.minY)
        let bottom = edge(band.maxY).reversed().map { $0 }
        let path = NSBezierPath()
        // The start: the chisel's top a little ahead of its bottom.
        path.move(to: NSPoint(x: band.minX + slant, y: top[0].y))
        curve(through: top, in: path)
        // The end slants the other way, the bottom running on past the top.
        path.line(to: NSPoint(x: band.maxX, y: bottom[0].y))
        curve(through: bottom, in: path)
        path.line(to: NSPoint(x: band.minX, y: bottom.last!.y))
        path.close()
        return path
    }

    /// Smooth curves through `points`, by their midpoints, from where the path is.
    private static func curve(through points: [NSPoint], in path: NSBezierPath) {
        guard points.count > 1 else { return }
        for index in 1..<points.count {
            let previous = points[index - 1], point = points[index]
            let mid = NSPoint(x: (previous.x + point.x) / 2, y: (previous.y + point.y) / 2)
            path.curve(to: mid, controlPoint1: previous, controlPoint2: previous)
            if index == points.count - 1 { path.line(to: point) }
        }
    }

    /// Draws the strokes over `boxes`, of which the first `revealed` points (all of them when nil) show, line after
    /// line, the cut slanted like the marker's tip.
    static func draw(_ boxes: [NSRect], color: NSColor, seed: UInt64, revealed: CGFloat? = nil) {
        var offset: CGFloat = 0
        for (index, box) in boxes.enumerated() {
            defer { offset += box.width }
            let shown = revealed.map { min(max($0 - offset, 0), box.width) } ?? box.width
            guard shown > 0 else { break }
            let path = path(for: box, seed: seed &+ UInt64(index) &* 0x9E37_79B9)
            NSGraphicsContext.saveGraphicsState()
            if shown < box.width {
                let tip = box.minX + shown
                let clip = NSBezierPath()
                clip.move(to: NSPoint(x: box.minX - 4, y: box.minY - 4))
                clip.line(to: NSPoint(x: tip + slant, y: box.minY - 4))
                clip.line(to: NSPoint(x: tip, y: box.maxY + 4))
                clip.line(to: NSPoint(x: box.minX - 4, y: box.maxY + 4))
                clip.close()
                clip.addClip()
            }
            color.setFill()
            path.fill()
            // A little more ink where the marker touched down, and where it lifted once the line is drawn.
            let pool = color.shadow(withLevel: 0.07)?.withAlphaComponent(color.alphaComponent * 0.45) ?? color
            pool.setFill()
            let height = box.height * 0.84
            NSBezierPath(ovalIn: NSRect(x: box.minX - 1.5, y: box.midY - height / 2, width: min(5, box.width / 3), height: height)).fill()
            if shown >= box.width {
                NSBezierPath(ovalIn: NSRect(x: box.maxX - min(4, box.width / 3), y: box.midY - height / 2, width: min(5, box.width / 3), height: height)).fill()
            }
            NSGraphicsContext.restoreGraphicsState()
        }
    }

    /// A seed from the highlighted words: the same text draws the same stroke on every launch.
    static func seed(of text: String) -> UInt64 {
        var hash: UInt64 = 0xCBF2_9CE4_8422_2325
        for unit in text.utf16 {
            hash ^= UInt64(unit)
            hash = hash &* 0x100_0000_01B3
        }
        return hash
    }
}

/// A highlight being drawn: which characters, when it started, and how long the stroke takes.
struct HighlightReveal {
    let range: NSRange
    let start: CFTimeInterval
    let duration: CFTimeInterval

    /// The stroke takes longer on a longer highlight, as a hand would, within what still feels quick (the marker's
    /// sound lasts about half a second).
    static func duration(width: CGFloat) -> CFTimeInterval {
        min(max(0.3 + Double(width) / 2000, 0.32), 0.6)
    }

    /// How much of `total` points of stroke is drawn at `now`: fast as the marker touches down, slowing as it reaches
    /// the end.
    func revealed(of total: CGFloat, at now: CFTimeInterval) -> CGFloat {
        let t = min(max((now - start) / duration, 0), 1)
        return total * CGFloat(1 - pow(1 - t, 2.4))
    }

    func isDone(at now: CFTimeInterval) -> Bool { now - start >= duration }
}

/// A small, fast generator from a seed (SplitMix64), so the same seed always wobbles the same way.
struct SeededRandom {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func next(in range: ClosedRange<CGFloat>) -> CGFloat {
        let unit = CGFloat(next() >> 11) / CGFloat(1 << 53)
        return range.lowerBound + unit * (range.upperBound - range.lowerBound)
    }
}

extension EditorTextView {
    /// The highlights of `drawn`, as marker strokes; the one being applied only as far as its stroke has gone.
    func drawHighlights(in drawn: NSRange) {
        guard let storage = textStorage, drawn.length > 0 else { return }
        let now = CACurrentMediaTime()
        storage.enumerateAttribute(.markdownHighlight, in: drawn) { value, range, _ in
            guard let color = value as? NSColor else { return }
            let boxes = selectionBoxes(for: range)
            guard !boxes.isEmpty else { return }
            let seed = HighlighterStroke.seed(of: (storage.string as NSString).substring(with: range))
            var revealed: CGFloat?
            if let reveal = highlightReveal, NSIntersectionRange(reveal.range, range).length > 0 {
                revealed = reveal.revealed(of: boxes.reduce(0) { $0 + $1.width }, at: now)
            }
            HighlighterStroke.draw(boxes, color: color.usingColorSpace(.deviceRGB) ?? color, seed: seed, revealed: revealed)
        }
    }

    /// Plays the stroke of a highlight just applied over `range`, with the marker's sound. Under "Reduce motion" the
    /// highlight is simply there.
    func revealHighlight(in range: NSRange) {
        guard range.length > 0 else { return }
        Sounds.play(.highlighted)
        guard !Motion.reduceMotion, window != nil else { return }
        let width = selectionBoxes(for: range).reduce(0) { $0 + $1.width }
        highlightReveal = HighlightReveal(range: range, start: CACurrentMediaTime(), duration: HighlightReveal.duration(width: width))
        highlightLink?.invalidate()
        let link = displayLink(target: self, selector: #selector(stepHighlightReveal(_:)))
        link.add(to: .main, forMode: .common)
        highlightLink = link
        redrawHighlightReveal()
    }

    @objc private func stepHighlightReveal(_ link: CADisplayLink) {
        redrawHighlightReveal()
        guard let reveal = highlightReveal, !reveal.isDone(at: CACurrentMediaTime()) else {
            link.invalidate()
            highlightLink = nil
            // Drawn once more whole, ends and all.
            redrawHighlightReveal()
            highlightReveal = nil
            return
        }
    }

    /// Only the lines of the stroke are drawn again on each frame.
    private func redrawHighlightReveal() {
        guard let reveal = highlightReveal else { return }
        for box in selectionBoxes(for: reveal.range) { setNeedsDisplay(box.insetBy(dx: -8, dy: -4)) }
    }
}
