import Foundation

/// Frames and the order a board is presented in, as Advanced Canvas keeps them: a frame (a slide) is a group with a
/// `ratio`, the presentation starts at `metadata.startNode` and follows the arrows from one slide to the next.
extension CanvasDocument {
    /// A new frame's size: 16:9, at a size a screen shows whole at about 100 %.
    public static let frameSize = (width: 1280.0, height: 720.0)
    public static let frameRatio = 16.0 / 9.0

    /// The slides: the frames, or when there are none, the groups.
    public var slideCandidates: [CanvasNode] {
        let frames = nodes.filter { $0.kind == .group && $0.ratio != nil }
        return frames.isEmpty ? nodes.filter { $0.kind == .group } : frames
    }

    /// The ids of the slides in the order they are shown: from the start node along the arrows that join slides (the
    /// first by label when several leave one), then the slides no arrow reaches, in reading order (rows top to
    /// bottom, left to right within a row).
    public func slides() -> [String] {
        let slides = slideCandidates
        guard !slides.isEmpty else { return [] }
        let ids = Set(slides.map(\.id))
        let reading = Self.readingOrder(slides).map(\.id)
        var order: [String] = []
        var seen = Set<String>()
        // Without a start, the first in reading order starts, and arrows still lead from it.
        var current = startNode.flatMap { ids.contains($0) ? $0 : nil } ?? reading.first
        while let id = current, !seen.contains(id) {
            order.append(id)
            seen.insert(id)
            current = edges.filter { $0.fromNode == id && ids.contains($0.toNode) && !seen.contains($0.toNode) }
                .sorted { ($0.label ?? "\u{10FFFF}") < ($1.label ?? "\u{10FFFF}") }
                .first?.toNode
        }
        return order + reading.filter { !seen.contains($0) }
    }

    /// Nodes in reading order: those whose middles are at about the same height (within half the smaller one) are
    /// one row, read left to right.
    static func readingOrder(_ nodes: [CanvasNode]) -> [CanvasNode] {
        var rows: [[CanvasNode]] = []
        for node in nodes.sorted(by: { $0.frame.center.y < $1.frame.center.y }) {
            if let last = rows.last?.last,
               abs(node.frame.center.y - last.frame.center.y) < min(node.height, last.height) / 2 {
                rows[rows.count - 1].append(node)
            } else {
                rows.append([node])
            }
        }
        return rows.flatMap { $0.sorted { $0.x < $1.x } }
    }

    /// A frame of `ratio` holding `rect` with `padding` round it, centred on it.
    public static func frame(around rect: CanvasRect, ratio: Double = frameRatio, padding: Double = 60) -> CanvasRect {
        var width = rect.width + padding * 2, height = rect.height + padding * 2
        if width / height > ratio { height = width / ratio } else { width = height * ratio }
        return CanvasRect(x: (rect.center.x - width / 2).rounded(), y: (rect.center.y - height / 2).rounded(),
                          width: width.rounded(), height: height.rounded())
    }

    /// The label the next frame gets: "Slide 1", "Slide 2"…
    public var nextFrameLabel: String {
        "Slide \(nodes.filter { $0.kind == .group && $0.ratio != nil }.count + 1)"
    }

    /// Adds a frame at `rect` (made 16:9 around it), under the cards it holds, labelled "Slide N". The first frame of
    /// a board starts its presentation. Returns its id.
    @discardableResult
    public mutating func addFrame(_ rect: CanvasRect, label: String? = nil) -> String {
        let id = newID()
        var frame = CanvasNode(id: id, kind: .group, x: rect.x, y: rect.y, width: rect.width, height: rect.height,
                               label: label ?? nextFrameLabel)
        frame.ratio = rect.width / max(rect.height, 1)
        add(frame)
        if startNode == nil || node(startNode!) == nil { startNode = id }
        return id
    }
}
