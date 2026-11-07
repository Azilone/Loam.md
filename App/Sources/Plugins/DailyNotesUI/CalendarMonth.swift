import Foundation

/// A month of the Gregorian calendar, `YYYY-MM`. The calendar view's state and the rest of a `calendar:` resource.
struct Month: Hashable, Codable, Sendable, Comparable {
    let year: Int
    /// 1...12.
    let month: Int

    init?(year: Int, month: Int) {
        guard (1...12).contains(month), (1...9999).contains(year) else { return nil }
        self.year = year
        self.month = month
    }

    /// Parses `YYYY-MM`, or the month of a day `YYYY-MM-DD`.
    init?(_ text: String) {
        let parts = text.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 2 || parts.count == 3, parts[0].count == 4, parts[1].count == 2,
              let year = Int(parts[0]), let month = Int(parts[1])
        else { return nil }
        self.init(year: year, month: month)
    }

    /// `YYYY-MM`.
    var string: String { String(format: "%04d-%02d", year, month) }

    /// The month `count` months later (earlier when negative).
    func adding(_ count: Int) -> Month {
        let index = year * 12 + (month - 1) + count
        return Month(year: index / 12, month: index % 12 + 1) ?? self
    }

    /// `YYYY-MM-DD` of a day of this month.
    func day(_ day: Int) -> String { string + String(format: "-%02d", day) }

    static func < (a: Month, b: Month) -> Bool { (a.year, a.month) < (b.year, b.month) }
}

/// What the calendar grid shows for one month: weekday titles and weeks of seven cells. Pure, so the layout is
/// tested without a view.
struct CalendarMonth: Equatable, Sendable {
    struct Cell: Identifiable, Equatable, Sendable {
        /// The date for a day, `blank-<n>` for the empty cells before and after the month, so no two cells of the
        /// grid share an id.
        let id: String
        /// `YYYY-MM-DD`, nil for a blank cell.
        let date: String?
        /// The day of the month, 0 for a blank cell.
        let number: Int
        let hasNote: Bool
        let isToday: Bool
        /// The day of the daily note in the focused tab.
        let isSelected: Bool

        static func blank(_ index: Int) -> Cell {
            Cell(id: "blank-\(index)", date: nil, number: 0, hasNote: false, isToday: false, isSelected: false)
        }
    }

    let month: Month
    /// "October 2026", in the calendar's locale.
    let title: String
    /// Seven short weekday names, starting with the calendar's first weekday.
    let weekdays: [String]
    /// Each week has seven cells.
    let weeks: [[Cell]]

    /// The grid of `month`. Weeks start on `calendar.firstWeekday` (Monday in most of Europe), so the first week
    /// has that many blank cells before day 1; the last week is padded with blanks.
    static func make(
        _ month: Month,
        calendar: Calendar,
        dates: Set<String>,
        today: String,
        selected: String?
    ) -> CalendarMonth {
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.locale = calendar.locale
        gregorian.timeZone = calendar.timeZone
        gregorian.firstWeekday = calendar.firstWeekday

        let first = gregorian.date(from: DateComponents(year: month.year, month: month.month, day: 1)) ?? Date()
        let weekday = gregorian.component(.weekday, from: first)
        let leading = (weekday - gregorian.firstWeekday + 7) % 7
        let count = gregorian.range(of: .day, in: .month, for: first)?.count ?? 30

        var cells = (0..<leading).map(Cell.blank)
        for number in 1...count {
            let date = month.day(number)
            cells.append(Cell(
                id: date,
                date: date,
                number: number,
                hasNote: dates.contains(date),
                isToday: date == today,
                isSelected: date == selected
            ))
        }
        while cells.count % 7 != 0 { cells.append(.blank(cells.count)) }
        let weeks = stride(from: 0, to: cells.count, by: 7).map { Array(cells[$0..<$0 + 7]) }

        let symbols = gregorian.shortStandaloneWeekdaySymbols
        let shift = gregorian.firstWeekday - 1
        let weekdays = Array(symbols[shift...] + symbols[..<shift])

        let formatter = DateFormatter()
        formatter.calendar = gregorian
        formatter.locale = gregorian.locale
        formatter.timeZone = gregorian.timeZone
        formatter.setLocalizedDateFormatFromTemplate("MMMM y")
        return CalendarMonth(month: month, title: formatter.string(from: first), weekdays: weekdays, weeks: weeks)
    }
}
