import Foundation
import PluginKit

/// The headings each note had folded, by note path, kept in the vault's cache (`.loam/cache/folds.json`). A tab
/// keeps its own folds only while it shows the note: this brings them back when the note comes back in a tab (Back, a
/// link, a sidebar row) or after the app restarts. Deleting the file only unfolds the notes.
@MainActor
final class NoteFoldStore {
    static let path = ".loam/cache/folds.json"

    private let vault: VaultAccess
    private var folds: [String: [Int]]?

    init(vault: VaultAccess) {
        self.vault = vault
    }

    /// Where the lines of the folded headings of the note at `path` start; empty when none are folded.
    func folded(in path: String) -> [Int] {
        load()[path] ?? []
    }

    /// Remembers the folds of the note at `path`; a note with none is forgotten.
    func set(_ folded: [Int], in path: String) {
        var all = load()
        guard (all[path] ?? []) != folded else { return }
        all[path] = folded.isEmpty ? nil : folded
        folds = all
        guard let data = try? JSONEncoder().encode(all) else { return }
        try? vault.writeData(Self.path, data)
    }

    private func load() -> [String: [Int]] {
        if let folds { return folds }
        var loaded: [String: [Int]] = [:]
        if vault.exists(Self.path), let text = try? vault.read(Self.path),
           let decoded = try? JSONDecoder().decode([String: [Int]].self, from: Data(text.utf8)) {
            loaded = decoded
        }
        folds = loaded
        return loaded
    }
}
