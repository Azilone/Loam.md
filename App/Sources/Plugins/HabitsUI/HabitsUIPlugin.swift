import Foundation
import HabitTrackerPlugin
import PluginKitUI
import SwiftUI

/// The habits board: a table of the habits over the last two weeks as a view type (`habits:`), `habits.open` and
/// `habits.check-today` (a popup of the habits). Habits are read and written through the `habits` service of the
/// logic plugin, so the CLI and agents do the same with its `habits.*` commands.
public final class HabitsUIPlugin: UIPlugin {
    public static let manifest = PluginManifest(
        id: "habits-ui",
        name: "Habits board",
        version: "0.1.0",
        description: "Your habits, their week and their streaks, checked in a click.",
        icon: "calendar.badge.checkmark",
        requires: ["habits"],
        permissions: ["ui", "vault.read", "vault.write"]
    )

    static let viewTypeID = "habits.board"
    /// The board's only resource.
    static let boardResource = Resource.virtual("habits:")
    /// Internal: lets the tests reach the shared model. Not a contract.
    static var modelKey: ServiceKey<HabitsBoard> { ServiceKey("habits-ui.model") }

    public init() {}

    @MainActor public func activateUI(context: PluginContext) throws {
        guard let service = context.service(.habits) else { throw HabitsUIError.serviceMissing }
        let model = HabitsBoard(
            service: service,
            workspace: { [weak context] in context?.workspace },
            quickPick: { [weak context] in context?.quickPick }
        )
        model.refresh()
        try context.provide(Self.modelKey, model)

        try context.registerView(ViewType(
            id: Self.viewTypeID,
            title: "Habits",
            canOpen: { $0 == Self.boardResource },
            makeView: { view in AnyView(HabitsBoardView(model: model, view: view)) }
        ))

        try context.registerCommand(Command(
            id: "habits.open",
            title: "Open habits",
            summary: "Opens the habits page (every habit, its week and streak) in a new tab. Returns what it did."
        ) { _ in
            await MainActor.run { model.openBoard() }
        })

        try context.addSidebarLink(SidebarLink(
            id: "habits.link", title: "Habits", symbol: "flame", resource: Self.boardResource, order: 25
        ))

        try context.registerCommand(Command(
            id: "habits.new",
            title: "New habit…",
            summary: "Opens the habits page with its New habit field ready. From the command line or an agent use habits.create with a name."
        ) { _ in
            await MainActor.run { model.newHabit() }
        })

        try context.registerCommand(Command(
            id: "habits.check-today",
            title: "Check a habit for today",
            summary: "Shows a popup of the habits; the one picked is checked for today, which writes to its note. "
                + "Use habits.check with a name to do it without the popup."
        ) { _ in
            await MainActor.run { model.showCheckToday() }
        })

        context.on(VaultChanged.self) { [weak model] event in
            guard !event.noteChanges.isEmpty else { return }
            onMainThread { model?.refresh() }
        }
        context.on(NotesMoved.self) { [weak model] _ in
            onMainThread { model?.refresh() }
        }
        // The provider of the service says when its folder changes: show the habits of the new one.
        context.on(HabitsFolderChanged.self) { [weak model] _ in
            onMainThread { model?.refresh() }
        }
    }
}

enum HabitsUIError: Error, Equatable {
    /// The host activates this plugin after `habits` (it is in `requires`), so this means a broken host.
    case serviceMissing
}

/// Runs main-actor code from an event listener, which Swift cannot prove runs on the main thread. The kernel is
/// main-thread only, so this is normally a direct call.
func onMainThread(_ body: @MainActor @Sendable () -> Void) {
    if Thread.isMainThread {
        MainActor.assumeIsolated { body() }
    } else {
        DispatchQueue.main.sync { MainActor.assumeIsolated { body() } }
    }
}
