import PluginKitUI

/// Turns a query into the switcher's rows. Pure, so the ranking is tested without a popup.
enum SwitcherRanking {
    /// Enough rows to scroll through; more would only slow every keystroke on a large vault.
    static let limit = 50
    /// Added to a title's score: a note named like the query beats one whose folder merely contains it.
    static let titleBonus = 32
    static let notePrefix = "note:"
    static let createPrefix = "create:"

    /// The rows for `query`: the best matching notes (on the title or the path, the title weighted higher),
    /// or the most recently modified ones for an empty query; then a "Create" row when no note has exactly
    /// that title. `symbol` gives a note's icon (a board's, a mindmap's), a plain document by default.
    static func items(
        for query: String, in candidates: [NoteCandidate], symbol: (String) -> String = { _ in "doc.text" }
    ) -> [QuickPickItem] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        let section = trimmed.isEmpty ? "Recent" : nil
        let notes = rank(trimmed, candidates).prefix(limit).map {
            QuickPickItem(id: notePrefix + $0.path, title: $0.title, subtitle: $0.path, symbol: symbol($0.path),
                          section: section)
        }
        guard !trimmed.isEmpty, NoteName.sanitize(trimmed) != nil,
              !candidates.contains(where: { $0.title.caseInsensitiveCompare(trimmed) == .orderedSame })
        else { return notes }
        return notes + [QuickPickItem(id: createPrefix + trimmed, title: "Create “\(trimmed)”", symbol: "plus")]
    }

    /// Matching candidates, best first. Equal scores keep the candidates' order (most recent first).
    static func rank(_ query: String, _ candidates: [NoteCandidate]) -> [NoteCandidate] {
        guard !query.isEmpty else { return candidates }
        return candidates.enumerated()
            .compactMap { offset, note in score(query, note).map { (offset, note, $0) } }
            .sorted { $0.2 != $1.2 ? $0.2 > $1.2 : $0.0 < $1.0 }
            .map(\.1)
    }

    /// The better of the title's score (plus `titleBonus`) and the path's, nil when neither matches.
    static func score(_ query: String, _ note: NoteCandidate) -> Int? {
        let title = Fuzzy.score(query, in: note.title).map { $0 + titleBonus }
        let path = Fuzzy.score(query, in: note.path)
        switch (title, path) {
        case let (t?, p?): return max(t, p)
        case let (t?, nil): return t
        case let (nil, p?): return p
        case (nil, nil): return nil
        }
    }
}
