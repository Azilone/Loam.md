import Foundation
import PluginKitUI

/// The workspace as a value: a tree of splits and panes, the panes' tabs, and the focused pane.
///
/// It is pure so every rule (placement, close, drops, collapse) is unit tested without a window; the shell only
/// renders it and forwards user actions to its mutating methods. Every mutation keeps the invariants that
/// `validate()` checks, and silently ignores ids that are not in the layout (a stale drag, a closed tab).
public struct WorkspaceLayout: Codable, Equatable, Sendable {
    // `internal(set)` rather than `private(set)` so the extensions in other files can mutate; read-only outside.
    public internal(set) var root: LayoutNode
    public internal(set) var focusedPane: PaneID
    /// Makes ids for new tabs, panes and splits. Injectable for deterministic tests; not encoded.
    var makeID: @Sendable () -> UUID

    /// One empty pane, focused.
    public init(makeID: @escaping @Sendable () -> UUID = UUID.init) {
        self.makeID = makeID
        let pane = Pane(id: PaneID(raw: makeID()))
        root = .pane(pane)
        focusedPane = pane.id
    }

    // MARK: Codable and Equatable ignore `makeID`

    private enum CodingKeys: String, CodingKey { case root, focusedPane }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        root = try container.decode(LayoutNode.self, forKey: .root)
        focusedPane = try container.decode(PaneID.self, forKey: .focusedPane)
        makeID = UUID.init
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(root, forKey: .root)
        try container.encode(focusedPane, forKey: .focusedPane)
    }

    public static func == (lhs: WorkspaceLayout, rhs: WorkspaceLayout) -> Bool {
        lhs.root == rhs.root && lhs.focusedPane == rhs.focusedPane
    }

    // MARK: Reading

    /// The panes in reading order (depth first, leading to trailing, top to bottom).
    public var panes: [Pane] { root.panes }

    public var focused: Pane { panes.first { $0.id == focusedPane } ?? root.firstPane }

    /// The selected tab of the focused pane: what "the active note" means for commands.
    public var activeTab: Tab? {
        let pane = focused
        return pane.tabs.first { $0.id == pane.selected }
    }

    public func pane(containing tab: TabID) -> PaneID? {
        panes.first { $0.tabs.contains { $0.id == tab } }?.id
    }

    public func tab(_ id: TabID) -> Tab? {
        for pane in panes { if let tab = pane.tabs.first(where: { $0.id == id }) { return tab } }
        return nil
    }

    func newTab(_ resource: Resource) -> Tab { Tab(id: TabID(raw: makeID()), resource: resource) }

    // MARK: Open

    /// Opens `resource` following the placement hint, and returns the tab that shows it.
    ///
    /// Never duplicates a tab inside the target pane: if it already shows the resource, that tab is selected.
    @discardableResult
    public mutating func open(_ resource: Resource, placement: Placement) -> TabID {
        switch placement {
        case .replace:
            if let existing = focused.tabs.first(where: { $0.resource == resource }) {
                select(existing.id)
                return existing.id
            }
            guard let active = activeTab else { return appendTab(resource, in: focusedPane) }
            root.updatePane(focusedPane) { pane in
                guard let index = pane.tabs.firstIndex(where: { $0.id == active.id }) else { return }
                pane.tabs[index].resource = resource
                pane.tabs[index].state = nil
                pane.tabs[index].viewType = nil
            }
            return active.id
        case .newTab:
            if let existing = focused.tabs.first(where: { $0.resource == resource }) {
                select(existing.id)
                return existing.id
            }
            return appendTab(resource, in: focusedPane)
        case .beside:
            focusedPane = paneBeside(focusedPane)
            return open(resource, placement: .newTab)
        }
    }

    /// Adds a tab showing `resource` after the selected one of the focused pane and selects it, even when a tab
    /// there already shows it (a new tab, Cmd+T). `open` never duplicates; this does.
    @discardableResult
    public mutating func openNewTab(_ resource: Resource) -> TabID { appendTab(resource, in: focusedPane) }

    /// Adds a tab after the selected one of `paneID`, selects it and focuses the pane.
    private mutating func appendTab(_ resource: Resource, in paneID: PaneID) -> TabID {
        let tab = newTab(resource)
        root.updatePane(paneID) { pane in
            let after = pane.tabs.firstIndex { $0.id == pane.selected }.map { $0 + 1 } ?? pane.tabs.count
            pane.tabs.insert(tab, at: after)
            pane.selected = tab.id
        }
        focusedPane = paneID
        return tab.id
    }

    /// The pane to the right of `paneID`: the next child of its nearest horizontal split, or a new pane split off
    /// its trailing edge when there is nothing to its right.
    private mutating func paneBeside(_ paneID: PaneID) -> PaneID {
        if let nearest = root.ancestors(of: paneID).last(where: { $0.axis == .horizontal }),
            nearest.index + 1 < nearest.children.count {
            return nearest.children[nearest.index + 1].firstPane.id
        }
        let pane = Pane(id: PaneID(raw: makeID()))
        insert(pane, beside: paneID, edge: .trailing)
        return pane.id
    }

    // MARK: Close, select, focus

    /// Closes a tab. Its neighbour (right, else left) becomes selected; a pane left empty disappears unless it is
    /// the last one, and the focus moves to a sibling pane if it was there.
    public mutating func close(_ tab: TabID) {
        guard let paneID = pane(containing: tab) else { return }
        detach(tab, from: paneID)
        removePaneIfEmpty(paneID)
    }

    /// Removes the tab from its pane and fixes the pane's selection; leaves the pane in place even if empty.
    mutating func detach(_ tab: TabID, from paneID: PaneID) {
        root.updatePane(paneID) { pane in
            guard let index = pane.tabs.firstIndex(where: { $0.id == tab }) else { return }
            pane.tabs.remove(at: index)
            if pane.selected == tab {
                if pane.tabs.isEmpty {
                    pane.selected = nil
                } else {
                    pane.selected = pane.tabs[min(index, pane.tabs.count - 1)].id
                }
            }
        }
    }

    /// Removes an empty pane from the tree (unless it is the only one), collapses what is left and moves the
    /// focus to a sibling if needed.
    mutating func removePaneIfEmpty(_ paneID: PaneID) {
        guard panes.count > 1, let pane = panes.first(where: { $0.id == paneID }), pane.tabs.isEmpty else { return }
        let sibling: PaneID? = root.ancestors(of: paneID).last.map { parent in
            parent.index + 1 < parent.children.count
                ? parent.children[parent.index + 1].firstPane.id
                : parent.children[parent.index - 1].lastPane.id
        }
        guard let remaining = root.removingPane(paneID) else { return }
        root = remaining.normalized()
        if focusedPane == paneID { focusedPane = sibling ?? root.firstPane.id }
    }

    /// Selects a tab and focuses its pane.
    public mutating func select(_ tab: TabID) {
        guard let paneID = pane(containing: tab) else { return }
        root.updatePane(paneID) { $0.selected = tab }
        focusedPane = paneID
    }

    public mutating func focus(_ pane: PaneID) {
        guard root.contains(pane: pane) else { return }
        focusedPane = pane
    }

    /// Moves a tab to `index` in `pane` (clamped), selects it and focuses that pane. Within one pane it reorders.
    public mutating func moveTab(_ tab: TabID, to target: PaneID, at index: Int) {
        guard let source = pane(containing: tab), root.contains(pane: target), let moving = self.tab(tab) else {
            return
        }
        detach(tab, from: source)
        root.updatePane(target) { pane in
            pane.tabs.insert(moving, at: max(0, min(index, pane.tabs.count)))
            pane.selected = tab
        }
        focusedPane = target
        if source != target { removePaneIfEmpty(source) }
    }

    /// Closes every tab whose resource matches, for example the notes of a deleted folder.
    public mutating func closeAll(where shouldClose: (Resource) -> Bool) {
        for pane in panes {
            for tab in pane.tabs where shouldClose(tab.resource) { close(tab.id) }
        }
    }

    // MARK: Per-tab data

    /// Sets a split's fractions. They are scaled to sum to 1; ignored if the count differs or one is not positive.
    public mutating func setFractions(split: UUID, _ fractions: [Double]) {
        guard fractions.allSatisfy({ $0 > 0 && $0.isFinite }) else { return }
        root.updateSplit(split) { _, children, current in
            guard fractions.count == children.count else { return }
            current = LayoutNode.normalize(fractions)
        }
    }

    public mutating func setState(_ data: Data?, for tab: TabID) {
        updateTab(tab) { $0.state = data }
    }

    /// Shows `resource` in an existing tab, as `.replace` does for the active one: its view data is reset. Used to
    /// go back to what the tab showed before.
    public mutating func show(_ resource: Resource, in tab: TabID) {
        updateTab(tab) { tab in
            tab.resource = resource
            tab.state = nil
            tab.viewType = nil
        }
    }

    /// Records the view type picked with "Open with"; nil goes back to the default view type.
    public mutating func setViewType(_ id: String?, for tab: TabID) {
        updateTab(tab) { $0.viewType = id }
    }

    mutating func updateTab(_ tab: TabID, _ body: (inout Tab) -> Void) {
        guard let paneID = pane(containing: tab) else { return }
        root.updatePane(paneID) { pane in
            if let index = pane.tabs.firstIndex(where: { $0.id == tab }) { body(&pane.tabs[index]) }
        }
    }
}
