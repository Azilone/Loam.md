import AppKit

/// How the editor draws a `📅 2026-10-21` (or `due:`, `✅`) in place of its text: Craft's pill, a calendar and
/// "Today", "Tomorrow" or "Wed, Oct 21". Blue, red when an open task is overdue, grey once done.
struct DatePill: Equatable {
    enum Tone: Equatable { case due, overdue, done }

    /// `YYYY-MM-DD`, as written in the note.
    let day: String
    let label: String
    let symbol: String
    let tone: Tone

    init(day: String, today: String, completion: Bool, openTask: Bool) {
        self.day = day
        label = Self.label(day: day, today: today)
        symbol = completion ? "checkmark" : "calendar"
        tone = completion || !openTask && day < today ? .done : (openTask && day < today ? .overdue : .due)
    }

    static let padding: CGFloat = 6
    static let gap: CGFloat = 4

    static func iconSize(_ font: NSFont) -> CGFloat { round(font.pointSize * 0.85) }

    /// The room the pill takes on the line.
    func width(font: NSFont) -> CGFloat {
        let text = (label as NSString).size(withAttributes: [.font: font]).width
        return ceil(Self.padding * 2 + Self.iconSize(font) + Self.gap + text) + 2
    }

    /// "Today", "Tomorrow", "Yesterday", else "Wed, Oct 21", with the year when it is not this one.
    static func label(day: String, today: String) -> String {
        guard let date = parser.date(from: day), let base = parser.date(from: today) else { return day }
        switch calendar.dateComponents([.day], from: base, to: date).day {
        case 0: return "Today"
        case 1: return "Tomorrow"
        case -1: return "Yesterday"
        default:
            return (day.prefix(4) == today.prefix(4) ? sameYear : otherYear).string(from: date)
        }
    }

    private static func formatter(_ format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = format
        return formatter
    }

    private static let sameYear = formatter("EEE, MMM d")
    private static let otherYear = formatter("MMM d, yyyy")

    /// Today in the user's time zone, `YYYY-MM-DD`.
    static func localToday() -> String {
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    private static let parser: DateFormatter = {
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.timeZone = TimeZone(identifier: "UTC")
        parser.dateFormat = "yyyy-MM-dd"
        return parser
    }()

    private static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()
}
