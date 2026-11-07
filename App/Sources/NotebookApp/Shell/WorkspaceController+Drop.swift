import PluginKitUI
import WorkspaceModel

// Drag and drop, as the views report it: the views only measure and decode, the rules are in the model.
extension WorkspaceController {
    /// A drop on a pane's content: on an edge the pane splits and the dragged tab or resource gets the new pane, on
    /// the center it becomes a tab of the pane. A tab that no longer exists is ignored.
    public func perform(_ payload: DragPayload, on pane: PaneID, edge: DropEdge) {
        switch payload {
        case .tab(let raw):
            update { $0.drop(tab: TabID(raw: raw), on: pane, edge: edge) }
        case .resource(let resource):
            update { $0.drop(resource: resource, on: pane, edge: edge) }
        }
        Sounds.play(.dropped)
    }

    /// A drop on a pane's tab bar, at `index` among the tabs as they are shown during the drag (`tabs.count`
    /// appends). A tab is moved there (reordered in its own pane), a resource opens there as a new tab.
    public func perform(_ payload: DragPayload, inTabBarOf pane: PaneID, at index: Int) {
        switch payload {
        case .tab(let raw):
            let tab = TabID(raw: raw)
            update { layout in
                var target = index
                // The model removes the tab before inserting it: a tab moving right in its own pane lands one
                // place earlier than the gap it was dropped in.
                if layout.pane(containing: tab) == pane,
                   let current = layout.panes.first(where: { $0.id == pane })?.tabs.firstIndex(where: { $0.id == tab }),
                   current < index {
                    target -= 1
                }
                layout.moveTab(tab, to: pane, at: target)
            }
        case .resource(let resource):
            update { layout in
                let tab = layout.drop(resource: resource, on: pane, edge: .center)
                layout.moveTab(tab, to: pane, at: index)
            }
        }
        Sounds.play(.dropped)
    }
}
