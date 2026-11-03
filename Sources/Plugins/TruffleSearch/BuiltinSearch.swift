import Foundation
import PluginKit

/// Name and content search without an index, as Obsidian does: scans the vault's Markdown files.
///
/// Note texts are kept in memory by file stamp, with a folded copy (no case, no accents), so a search (one per
/// keystroke) walks the vault once, reads only the notes that changed, and skips at once every note that does not
/// contain the query. Thread-safe: a lock guards the cache.
final class BuiltinSearch: @unchecked Sendable {
    /// Content hits per note, so one long note does not fill the whole list.
    static let maxLinesPerNote = 5
    /// Characters of context kept before the match in a snippet, and in all.
    static let snippetLead = 40
    static let snippetLength = 160

    private let vault: VaultAccess
    private let lock = NSLock()
    private var cache: [String: Cached] = [:]

    /// Folded names and paths by path, which never change for a path.
    private var foldedNames: [String: Folds] = [:]

    /// A note's folded name and extensionless path, with their bytes for the fast ASCII path of `nameScore`.
    struct Folds {
        let name: String
        let path: String
        let nameBytes: [UInt8]
        let pathBytes: [UInt8]
        let nameLength: Int
        let isASCII: Bool

        init(name: String, path: String) {
            self.name = name
            self.path = path
            nameBytes = Array(name.utf8)
            pathBytes = Array(path.utf8)
            nameLength = name.count
            isASCII = nameBytes.allSatisfy { $0 < 0x80 } && pathBytes.allSatisfy { $0 < 0x80 }
        }
    }
    /// The last walk of the vault, kept while `followsChanges` says no file changed since.
    private var lastWalk: [String: FileStamp]?
    /// Set when `vaultChanged` is called on every change of the vault (`VaultChanged`): searches then reuse one
    /// walk instead of walking the vault on every keystroke. Off, every search walks it.
    var followsChanges = false

    private struct Cached {
        let stamp: FileStamp
        let text: String
        /// The folded text's UTF-8 bytes, searched with `memmem`: much faster than `String.contains`.
        let folded: [UInt8]
    }

    init(vault: VaultAccess) {
        self.vault = vault
    }

    // MARK: Names

    /// Fuzzy file-name match: the query's characters in order (spaces ignored), a whole substring of the name
    /// first, then a match in the name, then one in the folder path.
    func names(_ query: String, limit: Int) throws -> [SearchHit] {
        let needle = Self.fold(query).filter { !$0.isWhitespace }
        guard !needle.isEmpty else { throw SearchError.emptyQuery }
        var scored: [(score: Double, path: String)] = []
        let needleBytes = Array(needle.utf8)
        let asciiNeedle = needleBytes.allSatisfy { $0 < 0x80 }
        for (path, folds) in folds(of: Array(try markdownStamps().keys)) {
            let score = asciiNeedle && folds.isASCII
                ? Self.nameScore(needleBytes, folds)
                : Self.nameScore(needle, name: folds.name, path: folds.path)
            if let score {
                scored.append((score, path))
            }
        }
        scored.sort { $0.score != $1.score ? $0.score > $1.score : $0.path < $1.path }
        return scored.prefix(max(limit, 0)).map { SearchHit(path: $0.path, title: Self.title(of: $0.path), score: $0.score) }
    }

    static func nameScore(_ needle: String, name: String, path: String) -> Double? {
        let lengthPenalty = Double(name.count) / 100
        if name == needle { return 1000 }
        if name.hasPrefix(needle) { return 900 - lengthPenalty }
        if name.contains(needle) { return 800 - lengthPenalty }
        if let gaps = subsequenceGaps(needle, in: name) { return 500 - Double(gaps) - lengthPenalty }
        if path.contains(needle) { return 300 - lengthPenalty }
        if let gaps = subsequenceGaps(needle, in: path) { return 100 - Double(gaps) - lengthPenalty }
        return nil
    }

    /// The characters skipped between the first and the last matched character, or nil if `needle` is not a
    /// subsequence of `haystack`. Greedy, which is good enough to rank names.
    static func subsequenceGaps(_ needle: String, in haystack: String) -> Int? {
        var remaining = needle[...]
        var gaps = 0
        var started = false
        for character in haystack {
            guard let next = remaining.first else { break }
            if character == next {
                remaining = remaining.dropFirst()
                started = true
            } else if started {
                gaps += 1
            }
        }
        return remaining.isEmpty ? gaps : nil
    }

    // MARK: Content

    /// Case- and accent-insensitive substring match, line by line, in path order; notes whose name contains the
    /// query come first.
    func content(_ query: String, limit: Int) throws -> [SearchHit] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { throw SearchError.emptyQuery }
        guard limit > 0 else { return [] }
        let folded = Self.fold(needle)
        let bytes = Array(folded.utf8)
        // One walk of the vault for every stamp, instead of one file system call per note.
        let stamps = try markdownStamps()
        let paths = stamps.keys.sorted()
        let named = Set(folds(of: paths).filter { Self.contains($0.folds.nameBytes, bytes) }.map(\.path))
        let ordered = paths.filter(named.contains) + paths.filter { !named.contains($0) }

        var hits: [SearchHit] = []
        for path in ordered {
            guard let note = note(at: path, stamp: stamps[path]), Self.contains(note.folded, bytes) else { continue }
            let text = note.text
            var inNote = 0
            var number = 0
            for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
                number += 1
                let line = rawLine.hasSuffix("\r") ? String(rawLine.dropLast()) : String(rawLine)
                guard let range = line.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) else {
                    continue
                }
                hits.append(SearchHit(
                    path: path,
                    title: Self.title(of: path),
                    snippet: Self.snippet(line, around: range),
                    line: number
                ))
                if hits.count >= limit { return hits }
                inNote += 1
                if inNote >= Self.maxLinesPerNote { break }
            }
        }
        return hits
    }

    /// The line around the match: some context before, the rest up to `snippetLength`, with "…" where cut.
    static func snippet(_ line: String, around range: Range<String.Index>) -> String {
        let start = line.index(range.lowerBound, offsetBy: -snippetLead, limitedBy: line.startIndex) ?? line.startIndex
        let end = line.index(start, offsetBy: snippetLength, limitedBy: line.endIndex) ?? line.endIndex
        var snippet = String(line[start..<end]).trimmingCharacters(in: .whitespaces)
        if start > line.startIndex { snippet = "…" + snippet }
        if end < line.endIndex { snippet += "…" }
        return snippet
    }

    /// The note's text and its folded copy, read again only when its stamp changed. Nil if it cannot be read (not
    /// UTF-8, gone). Notes deleted since are dropped from the cache on the way.
    private func note(at path: String, stamp: FileStamp?) -> Cached? {
        lock.lock()
        if let stamp, let cached = cache[path], cached.stamp == stamp {
            lock.unlock()
            return cached
        }
        lock.unlock()
        guard let text = try? vault.read(path) else { return nil }
        let note = Cached(stamp: stamp ?? FileStamp(modified: 0, size: -1), text: text, folded: Array(Self.fold(text).utf8))
        if stamp != nil {
            lock.lock()
            cache[path] = note
            lock.unlock()
        }
        return note
    }

    /// The vault's notes and their stamps, walked again after a change when `followsChanges`, else every time.
    private func markdownStamps() throws -> [String: FileStamp] {
        lock.lock()
        if followsChanges, let lastWalk {
            lock.unlock()
            return lastWalk
        }
        lock.unlock()
        let stamps = try vault.stamps().filter { $0.key.hasSuffix(".md") }
        lock.lock()
        if followsChanges { lastWalk = stamps }
        lock.unlock()
        return stamps
    }

    /// A file of the vault changed: the next search walks it again.
    func vaultChanged() {
        lock.lock()
        lastWalk = nil
        lock.unlock()
    }

    /// The folds of `paths`, made once per path.
    private func folds(of paths: [String]) -> [(path: String, folds: Folds)] {
        lock.lock()
        defer { lock.unlock() }
        return paths.map { path in
            if let folds = foldedNames[path] { return (path, folds) }
            let folds = Folds(name: Self.fold(Self.title(of: path)), path: Self.fold(String(path.dropLast(3))))
            foldedNames[path] = folds
            return (path, folds)
        }
    }

    /// `nameScore` on bytes, for an ASCII query, name and path: the same scores, without Unicode work.
    static func nameScore(_ needle: [UInt8], _ folds: Folds) -> Double? {
        let name = folds.nameBytes
        let lengthPenalty = Double(folds.nameLength) / 100
        if name == needle { return 1000 }
        if name.starts(with: needle) { return 900 - lengthPenalty }
        if contains(name, needle) { return 800 - lengthPenalty }
        if let gaps = subsequenceGaps(needle, in: name) { return 500 - Double(gaps) - lengthPenalty }
        if contains(folds.pathBytes, needle) { return 300 - lengthPenalty }
        if let gaps = subsequenceGaps(needle, in: folds.pathBytes) { return 100 - Double(gaps) - lengthPenalty }
        return nil
    }

    static func subsequenceGaps(_ needle: [UInt8], in haystack: [UInt8]) -> Int? {
        var index = 0
        var gaps = 0
        for byte in haystack {
            guard index < needle.count else { break }
            if byte == needle[index] {
                index += 1
            } else if index > 0 {
                gaps += 1
            }
        }
        return index == needle.count ? gaps : nil
    }

    static func contains(_ haystack: [UInt8], _ needle: [UInt8]) -> Bool {
        guard !needle.isEmpty else { return true }
        guard haystack.count >= needle.count else { return false }
        return haystack.withUnsafeBytes { h in
            // Non-empty arrays (checked above) have a base address; Glibc's memmem takes non-optional pointers.
            needle.withUnsafeBytes { n in memmem(h.baseAddress!, h.count, n.baseAddress!, n.count) != nil }
        }
    }

    // MARK: Helpers

    /// The file name without its extension.
    static func title(of path: String) -> String {
        let name = path.split(separator: "/").last.map(String.init) ?? path
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return name }
        return String(name[..<dot])
    }

    static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }
}
