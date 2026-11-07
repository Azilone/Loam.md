import AppKit

extension EditorController {
    /// The text selected in the note, as written; nil when nothing is selected.
    public var selectedText: String? {
        guard let textView else { return nil }
        let range = textView.selectedRange()
        guard range.length > 0, NSMaxRange(range) <= (textView.string as NSString).length else { return nil }
        let text = (textView.string as NSString).substring(with: range)
        return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : text
    }
}
