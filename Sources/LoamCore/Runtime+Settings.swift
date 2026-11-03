import Foundation
import PluginKit

/// One top-level key of a plugin's settings, as its page in Settings and `plugins.settings` show it.
public struct SettingField: Codable, Identifiable, Equatable, Sendable {
    /// Empty when the settings are not an object: the field is then the whole value.
    public let key: String
    /// The value in effect: the stored one, else (nothing stored, or a stored value the plugin cannot read) the
    /// plugin's default.
    public let value: JSONValue
    /// The plugin's default for it; nil when unknown (a plugin that has not run, for a key it does not describe).
    /// Its type gives the control on the plugin's page, and the type a new value must have.
    public var defaultValue: JSONValue?
    /// From the plugin's `SettingDescription`, else made from the key (`showRecent`: "Show recent").
    public var title: String
    public var help: String
    /// A picker's values, from the plugin's `SettingDescription`; empty for the control the value's type gives.
    public var choices: [SettingChoice]
    /// True when the value is the plugin's default: nothing is stored for it, or what is stored cannot be read.
    public var isDefault: Bool
    /// A number setting the plugin reads as an integer (a count of days): a fraction is refused.
    public var isWholeNumber: Bool

    public init(key: String, value: JSONValue, defaultValue: JSONValue? = nil, title: String? = nil, help: String = "",
                choices: [SettingChoice] = [], isDefault: Bool = false, isWholeNumber: Bool = false) {
        self.key = key
        self.value = value
        self.defaultValue = defaultValue
        self.title = title ?? SettingField.title(forKey: key)
        self.help = help
        self.choices = choices
        self.isDefault = isDefault
        self.isWholeNumber = isWholeNumber
    }

    /// The value whose type picks the control: the default's when known, so a stored value of the wrong type never
    /// turns a text field into a switch.
    public var kind: JSONValue {
        if let defaultValue, defaultValue != .null { return defaultValue }
        return value
    }

    public var id: String { key }

    /// A key in words: `showRecent` and `show_recent` give "Show recent", `imageURL` gives "Image URL".
    public static func title(forKey key: String) -> String {
        guard !key.isEmpty else { return "Value" }
        var words: [String] = []
        var word = ""
        let characters = Array(key)
        for (index, character) in characters.enumerated() {
            if character == "_" || character == "-" || character == " " || character == "." {
                if !word.isEmpty { words.append(word) }
                word = ""
                continue
            }
            if character.isUppercase, let last = word.last {
                let nextIsLower = index + 1 < characters.count && characters[index + 1].isLowercase
                if last.isLowercase || last.isNumber || (last.isUppercase && nextIsLower) {
                    words.append(word)
                    word = ""
                }
            }
            word.append(character)
        }
        if !word.isEmpty { words.append(word) }
        return words.enumerated().map { index, word in
            // Acronyms stay as they are; other words read as a sentence.
            if word.count > 1, word.allSatisfy({ $0.isUppercase || $0.isNumber }) { return word }
            let lower = word.lowercased()
            return index == 0 ? lower.prefix(1).uppercased() + lower.dropFirst() : lower
        }.joined(separator: " ")
    }
}

/// Plugin settings for the settings window and for agents: every key a plugin has, stored or not, and writing one.
extension Runtime {
    /// A plugin's settings, one field per top-level key: the stored value over the default the plugin reads its
    /// settings with (`settingsDefault(for:)`), titled by its `SettingDescription`s. A stored value the plugin cannot
    /// read shows its default, as the plugin then uses it. Described keys come first, in their order, then the others
    /// by key. Empty when the plugin has no settings, or has not run, describes no default and nothing is stored.
    public func settingFields(for id: String) -> [SettingField] {
        let stored = config.config.settings(for: id)
        let defaults = settingsDefault(for: id)
        // Settings that are one value rather than an object: a single field, the whole value.
        if let stored, stored.mapValue == nil, stored != .null {
            let readable = accepts(stored, key: "", default: defaults, for: id)
            return [field(key: "", stored: readable ? stored : nil, default: defaults, for: id)]
        }
        if stored?.mapValue == nil, let defaults, defaults.mapValue == nil {
            return [field(key: "", stored: nil, default: defaults, for: id)]
        }

        let storedMap = stored?.mapValue ?? [:]
        let defaultMap = defaults?.mapValue ?? [:]
        let descriptions = descriptions(of: id)
        // Once the plugin's keys are known, a stored key it never reads (a typo, a leftover) is not a setting.
        let known = defaults?.mapValue != nil
        let shown = known ? Set(defaultMap.keys) : Set(storedMap.keys).union(defaultMap.keys)
        let described = descriptions.map(\.key).filter { shown.contains($0) }
        let others = shown.subtracting(described).sorted()
        return (described + others).map { key in
            let fallback = defaultMap[key]
            let value = storedMap[key].flatMap { accepts($0, key: key, default: fallback, for: id) ? $0 : nil }
            var field = field(key: key, stored: value, default: fallback, for: id)
            if let description = descriptions.first(where: { $0.key == key }) {
                field.title = description.title
                field.help = description.help
                field.choices = description.choices
            }
            return field
        }
    }

    /// Writes one setting (`key` empty: the whole value) to `.loam/config.json` and sends `PluginSettingsChanged`, so
    /// the plugin applies it. The other stored keys stay; keys never written keep following the plugin's defaults.
    /// Throws `RuntimeError.invalidSetting`, writing nothing, for a value the plugin cannot read: another type than
    /// its default (text for a switch), or one its settings type refuses (a fraction for a whole number).
    public func setSetting(_ key: String, to value: JSONValue, for id: String) throws {
        let fallback = defaultSetting(key, for: id)
        if !key.isEmpty, fallback == nil, config.config.settings(for: id)?.mapValue?[key] == nil {
            // A key the plugin never reads would show as a setting that does nothing.
            let known = (settingsDefault(for: id)?.mapValue ?? [:]).keys.sorted()
            throw RuntimeError.unknownSetting(id: id, key: key, known: known)
        }
        guard accepts(value, key: key, default: fallback, for: id) else {
            throw RuntimeError.invalidSetting(id: id, key: key, expected: Self.expectation(fallback, given: value))
        }
        try config.mutate { config in
            guard !key.isEmpty else { return config.setSettings(value, for: id) }
            var map = config.settings(for: id)?.mapValue ?? [:]
            map[key] = value
            config.setSettings(.map(map), for: id)
        }
        kernel.events.emit(PluginSettingsChanged(pluginID: id))
    }

    /// Tells the plugins whose stored settings differ from `before` (a config read from disk after an edit made
    /// outside this process: the CLI, a sync, a hand edit), as `setSetting` does for a change made here.
    public func announceSettingChanges(since before: VaultConfig) {
        func ids(_ config: VaultConfig) -> Set<String> { Set(config.raw["plugins"]?.mapValue?.keys.map { $0 } ?? []) }
        let now = config.config
        for id in ids(before).union(ids(now)).sorted() where before.settings(for: id) != now.settings(for: id) {
            kernel.events.emit(PluginSettingsChanged(pluginID: id))
        }
    }

    /// The default a plugin reads its settings with: what it read them with (`Kernel.settingsDefault(for:)`), over
    /// the defaults its `SettingDescription`s give, so a plugin that has not run (turned off, safe mode) has them too.
    public func settingsDefault(for id: String) -> JSONValue? {
        let described = descriptions(of: id).compactMap { description in
            description.defaultValue.map { (description.key, $0) }
        }
        let fromDescriptions = described.isEmpty
            ? nil : JSONValue.map(Dictionary(described, uniquingKeysWith: { first, _ in first }))
        guard let read = kernel.settingsDefault(for: id) else { return fromDescriptions }
        return fromDescriptions.map { JSONBridge.merge(read, over: $0) } ?? read
    }

    /// What `plugins.set-setting` stores for the text it was given: for a setting whose default is text, the text
    /// itself (a folder named 2026 stays "2026"; a quoted JSON string loses its quotes); otherwise its JSON (`true`,
    /// `3`, `["a"]`), or the text when it is not JSON.
    func settingValue(parsing text: String, key: String, for id: String) -> JSONValue {
        let parsed = try? JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
        if case .string = defaultSetting(key, for: id) {
            if case .string(let string)? = parsed { return .string(string) }
            return .string(text)
        }
        return parsed ?? .string(text)
    }

    private func descriptions(of id: String) -> [SettingDescription] {
        host.manifests.first { $0.id == id }?.settings ?? []
    }

    private func defaultSetting(_ key: String, for id: String) -> JSONValue? {
        let defaults = settingsDefault(for: id)
        return key.isEmpty ? defaults : defaults?.mapValue?[key]
    }

    private func field(key: String, stored: JSONValue?, default fallback: JSONValue?, for id: String) -> SettingField {
        var isWholeNumber = false
        if case .number(let number) = fallback {
            // A plugin reading an integer cannot read half of one.
            isWholeNumber = !accepts(.number(number + 0.5), key: key, default: fallback, for: id)
        }
        return SettingField(
            key: key, value: stored ?? fallback ?? .null, defaultValue: fallback, isDefault: stored == nil,
            isWholeNumber: isWholeNumber
        )
    }

    /// Whether the plugin can read `value` for `key` (empty: the whole settings): of its default's type, and, once
    /// it has read its settings, decoding as the type it reads them as. Null is taken for an optional setting.
    private func accepts(_ value: JSONValue, key: String, default fallback: JSONValue?, for id: String) -> Bool {
        if let fallback, fallback != .null, value != .null, !value.hasSameType(as: fallback) { return false }
        return kernel.settingsDefaults.accepts(key.isEmpty ? value : .map([key: value]), for: id) ?? true
    }

    /// What a setting takes, in words, for the error that refuses `value`.
    static func expectation(_ fallback: JSONValue?, given value: JSONValue) -> String {
        if let fallback, fallback != .null, !value.hasSameType(as: fallback) {
            switch fallback {
            case .bool: return "true or false"
            case .number: return "a number"
            case .string: return "text"
            case .list: return "a list"
            case .map: return "an object"
            case .null: break
            }
        }
        if case .number(let number) = value, number.rounded() != number { return "a whole number" }
        return "another value"
    }

    func registerSettingsCommands() throws {
        try registerCore(Command(
            id: "plugins.settings",
            title: "List plugin settings",
            summary: "The settings of a plugin as JSON, one field per key: key, title, help, value (stored, else the "
                + "plugin's default), defaultValue, isDefault, isWholeNumber and the choices a picker offers. "
                + "Argument: id.",
            isInPalette: false
        ) { [weak self] arguments in
            guard let self else { throw RuntimeError.closed }
            let id = try arguments.require("id")
            try requireRegistered(id)
            return try JSON.string(settingFields(for: id))
        })

        try registerCore(Command(
            id: "plugins.set-setting",
            title: "Change a plugin setting",
            summary: "Changes one setting of a plugin and tells it; writes .loam/config.json. Arguments: id, key, value "
                + "(JSON: true, 3, [\"a\"]; a setting that takes text keeps the value as typed, and anything that is "
                + "not JSON is taken as text). Refuses, writing nothing, a value of another type than the setting's "
                + "default. Returns the field as JSON.",
            isInPalette: false
        ) { [weak self] arguments in
            // The runtime is not `Sendable`; it is only touched on the main actor, inside the hop.
            nonisolated(unsafe) let runtime = self
            return try await MainActor.run {
                guard let runtime else { throw RuntimeError.closed }
                let id = try arguments.require("id")
                try runtime.requireRegistered(id)
                let key = arguments["key"] ?? ""
                let value = runtime.settingValue(parsing: arguments["value"] ?? "", key: key, for: id)
                try runtime.setSetting(key, to: value, for: id)
                let field = runtime.settingFields(for: id).first { $0.key == key } ?? SettingField(key: key, value: value)
                return try JSON.string(field)
            }
        })
    }
}

extension JSONValue {
    var mapValue: [String: JSONValue]? {
        if case .map(let map) = self { return map }
        return nil
    }

    /// Both bools, both numbers, both strings, both lists, both objects or both null.
    func hasSameType(as other: JSONValue) -> Bool {
        switch (self, other) {
        case (.null, .null), (.bool, .bool), (.number, .number), (.string, .string), (.list, .list), (.map, .map):
            return true
        default:
            return false
        }
    }
}
