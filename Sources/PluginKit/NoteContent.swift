import Foundation

/// What counts as a note holding nothing. Loam never keeps such a note on disk: a note made in the app is only
/// written once it has content.
public enum NoteContent {
    /// True for a text that is only whitespace, or only frontmatter without any property (an empty `---` block)
    /// with nothing after it. Frontmatter that holds a property is content: the user typed it, or a template put
    /// it there and the user kept the note.
    public static func isEmpty(_ text: String) -> Bool {
        let parts = MarkdownFrontmatter.split(text)
        guard parts.body.allSatisfy(\.isWhitespace) else { return false }
        guard let yaml = parts.yaml else { return true }
        return yaml.split(whereSeparator: \.isNewline).allSatisfy {
            let line = $0.trimmingCharacters(in: .whitespaces)
            return line.isEmpty || line.hasPrefix("#")
        }
    }

    /// True when nothing follows the frontmatter but whitespace: a template of properties alone, which nobody has
    /// written in yet, is not worth a file.
    public static func hasNoBody(_ text: String) -> Bool {
        MarkdownFrontmatter.split(text).body.allSatisfy(\.isWhitespace)
    }
}
