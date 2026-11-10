import Foundation

/// A plain JSON value. Settings use the same enum as frontmatter properties, so a plugin learns one type.
public typealias JSONValue = PropertyValue

/// One plugin's settings, stored in `.loam/config.json` under `plugins.<id>.settings`.
///
/// A plugin describes its settings as one `Codable` value with a default, and reads it back with that default:
///
///     struct Settings: Codable, Equatable { var folder = "Daily"; var template = "" }
///     let settings = context.settings.value(default: Settings())
///
/// Keys missing from the file come from the default, so adding a setting never breaks an existing vault.
public protocol PluginSettingsAccess: AnyObject {
    /// The stored settings merged over the encoded `default`, key by key at the top level, then decoded. A stored
    /// key that does not decode (text where the default has a number) follows the default; returns `default` when
    /// nothing is stored or the stored value does not decode at all.
    func value<S: Codable & Equatable>(default: S) -> S
    /// Replaces the stored settings with `value` and sends `PluginSettingsChanged`.
    func update<S: Codable & Equatable>(_ value: S) throws
}

/// Sent after a plugin's settings were updated, so the plugin (or its settings view) can refresh.
public struct PluginSettingsChanged: PluginEvent, Equatable {
    public let pluginID: String

    public init(pluginID: String) {
        self.pluginID = pluginID
    }
}

/// How a plugin's page in Settings names one of its settings. The value and its default come from the plugin's
/// settings (`context.settings.value(default:)`); this gives it a title, a line of help, for a setting with a fixed
/// set of values the choices of a picker, and optionally its default, so the page shows it before the plugin has
/// run (turned off, safe mode):
///
///     settings: [
///         SettingDescription("folder", title: "Folder", help: "Where new daily notes go.", default: .string("Daily")),
///         SettingDescription("week", title: "Week starts on", choices: [
///             SettingChoice(.string("monday"), title: "Monday"), SettingChoice(.string("sunday"), title: "Sunday"),
///         ]),
///     ]
///
/// A setting without a description is still shown, titled after its key (`showRecent`: "Show recent").
public struct SettingDescription: Codable, Sendable, Equatable {
    /// A top-level key of the settings value: a property of the plugin's `Codable` settings.
    public let key: String
    public let title: String
    /// One line under the title; empty for none.
    public let help: String
    /// The value the plugin reads when nothing is stored, the same as its `Codable` default gives. Optional: the
    /// kernel learns it when the plugin reads its settings; given here, the page shows the setting, and checks what is
    /// typed in it, before then.
    public let defaultValue: JSONValue?
    /// The values a picker offers, in order; empty for a switch (a bool), a text field (a string) or a number field.
    public let choices: [SettingChoice]
    /// A text setting naming a vault folder: the page offers the vault's folders and says whether the one typed
    /// exists. `"folder": true` in a manifest file.
    public let isFolder: Bool
    /// A setting with `choices` whose page draws them as chips the user taps, beside a field they can type in: for
    /// values that are short and worth seeing at once (the daily notes' subfolder pattern). `"chips": true` in a
    /// manifest file. A setting without choices ignores it.
    public let chips: Bool
    /// A command the page runs with `value` (what is typed, before it is saved) to get one line to show under the
    /// field: what the value will do, worked out by the plugin that knows (`daily.path-preview` says where today's
    /// note will go). `"preview": "command.id"` in a manifest file. Empty for none.
    public let preview: String

    public init(
        _ key: String, title: String, help: String = "", default defaultValue: JSONValue? = nil,
        choices: [SettingChoice] = []
    ) {
        self.init(key, title: title, help: help, default: defaultValue, choices: choices, folder: false)
    }

    public init(
        _ key: String, title: String, help: String = "", default defaultValue: JSONValue? = nil,
        choices: [SettingChoice] = [], folder: Bool
    ) {
        self.init(key, title: title, help: help, default: defaultValue, choices: choices, folder: folder, chips: false)
    }

    public init(
        _ key: String, title: String, help: String = "", default defaultValue: JSONValue? = nil,
        choices: [SettingChoice] = [], chips: Bool
    ) {
        self.init(key, title: title, help: help, default: defaultValue, choices: choices, folder: false, chips: chips)
    }

    /// Every option at once. The shorter initializers above stay, so a plugin compiled against them keeps running.
    public init(
        _ key: String, title: String, help: String = "", default defaultValue: JSONValue? = nil,
        choices: [SettingChoice] = [], folder: Bool = false, chips: Bool = false, preview: String = ""
    ) {
        self.key = key
        self.title = title
        self.help = help
        self.defaultValue = defaultValue
        self.choices = choices
        self.isFolder = folder
        self.chips = chips
        self.preview = preview
    }

    /// The one `folder` and `chips` took, kept for plugins compiled against it.
    public init(
        _ key: String, title: String, help: String = "", default defaultValue: JSONValue? = nil,
        choices: [SettingChoice] = [], folder: Bool, chips: Bool
    ) {
        self.init(key, title: title, help: help, default: defaultValue, choices: choices,
                  folder: folder, chips: chips, preview: "")
    }

    private enum CodingKeys: String, CodingKey {
        case key, title, help, choices, chips, preview
        case defaultValue = "default"
        case isFolder = "folder"
    }

    /// Only `key` and `title` are required in a manifest file.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        key = try container.decode(String.self, forKey: .key)
        title = try container.decode(String.self, forKey: .title)
        help = try container.decodeIfPresent(String.self, forKey: .help) ?? ""
        defaultValue = try container.decodeIfPresent(JSONValue.self, forKey: .defaultValue)
        choices = try container.decodeIfPresent([SettingChoice].self, forKey: .choices) ?? []
        isFolder = try container.decodeIfPresent(Bool.self, forKey: .isFolder) ?? false
        chips = try container.decodeIfPresent(Bool.self, forKey: .chips) ?? false
        preview = try container.decodeIfPresent(String.self, forKey: .preview) ?? ""
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(key, forKey: .key)
        try container.encode(title, forKey: .title)
        try container.encode(help, forKey: .help)
        try container.encodeIfPresent(defaultValue, forKey: .defaultValue)
        try container.encode(choices, forKey: .choices)
        if isFolder { try container.encode(true, forKey: .isFolder) }
        if chips { try container.encode(true, forKey: .chips) }
        if !preview.isEmpty { try container.encode(preview, forKey: .preview) }
    }
}

/// One value of a setting's picker, with the words shown for it.
public struct SettingChoice: Codable, Sendable, Equatable {
    public let value: JSONValue
    public let title: String

    public init(_ value: JSONValue, title: String) {
        self.value = value
        self.title = title
    }
}
