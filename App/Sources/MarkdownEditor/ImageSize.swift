import Foundation

/// An image's width as a note keeps it: after a pipe at the end of its alt text, `![A bridge|300](assets/a.png)`
/// (Obsidian's convention, so a vault opens the same in both; any other reader still shows the image, and the
/// alt text at worst). `![|300](...)` has no caption; `|300x200` is read as a width of 300, the height following the
/// ratio. A note whose images were never resized has no pipe, so is never rewritten.
enum ImageSize {
    /// The caption and the width in points of `alt`, as written inside `![...]`.
    static func split(_ alt: String) -> (caption: String, width: Int?) {
        guard let pipe = alt.lastIndex(of: "|") else { return (alt, nil) }
        let size = alt[alt.index(after: pipe)...]
        let parts = size.split(separator: "x", maxSplits: 1, omittingEmptySubsequences: false)
        guard let first = parts.first, !first.isEmpty, first.allSatisfy(\.isASCIIDigit), let width = Int(first), width > 0,
              parts.count == 1 || (parts[1].allSatisfy(\.isASCIIDigit) && !parts[1].isEmpty)
        else { return (alt, nil) }
        return (String(alt[..<pipe]), width)
    }

    /// `alt` with its width replaced by `width`, or removed when nil.
    static func alt(_ alt: String, width: Int?) -> String {
        let caption = split(alt).caption
        guard let width else { return caption }
        return "\(caption)|\(width)"
    }

    /// The part of the line `![alt](destination)` between the brackets, as a range of `line`; nil when it is no image.
    static func altRange(inImageLine line: String) -> Range<String.Index>? {
        guard let open = line.range(of: "![") else { return nil }
        guard line[..<open.lowerBound].allSatisfy(\.isWhitespace),
              let close = line.range(of: "](", range: open.upperBound..<line.endIndex) else { return nil }
        return open.upperBound..<close.lowerBound
    }

    /// The image line `line` with its width set (nil: removed); the rest of the line is kept as written. Nil when
    /// `line` is no image link.
    static func setting(width: Int?, inImageLine line: String) -> String? {
        guard let range = altRange(inImageLine: line) else { return nil }
        var result = line
        result.replaceSubrange(range, with: alt(String(line[range]), width: width))
        return result
    }
}

private extension Character {
    var isASCIIDigit: Bool { isASCII && isNumber }
}
