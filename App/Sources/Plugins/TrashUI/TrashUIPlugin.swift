import Foundation
import PluginKit
import PluginKitUI
import SwiftUI
import TrashPlugin

/// Recently Deleted: a page (`trash:`) listing what is in the vault's `.trash/` with when it was trashed and the
/// days left, Restore, Delete Forever and Empty, a link at the end of the sidebar's navigation, and `trash.open`.
/// It also runs the purge: when the vault opens and every hour, items past the retention are deleted for good.
/// Everything goes through the `trash` service of the logic plugin, so agents do the same with `trash.*`.
public final class TrashUIPlugin: UIPlugin {
    public static let manifest = PluginManifest(
        id: "trash-ui",
        name: "Recently Deleted",
        version: "0.1.0",
        description: "The Recently Deleted page, to restore what you deleted or delete it for good.",
        icon: "trash.circle",
        requires: ["trash"],
        permissions: ["ui", "vault.read", "vault.write"]
    )

    static let viewTypeID = "trash.list"
    static let resource = Resource.virtual("trash:Recently Deleted")
    /// Internal: lets the tests reach the shared model. Not a contract.
    static var modelKey: ServiceKey<TrashModel> { ServiceKey("trash-ui.model") }
    /// How often expired items are purged while the app runs.
    static let purgeInterval: TimeInterval = 3600

    public init() {}

    @MainActor public func activateUI(context: PluginContext) throws {
        guard let service = context.service(.trash) else { throw TrashUIError.serviceMissing }
        let model = TrashModel(service: service, setRetention: { [weak context] days in
            try? context?.settings.update(TrashPlugin.Settings(retentionDays: days))
        })
        model.openPage = { [weak context] in context?.workspace?.open(Self.resource, placement: .newTab) }
        model.readText = { [weak context] path in try? context?.vault.read(path) }
        model.purgeExpired()
        try context.provide(Self.modelKey, model)

        try context.registerView(ViewType(
            id: Self.viewTypeID,
            title: "Recently Deleted",
            canOpen: { $0 == Self.resource },
            makeView: { _ in AnyView(TrashView(model: model)) }
        ))

        try context.registerCommand(Command(
            id: "trash.open",
            title: "Open Recently Deleted",
            summary: "Opens the page listing the vault's trash (when each item was trashed, days left, restore, delete "
                + "for good) in a new tab. Returns what it did."
        ) { _ in
            await MainActor.run {
                model.refresh()
                model.openPage()
                return "Opened Recently Deleted."
            }
        })

        context.on(TrashChanged.self, refreshing(model))
        // Not on every save: only a removal, or a change inside the trash, can change what it lists.
        context.on(VaultChanged.self, refreshing(model, when: { event in
            event.changes.contains { $0.kind == .removed || $0.path.hasPrefix(TrashStore.folder + "/") }
        }))

        let timer = Timer.scheduledTimer(withTimeInterval: Self.purgeInterval, repeats: true) { [weak model] _ in
            Task { @MainActor in model?.purgeExpired() }
        }
        context.effect { timer.invalidate() }
    }
}

enum TrashUIError: Error, Equatable {
    /// The host activates this plugin after `trash` (it is in `requires`), so this means a broken host.
    case serviceMissing
}

/// Runs main-actor code from an event listener on the main queue. Always deferred: a command can emit from a
/// background thread (its handler is async), and the page only needs to catch up a moment later.
func onMainThread(_ body: @escaping @MainActor @Sendable () -> Void) {
    DispatchQueue.main.async { MainActor.assumeIsolated { body() } }
}

/// An event listener that refreshes the page. Built outside the main actor on purpose: a closure written inside
/// `activateUI` would be main-actor isolated and trap when a command emits from a background thread.
nonisolated func refreshing<E>(_ model: TrashModel, when relevant: @escaping @Sendable (E) -> Bool = { _ in true }) -> (E) -> Void {
    { [weak model] event in
        guard relevant(event) else { return }
        onMainThread { model?.refresh() }
    }
}
