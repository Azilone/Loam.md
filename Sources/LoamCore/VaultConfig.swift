import Foundation
import PluginKit

/// The contents of `.loam/config.json`: which plugins are on, their settings, and shortcut overrides.
///
///     { "version": 1,
///       "plugins": { "truffle-search": { "enabled": false }, "daily-notes": { "settings": { "folder": "Journal" } } },
///       "shortcuts": { "switcher.open": "cmd+o", "notes.reindex": "" } }
///
/// The whole JSON object is kept in `raw` and the accessors read and write into it, so keys this version does
/// not know (written by a newer app, a plugin, or by hand) survive a round trip, at the top level and inside
/// a plugin's entry.
public struct VaultConfig: Equatable, Codable {
    /// The format version written to new files.
    public static let currentVersion = 1

    /// The top-level JSON object, unknown keys included.
    public var raw: [String: JSONValue]

    public init(raw: [String: JSONValue] = [:]) {
        self.raw = raw
    }

    /// A plugin missing from `plugins`, or without `enabled`, is enabled: new plugins start on.
    public func isEnabled(_ id: String) -> Bool {
        if case .bool(false)? = entry(id)["enabled"] { return false }
        return true
    }

    /// True only when the plugin's entry says `"enabled": true`. Third-party plugins need this: they start off.
    public func isExplicitlyEnabled(_ id: String) -> Bool {
        if case .bool(true)? = entry(id)["enabled"] { return true }
        return false
    }

    public mutating func setEnabled(_ enabled: Bool, _ id: String) {
        updateEntry(id) { $0["enabled"] = .bool(enabled) }
    }

    /// The stored settings of a plugin, nil when it has none.
    public func settings(for id: String) -> JSONValue? {
        entry(id)["settings"]
    }

    /// Replaces a plugin's settings; nil removes them.
    public mutating func setSettings(_ value: JSONValue?, for id: String) {
        updateEntry(id) { $0["settings"] = value }
    }

    /// Command id to shortcut text (`shift+cmd+o`). An empty text removes the command's default shortcut.
    /// Entries that are not strings are ignored when reading.
    public var shortcuts: [String: String] {
        get {
            guard case .map(let map)? = raw["shortcuts"] else { return [:] }
            return map.compactMapValues { value in
                if case .string(let text) = value { return text }
                return nil
            }
        }
        set {
            raw["shortcuts"] = newValue.isEmpty ? nil : .map(newValue.mapValues { .string($0) })
        }
    }

    // MARK: - Codable

    /// Only the shape the accessors rely on is checked, so a wrong type is reported instead of being
    /// silently replaced on the next write.
    public init(from decoder: Decoder) throws {
        let raw = try [String: JSONValue](from: decoder)
        if let plugins = raw["plugins"] {
            guard case .map(let entries) = plugins else { throw Self.shapeError(decoder, "\"plugins\" must be an object") }
            for (id, entry) in entries {
                guard case .map(let fields) = entry else {
                    throw Self.shapeError(decoder, "\"plugins.\(id)\" must be an object")
                }
                if let enabled = fields["enabled"] {
                    guard case .bool = enabled else {
                        throw Self.shapeError(decoder, "\"plugins.\(id).enabled\" must be true or false")
                    }
                }
            }
        }
        if let shortcuts = raw["shortcuts"] {
            guard case .map = shortcuts else { throw Self.shapeError(decoder, "\"shortcuts\" must be an object") }
        }
        self.raw = raw
    }

    public func encode(to encoder: Encoder) throws {
        var output = raw
        if output["version"] == nil { output["version"] = .number(Double(Self.currentVersion)) }
        try output.encode(to: encoder)
    }

    // MARK: - Plugin entries

    private func entry(_ id: String) -> [String: JSONValue] {
        guard case .map(let plugins)? = raw["plugins"], case .map(let entry)? = plugins[id] else { return [:] }
        return entry
    }

    private mutating func updateEntry(_ id: String, _ change: (inout [String: JSONValue]) -> Void) {
        var plugins: [String: JSONValue] = [:]
        if case .map(let existing)? = raw["plugins"] { plugins = existing }
        var entry = self.entry(id)
        change(&entry)
        plugins[id] = entry.isEmpty ? nil : .map(entry)
        raw["plugins"] = plugins.isEmpty ? nil : .map(plugins)
    }

    private static func shapeError(_ decoder: Decoder, _ message: String) -> DecodingError {
        DecodingError.dataCorrupted(DecodingError.Context(codingPath: decoder.codingPath, debugDescription: message))
    }
}
