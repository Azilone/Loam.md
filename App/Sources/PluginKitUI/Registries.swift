/// Where view types are registered. Plugins use `context.registerView`, which also unregisters on unload.
///
/// `register` returns its remover instead of taking an id to remove, so a plugin can only remove what it
/// registered. The remover is main-actor isolated like the registry, which lets the context helpers call it from
/// an effect without a hop.
@MainActor
public protocol ViewRegistry: AnyObject {
    func register(_ type: ViewType) -> @MainActor () -> Void
    /// The types that can open `resource`: those that prefer it first, then by priority, then by id so the order
    /// is stable.
    func viewTypes(for resource: Resource) -> [ViewType]
}

public extension ViewRegistry {
    /// The icon of a resource: the symbol of the view type that opens it by default.
    func symbol(for resource: Resource) -> String? { viewTypes(for: resource).first?.symbol }

    /// A short title for a tab: `Resource.name`, but a file its viewer shows with its extension (`photo.heic`)
    /// keeps it.
    func title(for resource: Resource) -> String {
        guard resource.kind == .file, viewTypes(for: resource).first?.keepsExtension == true else { return resource.name }
        return resource.path.split(separator: "/").last.map(String.init) ?? resource.name
    }
}

/// Where panels and the sidebar's navigation links are registered. Plugins use `context.registerPanel` and
/// `context.addSidebarLink`, which also unregister on unload.
@MainActor
public protocol PanelRegistry: AnyObject {
    func register(_ panel: Panel) -> @MainActor () -> Void
    /// The panels of `slot`, by `order`, then by id.
    func panels(in slot: Slot) -> [Panel]
    func register(_ link: SidebarLink) -> @MainActor () -> Void
    /// The navigation links, by `order`, then by id.
    var links: [SidebarLink] { get }
    func register(_ item: NewItem) -> @MainActor () -> Void
    /// The kinds of notes besides a plain note that can be created ("New Mindmap"), by `order`, then by id.
    var newItems: [NewItem] { get }
    func register(_ section: SidebarSection) -> @MainActor () -> Void
    /// The sections of the left sidebar, by `order`, then by id.
    var sections: [SidebarSection] { get }
}
