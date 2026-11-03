import Foundation

/// YAML frontmatter: an optional block between two `---` lines at the very top of a note.
public enum MarkdownFrontmatter {
    /// `raw + body == text`. `yaml` is the content between the delimiters, nil when there is none.
    public static func split(_ text: String) -> (raw: String, yaml: String?, body: String) {
        guard text.hasPrefix("---\n") || text.hasPrefix("---\r\n") else { return ("", nil, text) }
        // "\r\n" is a single Character, so both openings are four characters long.
        var offset = text.index(text.startIndex, offsetBy: 4)
        let yamlStart = offset
        while offset < text.endIndex {
            let lineEnd = text[offset...].firstIndex { $0 == "\n" || $0 == "\r\n" } ?? text.endIndex
            let line = text[offset..<lineEnd].trimmingCharacters(in: .whitespaces)
            let next = lineEnd < text.endIndex ? text.index(after: lineEnd) : text.endIndex
            if line == "---" || line == "..." {
                return (String(text[..<next]), String(text[yamlStart..<offset]), String(text[next...]))
            }
            offset = next
        }
        return ("", nil, text)
    }
}
