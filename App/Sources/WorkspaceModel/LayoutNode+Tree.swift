import Foundation

// Tree walks and rewrites. Kept internal: the public API is `WorkspaceLayout`, which keeps the invariants.
extension LayoutNode {
    /// The panes in reading order: depth first, children in order.
    var panes: [Pane] {
        switch self {
        case .pane(let pane): [pane]
        case .split(_, _, let children, _): children.flatMap(\.panes)
        }
    }

    var firstPane: Pane { panes[0] }
    var lastPane: Pane { panes[panes.count - 1] }

    func contains(pane id: PaneID) -> Bool {
        switch self {
        case .pane(let pane): pane.id == id
        case .split(_, _, let children, _): children.contains { $0.contains(pane: id) }
        }
    }

    /// Applies `body` to the pane with this id. Returns false when there is none.
    @discardableResult
    mutating func updatePane(_ id: PaneID, _ body: (inout Pane) -> Void) -> Bool {
        switch self {
        case .pane(var pane):
            guard pane.id == id else { return false }
            body(&pane)
            self = .pane(pane)
            return true
        case .split(let splitID, let axis, var children, let fractions):
            for index in children.indices where children[index].contains(pane: id) {
                children[index].updatePane(id, body)
                self = .split(id: splitID, axis: axis, children: children, fractions: fractions)
                return true
            }
            return false
        }
    }

    /// Replaces the pane with this id by `replacement` (a pane or a split).
    mutating func replacePane(_ id: PaneID, with replacement: LayoutNode) {
        switch self {
        case .pane(let pane):
            if pane.id == id { self = replacement }
        case .split(let splitID, let axis, var children, let fractions):
            for index in children.indices where children[index].contains(pane: id) {
                children[index].replacePane(id, with: replacement)
            }
            self = .split(id: splitID, axis: axis, children: children, fractions: fractions)
        }
    }

    /// Rewrites the split with this id. Returns false when there is none.
    @discardableResult
    mutating func updateSplit(
        _ id: UUID, _ body: (_ axis: SplitAxis, _ children: inout [LayoutNode], _ fractions: inout [Double]) -> Void
    ) -> Bool {
        guard case .split(let splitID, let axis, var children, var fractions) = self else { return false }
        if splitID == id {
            body(axis, &children, &fractions)
            self = .split(id: splitID, axis: axis, children: children, fractions: fractions)
            return true
        }
        for index in children.indices where children[index].updateSplit(id, body) {
            self = .split(id: splitID, axis: axis, children: children, fractions: fractions)
            return true
        }
        return false
    }

    /// The chain of splits from the root down to the pane: each split's id, axis and the index of the child that
    /// leads to the pane. Empty when the pane is the root or absent.
    func ancestors(of pane: PaneID) -> [(split: UUID, axis: SplitAxis, index: Int, children: [LayoutNode])] {
        guard case .split(let splitID, let axis, let children, _) = self else { return [] }
        guard let index = children.firstIndex(where: { $0.contains(pane: pane) }) else { return [] }
        return [(splitID, axis, index, children)] + children[index].ancestors(of: pane)
    }

    /// Removes the pane with this id; the rest is tidied by `normalized()`.
    func removingPane(_ id: PaneID) -> LayoutNode? {
        switch self {
        case .pane(let pane):
            return pane.id == id ? nil : self
        case .split(let splitID, let axis, let children, let fractions):
            var keptChildren: [LayoutNode] = []
            var keptFractions: [Double] = []
            for (child, fraction) in zip(children, fractions) {
                if let kept = child.removingPane(id) {
                    keptChildren.append(kept)
                    keptFractions.append(fraction)
                }
            }
            if keptChildren.isEmpty { return nil }
            return .split(id: splitID, axis: axis, children: keptChildren, fractions: keptFractions)
        }
    }

    /// Restores the shape invariants after an edit: a split with one child is replaced by that child, a split
    /// nested in a split of the same axis is flattened into it, and fractions sum to 1 again.
    func normalized() -> LayoutNode {
        guard case .split(let splitID, let axis, let children, let fractions) = self else { return self }
        var flatChildren: [LayoutNode] = []
        var flatFractions: [Double] = []
        for (child, fraction) in zip(children, fractions) {
            let child = child.normalized()
            if case .split(_, let childAxis, let grandChildren, let childFractions) = child, childAxis == axis {
                flatChildren += grandChildren
                flatFractions += childFractions.map { $0 * fraction }
            } else {
                flatChildren.append(child)
                flatFractions.append(fraction)
            }
        }
        if flatChildren.count == 1 { return flatChildren[0] }
        return .split(id: splitID, axis: axis, children: flatChildren, fractions: Self.normalize(flatFractions))
    }

    /// Scales positive fractions to sum to 1; falls back to equal shares if they cannot be.
    static func normalize(_ fractions: [Double]) -> [Double] {
        let sum = fractions.reduce(0, +)
        guard sum > 0, sum.isFinite, fractions.allSatisfy({ $0 > 0 && $0.isFinite }) else {
            return Array(repeating: 1 / Double(fractions.count), count: fractions.count)
        }
        return fractions.map { $0 / sum }
    }
}
