import Foundation

/// One replacement in the editor's text, in UTF-16 offsets, and where the selection goes afterwards.
public struct TextEdit: Equatable, Sendable {
    public let range: NSRange
    public let replacement: String
    /// The selection after the edit, in the edited text.
    public let selection: NSRange

    public init(range: NSRange, replacement: String, selection: NSRange) {
        self.range = range
        self.replacement = replacement
        self.selection = selection
    }

    /// Applies the edit to `text`. Used by tests; the editor applies edits through its text view.
    public func applied(to text: String) -> String {
        (text as NSString).replacingCharacters(in: range, with: replacement)
    }
}

extension NSString {
    /// The line containing `location`, without its line break.
    func lineWithoutBreak(at location: Int) -> NSRange {
        var line = lineRange(for: NSRange(location: min(location, length), length: 0))
        while line.length > 0, [10, 13].contains(character(at: NSMaxRange(line) - 1)) { line.length -= 1 }
        return line
    }
}
