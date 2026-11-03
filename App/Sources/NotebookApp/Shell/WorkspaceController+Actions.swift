import PluginKitUI
import WorkspaceModel

// The actions behind the shell commands (`workspace.*`), on the focused pane.
extension WorkspaceController {
    /// Closes the focused pane's selected tab. Returns false when there is none, so the menu can close the window.
    @discardableResult
    public func closeActiveTab() -> Bool {
        guard let tab = layout.activeTab else { return false }
        close(tab.id)
        return true
    }

    /// Opens the active tab's resource again in a new pane on `edge` of the focused pane (`.trailing` splits right,
    /// `.bottom` splits down). Does nothing without an active tab: an empty pane has nothing to show twice.
    public func splitActive(_ edge: DropEdge) {
        guard let tab = layout.activeTab else { return }
        update { $0.drop(resource: tab.resource, on: $0.focusedPane, edge: edge) }
    }

    /// Selects the tab `offset` places after the selected one in the focused pane, wrapping around.
    public func selectAdjacentTab(_ offset: Int) {
        let pane = layout.focused
        guard pane.tabs.count > 1, let index = pane.tabs.firstIndex(where: { $0.id == pane.selected }) else { return }
        let count = pane.tabs.count
        select(pane.tabs[((index + offset) % count + count) % count].id)
    }
}
