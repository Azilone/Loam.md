import Observation
import SwiftUI

/// A part of a plugin's own page in Settings that the generic form cannot draw: a list the user edits (the
/// Assistant's saved prompts), the state of something outside the app (its agents). The page shows it under the
/// plugin's settings, under `title`, in the page's grey card.
public struct SettingsSection: Identifiable, Sendable {
    /// Dotted and owned by the plugin, such as `assistant.prompts`.
    public let id: String
    /// The plugin whose page shows it.
    public let pluginID: String
    public let title: String
    /// One line under the title; empty for none.
    public let subtitle: String
    /// Top to bottom: lower first. Below 0, above the plugin's generic settings; else under them.
    public let order: Int
    public let makeView: @MainActor () -> AnyView

    public init(
        id: String, pluginID: String, title: String, subtitle: String = "", order: Int = 0,
        makeView: @escaping @MainActor () -> AnyView
    ) {
        self.id = id
        self.pluginID = pluginID
        self.title = title
        self.subtitle = subtitle
        self.order = order
        self.makeView = makeView
    }
}

/// Where settings sections are registered, and the way to the page that shows them. Plugins use
/// `context.addSettingsSection` and `context.openSettings(pluginID:)`.
@MainActor
public protocol SettingsSectionRegistry: AnyObject {
    func register(_ section: SettingsSection) -> @MainActor () -> Void
    /// The sections of `pluginID`'s page, by `order`, then by id.
    func sections(for pluginID: String) -> [SettingsSection]
    /// Opens the settings window on `pluginID`'s page.
    func openPage(_ pluginID: String)
}

/// The standard `SettingsSectionRegistry`; the shell sets `open`.
@MainActor
@Observable
public final class SettingsSectionStore: SettingsSectionRegistry {
    private var entries = RegistryEntries<SettingsSection>()
    @ObservationIgnored public var open: ((String) -> Void)?

    public init() {}

    public func register(_ section: SettingsSection) -> @MainActor () -> Void {
        let token = entries.insert(section, id: section.id)
        return { [weak self] in self?.entries.remove(token) }
    }

    public func sections(for pluginID: String) -> [SettingsSection] {
        entries.values
            .filter { $0.pluginID == pluginID }
            .sorted { $0.order != $1.order ? $0.order < $1.order : $0.id < $1.id }
    }

    public func openPage(_ pluginID: String) {
        open?(pluginID)
    }
}

public extension ServiceKey where Service == any SettingsSectionRegistry {
    static var settingsSections: ServiceKey<any SettingsSectionRegistry> {
        ServiceKey<any SettingsSectionRegistry>("ui.settings-sections")
    }
}

@MainActor
public extension PluginContext {
    /// Adds a section to a plugin's page in Settings. Throws `UIContractError.registryMissing("ui.settings-sections")`
    /// without the shell.
    func addSettingsSection(_ section: SettingsSection) throws {
        guard let registry = service(.settingsSections) else {
            throw UIContractError.registryMissing(ServiceKey<any SettingsSectionRegistry>.settingsSections.id)
        }
        let remove = registry.register(section)
        effect { MainActor.assumeIsolated { remove() } }
    }

    /// Opens the settings window on a plugin's page (its settings and sections).
    func openSettings(pluginID: String) {
        service(.settingsSections)?.openPage(pluginID)
    }
}
