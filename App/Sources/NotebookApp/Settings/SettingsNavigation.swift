import CoreGraphics
import Observation

/// The panes of the settings window.
public enum SettingsPane: String, CaseIterable, Identifiable, Sendable {
    case vaults, appearance, sidebars, shortcuts, plugins, developers, about

    public var id: String { rawValue }

    var title: String {
        switch self {
        case .vaults: String(localized: "Vaults")
        case .appearance: String(localized: "Appearance")
        case .sidebars: String(localized: "Sidebars")
        case .shortcuts: String(localized: "Shortcuts")
        case .plugins: String(localized: "Plugins")
        case .developers: String(localized: "Developers")
        case .about: String(localized: "About")
        }
    }

    var symbol: String {
        switch self {
        case .vaults: "folder"
        case .appearance: "textformat"
        case .sidebars: "sidebar.left"
        case .shortcuts: "command"
        case .plugins: "puzzlepiece.extension"
        case .developers: "terminal"
        case .about: "info.circle"
        }
    }
}

/// Where the settings window is: a pane, and on the Plugins pane the plugin whose page is open. The app keeps it, so
/// the window opens where it was left and a developer script can open a plugin's page (`settings plugins/<id>`).
@MainActor
@Observable
public final class SettingsNavigation {
    public var pane: SettingsPane = .plugins
    /// The plugin whose page is open over the list of plugins; nil for the list.
    public var pluginID: String?

    /// The plugin pages Back returns to, the last one last.
    @ObservationIgnored private var history: [String] = []
    /// How far each page is scrolled, by title: a page rebuilt in place (a new theme redraws the window) opens where
    /// it was. Going to another pane forgets it.
    @ObservationIgnored var scrollOffsets: [String: CGFloat] = [:]

    public init() {}

    public func open(_ pane: SettingsPane, plugin: String? = nil) {
        history = []
        scrollOffsets = [:]
        self.pane = pane
        pluginID = pane == .plugins ? plugin : nil
    }

    /// Opens a plugin's page from the page of another (one it needs): Back returns there.
    public func openPlugin(_ id: String) {
        if pane == .plugins, let current = pluginID, current != id { history.append(current) }
        pane = .plugins
        pluginID = id
    }

    /// From a plugin's page, the page it was opened from, else the list.
    public func back() {
        pluginID = history.popLast()
    }

    /// Opens `appearance`, `plugins` or `plugins/<id>`. False when the path names no pane.
    @discardableResult
    public func open(path: String) -> Bool {
        let parts = path.split(separator: "/", maxSplits: 1).map(String.init)
        guard let first = parts.first, let pane = SettingsPane(rawValue: first) else { return false }
        open(pane, plugin: parts.count > 1 ? parts[1] : nil)
        return true
    }
}
