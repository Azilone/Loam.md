import CoreGraphics
import Foundation

public enum MindmapLayoutMode: String, CaseIterable, Sendable, Codable {
    /// Branches balanced on both sides of the central topic.
    case mindmap
    /// Everything grows to the right.
    case logic
    /// First-level topics chained along an axis, their details alternately below and above.
    case timeline

    init?(storedValue: String) {
        switch storedValue {
        case "balanced": self = .mindmap
        case "right", "left": self = .logic
        default: self.init(rawValue: storedValue)
        }
    }

    public var title: String {
        switch self {
        case .mindmap: "Mindmap"
        case .logic: "Logic"
        case .timeline: "Timeline"
        }
    }

    public var systemImage: String {
        switch self {
        case .mindmap: "arrow.left.and.right.square"
        case .logic: "list.bullet.indent"
        case .timeline: "point.3.connected.trianglepath.dotted"
        }
    }
}

/// Where a topic is drawn, in world coordinates with the central topic centred on (0, 0).
public struct MindmapPlacement: Equatable, Sendable {
    public enum Side: Equatable, Sendable { case left, right, top, bottom }

    /// The topic's frame.
    public var frame: CGRect
    public var depth: Int
    /// 1 when the branch grows to the right of the central topic, -1 to the left.
    public var direction: Int
    /// The index of the first-level branch the topic belongs to (colours); -1 for the central topic.
    public var branch: Int
    /// The sides the edge from the parent leaves and enters by.
    public var fromSide: Side = .right
    public var toSide: Side = .left
    /// Draw the incoming edge from this topic instead of the parent (the timeline's axis).
    public var edgeFrom: String?
}

/// The tidy-tree layout of a mindmap, a pure function of the tree, the folded topics and the topic sizes.
public enum MindmapLayout {
    public static let horizontalGap: CGFloat = 46
    public static let verticalGap: CGFloat = 12

    /// - Parameter rightCount: in the mindmap mode, how many of the central topic's children go on the right (the
    ///   others on the left); nil balances the two sides (`balancedSplit`).
    /// - Parameter branchSlots: the colour slot of a first-level branch by topic id, so a branch keeps its colour when
    ///   it moves; a branch without one takes its index.
    public static func compute(
        _ root: MindTopic,
        mode: MindmapLayoutMode,
        folded: Set<String> = [],
        rightCount: Int? = nil,
        branchSlots: [String: Int] = [:],
        size: (MindTopic, Int) -> CGSize
    ) -> [String: MindmapPlacement] {
        var out: [String: MindmapPlacement] = [:]
        var heights: [String: CGFloat] = [:]
        var sizes: [String: CGSize] = [:]

        func kids(_ topic: MindTopic) -> [MindTopic] {
            topic === root || !folded.contains(topic.id) ? topic.children : []
        }
        func vGap(_ depth: Int) -> CGFloat { Self.vGap(depth) }
        func hGap(_ depth: Int) -> CGFloat { depth == 0 ? horizontalGap * 1.4 : horizontalGap }
        func sizeOf(_ topic: MindTopic, _ depth: Int) -> CGSize {
            if let known = sizes[topic.id] { return known }
            let measured = size(topic, depth)
            sizes[topic.id] = measured
            return measured
        }

        @discardableResult
        func measure(_ topic: MindTopic, _ depth: Int) -> CGFloat {
            var total: CGFloat = 0
            for (i, child) in kids(topic).enumerated() {
                total += measure(child, depth + 1) + (i > 0 ? vGap(depth) : 0)
            }
            let height = max(sizeOf(topic, depth).height, total)
            heights[topic.id] = height
            return height
        }
        func stackHeight(_ list: [MindTopic], _ depth: Int) -> CGFloat {
            list.enumerated().reduce(0) { $0 + heights[$1.element.id, default: 0] + ($1.offset > 0 ? vGap(depth) : 0) }
        }
        func subtreeRight(_ topic: MindTopic) -> CGFloat {
            var right = out[topic.id].map { $0.frame.maxX } ?? -.infinity
            for child in kids(topic) { right = max(right, subtreeRight(child)) }
            return right
        }

        func place(_ topic: MindTopic, x: CGFloat, centerY: CGFloat, direction: Int, depth: Int, branch: Int) {
            let s = sizeOf(topic, depth)
            out[topic.id] = MindmapPlacement(
                frame: CGRect(x: x, y: centerY - s.height / 2, width: s.width, height: s.height),
                depth: depth, direction: direction, branch: branch,
                fromSide: direction == 1 ? .right : .left, toSide: direction == 1 ? .left : .right
            )
            placeChildren(kids(topic), parentX: x, parentWidth: s.width, centerY: centerY, direction: direction,
                          depth: depth) { _ in branch }
        }
        func placeChildren(
            _ list: [MindTopic], parentX: CGFloat, parentWidth: CGFloat, centerY: CGFloat, direction: Int,
            depth: Int, branchOf: (MindTopic) -> Int
        ) {
            var y = centerY - stackHeight(list, depth) / 2
            for child in list {
                let h = heights[child.id, default: 0]
                let s = sizeOf(child, depth + 1)
                let x = direction == 1 ? parentX + parentWidth + hGap(depth) : parentX - hGap(depth) - s.width
                place(child, x: x, centerY: y + h / 2, direction: direction, depth: depth + 1, branch: branchOf(child))
                y += h + vGap(depth)
            }
        }

        let rootSize = sizeOf(root, 0)
        let rootX = -rootSize.width / 2
        out[root.id] = MindmapPlacement(
            frame: CGRect(x: rootX, y: -rootSize.height / 2, width: rootSize.width, height: rootSize.height),
            depth: 0, direction: 1, branch: -1
        )
        let children = root.children
        for child in children { measure(child, 1) }
        let index = Dictionary(uniqueKeysWithValues: children.enumerated().map { ($1.id, $0) })
        let branchOf: (MindTopic) -> Int = { branchSlots[$0.id] ?? index[$0.id] ?? 0 }

        if mode == .timeline {
            let indent: CGFloat = 36
            var x = rootX + rootSize.width + hGap(0)
            for (i, event) in children.enumerated() {
                let s = sizeOf(event, 1)
                out[event.id] = MindmapPlacement(
                    frame: CGRect(x: x, y: -s.height / 2, width: s.width, height: s.height),
                    depth: 1, direction: 1, branch: branchOf(event), fromSide: .right, toSide: .left,
                    edgeFrom: i > 0 ? children[i - 1].id : nil
                )
                let up = i % 2 == 1
                let details = kids(event)
                let dx = x + s.width / 2 + indent
                var cursor = up ? -s.height / 2 - verticalGap * 1.5 : s.height / 2 + verticalGap * 1.5
                var right = x + s.width
                for detail in up ? details.reversed() : details {
                    let h = heights[detail.id, default: 0]
                    let cy = up ? cursor - h / 2 : cursor + h / 2
                    place(detail, x: dx, centerY: cy, direction: 1, depth: 2, branch: branchOf(event))
                    out[detail.id]?.fromSide = up ? .top : .bottom
                    out[detail.id]?.toSide = .left
                    right = max(right, subtreeRight(detail))
                    cursor = up ? cursor - h - verticalGap : cursor + h + verticalGap
                }
                x = right + hGap(0)
            }
            return out
        }

        var right = children
        var left: [MindTopic] = []
        if mode == .mindmap {
            let split = min(max(rightCount ?? balancedSplit(root, size: sizeOf), 0), children.count)
            right = Array(children[..<split])
            left = Array(children[split...])
        }
        placeChildren(right, parentX: rootX, parentWidth: rootSize.width, centerY: 0, direction: 1, depth: 0,
                      branchOf: branchOf)
        placeChildren(left, parentX: rootX, parentWidth: rootSize.width, centerY: 0, direction: -1, depth: 0,
                      branchOf: branchOf)
        return out
    }

    /// How many of the central topic's children the balanced mindmap puts on the right: the split that evens the
    /// heights of the two sides, every branch unfolded, so folding a branch never sends another across.
    public static func balancedSplit(_ root: MindTopic, size: (MindTopic, Int) -> CGSize) -> Int {
        let children = root.children
        guard children.count > 1 else { return children.count }
        func height(_ topic: MindTopic, _ depth: Int) -> CGFloat {
            var total: CGFloat = 0
            for (i, child) in topic.children.enumerated() {
                total += height(child, depth + 1) + (i > 0 ? vGap(depth) : 0)
            }
            return max(size(topic, depth).height, total)
        }
        let heights = children.map { height($0, 1) }
        let total = heights.reduce(0, +)
        var best = 1
        var bestDiff = CGFloat.infinity
        var sum: CGFloat = 0
        for split in 1 ... children.count {
            sum += heights[split - 1]
            let diff = abs(2 * sum - total)
            if diff < bestDiff {
                best = split
                bestDiff = diff
            }
        }
        return best
    }

    static func vGap(_ depth: Int) -> CGFloat {
        depth == 0 ? verticalGap * 2 : depth == 1 ? verticalGap * 1.3 : verticalGap
    }

    /// The box around every placed topic.
    public static func bounds(_ placements: [String: MindmapPlacement]) -> CGRect {
        placements.values.reduce(CGRect.null) { $0.union($1.frame) }
    }
}
