import Foundation
import PluginKitUI

// Drag and drop: on a pane's center a tab joins the pane, on an edge it gets a new pane split off that edge.
extension WorkspaceLayout {
    /// Drops an existing tab on a pane. Dropping the only tab of a pane on that same pane does nothing; dropping
    /// it on the center of its own pane only selects it.
    public mutating func drop(tab: TabID, on target: PaneID, edge: DropEdge) {
        guard let source = pane(containing: tab), root.contains(pane: target), let moving = self.tab(tab) else {
            return
        }
        if source == target {
            if edge == .center || panes.first(where: { $0.id == source })?.tabs.count == 1 {
                if edge == .center { select(tab) }
                return
            }
        }
        detach(tab, from: source)
        place(moving, on: target, edge: edge)
        if source != target { removePaneIfEmpty(source) }
    }

    /// Drops a resource (a note dragged from the sidebar) on a pane, as a new tab.
    @discardableResult
    public mutating func drop(resource: Resource, on target: PaneID, edge: DropEdge) -> TabID {
        guard root.contains(pane: target) else { return open(resource, placement: .newTab) }
        let tab = newTab(resource)
        place(tab, on: target, edge: edge)
        return tab.id
    }

    /// Puts a detached tab in `target` (center) or in a new pane on one of its edges, selected and focused.
    private mutating func place(_ tab: Tab, on target: PaneID, edge: DropEdge) {
        if edge == .center {
            root.updatePane(target) { pane in
                pane.tabs.append(tab)
                pane.selected = tab.id
            }
            focusedPane = target
            return
        }
        let pane = Pane(id: PaneID(raw: makeID()), tabs: [tab], selected: tab.id)
        insert(pane, beside: target, edge: edge)
        focusedPane = pane.id
    }

    /// Inserts `pane` next to `target` on `edge`. If the target's parent split already has the edge's axis, the
    /// pane becomes a sibling instead of nesting a new split; either way it shares the target's fraction equally.
    mutating func insert(_ pane: Pane, beside target: PaneID, edge: DropEdge) {
        let axis: SplitAxis = (edge == .top || edge == .bottom) ? .vertical : .horizontal
        let before = edge == .leading || edge == .top
        if let parent = root.ancestors(of: target).last, parent.axis == axis {
            root.updateSplit(parent.split) { _, children, fractions in
                let half = fractions[parent.index] / 2
                fractions[parent.index] = half
                let at = before ? parent.index : parent.index + 1
                children.insert(.pane(pane), at: at)
                fractions.insert(half, at: at)
            }
            return
        }
        guard let existing = panes.first(where: { $0.id == target }) else { return }
        let children: [LayoutNode] = before ? [.pane(pane), .pane(existing)] : [.pane(existing), .pane(pane)]
        root.replacePane(target, with: .split(id: makeID(), axis: axis, children: children, fractions: [0.5, 0.5]))
    }
}
