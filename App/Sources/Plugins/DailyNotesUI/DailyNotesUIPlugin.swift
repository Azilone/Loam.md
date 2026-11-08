import DailyNotesPlugin
import Foundation
import PluginKitUI
import SwiftUI

/// The daily notes interface: today's note (Cmd+D), the previous and next daily note, and a month calendar as a
/// view type (`calendar:` resources) and as a panel in the right sidebar. Notes are created and listed through the
/// `daily-notes` service, so the CLI and agents do the same with the `daily.*` commands of the logic plugin.
///
/// A calendar tab keeps the month it shows in its `ViewContext` state; its resource stays the one it was opened
/// with (`calendar:` or `calendar:YYYY-MM`, the first month shown), so the tab never moves in the workspace.
public final class DailyNotesUIPlugin: UIPlugin {
    public static let manifest = PluginManifest(
        id: "daily-notes-ui",
        name: "Calendar",
        version: "0.1.0",
        description: "The calendar, Cmd+D for today's note, and the week above each daily note.",
        icon: "calendar",
        requires: ["daily-notes"],
        optionalRequires: ["editor"],
        permissions: ["ui", "vault.read", "vault.write"]
    )

    static let viewTypeID = "daily.calendar"
    static let sectionID = "daily.calendar"
    /// A daily note's first tab in the right sidebar: the month, then what is due (the Tasks plugin's).
    static let dayPage = InspectorPage(id: "daily.day", title: "Day", order: -10)
    static let headerID = "daily.header"
    /// The resource `calendar.open` opens: the calendar on the current month.
    static let calendarResource = Resource.virtual("calendar:")
    /// Internal: lets the tests reach the shared model. Not a contract.
    static var modelKey: ServiceKey<DailyCalendar> { ServiceKey("daily-notes-ui.model") }

    public init() {}

    @MainActor public func activateUI(context: PluginContext) throws {
        guard let service = context.service(.dailyNotes) else { throw DailyNotesUIError.serviceMissing }
        let model = DailyCalendar(service: service, workspace: { [weak context] in context?.workspace })
        model.vault = context.vault
        model.editor = { [weak context] in context?.service(.editor) }
        model.refresh()
        model.activeChanged(context.workspace?.activeResource)
        try context.provide(Self.modelKey, model)

        // The subfolder pattern has its own field, its presets and where today's note falls. The page folds a
        // plugin's generic settings under "Advanced settings" as soon as it draws a section, so Folder and Template
        // move there too; another provider of `daily-notes` keeps its own settings, and then the generic fields are
        // the way in.
        if let daily = service as? DailyNotes {
            let subfolders = SubfoldersSettings(
                daily: daily, commands: { [weak context] in context?.service(.commands) }
            )
            // A change made elsewhere (the CLI, the generic field) shows in the section too.
            context.on(PluginSettingsChanged.self) { [weak subfolders] event in
                guard event.pluginID == "daily-notes" else { return }
                MainThread.run { subfolders?.refresh() }
            }
            context.on(DailyNotesLayoutChanged.self) { [weak subfolders] _ in
                MainThread.run { subfolders?.refresh() }
            }
            try context.addSettingsSection(SettingsSection(
                id: "daily-notes.subfolders", pluginID: "daily-notes", title: "Subfolders",
                subtitle: "Folders for new daily notes, written from the day's date: yyyy, MM, MMM, MMMM, dd. "
                    + "Leave it empty for no subfolders. Notes already written stay where they are and are still found.",
                order: -1
            ) { AnyView(SubfoldersSettingsView(model: subfolders)) })
        }

        try context.registerView(ViewType(
            id: Self.viewTypeID,
            title: "Calendar",
            canOpen: { Self.isCalendar($0) },
            makeView: { _ in
                // Craft's calendar page: the days one under the other, from today.
                AnyView(AgendaView(model: model, placement: DailyCalendar.tabPlacement))
            }
        ))

        // The week and the date above every daily note's text.
        try context.addNoteHeader(NoteHeader(
            id: Self.headerID,
            order: 10,
            createsOnEdit: true,
            appliesTo: { [weak model] in model?.date(of: $0) != nil },
            makeView: { [weak model] view in
                guard let model, let date = model.date(of: view.resource) else { return AnyView(EmptyView()) }
                return AnyView(DailyHeader(model: model, date: date).id(date))
            }
        ))

        try context.addSidebarLink(SidebarLink(
            id: "daily.calendar-link", title: "Calendar", symbol: "calendar", resource: Self.calendarResource, order: 20
        ))

        try context.addInspectorSection(InspectorSection(
            id: Self.sectionID, placement: .tab(Self.dayPage), order: 0,
            appliesTo: { [weak model] in model?.date(of: $0) != nil }
        ) { _ in
            AnyView(InspectorGroup("Calendar") {
                InspectorCard(padding: 6) {
                    CalendarView(model: model, month: model.currentMonth, placement: DailyCalendar.panelPlacement)
                }
            })
        })

        try context.registerCommand(Command(
            id: "daily.open-today",
            title: "Open today's note",
            summary: "Opens today's daily note in the focused tab. The file is only created when text is typed in "
                + "it, so opening it writes nothing. Returns its path.",
            shortcut: KeyShortcut("d", [.command])
        ) { _ in
            try await MainActor.run { try model.openToday() }
        })

        try context.registerCommand(Command(
            id: "daily.open-previous",
            title: "Open previous daily note",
            summary: "Opens the nearest existing daily note before the one in the focused tab (or before today) in "
                + "the focused tab. Never creates a note. Returns its path, or says there is none."
        ) { _ in
            try await MainActor.run { try model.openAdjacent(forward: false) }
        })

        try context.registerCommand(Command(
            id: "daily.open-next",
            title: "Open next daily note",
            summary: "Opens the nearest existing daily note after the one in the focused tab (or after today) in "
                + "the focused tab. Never creates a note. Returns its path, or says there is none."
        ) { _ in
            try await MainActor.run { try model.openAdjacent(forward: true) }
        })

        try context.registerCommand(Command(
            id: "calendar.open",
            title: "Open calendar",
            summary: "Opens the calendar of daily notes on the current month, beside the focused tab. Returns what "
                + "it did."
        ) { _ in
            await MainActor.run { model.openCalendar(Self.calendarResource) }
        })

        context.on(VaultChanged.self) { [weak model] event in
            guard !event.noteChanges.isEmpty else { return }
            MainThread.run { model?.refresh() }
        }
        context.on(NotesMoved.self) { [weak model] _ in
            MainThread.run { model?.refresh() }
        }
        // The provider of the service says when its folder changes: list the days of the new one.
        context.on(DailyNotesLayoutChanged.self) { [weak model] _ in
            MainThread.run { model?.refresh() }
        }
        context.on(ActiveResourceChanged.self) { [weak model] event in
            let resource = event.resource
            MainThread.run { model?.activeChanged(resource) }
        }
    }

    /// `calendar:` (the current month) or `calendar:YYYY-MM`.
    static func isCalendar(_ resource: Resource) -> Bool {
        guard resource.kind == .virtual, resource.path.hasPrefix("calendar:") else { return false }
        let rest = resource.path.dropFirst("calendar:".count)
        return rest.isEmpty || month(of: resource) != nil
    }

    /// The month a `calendar:YYYY-MM` resource names; nil for `calendar:` alone and anything else.
    static func month(of resource: Resource) -> Month? {
        guard resource.kind == .virtual, resource.path.hasPrefix("calendar:") else { return nil }
        let rest = resource.path.dropFirst("calendar:".count)
        guard rest.count == 7 else { return nil }
        return Month(String(rest))
    }
}

/// What a calendar tab saves: the month it shows, `YYYY-MM`.
struct CalendarState: Codable, Equatable {
    var month: String
}

enum DailyNotesUIError: Error, Equatable {
    /// The host activates this plugin after `daily-notes` (it is in `requires`), so this means a broken host.
    case serviceMissing
}

