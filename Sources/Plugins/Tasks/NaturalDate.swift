import Foundation

/// Days written as people type them after `@`: "today", "tom", "fri", "next week", "in 3 days", "21oct",
/// "oct 21", "21/10", "2026-10-21", in English and in the user's language (French, German, Spanish, Italian, Dutch,
/// Arabic, Hindi, Japanese, Korean, Chinese: `demain`, `morgen`, `明日`, `10月21日`). Dates are `YYYY-MM-DD` strings,
/// as in task lines, and everything is relative to a `today` given by the caller, so the results never depend on the
/// clock.
public enum NaturalDate {
    /// The days `query` can mean, best first, without duplicates; at most `limit`. An empty query offers today,
    /// tomorrow and next week. A day without a year is its next occurrence (today included). `language` is the
    /// user's (`fr`, `zh-Hans`): its words are understood besides English, and come first.
    public static func suggestions(for query: String, today: String, language: String = "en", limit: Int = 5) -> [String] {
        guard let base = day(today) else { return [] }
        let words = normalized(query)
        let lexicon = Lexicon(language)
        var results: [String] = []
        func add(_ date: Date?) {
            guard let date else { return }
            let text = string(date)
            if !results.contains(text) { results.append(text) }
        }
        if words.isEmpty {
            for meaning in [Meaning.today, .tomorrow, .nextWeek] { add(resolve(meaning, from: base)) }
            return results
        }
        add(iso(words))
        for date in numeric(words, from: base) { add(date) }
        for date in counted(words, lexicon: lexicon, from: base) { add(date) }
        for date in dayAndMonth(words, lexicon: lexicon, from: base) { add(date) }
        for date in eastAsian(words, from: base) { add(date) }
        for (phrase, meaning) in lexicon.phrases
        where phrase.split(separator: " ").contains(where: { $0.hasPrefix(words) }) || phrase.hasPrefix(words) {
            add(resolve(meaning, from: base))
        }
        return Array(results.prefix(limit))
    }

    /// How the `@` menu names a day, in `language`: "Today, Mon, Oct 19", "Tomorrow, Tue, Oct 20", else
    /// "Wed, Oct 21", with the year when it is not this year's ("Demain, mar. 20 oct." in French).
    public static func title(of date: String, today: String, language: String = "en") -> String {
        guard let target = day(date), let base = day(today) else { return date }
        let lexicon = Lexicon(language)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: lexicon.code == "en" ? "en_US_POSIX" : language)
        formatter.timeZone = utc
        let sameYear = calendar.component(.year, from: target) == calendar.component(.year, from: base)
        if lexicon.code == "en" {
            formatter.dateFormat = sameYear ? "EEE, MMM d" : "EEE, MMM d, yyyy"
        } else {
            formatter.setLocalizedDateFormatFromTemplate(sameYear ? "EEEMMMd" : "EEEMMMdyyyy")
        }
        let name = formatter.string(from: target)
        let relative: Meaning? = switch calendar.dateComponents([.day], from: base, to: target).day {
        case 0: .today
        case 1: .tomorrow
        case -1: .yesterday
        default: nil
        }
        guard let relative, let word = lexicon.word(for: relative) else { return name }
        return word.prefix(1).uppercased() + word.dropFirst() + ", " + name
    }

    // MARK: Phrases

    /// What a word-based day means.
    enum Meaning: Equatable {
        case today, tomorrow, yesterday, dayAfterTomorrow, nextWeek, thisWeekend, nextMonth, endOfMonth
        /// 1 is Sunday, as in `Calendar`.
        case weekday(Int)
    }

    private static func resolve(_ meaning: Meaning, from base: Date) -> Date? {
        switch meaning {
        case .weekday(let weekday): return next(weekday: weekday, after: base, includingToday: false)
        case .today: return base
        case .tomorrow: return adding(1, .day, to: base)
        case .yesterday: return adding(-1, .day, to: base)
        case .dayAfterTomorrow: return adding(2, .day, to: base)
        case .nextWeek: return next(weekday: 2, after: base, includingToday: false)
        case .thisWeekend: return next(weekday: 7, after: base, includingToday: true)
        case .nextMonth:
            let start = calendar.date(from: calendar.dateComponents([.year, .month], from: base))
            return start.flatMap { adding(1, .month, to: $0) }
        case .endOfMonth:
            let start = calendar.date(from: calendar.dateComponents([.year, .month], from: base))
            return start.flatMap { adding(1, .month, to: $0) }.flatMap { adding(-1, .day, to: $0) }
        }
    }

    // MARK: Numbers

    /// `2026-10-21`.
    private static func iso(_ words: String) -> Date? {
        guard words.range(of: "^[0-9]{4}-[0-9]{2}-[0-9]{2}$", options: .regularExpression) != nil else { return nil }
        return day(words)
    }

    /// `21` (that day of this month, or the next), `21/10`, `21.10`, `21/10/2027`: day first, as in French, unless
    /// the first number cannot be a month day and the second can (`10/21`).
    private static func numeric(_ words: String, from base: Date) -> [Date] {
        let parts = words.split(whereSeparator: { $0 == "/" || $0 == "." }).map(String.init)
        guard (1...3).contains(parts.count), parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isASCII) && Int($0) != nil }),
              words.last != "/", words.last != "." || parts.count == 1 else { return [] }
        let numbers = parts.compactMap { Int($0) }
        if numbers.count == 1 {
            guard words.allSatisfy(\.isNumber), (1...31).contains(numbers[0]) else { return [] }
            let month = calendar.component(.month, from: base)
            return [occurrence(day: numbers[0], month: month, year: nil, from: base, monthly: true)].compactMap { $0 }
        }
        var (dayNumber, month) = (numbers[0], numbers[1])
        if dayNumber <= 12, month > 12 { swap(&dayNumber, &month) }
        let year = numbers.count == 3 ? (numbers[2] < 100 ? 2000 + numbers[2] : numbers[2]) : nil
        return [occurrence(day: dayNumber, month: month, year: year, from: base)].compactMap { $0 }
    }

    /// `in 3 days`, `3 days`, `3d`, `2 weeks`, `2w`, `1 month`, `+3`, and the same in the user's language:
    /// `dans 3 jours`, `in 2 Wochen`, `3日後`, `3일 후`.
    private static func counted(_ words: String, lexicon: Lexicon, from base: Date) -> [Date] {
        var text = words
        for prefix in lexicon.countPrefixes + ["+"] where text.hasPrefix(prefix) { text = String(text.dropFirst(prefix.count)) }
        let digits = text.prefix { $0.isASCII && $0.isNumber }
        guard let count = Int(digits), count > 0, count < 1000 else { return [] }
        let unit = text.dropFirst(digits.count).trimmingCharacters(in: .whitespaces)
        // A bare number is a day of the month (`numeric`), unless it was written `in 3` or `+3`.
        if unit.isEmpty { return text == words ? [] : [adding(count, .day, to: base)].compactMap { $0 } }
        // Any start of the unit's name (`d`, `day`, `days`), or the name and what follows it (`日後`, `दिन बाद`).
        return lexicon.units.filter { $0.names.contains { $0.hasPrefix(unit) || unit.hasPrefix($0) } }
            .compactMap { adding(count * $0.scale, $0.component, to: base) }
    }

    // MARK: Day and month

    /// `21oct`, `21 oct`, `21 octobre`, `oct 21`, `october 21st`, `1er mai`, `21. Oktober`, `21 de octubre`,
    /// `21 oct 2027`. A month written in part (`21 ju`) offers every month it can be.
    private static func dayAndMonth(_ words: String, lexicon: Lexicon, from base: Date) -> [Date] {
        let ns = words as NSString
        guard let match = dayMonthPattern.firstMatch(in: words, range: NSRange(location: 0, length: ns.length)) else { return [] }
        func group(_ index: Int) -> String? {
            let range = match.range(at: index)
            return range.location == NSNotFound ? nil : ns.substring(with: range)
        }
        guard let dayNumber = (group(1) ?? group(4)).flatMap({ Int($0) }), let monthText = group(2) ?? group(3) else { return [] }
        let year = group(5).flatMap { Int($0) }
        return lexicon.months.filter { month in month.names.contains { $0.hasPrefix(monthText) } }
            .compactMap { occurrence(day: dayNumber, month: $0.number, year: year, from: base) }
    }

    private static let dayMonthPattern = try! NSRegularExpression(
        pattern: "^(?:([0-9]{1,2})(?:st|nd|rd|th|er|\\.)?\\s*(?:de\\s+)?([a-z]+)|([a-z]+)\\s*([0-9]{1,2})(?:st|nd|rd|th)?)(?:\\s+([0-9]{4}))?$"
    )

    /// `10月21日`, `2027年10月21日`, `10월 21일`: month then day, as Chinese, Japanese and Korean write them.
    private static func eastAsian(_ words: String, from base: Date) -> [Date] {
        let ns = words as NSString
        guard let match = eastAsianPattern.firstMatch(in: words, range: NSRange(location: 0, length: ns.length)) else { return [] }
        func number(_ index: Int) -> Int? {
            let range = match.range(at: index)
            return range.location == NSNotFound ? nil : Int(ns.substring(with: range))
        }
        guard let month = number(2), let dayNumber = number(3) else { return [] }
        return [occurrence(day: dayNumber, month: month, year: number(1), from: base)].compactMap { $0 }
    }

    private static let eastAsianPattern = try! NSRegularExpression(
        pattern: "^(?:([0-9]{4})\\s*[年년]\\s*)?([0-9]{1,2})\\s*[月월]\\s*([0-9]{1,2})\\s*[日号일]?$"
    )

    // MARK: Calendar

    private static let utc = TimeZone(identifier: "UTC")!

    private static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utc
        return calendar
    }()

    /// `YYYY-MM-DD` as midnight UTC, or nil when it is not a real day.
    static func day(_ text: String) -> Date? {
        let parts = text.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3, text.count == 10 else { return nil }
        return valid(year: parts[0], month: parts[1], day: parts[2])
    }

    static func string(_ date: Date) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    private static func valid(year: Int, month: Int, day: Int) -> Date? {
        guard (1...12).contains(month), (1...31).contains(day),
              let date = calendar.date(from: DateComponents(year: year, month: month, day: day)) else { return nil }
        // The calendar rolls Feb 30 over into March; that is not a day someone meant.
        let check = calendar.dateComponents([.year, .month, .day], from: date)
        return check.year == year && check.month == month && check.day == day ? date : nil
    }

    /// That day in `year`, or its next occurrence from `base` (today included): next year for a month, next month
    /// when `monthly`.
    private static func occurrence(day: Int, month: Int, year: Int?, from base: Date, monthly: Bool = false) -> Date? {
        if let year { return valid(year: year, month: month, day: day) }
        let parts = calendar.dateComponents([.year, .month], from: base)
        guard let thisYear = parts.year else { return nil }
        if monthly {
            for offset in 0..<12 {
                guard let start = valid(year: thisYear, month: parts.month ?? 1, day: 1),
                      let shifted = adding(offset, .month, to: start) else { continue }
                let shiftedParts = calendar.dateComponents([.year, .month], from: shifted)
                if let date = valid(year: shiftedParts.year ?? thisYear, month: shiftedParts.month ?? 1, day: day), date >= base {
                    return date
                }
            }
            return nil
        }
        for candidate in thisYear...(thisYear + 4) {
            if let date = valid(year: candidate, month: month, day: day), date >= base { return date }
        }
        return nil
    }

    private static func next(weekday: Int, after base: Date, includingToday: Bool) -> Date? {
        let current = calendar.component(.weekday, from: base)
        var offset = (weekday - current + 7) % 7
        if offset == 0, !includingToday { offset = 7 }
        return adding(offset, .day, to: base)
    }

    private static func adding(_ value: Int, _ component: Calendar.Component, to date: Date) -> Date? {
        calendar.date(byAdding: component, value: value, to: date)
    }

    /// Lowercased, without accents, single spaces, no `@`.
    static func normalized(_ query: String) -> String {
        let folded = query.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .replacingOccurrences(of: "’", with: "'")
        return folded.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: "@"))
    }
}
