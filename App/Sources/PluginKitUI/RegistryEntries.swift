import Foundation

/// Entries keyed by id where registering an id again replaces the previous entry, and each registration's
/// remover only removes that registration. Replacing instead of failing keeps a plugin restart (or two plugins
/// fighting over one id) from crashing the app; the token keeps the loser's unload from removing the winner.
struct RegistryEntries<Value> {
    private var entries: [(token: UUID, id: String, value: Value)] = []

    var values: [Value] { entries.map(\.value) }

    mutating func insert(_ value: Value, id: String) -> UUID {
        let token = UUID()
        entries.removeAll { $0.id == id }
        entries.append((token, id, value))
        return token
    }

    mutating func remove(_ token: UUID) {
        entries.removeAll { $0.token == token }
    }
}
