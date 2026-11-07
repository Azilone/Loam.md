import Foundation

/// Date formatting for the daily notes views. A `DateFormatter` costs about 0.2 ms to make, and a view that builds
/// one per label did it a hundred times per draw, so they are made once and kept.
@MainActor
enum DayFormat {
    private static let parser: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
    private static var fixed: [String: DateFormatter] = [:]
    private static var localized: [String: DateFormatter] = [:]

    static func date(_ day: String) -> Date? { parser.date(from: day) }

    static var timeZone: TimeZone { parser.timeZone }

    static func string(from date: Date) -> String { parser.string(from: date) }

    /// `day` (`YYYY-MM-DD`) written with a fixed English pattern such as "EEE" or "MMM d, yyyy"; `day` itself when it
    /// is not a date.
    static func string(_ day: String, _ pattern: String) -> String {
        guard let date = date(day) else { return day }
        let formatter = fixed[pattern] ?? {
            let made = DateFormatter()
            made.locale = Locale(identifier: "en_US")
            made.dateFormat = pattern
            fixed[pattern] = made
            return made
        }()
        return formatter.string(from: date)
    }

    /// `day` written in the user's language from a template such as "MMM d".
    static func localized(_ day: String, _ template: String) -> String {
        guard let date = date(day) else { return day }
        let formatter = localized[template] ?? {
            let made = DateFormatter()
            made.setLocalizedDateFormatFromTemplate(template)
            localized[template] = made
            return made
        }()
        return formatter.string(from: date)
    }
}
