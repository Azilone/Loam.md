import Foundation
import Observation
import PluginKit
import PluginKitUI
import LoamCore
import SwiftUI

/// The themes of a vault: the files in `.loam/themes/` and the one `.loam/config.json` chooses with `"theme": "<name>"`
/// (the file name without `.json`; none, or the retired `"system"`, is the built-in Dither Green theme). Plugins never see
/// it: the shell turns the chosen theme into the `themeTokens` of the window.
///
/// A theme that cannot be used (missing, not valid) leaves the system look and says why in `error`; it never stops
/// the app. `reload` is called when anything under the vault changes, so a theme edited by hand or by an agent
/// applies at once.
@MainActor
@Observable
public final class ThemeStore {
    /// One file of `.loam/themes/`.
    public struct Entry: Identifiable, Equatable, Sendable {
        /// The file name without `.json`: what the config names.
        public let id: String
        /// The parsed theme, nil when the file cannot be read.
        public let theme: Theme?
        /// Why the file cannot be used.
        public let error: String?

        public var displayName: String { theme?.name ?? id }
    }

    public static let folder = ".loam/themes"
    /// The top-level key of `.loam/config.json` that names the theme.
    public static let configKey = "theme"
    /// The theme used when the config names none: the built-in Dither Green.
    public static let defaultName = BuiltInThemes.ditherGreen.id
    /// What older configs name for the retired system look; read as the default theme.
    public static let systemName = "system"
    /// The keys of `.loam/config.json` that override the theme: `"appearance": "light" | "dark" | "auto"` and
    /// `"accent": "#RRGGBB"`. Settings > Appearance writes them.
    public static let appearanceKey = "appearance"
    public static let accentKey = "accent"
    /// The accents offered in Settings, the design's blue first.
    nonisolated public static let accents: [(name: String, color: ThemeColor)] = [
        ("Blue", ThemeColor(hex: "#2F62E0")!),
        ("Magenta", ThemeColor(hex: "#C6339A")!),
        ("Teal", ThemeColor(hex: "#3FB8A0")!),
        ("Violet", ThemeColor(hex: "#5B1FD6")!),
        ("Mustard", ThemeColor(hex: "#E0B52F")!),
        ("Graphite", ThemeColor(hex: "#4A4F58")!),
    ]

    /// The theme files, sorted by name.
    public private(set) var entries: [Entry] = []
    /// What the config names, nil for the system look.
    public private(set) var selectedName: String?
    /// The theme in use, nil for the system look.
    public private(set) var current: Theme?
    /// Why the chosen theme is not in use, shown in Settings.
    public private(set) var error: String?
    /// The appearance chosen in Settings, for a theme made for light and dark (one made for one keeps it); nil is
    /// light (the design is light first; `auto` in Settings follows the system).
    public private(set) var appearance: ThemeAppearance?
    /// The accent chosen in Settings, over the theme's; nil keeps the theme's.
    public private(set) var accent: ThemeColor?
    /// The text size as a multiple of the theme's, set with Cmd-+ and Cmd-- as in a browser. A preference of this
    /// Mac, not of the vault: it is kept in the user defaults, not in `.loam/config.json`.
    public private(set) var textZoom: Double = ThemeStore.storedTextZoom

    @ObservationIgnored public let rootURL: URL
    @ObservationIgnored private let config: ConfigStore

    public init(rootURL: URL, config: ConfigStore) {
        self.rootURL = rootURL
        self.config = config
        reload()
    }

    public var folderURL: URL { rootURL.appendingPathComponent(Self.folder, isDirectory: true) }

    /// The scheme the window is forced into, nil to follow the system.
    public var colorScheme: ColorScheme? { effectiveTheme.colorScheme }

    /// The tokens for the window: the current theme's, or the system's, with the appearance and accent chosen in
    /// Settings on top.
    public func tokens(systemIsDark: Bool) -> ThemeTokens {
        let theme = effectiveTheme
        var tokens = theme.tokens(dark: theme.isDark(systemIsDark: systemIsDark))
        tokens.bodySize = (tokens.bodySize * textZoom).rounded()
        return tokens
    }

    /// The current theme (or the system look) with the overrides of Settings.
    private var effectiveTheme: Theme {
        var theme = current ?? Theme(name: "System")
        // The appearance chosen in Settings applies to a theme made for both; a theme made for one keeps it, since its
        // colours are drawn for it (a dark theme in a light window puts light text on the system's light controls).
        if theme.appearance == .auto {
            theme.appearance = appearance ?? .light
        }
        if let accent {
            theme.colors.accent = accent
            if theme.darkColors.accent != nil { theme.darkColors.accent = accent }
        }
        return theme
    }

    // MARK: Loading

    /// Reads the theme files and the config (as last loaded by its store) again. Changes nothing observable when
    /// nothing changed, so it is cheap to call on every file event.
    public func reload() {
        let entries = Self.readEntries(in: folderURL)
        var selected: String?
        var current: Theme?
        var error: String?
        let configured: String?
        switch config.config.raw[Self.configKey] {
        case nil, .null?:
            configured = Self.defaultName
        case .string(let name)? where name.isEmpty || name.lowercased() == Self.systemName:
            // The system look is gone: a vault that still names it gets the default theme.
            configured = Self.defaultName
        case .string(let name)?:
            configured = name
        case _?:
            configured = nil
            error = String(localized: "\"theme\" in .loam/config.json must be the name of a theme. The system look is used instead.")
        }
        if let name = configured {
            selected = name
            if let entry = Self.entry(named: name, in: entries) ?? Self.entry(named: name, in: BuiltInThemes.all) {
                current = entry.theme
                if let reason = entry.error {
                    error = String(localized: "The theme “\(name)” cannot be used: \(reason). The system look is used instead.")
                }
            } else {
                error = String(localized: "No theme named “\(name)” in \(Self.folder). The system look is used instead.")
            }
        }
        let raw = config.config.raw
        var appearance: ThemeAppearance?
        if case .string(let text)? = raw[Self.appearanceKey] { appearance = ThemeAppearance(rawValue: text.lowercased()) }
        var accent: ThemeColor?
        if case .string(let text)? = raw[Self.accentKey] { accent = ThemeColor(hex: text) }
        if self.appearance != appearance { self.appearance = appearance }
        if self.accent != accent { self.accent = accent }
        if self.entries != entries { self.entries = entries }
        if self.selectedName != selected { self.selectedName = selected }
        if self.current != current { self.current = current }
        AppIcon.shared.apply(for: current)
        if self.error != error { self.error = error }
    }

    /// The file named `name`, or else the one whose name or `name` key matches ignoring case.
    static func entry(named name: String, in entries: [Entry]) -> Entry? {
        entries.first { $0.id == name }
            ?? entries.first { $0.id.caseInsensitiveCompare(name) == .orderedSame }
            ?? entries.first { $0.theme?.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    static func readEntries(in folder: URL) -> [Entry] {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return files
            .filter { $0.pathExtension.lowercased() == "json" && !$0.lastPathComponent.hasPrefix(".") }
            .map { url in
                let id = url.deletingPathExtension().lastPathComponent
                do {
                    let theme = try Theme.parse(try Data(contentsOf: url), fallbackName: id)
                    return Entry(id: id, theme: theme, error: nil)
                } catch {
                    return Entry(id: id, theme: nil, error: (error as? LocalizedError)?.errorDescription ?? "\(error)")
                }
            }
            .sorted { $0.id.localizedStandardCompare($1.id) == .orderedAscending }
    }

    // MARK: Changing

    /// Writes the choice to `.loam/config.json` (nil: the default theme) and applies it.
    public func select(_ name: String?) throws {
        try config.mutate { config in
            config.raw[Self.configKey] = .string(name ?? Self.defaultName)
        }
        reload()
    }

    /// Writes the appearance chosen in Settings to `.loam/config.json` (nil: the theme's) and applies it.
    public func setAppearance(_ appearance: ThemeAppearance?) throws {
        try config.mutate { config in
            config.raw[Self.appearanceKey] = appearance.map { .string($0.rawValue) }
        }
        reload()
    }

    /// Writes the accent chosen in Settings to `.loam/config.json` (nil: the theme's) and applies it.
    public func setAccent(_ accent: ThemeColor?) throws {
        try config.mutate { config in
            config.raw[Self.accentKey] = accent.map { .string($0.hex) }
        }
        reload()
    }

    // MARK: Text zoom

    /// The steps of Cmd-+ and Cmd--, Safari's within what the editor's fixed parts (checkboxes, pills) still fit.
    public static let textZoomSteps: [Double] = [0.75, 0.85, 1, 1.15, 1.25, 1.5, 1.75, 2]
    static let textZoomKey = "textZoom"

    private static var storedTextZoom: Double {
        let value = UserDefaults.standard.double(forKey: textZoomKey)
        return textZoomSteps.contains(value) ? value : 1
    }

    public var canZoomTextIn: Bool { textZoom < Self.textZoomSteps.last! }
    public var canZoomTextOut: Bool { textZoom > Self.textZoomSteps.first! }

    /// One step larger (`by: 1`) or smaller (`by: -1`).
    public func zoomText(by step: Int) {
        let steps = Self.textZoomSteps
        let index = steps.firstIndex(of: textZoom) ?? steps.firstIndex(of: 1)!
        setTextZoom(steps[min(max(index + step, 0), steps.count - 1)])
    }

    public func setTextZoom(_ zoom: Double) {
        guard zoom != textZoom else { return }
        textZoom = zoom
        if zoom == 1 {
            UserDefaults.standard.removeObject(forKey: Self.textZoomKey)
        } else {
            UserDefaults.standard.set(zoom, forKey: Self.textZoomKey)
        }
    }

    /// Writes the example themes to `.loam/themes/`, keeping files that already exist. Returns the paths written.
    @discardableResult
    public func installExamples() throws -> [String] {
        try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        var written: [String] = []
        for (name, json) in Self.examples {
            let url = folderURL.appendingPathComponent("\(name).json")
            guard !FileManager.default.fileExists(atPath: url.path) else { continue }
            try Data(json.utf8).write(to: url, options: .atomic)
            written.append("\(Self.folder)/\(name).json")
        }
        reload()
        return written
    }

    /// Writes a theme from the catalog to `.loam/themes/<id>.json`, after reading it as a theme. An existing file is
    /// kept unless `force`. Returns the path written.
    @discardableResult
    public func install(id: String, json: Data, force: Bool = false) throws -> String {
        guard ThemeCatalog.isValidID(id) else { throw ThemeError.invalid("“\(id)” is not a theme id") }
        _ = try Theme.parse(json, fallbackName: id)
        try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        let url = folderURL.appendingPathComponent("\(id).json")
        if !force, FileManager.default.fileExists(atPath: url.path) {
            throw ThemeError.invalid("\(Self.folder)/\(id).json already exists")
        }
        try json.write(to: url, options: .atomic)
        reload()
        return "\(Self.folder)/\(id).json"
    }

    /// Whether `.loam/themes/<id>.json` exists.
    public func isInstalled(_ id: String) -> Bool {
        FileManager.default.fileExists(atPath: folderURL.appendingPathComponent("\(id).json").path)
    }

    /// Templates for users and agents: every key of the format, a light theme with dark overrides and a dark one.
    public static let examples: [(name: String, json: String)] = [
        ("Paper", """
        {
          "name": "Paper",
          "appearance": "auto",
          "colors": {
            "accent": "#C2410C",
            "text": "#1F2937",
            "secondaryText": "#6B7280",
            "background": "#FBF7F0",
            "separator": "#E5E0D8",
            "codeBackground": "#F2EDE4",
            "link": "#C2410C",
            "marker": "#B8B0A3",
            "heading": "#111827",
            "highlight": "#FDE7A9",
            "tagText": "#9A3412",
            "tagBackground": "#F6E3D3",
            "checkbox": "#C2410C",
            "checkboxBorder": "#B8B0A3",
            "quoteBar": "#C2410C",
            "sidebar": "#F3EDE3"
          },
          "dark": {
            "colors": {
              "accent": "#F59E0B",
              "text": "#EDE6DA",
              "secondaryText": "#A8A092",
              "background": "#1C1A17",
              "separator": "#36322C",
              "codeBackground": "#26231F",
              "link": "#F59E0B",
              "marker": "#6B645A",
              "heading": "#F5EFE4",
              "highlight": "#5C4A1A",
              "tagText": "#FBBF24",
              "tagBackground": "#3A2F1C",
              "checkbox": "#F59E0B",
              "checkboxBorder": "#6B645A",
              "quoteBar": "#F59E0B",
              "sidebar": "#161412"
            }
          },
          "fonts": { "body": "New York", "mono": "SF Mono", "size": 16 },
          "editor": { "lineHeight": 1.3, "columnWidth": 720 },
          "headings": { "font": "New York", "weight": "bold", "sizes": [1.6, 1.35, 1.15, 1], "rules": [1] },
          "tasks": { "checkbox": "circle", "strikethrough": true },
          "tags": { "shape": "rounded" }
        }

        """),
        ("Night", """
        {
          "name": "Night",
          "appearance": "dark",
          "colors": {
            "accent": "#7AA2F7",
            "text": "#D8DEE9",
            "secondaryText": "#8A94A6",
            "background": "#16181D",
            "separator": "#2A2E36",
            "codeBackground": "#1F232B",
            "link": "#7AA2F7",
            "marker": "#4C5566",
            "heading": "#ECEFF4",
            "highlight": "#3B4A6B",
            "tagText": "#7AA2F7",
            "tagBackground": "#232B3D",
            "checkbox": "#7AA2F7",
            "checkboxBorder": "#4C5566",
            "quoteBar": "#7AA2F7",
            "sidebar": "#111317"
          },
          "fonts": { "body": "SF Pro", "mono": "SF Mono", "size": 15 },
          "editor": { "lineHeight": 1.35, "columnWidth": 760 },
          "headings": { "weight": "semibold", "rules": [1, 2] },
          "tasks": { "checkbox": "circle", "strikethrough": false },
          "tags": { "shape": "capsule" }
        }

        """),
    ]
}
