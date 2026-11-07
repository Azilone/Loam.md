import Foundation

/// The eight handles of a selected card: dragging one moves the edges it touches.
public enum CanvasHandle: CaseIterable, Sendable {
    case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left

    public var movesLeft: Bool { self == .topLeft || self == .left || self == .bottomLeft }
    public var movesRight: Bool { self == .topRight || self == .right || self == .bottomRight }
    public var movesTop: Bool { self == .topLeft || self == .top || self == .topRight }
    public var movesBottom: Bool { self == .bottomLeft || self == .bottom || self == .bottomRight }
    public var isCorner: Bool { (movesLeft || movesRight) && (movesTop || movesBottom) }

    /// Where the handle sits on a frame.
    public func position(in frame: CanvasRect) -> CanvasPoint {
        let x = movesLeft ? frame.minX : movesRight ? frame.maxX : frame.center.x
        let y = movesTop ? frame.minY : movesBottom ? frame.maxY : frame.center.y
        return CanvasPoint(x: x, y: y)
    }

    /// The handle on the other side of the frame: the one that stays still in a resize from the opposite corner.
    public var opposite: CanvasHandle {
        switch self {
        case .topLeft: return .bottomRight
        case .top: return .bottom
        case .topRight: return .bottomLeft
        case .right: return .left
        case .bottomRight: return .topLeft
        case .bottom: return .top
        case .bottomLeft: return .topRight
        case .left: return .right
        }
    }
}

extension CanvasRect {
    /// The frame after dragging `handle` by `dx`, `dy`: the edges it touches move, the others stay. Never smaller
    /// than `minimum`: past it the dragged edge stops against the fixed one. With `keepRatio`, a corner keeps the
    /// frame's proportions (the larger of the two movements wins), and a side scales the other dimension about the
    /// frame's middle.
    public func resized(_ handle: CanvasHandle, by dx: Double, _ dy: Double, minimum: (width: Double, height: Double) = (40, 40),
                        keepRatio: Bool = false) -> CanvasRect {
        var left = minX, right = maxX, top = minY, bottom = maxY
        if handle.movesLeft { left = min(left + dx, right - minimum.width) }
        if handle.movesRight { right = max(right + dx, left + minimum.width) }
        if handle.movesTop { top = min(top + dy, bottom - minimum.height) }
        if handle.movesBottom { bottom = max(bottom + dy, top + minimum.height) }
        var result = CanvasRect(x: left, y: top, width: right - left, height: bottom - top)
        guard keepRatio, width > 0, height > 0 else { return result }
        let ratio = width / height
        if handle.isCorner {
            // Follow the movement that grew the frame most, relative to its size.
            let byWidth = result.width / width, byHeight = result.height / height
            var newWidth = result.width, newHeight = result.height
            if byWidth >= byHeight { newHeight = newWidth / ratio } else { newWidth = newHeight * ratio }
            newWidth = max(newWidth, minimum.width, minimum.height * ratio)
            newHeight = newWidth / ratio
            result.x = handle.movesLeft ? maxX - newWidth : minX
            result.y = handle.movesTop ? maxY - newHeight : minY
            result.width = newWidth
            result.height = newHeight
        } else if handle.movesLeft || handle.movesRight {
            let newHeight = max(result.width / ratio, minimum.height)
            result.y = center.y - newHeight / 2
            result.height = newHeight
        } else {
            let newWidth = max(result.height * ratio, minimum.width)
            result.x = center.x - newWidth / 2
            result.width = newWidth
        }
        return result
    }
}

public enum CanvasAlignment: String, CaseIterable, Sendable {
    case left, centerX, right, top, centerY, bottom
}

public enum CanvasAxis: Sendable {
    case horizontal, vertical
}

extension CanvasDocument {
    /// Lines the selected cards up on the left, middle or right of what they cover (or its top, middle, bottom).
    /// A group moves with what it holds, and what lies in a selected group is left to it.
    public mutating func align(_ ids: Set<String>, to alignment: CanvasAlignment) {
        let selected = topLevel(ids)
        guard selected.count > 1, let bounds = CanvasRect.bounds(selected.map(\.frame)) else { return }
        for node in selected {
            let frame = node.frame
            switch alignment {
            case .left: move([node.id], by: bounds.minX - frame.minX, 0)
            case .centerX: move([node.id], by: bounds.center.x - frame.center.x, 0)
            case .right: move([node.id], by: bounds.maxX - frame.maxX, 0)
            case .top: move([node.id], by: 0, bounds.minY - frame.minY)
            case .centerY: move([node.id], by: 0, bounds.center.y - frame.center.y)
            case .bottom: move([node.id], by: 0, bounds.maxY - frame.maxY)
            }
        }
    }

    /// Spaces three or more cards evenly between the first and the last along an axis.
    public mutating func distribute(_ ids: Set<String>, along axis: CanvasAxis) {
        var selected = topLevel(ids)
        guard selected.count > 2 else { return }
        selected.sort { axis == .horizontal ? $0.frame.center.x < $1.frame.center.x : $0.frame.center.y < $1.frame.center.y }
        let sizes = selected.map { axis == .horizontal ? $0.width : $0.height }
        let first = axis == .horizontal ? selected.first!.frame.minX : selected.first!.frame.minY
        let last = axis == .horizontal ? selected.last!.frame.maxX : selected.last!.frame.maxY
        let gap = (last - first - sizes.reduce(0, +)) / Double(selected.count - 1)
        var cursor = first
        for (node, size) in zip(selected, sizes) {
            let current = axis == .horizontal ? node.frame.minX : node.frame.minY
            if axis == .horizontal { move([node.id], by: cursor - current, 0) } else { move([node.id], by: 0, cursor - current) }
            cursor += size + gap
        }
    }

    /// The nodes of `ids` not inside another selected group, which carries them.
    private func topLevel(_ ids: Set<String>) -> [CanvasNode] {
        let groups = nodes.filter { ids.contains($0.id) && $0.kind == .group }
        return nodes.filter { node in
            ids.contains(node.id) && !groups.contains { $0.id != node.id && $0.frame.contains(node.frame) }
        }
    }
}
