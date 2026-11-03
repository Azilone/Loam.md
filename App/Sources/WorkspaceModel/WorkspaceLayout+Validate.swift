import Foundation

/// A broken invariant of a `WorkspaceLayout`, described for a test failure or a log line.
public struct WorkspaceLayoutError: Error, CustomStringConvertible, Equatable {
    public let description: String
}

extension WorkspaceLayout {
    /// Throws if an invariant is broken. Mutations keep them; this guards decoded layouts and the tests.
    public func validate() throws {
        var tabIDs = Set<TabID>()
        var paneIDs = Set<PaneID>()
        try Self.check(root, parentAxis: nil, tabIDs: &tabIDs, paneIDs: &paneIDs)
        guard paneIDs.contains(focusedPane) else { throw fail("focused pane \(focusedPane.raw) is not in the tree") }
    }

    private static func check(
        _ node: LayoutNode, parentAxis: SplitAxis?, tabIDs: inout Set<TabID>, paneIDs: inout Set<PaneID>
    ) throws {
        switch node {
        case .pane(let pane):
            guard paneIDs.insert(pane.id).inserted else { throw fail("pane \(pane.id.raw) appears twice") }
            for tab in pane.tabs where !tabIDs.insert(tab.id).inserted {
                throw fail("tab \(tab.id.raw) appears twice")
            }
            if pane.tabs.isEmpty {
                guard pane.selected == nil else { throw fail("empty pane \(pane.id.raw) has a selection") }
            } else {
                guard let selected = pane.selected, pane.tabs.contains(where: { $0.id == selected }) else {
                    throw fail("pane \(pane.id.raw) does not select one of its tabs")
                }
            }
        case .split(let id, let axis, let children, let fractions):
            guard children.count >= 2 else { throw fail("split \(id) has \(children.count) child") }
            guard fractions.count == children.count else { throw fail("split \(id) has mismatched fractions") }
            guard fractions.allSatisfy({ $0 > 0 }) else { throw fail("split \(id) has a fraction <= 0") }
            guard abs(fractions.reduce(0, +) - 1) <= 1e-9 else { throw fail("split \(id) fractions do not sum to 1") }
            guard axis != parentAxis else { throw fail("split \(id) nests in a split of the same axis") }
            for child in children {
                try check(child, parentAxis: axis, tabIDs: &tabIDs, paneIDs: &paneIDs)
            }
        }
    }
}

private func fail(_ message: String) -> WorkspaceLayoutError { WorkspaceLayoutError(description: message) }
