import Observation
import SwiftUI

/// An item a plugin adds to the menu of a file or folder, in the Files panel and on the folder page: "Turn into
/// Collection" on folders. `perform` runs the plugin's command.
public struct ResourceAction: Identifiable, Sendable {
    /// Dotted and owned by the plugin, such as `collection.turn-into`.
    public let id: String
    public let title: String
    /// SF Symbol name.
    public let symbol: String
    /// Position in the menu's plugin section, lowest first.
    public let order: Int
    public let appliesTo: @MainActor (Resource) -> Bool
    public let perform: @MainActor (Resource) -> Void

    public init(
        id: String, title: String, symbol: String, order: Int = 0,
        appliesTo: @escaping @MainActor (Resource) -> Bool,
        perform: @escaping @MainActor (Resource) -> Void
    ) {
        self.id = id
        self.title = title
        self.symbol = symbol
        self.order = order
        self.appliesTo = appliesTo
        self.perform = perform
    }
}

/// Where resource actions are registered. Plugins use `context.addResourceAction`, which also unregisters on unload.
@MainActor
public protocol ResourceActionRegistry: AnyObject {
    func register(_ action: ResourceAction) -> @MainActor () -> Void
    /// The actions that apply to `resource`, by `order`, then by id.
    func actions(for resource: Resource) -> [ResourceAction]
}

/// The standard `ResourceActionRegistry`. Observable, so menus show an action as soon as its plugin loads.
@MainActor
@Observable
public final class ResourceActionStore: ResourceActionRegistry {
    private var entries = RegistryEntries<ResourceAction>()

    public init() {}

    public func register(_ action: ResourceAction) -> @MainActor () -> Void {
        let token = entries.insert(action, id: action.id)
        return { [weak self] in self?.entries.remove(token) }
    }

    public func actions(for resource: Resource) -> [ResourceAction] {
        entries.values
            .filter { $0.appliesTo(resource) }
            .sorted { $0.order != $1.order ? $0.order < $1.order : $0.id < $1.id }
    }
}

public extension ServiceKey where Service == any ResourceActionRegistry {
    static var resourceActions: ServiceKey<any ResourceActionRegistry> {
        ServiceKey<any ResourceActionRegistry>("ui.resource-actions")
    }
}

@MainActor
public extension PluginContext {
    /// Adds an item to the menus of the files or folders `action.appliesTo` accepts. Does nothing without the
    /// registry (outside the app): the action is an extra, its command still works.
    func addResourceAction(_ action: ResourceAction) {
        guard let registry = service(.resourceActions) else { return }
        let remove = registry.register(action)
        effect { MainActor.assumeIsolated { remove() } }
    }
}
