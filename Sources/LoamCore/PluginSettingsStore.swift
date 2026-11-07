import Foundation
import PluginKit

/// Where the kernel keeps plugin settings: `.loam/config.json` through a `ConfigStore`, or memory when the
/// kernel was built without one (tests, tools that must not write the vault).
protocol SettingsBackend: AnyObject {
    func settings(for id: String) -> JSONValue?
    func setSettings(_ value: JSONValue, for id: String) throws
}

extension ConfigStore: SettingsBackend {
    func settings(for id: String) -> JSONValue? {
        config.settings(for: id)
    }

    func setSettings(_ value: JSONValue, for id: String) throws {
        try mutate { $0.setSettings(value, for: id) }
    }
}

final class InMemorySettings: SettingsBackend {
    private var values: [String: JSONValue] = [:]

    func settings(for id: String) -> JSONValue? {
        values[id]
    }

    func setSettings(_ value: JSONValue, for id: String) throws {
        values[id] = value
    }
}

/// The defaults plugins read their settings with, and the types they read them as, by plugin id. Plugins do not
/// declare their defaults to the host: the kernel learns them from `context.settings.value(default:)`, so the plugin
/// manager can show every setting a plugin has, not only the ones already written, and refuse a value the plugin
/// cannot read. Read from any thread.
final class SettingsDefaults: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: JSONValue] = [:]
    /// By plugin id, then by settings type: whether a stored value decodes as that type over its default.
    private var readers: [String: [ObjectIdentifier: (JSONValue) -> Bool]] = [:]

    /// Keeps `value` as the plugin's default for settings read as `type`; a plugin reading several settings types
    /// gets their keys merged.
    func record<S: Decodable>(_ value: JSONValue, as type: S.Type, for id: String) {
        lock.lock()
        defer { lock.unlock() }
        values[id] = values[id].map { JSONBridge.merge(value, over: $0) } ?? value
        readers[id, default: [:]][ObjectIdentifier(type)] = { stored in
            (try? JSONBridge.decode(type, from: JSONBridge.merge(stored, over: value))) != nil
        }
    }

    func value(for id: String) -> JSONValue? {
        lock.lock()
        defer { lock.unlock() }
        return values[id]
    }

    /// Whether the plugin can read `stored` (its whole settings, or some of their keys, over its defaults) as every
    /// type it read its settings as: false for text where it reads a number, a fraction where it reads a whole number.
    /// Nil before it read them.
    func accepts(_ stored: JSONValue, for id: String) -> Bool? {
        lock.lock()
        let checks = readers[id].map { Array($0.values) } ?? []
        lock.unlock()
        return checks.isEmpty ? nil : checks.allSatisfy { $0(stored) }
    }
}

/// The `context.settings` of one plugin.
final class ScopedSettings: PluginSettingsAccess {
    private let pluginID: String
    private let backend: SettingsBackend
    private let events: EventBus
    private let defaults: SettingsDefaults?

    init(pluginID: String, backend: SettingsBackend, events: EventBus, defaults: SettingsDefaults? = nil) {
        self.pluginID = pluginID
        self.backend = backend
        self.events = events
        self.defaults = defaults
    }

    func value<S: Codable & Equatable>(default defaultValue: S) -> S {
        guard let base = try? JSONBridge.value(from: defaultValue) else { return defaultValue }
        defaults?.record(base, as: S.self, for: pluginID)
        guard let stored = backend.settings(for: pluginID) else { return defaultValue }
        return JSONBridge.decode(S.self, stored: stored, over: base) ?? defaultValue
    }

    func update<S: Codable & Equatable>(_ value: S) throws {
        // Replaces the stored value: merging would make an optional setting set to nil impossible to clear.
        try backend.setSettings(try JSONBridge.value(from: value), for: pluginID)
        events.emit(PluginSettingsChanged(pluginID: pluginID))
    }
}

/// Converts between `Codable` values and `JSONValue` through JSON, the format the settings are stored in.
enum JSONBridge {
    static func value<T: Encodable>(from value: T) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value))
    }

    static func decode<T: Decodable>(_ type: T.Type, from value: JSONValue) throws -> T {
        try JSONDecoder().decode(type, from: JSONEncoder().encode(value))
    }

    /// `stored` over `base`, decoded. When that fails and both are objects, the stored keys that decode on their own
    /// are kept and the others follow `base`: one key of the wrong type (a folder written as `2026`) does not reset
    /// the plugin's other settings.
    static func decode<T: Decodable>(_ type: T.Type, stored: JSONValue, over base: JSONValue) -> T? {
        if let value = try? decode(type, from: merge(stored, over: base)) { return value }
        guard case .map(let storedMap) = stored, case .map = base else { return nil }
        let readable = storedMap.filter { key, value in
            (try? decode(type, from: merge(.map([key: value]), over: base))) != nil
        }
        return try? decode(type, from: merge(.map(readable), over: base))
    }

    /// `top` wins key by key when both are objects; otherwise `top` replaces `base`.
    static func merge(_ top: JSONValue, over base: JSONValue) -> JSONValue {
        guard case .map(let topMap) = top, case .map(let baseMap) = base else { return top }
        return .map(baseMap.merging(topMap) { _, new in new })
    }
}
