import Foundation
import PluginKitUI
import SwiftUI
import TasksPlugin

/// The home page (`Resource.home`, `home:`): what the house button, a new tab and an empty window show. Four layouts,
/// picked in its settings: Welcome (a greeting, Quick Open, three actions, the notes to pick up again), Today (today's
/// note, the tasks and what comes next), Activity (the year in a heatmap, the month in numbers) and Overview (a bit of
/// each). `home:<layout>` shows one layout whatever the setting says (the Overview's "See activity").
///
/// It reads the vault, and the `daily-notes` and `tasks` services when they are there; its buttons run other
/// plugins' commands (`daily.open-today`, `explorer.new-note`, `switcher.open`, `mindmap.new`) through `ui.commands`
/// and hide when a command is missing.
public final class HomeUIPlugin: UIPlugin {
    public static let manifest = PluginManifest(
        id: "home-ui",
        name: "Home",
        version: "0.1.0",
        description: "A home page: today's note, your tasks, the notes to pick up again and your rhythm.",
        icon: "house",
        optionalRequires: ["daily-notes", "tasks"],
        permissions: ["ui", "vault.read", "vault.write"],
        settings: [
            SettingDescription(
                "layout", title: "Layout", help: "What the home page shows.",
                default: .string(HomeLayout.welcome.rawValue),
                choices: [
                    SettingChoice(.string(HomeLayout.welcome.rawValue), title: "Welcome: greeting and shortcuts"),
                    SettingChoice(.string(HomeLayout.today.rawValue), title: "Today: daily note and tasks"),
                    SettingChoice(.string(HomeLayout.activity.rawValue), title: "Activity: your year in a glance"),
                    SettingChoice(.string(HomeLayout.overview.rawValue), title: "Overview: a bit of everything"),
                ]
            ),
            SettingDescription(
                "name", title: "Name", help: "The name the greeting uses; empty for your Mac's.", default: .string("")
            ),
        ]
    )

    static let viewTypeID = "home.page"
    static let scheme = "home:"
    /// Internal: lets the tests reach the shared model. Not a contract.
    static var modelKey: ServiceKey<HomeModel> { ServiceKey("home-ui.model") }

    public init() {}

    @MainActor public func activateUI(context: PluginContext) throws {
        let model = HomeModel(
            vault: { [weak context] in context?.vault },
            dailyNotes: { [weak context] in context?.service(.dailyNotes) },
            tasks: { [weak context] in context?.service(.tasks) },
            workspace: { [weak context] in context?.workspace },
            commands: { [weak context] in context?.service(.commands) }
        )
        apply(context.settings.value(default: HomeSettings()), to: model)
        try context.provide(Self.modelKey, model)

        try context.registerView(ViewType(
            id: Self.viewTypeID,
            title: "Home",
            canOpen: { $0.kind == .virtual && $0.path.hasPrefix(Self.scheme) },
            makeView: { view in
                AnyView(HomeView(model: model, pinned: Self.layout(of: view.resource)))
            }
        ))

        try context.registerCommand(Command(
            id: "home.open",
            title: "Open home",
            summary: "Shows the home page in the focused tab. Optional argument: layout (welcome, today, activity or "
                + "overview) to show that one rather than the one set in the settings. Returns what it did."
        ) { arguments in
            let layout = arguments["layout"].flatMap(HomeLayout.init(rawValue:))
            return await MainActor.run {
                model.open(.virtual(Self.scheme + (layout?.rawValue ?? "")), from: nil)
                return "Opened the home page."
            }
        })

        context.on(VaultChanged.self) { [weak model] event in
            guard !event.noteChanges.isEmpty else { return }
            onMainThread { model?.scheduleRefresh() }
        }
        context.on(NotesMoved.self) { [weak model] _ in
            onMainThread { model?.scheduleRefresh() }
        }
        context.on(DailyNotesLayoutChanged.self) { [weak model] _ in
            onMainThread { model?.refresh() }
        }
        let id = Self.manifest.id
        context.on(PluginSettingsChanged.self) { [weak model, weak context] event in
            guard event.pluginID == id, let settings = context?.settings.value(default: HomeSettings()) else { return }
            onMainThread { if let model { Self.apply(settings, to: model) } }
        }
    }

    @MainActor private static func apply(_ settings: HomeSettings, to model: HomeModel) {
        model.layout = HomeLayout(rawValue: settings.layout) ?? .welcome
        model.settingsName = settings.name
    }

    @MainActor private func apply(_ settings: HomeSettings, to model: HomeModel) {
        Self.apply(settings, to: model)
    }

    /// The layout a `home:<layout>` resource asks for; nil for `home:`, which follows the settings.
    static func layout(of resource: Resource) -> HomeLayout? {
        HomeLayout(rawValue: String(resource.path.dropFirst(scheme.count)))
    }
}

/// Runs `body` on the main thread: at once when already there (events sent from the main thread), else hopping.
private func onMainThread(_ body: @MainActor @Sendable () -> Void) {
    if Thread.isMainThread {
        MainActor.assumeIsolated(body)
    } else {
        DispatchQueue.main.sync { MainActor.assumeIsolated(body) }
    }
}
