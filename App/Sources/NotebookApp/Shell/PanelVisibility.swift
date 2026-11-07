import Foundation
import Observation
import PluginKit
import PluginKitUI
import LoamCore

/// Which panels the side columns show. Simple by default: only the first panel of the right column (the lowest
/// `order`: backlinks); every other panel is off until turned on in
/// Settings > Sidebars. The status bar shows all of its panels.
///
/// Choices live in `.loam/config.json` as `"panels": { "<panel id>": true | false }`, so they travel with the vault
/// and an agent can set them. A panel the config does not name follows the default.
@MainActor
@Observable
public final class PanelVisibility {
    /// The top-level key of `.loam/config.json`.
    public static let configKey = "panels"

    /// The choices of the config, by panel id.
    public private(set) var choices: [String: Bool] = [:]

    @ObservationIgnored private let config: ConfigStore

    public init(config: ConfigStore) {
        self.config = config
        reload()
    }

    /// Reads the choices again from the config as last loaded. Changes nothing observable when nothing changed.
    public func reload() {
        var choices: [String: Bool] = [:]
        if case .map(let map)? = config.config.raw[Self.configKey] {
            for (id, value) in map {
                if case .bool(let shown) = value { choices[id] = shown }
            }
        }
        if self.choices != choices { self.choices = choices }
    }

    /// Whether `panel` is shown, among the `registered` panels of its slot (sorted by order, as the registry gives
    /// them).
    public func isShown(_ panel: Panel, among registered: [Panel]) -> Bool {
        if let choice = choices[panel.id] { return choice }
        return Self.isShownByDefault(panel, among: registered)
    }

    /// The default: every status bar panel, and every panel of the right column, where they show as groups of the
    /// inspector's "Info". The left column's panels start off: its sections (`SidebarSection`) are the sidebar.
    public static func isShownByDefault(_ panel: Panel, among registered: [Panel]) -> Bool {
        panel.slot == .statusBar || panel.slot == .trailing
    }

    /// The panels of `registered` to show.
    public func shown(_ registered: [Panel]) -> [Panel] {
        registered.filter { isShown($0, among: registered) }
    }

    /// Writes a choice to the config. A choice equal to the default is removed, so the config only holds what the
    /// user changed.
    public func set(_ panel: Panel, shown: Bool, among registered: [Panel]) throws {
        let isDefault = Self.isShownByDefault(panel, among: registered) == shown
        try config.mutate { config in
            var map: [String: JSONValue] = [:]
            if case .map(let existing)? = config.raw[Self.configKey] { map = existing }
            map[panel.id] = isDefault ? nil : .bool(shown)
            config.raw[Self.configKey] = map.isEmpty ? nil : .map(map)
        }
        reload()
    }

    /// Goes back to the simple default: removes every choice.
    public func reset() throws {
        try config.mutate { config in
            config.raw[Self.configKey] = nil
        }
        reload()
    }
}
