/// Opens resources in the window. A plugin names what to show and gives a placement hint; the shell decides how
/// (a tab, a split, a pushed screen on iPhone). A plugin never sees tabs or panes.
@MainActor
public protocol Workspace: AnyObject {
    /// Shows `resource` with the view type of highest priority that can open it. `origin` is where the click came
    /// from (a card, a sidebar row), which the page grows out of; nil when there is none.
    func open(_ resource: Resource, placement: Placement, from origin: OpenOrigin?)
    /// What the focused tab shows, nil when no tab is open.
    var activeResource: Resource? { get }
    /// Shows the right sidebar (the inspector) if it is hidden, as a double-click on an item asks for its details.
    func showInspector()
}

extension Workspace {
    /// Shows `resource` without an origin: the page cross-fades in.
    public func open(_ resource: Resource, placement: Placement) {
        open(resource, placement: placement, from: nil)
    }
}

/// Sent by the shell on the event bus when the focused tab changes, so a panel (backlinks, outline) can follow
/// the open note without polling the workspace.
public struct ActiveResourceChanged: PluginEvent, Sendable, Equatable {
    public let resource: Resource?

    public init(resource: Resource?) {
        self.resource = resource
    }
}
