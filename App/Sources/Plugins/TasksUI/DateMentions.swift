import Foundation
import PluginKitUI
import TasksPlugin

/// The "Days" section of the editor's `@` menu, Craft's: `@tomorrow`, `@fri`, `@21oct` offer the day they mean,
/// and choosing one writes it as the line's due date, `📅 YYYY-MM-DD`, which the editor shows as a pill.
enum DateMentions {
    static let sourceID = "tasks.days"

    /// `language`: the app's, whose words for days are understood besides English and name the days.
    static func source(
        language: String = Bundle.main.preferredLocalizations.first ?? "en",
        today: @escaping @MainActor @Sendable () -> String
    ) -> MentionSource {
        MentionSource(id: sourceID, section: "Days") { query in
            let today = today()
            return NaturalDate.suggestions(for: query, today: today, language: language).map { date in
                let title = NaturalDate.title(of: date, today: today, language: language)
                return MentionItem(id: date, title: title, symbol: "calendar") { text, trigger in
                    change(in: text, trigger: trigger, date: date)
                }
            }
        }
    }

    /// Replaces `trigger` (the `@` and the words after it) with `📅 date`, followed by a space, the caret after
    /// it. A line has one due date: one already on it (`📅` or `due:`) goes.
    static func change(in text: String, trigger: NSRange, date: String) -> TextChange {
        let ns = text as NSString
        let lineRange = ns.lineRange(for: NSRange(location: trigger.location, length: 0))
        var line = NSRange(location: lineRange.location, length: lineRange.length)
        while line.length > 0, [10, 13].contains(ns.character(at: NSMaxRange(line) - 1)) { line.length -= 1 }
        let following = NSMaxRange(trigger) < ns.length ? ns.character(at: NSMaxRange(trigger)) : 10
        let insert = "📅 " + date + (following == 32 ? "" : " ")
        // Everything from the line's start to its end, rebuilt: the old date out, the new one in place of `@...`.
        let before = ns.substring(with: NSRange(location: line.location, length: trigger.location - line.location))
        let after = ns.substring(with: NSRange(location: NSMaxRange(trigger), length: max(0, NSMaxRange(line) - NSMaxRange(trigger))))
        let cleanBefore = removingDueDate(before)
        let cleanAfter = removingDueDate(after, leading: true)
        let replacement = cleanBefore + insert + cleanAfter
        let caret = line.location + (cleanBefore + insert).utf16.count
        return TextChange(range: line, replacement: replacement, selection: NSRange(location: caret, length: 0))
    }

    private static let dueDate = try! NSRegularExpression(
        pattern: "[ \\t]?(?:📅\\s*|(?<!\\S)due:\\s?)[0-9]{4}-[0-9]{2}-[0-9]{2}"
    )

    /// `text` without its due dates and the space before each. `leading`: the text that follows the new date,
    /// where a date right at the start takes the space after it instead.
    private static func removingDueDate(_ text: String, leading: Bool = false) -> String {
        let ns = text as NSString
        var result = text
        for match in dueDate.matches(in: text, range: NSRange(location: 0, length: ns.length)).reversed() {
            var range = match.range
            if leading, range.location == 0, ns.substring(with: range).first != " ",
               NSMaxRange(range) < ns.length, ns.character(at: NSMaxRange(range)) == 32 {
                range.length += 1
            }
            result = (result as NSString).replacingCharacters(in: range, with: "")
        }
        return result
    }
}
