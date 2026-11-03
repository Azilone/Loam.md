import Foundation

/// Fuzzy matching for quick picks (the palette, the quick switcher): the query's characters must appear in the
/// candidate in order, not next to each other, so `dn` finds "Daily notes".
///
/// Case and accents are ignored (`ete` matches "Été") and so are spaces in the query. Among the possible
/// alignments the best one is scored, so a later match on a word start beats an earlier one in the middle of a
/// word.
public enum Fuzzy {
    // Scores are relative; only their order matters. A matched character is worth `match`, more at the start of
    // the candidate or of a word, more again right after the previous match. Skipped characters cost a little,
    // and so does the candidate's length, so "Note" ranks above "Notebook" for `note`.
    private static let match = 16
    private static let prefixBonus = 8
    private static let wordStartBonus = 12
    private static let consecutiveBonus = 10
    private static let maxLeadingPenalty = 8
    private static let separators: Set<Character> = [" ", "/", "-", "_"]
    private static let impossible = Int.min / 4

    /// The score of `query` in `candidate`, higher is better, or nil if the query's characters do not all appear
    /// in order. An empty query matches everything with 0.
    public static func score(_ query: String, in candidate: String) -> Int? {
        let q = Array(fold(query).filter { !$0.isWhitespace })
        let c = Array(fold(candidate))
        guard !q.isEmpty else { return 0 }
        guard q.count <= c.count else { return nil }

        func bonus(_ j: Int) -> Int {
            var value = match
            if j == 0 { value += prefixBonus + wordStartBonus } else if separators.contains(c[j - 1]) { value += wordStartBonus }
            return value
        }

        // best[j]: the best score with the current query character matched at candidate position j. Gaps cost
        // one point per skipped character, so the best earlier match k is the one maximizing best[k] + k.
        var best = c.indices.map { c[$0] == q[0] ? bonus($0) - min($0, maxLeadingPenalty) : impossible }
        for i in 1..<q.count {
            var next = Array(repeating: impossible, count: c.count)
            var bestBeforeGap = impossible  // max of best[k] + k for k <= j - 2
            for j in 1..<c.count {
                if j >= 2, best[j - 2] > impossible { bestBeforeGap = max(bestBeforeGap, best[j - 2] + j - 2) }
                guard c[j] == q[i] else { continue }
                let adjacent = best[j - 1] > impossible ? best[j - 1] + consecutiveBonus : impossible
                let gapped = bestBeforeGap > impossible ? bestBeforeGap - (j - 1) : impossible
                let previous = max(adjacent, gapped)
                if previous > impossible { next[j] = previous + bonus(j) }
            }
            best = next
        }
        guard let top = best.max(), top > impossible else { return nil }
        return top - (c.count - q.count) / 4
    }

    /// The items matching `query`, best first; items with equal scores keep their order. An empty query
    /// returns `items` unchanged.
    public static func rank<T>(_ items: [T], query: String, key: (T) -> String) -> [T] {
        guard !query.allSatisfy(\.isWhitespace) else { return items }
        return items.enumerated()
            .compactMap { offset, item in score(query, in: key(item)).map { (offset, item, $0) } }
            .sorted { $0.2 != $1.2 ? $0.2 > $1.2 : $0.0 < $1.0 }
            .map(\.1)
    }

    private static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }
}
