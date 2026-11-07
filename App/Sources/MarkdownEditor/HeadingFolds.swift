import Foundation

/// Headings folded as Bear and Obsidian fold them: a folded heading hides what follows it, up to the next heading of
/// its level or higher. The text stays as it is; only the page hides the lines (`EditorTextView.foldedBodies`).
/// Foundation only: tests drive it without an editor.
struct HeadingFolds: Equatable {
    /// A heading that can fold, and what folding it hides.
    struct Section: Equatable {
        /// The heading's line, without its break.
        let heading: NSRange
        let level: Int
        /// The lines after it, up to the next heading of its level or higher (or the end of the note), without the
        /// blank lines before that heading.
        let body: NSRange
    }

    /// The folded headings, by where their line starts.
    private(set) var folded: Set<Int> = []

    init(folded: some Sequence<Int> = []) {
        self.folded = Set(folded)
    }

    var isEmpty: Bool { folded.isEmpty }

    func isFolded(_ section: Section) -> Bool { folded.contains(section.heading.location) }

    mutating func toggle(_ section: Section) {
        if folded.remove(section.heading.location) == nil { folded.insert(section.heading.location) }
    }

    mutating func unfold(_ section: Section) { folded.remove(section.heading.location) }

    mutating func removeAll() { folded = [] }

    /// Follows an edit of `range` replaced by `length` characters: the headings after it move with their text. A
    /// heading whose start was edited away no longer folds.
    mutating func follow(_ range: NSRange, replacementLength length: Int) {
        let delta = length - range.length
        folded = Set(folded.compactMap { start in
            if start < range.location { return start }
            if start >= NSMaxRange(range) { return start + delta }
            return nil
        })
    }

    /// Keeps only the folds of `sections`: a line that is no longer a heading, or has nothing under it, unfolds.
    mutating func keep(_ sections: [Section]) {
        let starts = Set(sections.map(\.heading.location))
        folded.formIntersection(starts)
    }

    /// What the page hides: the bodies of the folded headings, merged, ascending. A folded heading inside another's
    /// body adds nothing.
    func bodies(of sections: [Section]) -> [NSRange] {
        var result: [NSRange] = []
        for section in sections where folded.contains(section.heading.location) {
            if let last = result.last, NSMaxRange(last) >= NSMaxRange(section.body) { continue }
            if let last = result.last, section.body.location <= NSMaxRange(last) {
                result[result.count - 1] = NSUnionRange(last, section.body)
            } else {
                result.append(section.body)
            }
        }
        return result
    }

    private static let visible = CharacterSet.whitespacesAndNewlines.inverted

    /// The `#` headings of `text` with something under them, from the styler's spans. An underlined (setext) heading
    /// does not fold: its underline is part of it.
    static func sections(in spans: [StyleSpan], text: NSString) -> [Section] {
        var headings: [(line: NSRange, level: Int)] = []
        for span in spans {
            guard case .heading(let level) = span.style, span.range.location < text.length else { continue }
            let line = text.lineWithoutBreak(at: span.range.location)
            guard text.substring(with: line).trimmingCharacters(in: .whitespaces).hasPrefix("#") else { continue }
            headings.append((line, level))
        }
        headings.sort { $0.line.location < $1.line.location }
        var sections: [Section] = []
        for (index, heading) in headings.enumerated() {
            let start = NSMaxRange(text.paragraphRange(for: heading.line))
            let end = headings[(index + 1)...].first { $0.level <= heading.level }?.line.location ?? text.length
            guard end > start else { continue }
            // Up to its last line with text: the blank lines after it stay, keeping the room above the next heading.
            let last = text.rangeOfCharacter(from: Self.visible, options: .backwards, range: NSRange(location: start, length: end - start))
            guard last.location != NSNotFound else { continue }
            let bodyEnd = min(end, NSMaxRange(text.paragraphRange(for: last)))
            sections.append(Section(heading: heading.line, level: heading.level, body: NSRange(location: start, length: bodyEnd - start)))
        }
        return sections
    }
}
