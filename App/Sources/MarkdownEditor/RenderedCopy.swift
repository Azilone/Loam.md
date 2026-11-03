import AppKit

/// What a copy puts on the pasteboard besides the Markdown: the selection as the page shows it, rich text without a
/// syntax character (a bullet is a `•`, a task box a `☐`, a link a link). Pasted into another app it looks as it did
/// here; pasted into a plain text field it is the Markdown, which is the note's own text.
enum RenderedCopy {
    static func attributedString(from storage: NSAttributedString, range: NSRange) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let kept: [NSAttributedString.Key] = [.font, .foregroundColor, .strikethroughStyle, .underlineStyle, .backgroundColor]
        // A task box or a bullet is one mark however many runs its characters (kerning) split into.
        var drawn = NSRange(location: NSNotFound, length: 0)
        storage.enumerateAttributes(in: range) { attributes, run, _ in
            if drawn.location != NSNotFound, NSIntersectionRange(drawn, run).length == run.length { return }
            var shown: [NSAttributedString.Key: Any] = [:]
            for key in kept { if let value = attributes[key] { shown[key] = value } }
            if let destination = attributes[.markdownLink] as? String, let url = URL(string: destination) { shown[.link] = url }
            let text = (storage.string as NSString).substring(with: run)
            if attributes[.markdownBullet] != nil {
                result.append(NSAttributedString(string: "•", attributes: shown))
            } else if let checked = attributes[.markdownTaskBox] as? Bool {
                _ = storage.attribute(.markdownTaskBox, at: run.location, longestEffectiveRange: &drawn, in: range)
                result.append(NSAttributedString(string: checked ? "☑" : "☐", attributes: shown.filter { $0.key != .foregroundColor }))
            } else if isHidden(attributes) {
                return
            } else {
                result.append(NSAttributedString(string: text, attributes: shown))
            }
        }
        return result
    }

    private static func isHidden(_ attributes: [NSAttributedString.Key: Any]) -> Bool {
        if let font = attributes[.font] as? NSFont, font.pointSize < 1 { return true }
        if let color = attributes[.foregroundColor] as? NSColor, color == NSColor.clear { return true }
        return false
    }
}
