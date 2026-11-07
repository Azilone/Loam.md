import PluginKitUI
import SwiftUI
import WorkspaceModel

/// The selected tab's view: the view type the registry picks for its resource, or a placeholder when no installed
/// plugin can open it (its plugin was disabled: the tab stays, and comes back to life when the plugin does).
struct TabContentView: View {
    let tab: WorkspaceModel.Tab
    let context: ViewContext
    let views: ViewRegistryStore

    /// A new view when the tab, its resource or its view type changes, so no state leaks from one to the next. A view
    /// type that follows its resource (`ViewType.followsResource`) keeps its view while the page is replaced in place:
    /// the page generation stands for the resource.
    struct Identity: Hashable {
        let tab: TabID
        let resource: Resource?
        let generation: Int
        let viewType: String?

        @MainActor init(tab: WorkspaceModel.Tab, views: ViewRegistryStore, workspace: WorkspaceController) {
            self.tab = tab.id
            let type = WorkspaceController.viewType(for: tab, in: views)
            let follows = type?.followsResource ?? false
            resource = follows ? nil : tab.resource
            generation = follows ? workspace.pageGeneration(of: tab.id) : 0
            viewType = type?.id
        }
    }

    var body: some View {
        if let type = WorkspaceController.viewType(for: tab, in: views) {
            type.makeView(context)
        } else {
            ContentUnavailableView {
                Label("No installed plugin can open this", symbol: "puzzlepiece.extension")
            } description: {
                Text(tab.resource.name)
            }
        }
    }
}

/// A pane with no tab: only the last pane of the workspace can be empty.
struct EmptyPaneView: View {
    var body: some View {
        ContentUnavailableView("Nothing open", symbol: "square.dashed")
            .foregroundStyle(.tertiary)
    }
}
