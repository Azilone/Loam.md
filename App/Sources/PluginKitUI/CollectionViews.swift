import AppKit
import Observation
import SwiftUI

/// A kind of collection view: what draws the views whose `type:` is `id` in a `.base` (`table`, `kanban`, `cards`,
/// a third party's `calendar`). Loam's version of Obsidian's `registerBasesView`. Registered with
/// `context.addCollectionView`; the collection page shows it in its tabs and offers it under "+".
public struct CollectionViewType: Identifiable, Sendable {
    /// The `type:` of the views it draws.
    public let id: String
    /// Shown in the "+" menu and as a new view's name ("Gallery" for `cards`).
    public let title: String
    /// SF Symbol name.
    public let symbol: String
    /// Position in the "+" menu, lowest first.
    public let order: Int
    /// Whether the view shows groups (a board's columns): the view settings then offer "Group by".
    public let groupsEntries: Bool
    /// Edits applied right after a view of this type is added (a board picks the field it groups by).
    public let defaults: @MainActor (_ definition: CollectionDefinition, _ view: String) -> [CollectionEdit]
    public let makeView: @MainActor (CollectionViewModel) -> AnyView
    /// The view in AppKit, for a view of many entries (a gallery, a board): the collection page shows it in place of
    /// `makeView`, with the theme when it adopts `NativeHostedView`, and asks it its height when embedded in a note
    /// (`CollectionViewModel.isEmbedded`). A type that gives it makes its `makeView` the same view (`NativeView`).
    /// Nil by default.
    public var makeNSView: (@MainActor (CollectionViewModel) -> NSView)?

    public init(
        id: String,
        title: String,
        symbol: String,
        order: Int = 0,
        groupsEntries: Bool = false,
        defaults: @escaping @MainActor (_ definition: CollectionDefinition, _ view: String) -> [CollectionEdit] = { _, _ in [] },
        makeView: @escaping @MainActor (CollectionViewModel) -> AnyView
    ) {
        self.id = id
        self.title = title
        self.symbol = symbol
        self.order = order
        self.groupsEntries = groupsEntries
        self.defaults = defaults
        self.makeView = makeView
    }
}

/// Where collection view types are registered. The `CollectionsUI` plugin provides it as `collections.views`.
@MainActor
public protocol CollectionViewRegistry: AnyObject {
    func register(_ type: CollectionViewType) -> @MainActor () -> Void
    /// Every type, by `order`, then by id.
    var types: [CollectionViewType] { get }
}

public extension CollectionViewRegistry {
    func type(_ id: String) -> CollectionViewType? { types.first { $0.id == id } }
}

/// The standard `CollectionViewRegistry`. Observable, so open collections show a view as soon as its plugin loads.
@MainActor
@Observable
public final class CollectionViewStore: CollectionViewRegistry {
    private var entries = RegistryEntries<CollectionViewType>()

    public init() {}

    public func register(_ type: CollectionViewType) -> @MainActor () -> Void {
        let token = entries.insert(type, id: type.id)
        return { [weak self] in self?.entries.remove(token) }
    }

    public var types: [CollectionViewType] {
        entries.values.sorted { $0.order != $1.order ? $0.order < $1.order : $0.id < $1.id }
    }
}

public extension ServiceKey where Service == any CollectionViewRegistry {
    static var collectionViews: ServiceKey<any CollectionViewRegistry> {
        ServiceKey<any CollectionViewRegistry>("collections.views")
    }
}

@MainActor
public extension PluginContext {
    /// Adds a kind of collection view, removed on unload. Does nothing without the collections plugin; list
    /// `collections.views` in `optionalRequires` to be restarted when it comes.
    func addCollectionView(_ type: CollectionViewType) {
        guard let registry = service(.collectionViews) else { return }
        let remove = registry.register(type)
        effect { MainActor.assumeIsolated { remove() } }
    }
}
