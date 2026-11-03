import Foundation

/// The Markdown syntax a page hides (`**`, `#`, `> `, `- [ ] `, a link's `](url)`, the frontmatter...), as the model
/// the caret, the selection and the delete keys work from, so no syntax character is ever visible, selected alone or
/// left orphaned. Foundation only: tests drive it without an editor.
///
/// The text stays Markdown. A hidden character takes no room, so a caret "inside" syntax would sit where the text
/// next to it sits: the editor keeps the caret out (`snap`), and deleting next to syntax deletes what shows
/// (`deleteBackward`, `deleteForward`, `balanced`), taking an emptied pair of markers with it.
struct HiddenSyntax: Equatable {
    // Built once: a regex literal evaluated inline is parsed again at each use, which showed on every keystroke.
    nonisolated(unsafe) private static let quotePrefix = /^[ \t]*(?:>[ \t]?)+/
    nonisolated(unsafe) private static let headingPrefix = /^[ \t]*#{1,6}[ \t]+/
    nonisolated(unsafe) private static let bareHeadingPrefix = /^[ \t]*#{1,6}[ \t]*$/

    /// A line's hidden start, from the start of the line to where its text starts: `## `, `> `, `- [ ] `.
    struct Prefix: Equatable {
        let range: NSRange
        /// Whether its characters are hidden: a bullet's `-` and a heading's `#` are, an ordered list's `1.` shows.
        let hidden: Bool
    }

    /// A pair of markers around a text, `**` and `**`: deleting one without the other would leave the other showing.
    struct Pair: Equatable {
        let open: NSRange
        let close: NSRange
    }

    /// What deleting does: the ranges to remove (ascending, not touching) and where the caret goes, in the new text.
    struct Deletion: Equatable {
        let ranges: [NSRange]
        let caret: Int
    }

    /// The hidden characters, ascending and merged where they touch.
    let runs: [NSRange]
    let prefixes: [Prefix]
    let pairs: [Pair]
    let text: NSString

    static var none: HiddenSyntax { HiddenSyntax(runs: [], prefixes: [], pairs: [], text: "") }

    init(runs: [NSRange], prefixes: [Prefix], pairs: [Pair], text: NSString) {
        self.runs = Self.merged(runs)
        self.prefixes = prefixes.sorted { $0.range.location < $1.range.location }
        self.pairs = pairs
        self.text = text
    }

    // MARK: Building

    /// What the styles of `spans` hide in `text`.
    /// What a line starts with that the page hides or shows differently (a quote's `>`s, a heading's `#`s, a list item's
    /// marker and box): its length and whether it is hidden. The answer depends on the line alone, and the same lines
    /// come back at every keystroke, so it is kept: three regular expressions per list or heading line made typing in
    /// a long note slow.
    nonisolated(unsafe) private static let bareItem = /[ \t]*([-*+]|\d{1,9}[.)])([ \t]+\[[ xX]\])?[ \t]*/

    private static func prefix(ofLine content: String) -> (length: Int, hidden: Bool)? {
        if let known = prefixCache.get(content) { return known.value }
        var end = 0
        var hidden = false
        if let quote = content.firstMatch(of: Self.quotePrefix) {
            end = String(quote.0).utf16.count
            hidden = true
        }
        let rest = String(content.utf16.dropFirst(end)) ?? ""
        if let heading = rest.firstMatch(of: Self.headingPrefix) ?? rest.firstMatch(of: Self.bareHeadingPrefix) {
            end += String(heading.0).utf16.count
            // A heading's `#`s hide once it has text; until then they show (`MarkdownStyler.visitHeading`).
            hidden = hidden || end < content.utf16.count
        } else if let item = ListLine.parse(rest) {
            end += item.prefixLength
            hidden = hidden || ["-", "*", "+"].contains(item.marker)
            // An ordered marker shows, but `- ` and a box do not.
            if !["-", "*", "+"].contains(item.marker) { hidden = false }
        } else if let bare = rest.wholeMatch(of: Self.bareItem) {
            // An empty item without the space after its marker (`-`, `1.`, `- [ ]`) still shows a marker: the whole
            // line is its start.
            end += rest.utf16.count
            hidden = hidden || ["-", "*", "+"].contains(String(bare.1))
        }
        let value: (length: Int, hidden: Bool)? = end > 0 ? (end, hidden) : nil
        prefixCache.set(content, value)
        return value
    }

    private final class PrefixCache: @unchecked Sendable {
        struct Box { let value: (length: Int, hidden: Bool)? }
        private var entries: [String: Box] = [:]
        private let lock = NSLock()
        func get(_ key: String) -> Box? {
            lock.lock(); defer { lock.unlock() }
            return entries[key]
        }
        func set(_ key: String, _ value: (length: Int, hidden: Bool)?) {
            lock.lock(); defer { lock.unlock() }
            if entries.count > 4096 { entries.removeAll(keepingCapacity: true) }
            entries[key] = Box(value: value)
        }
    }
    private static let prefixCache = PrefixCache()

    init(spans: [StyleSpan], text: String) {
        let ns = text as NSString
        var runs: [NSRange] = []
        var prefixes: [Prefix] = []
        var openers: [NSRange] = []
        var concealable: [NSRange] = []
        for span in spans {
            switch span.style {
            case .concealable:
                runs.append(span.range)
                concealable.append(span.range)
            case .concealedOutside, .invisible, .taskBox, .date, .frontmatter:
                runs.append(span.range)
            case .embed:
                runs.append(span.range)
            case .listMarker:
                let marker = ns.substring(with: span.range)
                if ["-", "*", "+"].contains(marker) { runs.append(span.range) }
            default:
                break
            }
        }
        openers = concealable

        // Line prefixes: a heading's marker, a quote's `>`s, a list item's marker and box.
        var seenLines = Set<Int>()
        func addPrefix(line: NSRange) {
            guard seenLines.insert(line.location).inserted else { return }
            // A native string: one cut from the text view's bridged string hashes slowly, and the cache hashes it.
            var units = [UInt16](repeating: 0, count: line.length)
            units.withUnsafeMutableBufferPointer { buffer in
                if let base = buffer.baseAddress { ns.getCharacters(base, range: line) }
            }
            let content = String(decoding: units, as: UTF16.self)
            guard let found = Self.prefix(ofLine: content) else { return }
            prefixes.append(Prefix(range: NSRange(location: line.location, length: found.length), hidden: found.hidden))
        }
        for span in spans {
            switch span.style {
            case .heading:
                let line = ns.lineWithoutBreak(at: span.range.location)
                if ns.substring(with: line).trimmingCharacters(in: .whitespaces).hasPrefix("#") { addPrefix(line: line) }
            case .quote:
                var location = span.range.location
                while location < NSMaxRange(span.range) {
                    let line = ns.lineWithoutBreak(at: location)
                    addPrefix(line: line)
                    location = NSMaxRange(line) + 1
                }
            case .listMarker:
                addPrefix(line: ns.lineWithoutBreak(at: span.range.location))
            default:
                break
            }
        }

        // Pairs: the markers around a styled text. The openers are indexed by where they start and end: looking for
        // them one by one in the list made this quadratic in a long note.
        var startingAt: [Int: NSRange] = [:]
        var endingAt: [Int: [NSRange]] = [:]
        for opener in openers {
            if startingAt[opener.location] == nil { startingAt[opener.location] = opener }
            endingAt[NSMaxRange(opener), default: []].append(opener)
        }
        var pairs: [Pair] = []
        for span in spans {
            switch span.style {
            case .strong, .emphasis, .strikethrough, .inlineCode:
                if let open = startingAt[span.range.location],
                   let close = endingAt[NSMaxRange(span.range)]?.first(where: { $0.location >= NSMaxRange(open) }) {
                    pairs.append(Pair(open: open, close: close))
                }
            case .link, .highlight:
                if let open = endingAt[span.range.location]?.first,
                   let close = startingAt[NSMaxRange(span.range)] {
                    pairs.append(Pair(open: open, close: close))
                }
            default:
                break
            }
        }
        self.init(runs: runs, prefixes: prefixes, pairs: pairs, text: ns)
    }

    private static func merged(_ ranges: [NSRange]) -> [NSRange] {
        var result: [NSRange] = []
        for range in ranges.filter({ $0.length > 0 }).sorted(by: { $0.location < $1.location }) {
            if let last = result.last, range.location <= NSMaxRange(last) {
                result[result.count - 1] = NSRange(location: last.location, length: max(NSMaxRange(last), NSMaxRange(range)) - last.location)
            } else {
                result.append(range)
            }
        }
        return result
    }

    // MARK: Caret and selection

    /// The run `position` is strictly inside of (between two of its characters).
    private func run(strictlyContaining position: Int) -> NSRange? {
        runs.first { $0.location < position && position < NSMaxRange($0) }
    }

    /// The hidden prefix a caret at `position` would sit in or before: a caret there goes to where the text starts.
    private func prefix(containing position: Int) -> Prefix? {
        prefixes.first { $0.hidden && $0.range.location <= position && position < NSMaxRange($0.range) }
    }

    /// `selection` moved off hidden syntax. A caret never rests inside hidden syntax, nor before a line's hidden start:
    /// it goes to the edge in the direction it was moving, and past the syntax when that is where it came from, so an
    /// arrow key is never a keystroke without movement. The end of a selection that moves follows the same rule; the
    /// other end goes outwards, so what is selected, copied or deleted is whole syntax.
    func snap(_ selection: NSRange, from old: NSRange) -> NSRange {
        if selection.length == 0 {
            return NSRange(location: snapCaret(selection.location, from: old.location), length: 0)
        }
        let anchor: Int? = old.length == 0 ? old.location : nil
        let startMoved = selection.location != old.location && (old.length == 0 ? selection.location != anchor : NSMaxRange(selection) == NSMaxRange(old))
        let endMoved = NSMaxRange(selection) != NSMaxRange(old) && (old.length == 0 ? NSMaxRange(selection) != anchor : selection.location == old.location)
        var start = selection.location
        var end = NSMaxRange(selection)
        if startMoved, !endMoved, run(strictlyContaining: start) != nil, hiddenPrefix(strictlyContaining: start) == nil {
            start = snapOffRun(start, from: old.location)
        } else {
            start = outward(start, towardsStart: true)
        }
        if endMoved, !startMoved, run(strictlyContaining: end) != nil, hiddenPrefix(strictlyContaining: end) == nil {
            end = snapOffRun(end, from: old.length == 0 ? old.location : NSMaxRange(old))
        } else {
            end = outward(end, towardsStart: false)
        }
        return NSRange(location: start, length: max(0, end - start))
    }

    /// A selection's end moved off hidden syntax, to the side that includes it.
    private func outward(_ position: Int, towardsStart: Bool) -> Int {
        if let run = run(strictlyContaining: position) { return towardsStart ? run.location : NSMaxRange(run) }
        if let prefix = hiddenPrefix(strictlyContaining: position) {
            return towardsStart ? prefix.range.location : NSMaxRange(prefix.range)
        }
        return position
    }

    private func hiddenPrefix(strictlyContaining position: Int) -> Prefix? {
        prefixes.first { $0.hidden && $0.range.location < position && position < NSMaxRange($0.range) }
    }

    private func snapCaret(_ position: Int, from old: Int) -> Int {
        let position = min(max(position, 0), text.length)
        let left = position < old
        if let prefix = prefix(containing: position) {
            if left, old == NSMaxRange(prefix.range), position == old - 1, prefix.range.location > 0 {
                // Left from the start of a line's text: to the end of the line above.
                return snapCaret(prefix.range.location - 1, from: old)
            }
            return NSMaxRange(prefix.range)
        }
        return snapOffRun(position, from: old)
    }

    /// A position inside a run of hidden characters moved to its edge in the direction of the move; past the run when
    /// the move was one character from the run's edge (the same spot).
    private func snapOffRun(_ position: Int, from old: Int) -> Int {
        let left = position < old
        guard let run = run(strictlyContaining: position) else { return position }
        // Already at an edge of the run: both edges are the same spot, so the key goes on to the next visible character.
        if abs(position - old) == 1, left ? old == NSMaxRange(run) : old == run.location {
            let beyond = min(max(left ? run.location - 1 : NSMaxRange(run) + 1, 0), text.length)
            return beyond == (left ? run.location : NSMaxRange(run)) ? beyond : snapCaret(beyond, from: old)
        }
        return left ? run.location : NSMaxRange(run)
    }

    // MARK: Deleting

    /// Backspace with a caret at `caret`: removes the character that shows before it, not a hidden one. At the start of
    /// a line's text it removes what makes the line a heading, a quote or an item (one `>` of a quote). An emptied pair
    /// of markers goes with its text. Nil when there is nothing before the caret.
    func deleteBackward(caret: Int) -> Deletion? {
        if let prefix = prefixes.first(where: { NSMaxRange($0.range) == caret && $0.range.length > 0 }) {
            return Deletion(ranges: [Self.demoted(prefix.range, in: text)], caret: Self.demoted(prefix.range, in: text).location)
        }
        // At the start of the line under an empty item (or quote line, or heading): that line goes, marker and all.
        if caret > 0, text.character(at: caret - 1) == 10, caret - 1 > 0 {
            let above = text.lineRange(for: NSRange(location: caret - 1, length: 0))
            let content = NSRange(location: above.location, length: caret - 1 - above.location)
            if content.length > 0, prefixes.contains(where: { NSEqualRanges($0.range, content) }) {
                return Deletion(ranges: [NSRange(location: above.location, length: caret - above.location)], caret: above.location)
            }
        }
        var index = caret - 1
        while index >= 0, let run = run(containing: index) { index = run.location - 1 }
        guard index >= 0 else { return nil }
        // A hidden line (a code fence) is not deleted by its line break: the caret goes up past it instead.
        if text.character(at: index) == 10, let run = runs.first(where: { NSMaxRange($0) == index }),
           run.location == text.lineRange(for: NSRange(location: run.location, length: 0)).location {
            return Deletion(ranges: [], caret: run.location > 0 ? run.location - 1 : 0)
        }
        // A blank line between two blocks: removing it would glue them (a picture under a list item becomes its
        // text), so the caret only goes up.
        if text.character(at: index) == 10, index + 1 == caret, caret < text.length {
            let own = text.lineRange(for: NSRange(location: caret, length: 0))
            let above = text.lineRange(for: NSRange(location: index, length: 0))
            let below = NSMaxRange(own) < text.length ? text.lineRange(for: NSRange(location: NSMaxRange(own), length: 0)) : nil
            if Self.isBlank(own, in: text), !Self.isBlank(above, in: text), let below, !Self.isBlank(below, in: text),
               !Self.isPlain(above, in: text) || !Self.isPlain(below, in: text),
               // Between two list items the blank line only spaces the list out: it goes, and the list closes up.
               !(Self.isItem(above, in: text) && Self.isItem(below, in: text)),
               // A heading ends on its own line and starts a block under anything: nothing glues to it.
               !Self.isHeading(above, in: text), !Self.isHeading(below, in: text) {
                return Deletion(ranges: [], caret: index)
            }
        }
        // After the removed character a prefix of a line below may now be joined to the line: only a break joins.
        return removing(NSRange(location: index, length: 1))
    }

    /// A line of a plain paragraph: two of them join into one paragraph, as the user means.
    private static func isPlain(_ line: NSRange, in text: NSString) -> Bool {
        let trimmed = text.substring(with: line).trimmingCharacters(in: .whitespaces)
        guard let first = trimmed.first else { return false }
        return !"-*+>#|!`~".contains(first) && !(first.isNumber && trimmed.contains(where: { $0 == "." || $0 == ")" }))
    }

    private static func isItem(_ line: NSRange, in text: NSString) -> Bool {
        let content = text.substring(with: line).trimmingCharacters(in: .newlines)
        return ListLine.parse(content) != nil || content.wholeMatch(of: bareItem) != nil
    }

    /// An ATX heading's line (`## Title`).
    private static func isHeading(_ line: NSRange, in text: NSString) -> Bool {
        text.substring(with: line).trimmingCharacters(in: .whitespacesAndNewlines).wholeMatch(of: /#{1,6}(?:[ \t].*)?/) != nil
    }

    private static func isBlank(_ line: NSRange, in text: NSString) -> Bool {
        text.substring(with: line).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Forward delete at `caret`: removes the character that shows after it. A line break takes the next line's hidden
    /// start with it, so lines join without a stray `>` or `#`.
    func deleteForward(caret: Int) -> Deletion? {
        var index = caret
        while index < text.length, let run = run(containing: index) { index = NSMaxRange(run) }
        guard index < text.length else { return nil }
        if text.character(at: index) == 10 {
            var end = index + 1
            if let prefix = prefixes.first(where: { $0.range.location == end }) { end = NSMaxRange(prefix.range) }
            return Deletion(ranges: [NSRange(location: index, length: end - index)], caret: index)
        }
        return removing(NSRange(location: index, length: 1))
    }

    /// `range` and the other marker of each pair it breaks, so deleting a selection leaves no orphan marker showing.
    func balanced(_ range: NSRange) -> Deletion {
        var ranges = [range]
        for pair in pairs {
            let openIn = NSIntersectionRange(range, pair.open).length > 0
            let closeIn = NSIntersectionRange(range, pair.close).length > 0
            if openIn != closeIn { ranges.append(openIn ? pair.close : pair.open) }
        }
        let merged = Self.merged(ranges)
        return Deletion(ranges: merged, caret: merged.first?.location ?? range.location)
    }

    /// The pairs `range` breaks, as the ranges of their other markers (for a selection about to be replaced).
    func orphans(of range: NSRange) -> [NSRange] {
        balanced(range).ranges.filter { NSIntersectionRange($0, range).length == 0 && !NSEqualRanges($0, range) }
    }

    private func run(containing index: Int) -> NSRange? {
        runs.first { $0.location <= index && index < NSMaxRange($0) }
    }

    /// Deleting the character at `range`, with the pair of markers around it when that was all they held.
    private func removing(_ range: NSRange) -> Deletion {
        if let pair = pairs.first(where: { NSMaxRange($0.open) == range.location && $0.close.location == NSMaxRange(range) }) {
            let all = NSRange(location: pair.open.location, length: NSMaxRange(pair.close) - pair.open.location)
            return Deletion(ranges: [all], caret: all.location)
        }
        return Deletion(ranges: [range], caret: range.location)
    }

    /// What backspace removes at the start of a line's text: the last `>` (and its space) of a quote's marks, else the
    /// whole start of the line.
    private static func demoted(_ prefix: NSRange, in text: NSString) -> NSRange {
        let marks = text.substring(with: prefix)
        if let quote = marks.firstMatch(of: /^([ \t]*(?:>[ \t]?)+)$/) {
            let all = String(quote.1)
            // The whole prefix is a quote's: drop its last level.
            if let last = all.lastIndex(of: ">") {
                let start = all.utf16.distance(from: all.startIndex, to: last)
                return NSRange(location: prefix.location + start, length: prefix.length - start)
            }
        }
        return prefix
    }
}
