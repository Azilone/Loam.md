import Foundation
import PluginKit

/// The patterns a vault's daily notes were written under, newest first, the current one included. A note stays
/// found after the pattern changes: the settings hold one pattern, this file the others the vault used, kept
/// across a config edited while the app was closed.
///
/// It lives beside the config (`.loam/daily-notes-patterns.json`), so it travels with the vault and stays out of the
/// settings page. A missing or unreadable file is an empty history.
struct DailyPatternHistory: Codable, Equatable, Sendable {
    /// Where the file sits in the vault.
    static let path = ".loam/daily-notes-patterns.json"
    /// How many older patterns are kept: enough for a few changes, small enough to read whenever a note is found.
    static let limit = 8

    private(set) var patterns: [String]

    init(patterns: [String] = []) {
        self.patterns = patterns
    }

    /// Puts `pattern` first, without repeats, dropping the oldest past `limit`.
    mutating func remember(_ pattern: String) {
        patterns.removeAll { $0 == pattern }
        patterns.insert(pattern, at: 0)
        if patterns.count > Self.limit { patterns.removeLast(patterns.count - Self.limit) }
    }

    /// The history of the vault; empty when nothing was written yet.
    static func read(_ vault: VaultAccess) -> DailyPatternHistory {
        guard let text = try? vault.read(path),
              let history = try? JSONDecoder().decode(DailyPatternHistory.self, from: Data(text.utf8))
        else { return DailyPatternHistory() }
        return history
    }

    /// Writes the history; a vault that cannot take the file keeps the old one, which loses nothing but the
    /// newest pattern.
    func write(_ vault: VaultAccess) {
        guard let data = try? JSONEncoder().encode(self),
              let text = String(data: data, encoding: .utf8)
        else { return }
        try? vault.write(Self.path, text + "\n")
    }
}
