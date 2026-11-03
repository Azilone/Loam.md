import Foundation

/// The start of a list item line: `  - [ ] `, `1. `, `* `...
struct ListLine: Equatable {
    var indent: String
    var marker: String
    var spacing: String
    var box: String?

    /// Length of everything before the item's text.
    var prefixLength: Int { (indent + marker + spacing + (box.map { $0 + " " } ?? "")).utf16.count }

    /// Built once: a regex literal evaluated inline is parsed again at each use, which showed on every keystroke.
    nonisolated(unsafe) private static let pattern = /^([ \t]*)([-*+]|\d{1,9}[.)])([ \t]+)(\[[ xX]\] )?/

    static func parse(_ line: String) -> ListLine? {
        guard let match = line.firstMatch(of: pattern) else { return nil }
        return ListLine(
            indent: String(match.1),
            marker: String(match.2),
            spacing: String(match.3),
            box: match.4.map { String($0.dropLast()) }
        )
    }

    /// The marker of the item that follows this one: same bullet, or the next number.
    var nextMarker: String {
        guard let delimiter = marker.last, delimiter == "." || delimiter == ")", let number = Int(marker.dropLast())
        else { return marker }
        return "\(number + 1)\(delimiter)"
    }
}

/// Keyboard behaviours inside lists: Return continues a list, Tab and Shift-Tab nest items.
public enum ListEditing {
    /// A list item with no text and no space after its marker or box: `-`, `1.`, `- [ ]`.
    nonisolated(unsafe) private static let bareItem = /[ \t]*([-*+]|\d{1,9}[.)])([ \t]+\[[ xX]\])?[ \t]*/

    /// Return at `selection` inside a list item: starts the next item, or ends the list on an empty item.
    /// Returns nil when Return should behave normally.
    public static func newline(in text: String, selection: NSRange) -> TextEdit? {
        guard selection.length == 0 else { return nil }
        let ns = text as NSString
        let lineRange = ns.lineWithoutBreak(at: selection.location)
        let line = ns.substring(with: lineRange)
        // Return on an empty nested item moves it out one level, as in Craft: ending the list there would leave a
        // blank line inside it, which splits it (and turns the deeper items after it into code).
        if let item = ListLine.parse(line), !item.indent.isEmpty,
           (line as NSString).substring(from: item.prefixLength).trimmingCharacters(in: .whitespaces).isEmpty,
           let outdent = indent(in: text, selection: selection, outdent: true) {
            return outdent
        }
        if line.wholeMatch(of: bareItem) != nil, isInList(lineRange, ns) {
            // An empty item whose trailing space is gone (`-`, `1.`, `- [ ]`, as files trimmed of trailing
            // whitespace hold them) still shows a marker inside a list: Return ends the list too. A lone `-`
            // typed on its own is not a list yet.
            return TextEdit(range: lineRange, replacement: "", selection: NSRange(location: lineRange.location, length: 0))
        }
        guard let item = ListLine.parse(line) else { return nil }
        let contentStart = lineRange.location + item.prefixLength
        guard selection.location >= contentStart else { return nil }

        let content = ns.substring(with: NSRange(location: contentStart, length: NSMaxRange(lineRange) - contentStart))
        if content.trimmingCharacters(in: .whitespaces).isEmpty {
            // Return on an empty item ends the list: the marker goes away.
            return TextEdit(
                range: lineRange,
                replacement: "",
                selection: NSRange(location: lineRange.location, length: 0)
            )
        }
        let box = item.box == nil ? "" : "[ ] "
        let insertion = "\n" + item.indent + item.nextMarker + item.spacing + box
        return TextEdit(
            range: selection,
            replacement: insertion,
            selection: NSRange(location: selection.location + insertion.utf16.count, length: 0)
        )
    }

    /// Whether the line before or after `lineRange` is a list item.
    private static func isInList(_ lineRange: NSRange, _ ns: NSString) -> Bool {
        var neighbours: [NSRange] = []
        if lineRange.location > 0 { neighbours.append(ns.lineWithoutBreak(at: lineRange.location - 1)) }
        let after = NSMaxRange(lineRange) + 1
        if after <= ns.length, NSMaxRange(lineRange) < ns.length { neighbours.append(ns.lineWithoutBreak(at: after)) }
        return neighbours.contains { range in
            let line = ns.substring(with: range)
            return ListLine.parse(line) != nil || line.wholeMatch(of: bareItem) != nil
        }
    }

    /// Tab (or Shift-Tab with `outdent`) on list item lines: nests them under the previous item, or moves
    /// them back out. Returns nil when the first selected line is not a list item.
    public static func indent(in text: String, selection: NSRange, outdent: Bool) -> TextEdit? {
        let ns = text as NSString
        let firstLine = ns.lineWithoutBreak(at: selection.location)
        guard ListLine.parse(ns.substring(with: firstLine)) != nil else { return nil }
        let lastLine = ns.lineWithoutBreak(at: max(selection.location, NSMaxRange(selection) - (selection.length > 0 ? 1 : 0)))
        let block = NSRange(location: firstLine.location, length: NSMaxRange(lastLine) - firstLine.location)

        var lines = ns.substring(with: block).components(separatedBy: "\n")
        var shiftFirst = 0
        var shiftTotal = 0
        var lineStart = block.location
        for index in lines.indices {
            let line = lines[index]
            defer { lineStart += line.utf16.count + 1 }
            guard let item = ListLine.parse(line) else { continue }
            let newIndent: String
            if outdent {
                newIndent = parentIndent(before: lineStart, in: ns, indent: item.indent)
                    ?? String(item.indent.dropFirst(min(item.indent.count, item.marker.count + 1)))
            } else {
                newIndent = item.indent + String(repeating: " ", count: item.marker.count + item.spacing.count)
            }
            let delta = newIndent.utf16.count - item.indent.utf16.count
            lines[index] = newIndent + line.dropFirst(item.indent.count)
            if index == 0 { shiftFirst = delta }
            shiftTotal += delta
        }
        guard shiftTotal != 0 else { return nil }

        let replacement = lines.joined(separator: "\n")
        let newSelection: NSRange
        if selection.length == 0 {
            newSelection = NSRange(location: max(firstLine.location, selection.location + shiftFirst), length: 0)
        } else {
            newSelection = NSRange(location: block.location, length: replacement.utf16.count)
        }
        return TextEdit(range: block, replacement: replacement, selection: newSelection)
    }

    /// The indent of the closest list item above `location` that is less indented than `indent`.
    private static func parentIndent(before location: Int, in ns: NSString, indent: String) -> String? {
        var cursor = location - 1
        while cursor > 0 {
            let line = ns.lineWithoutBreak(at: cursor - 1)
            if let item = ListLine.parse(ns.substring(with: line)), item.indent.count < indent.count {
                return item.indent
            }
            if line.length == 0 { return nil }
            cursor = line.location
        }
        return nil
    }
}

/// Return inside a quote or a callout keeps writing in it, as in Craft's focus blocks.
public enum QuoteEditing {
    /// Return at `selection` on a `>` line: the next line starts with the same `>` marks, or an empty quote line
    /// ends the quote. Returns nil when Return should behave normally.
    public static func newline(in text: String, selection: NSRange) -> TextEdit? {
        guard selection.length == 0 else { return nil }
        let ns = text as NSString
        let lineRange = ns.lineWithoutBreak(at: selection.location)
        let line = ns.substring(with: lineRange)
        guard let match = line.firstMatch(of: /^[ \t]*(?:>[ \t]?)+/) else { return nil }
        let prefix = String(match.0)
        let contentStart = lineRange.location + prefix.utf16.count
        guard selection.location >= contentStart else { return nil }
        let content = ns.substring(with: NSRange(location: contentStart, length: NSMaxRange(lineRange) - contentStart))
        if content.trimmingCharacters(in: .whitespaces).isEmpty {
            // Return on an empty quote line leaves the quote: its marks go away, and a blank line keeps the next
            // line from joining the quote (a lazy continuation).
            return TextEdit(range: lineRange, replacement: "\n", selection: NSRange(location: lineRange.location + 1, length: 0))
        }
        let marks = prefix.hasSuffix(" ") || prefix.hasSuffix("\t") ? prefix : prefix + " "
        let insertion = "\n" + marks
        return TextEdit(
            range: selection,
            replacement: insertion,
            selection: NSRange(location: selection.location + insertion.utf16.count, length: 0)
        )
    }
}
