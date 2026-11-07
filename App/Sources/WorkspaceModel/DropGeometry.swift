import CoreGraphics
import Foundation

// Where a drag over the workspace would land, from the pointer's position. Pure, so the UI only measures.

/// The edge of a pane a drop at `point` lands on, in a pane of `size` (origin top left, y down): within `band` (a
/// fraction of the width or height) of an edge, that edge, the nearest one in a corner; else the center.
public func dropEdge(at point: CGPoint, in size: CGSize, band: CGFloat = 0.25) -> DropEdge {
    guard size.width > 0, size.height > 0, band > 0 else { return .center }
    let x = min(max(point.x / size.width, 0), 1)
    let y = min(max(point.y / size.height, 0), 1)
    let distances: [(DropEdge, CGFloat)] = [(.leading, x), (.trailing, 1 - x), (.top, y), (.bottom, 1 - y)]
    guard let nearest = distances.min(by: { $0.1 < $1.1 }), nearest.1 < band else { return .center }
    return nearest.0
}

/// Where a tab dropped at `x` on a tab bar is inserted, given the horizontal middle of each tab in order: before
/// the first tab whose middle is past `x`, else at the end.
public func tabInsertionIndex(at x: CGFloat, midpoints: [CGFloat]) -> Int {
    midpoints.firstIndex { x < $0 } ?? midpoints.count
}
