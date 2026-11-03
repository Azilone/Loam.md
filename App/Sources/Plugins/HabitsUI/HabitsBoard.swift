import Foundation
import HabitTrackerPlugin
import Observation
import PluginKitUI
import SwiftUI

/// The habits page's state, shared by the commands, the sidebar link and every `habits:` tab: one card per habit,
/// its last week and, opened, its last months. Habits are read and written through the `habits` service only.
@MainActor
@Observable
final class HabitsBoard {
    /// How many days the week strip shows, today last.
    static let dayCount = 7
    /// How many weeks the history grid shows.
    static let weekCount = 20

    /// One day of the strip.
    struct Day: Identifiable, Equatable, Sendable {
        /// `YYYY-MM-DD`, unique in the window.
        let id: String
        /// A short weekday name, "Mon".
        let weekday: String
        /// The day of the month.
        let number: Int
        let isToday: Bool
    }

    struct Row: Identifiable, Equatable, Sendable {
        var id: String { path }
        let name: String
        let path: String
        let color: String
        /// Whether the note sets `color`; otherwise it is derived from the name.
        var colorChosen = false
        let icon: String?
        let currentStreak: Int
        let longestStreak: Int
        let checkedDays: Set<String>
        /// In the order of `days`.
        let checked: [Bool]

        var doneToday: Bool { checked.last == true }
    }

    /// The colours a habit can take, in the menu's order.
    static let colors = ["orange", "red", "pink", "purple", "indigo", "blue", "teal", "green", "yellow"]

    private(set) var days: [Day] = []
    private(set) var rows: [Row] = []
    private(set) var error: String?
    private(set) var folder = "Habits"
    /// The habit the right sidebar shows; the first one when none was picked.
    private(set) var selected: String?
    /// Raised by `habits.new`: the page focuses its field.
    private(set) var focusRequest = 0

    @ObservationIgnored private let service: HabitsService
    @ObservationIgnored private let workspace: @MainActor () -> (any Workspace)?
    @ObservationIgnored private let quickPick: @MainActor () -> (any QuickPick)?

    init(
        service: HabitsService,
        workspace: @escaping @MainActor () -> (any Workspace)?,
        quickPick: @escaping @MainActor () -> (any QuickPick)?
    ) {
        self.service = service
        self.workspace = workspace
        self.quickPick = quickPick
    }

    var today: String { service.today }
    var doneToday: Int { rows.filter(\.doneToday).count }

    /// Reads the habits and today again (the date changes at midnight).
    func refresh() {
        let newDays = Self.window(endingAt: service.today, count: Self.dayCount)
        if newDays != days { days = newDays }
        if service.folder != folder { folder = service.folder }
        let habits: [Habit]
        do {
            habits = try service.habits()
        } catch {
            self.error = "\(error)"
            return
        }
        let newRows = habits.filter { !$0.archived }.map { habit in
            Row(
                name: habit.name,
                path: habit.path,
                color: habit.color.flatMap { Self.colors.contains($0.lowercased()) ? $0.lowercased() : nil } ?? Self.defaultColor(habit.name),
                colorChosen: habit.color.map { Self.colors.contains($0.lowercased()) } ?? false,
                icon: habit.icon,
                currentStreak: habit.currentStreak,
                longestStreak: habit.longestStreak,
                checkedDays: habit.checkedDays,
                checked: newDays.map { habit.checkedDays.contains($0.id) }
            )
        }
        guard newRows != rows else { return }
        // A habit added or archived slides in or out (`HabitCard`'s transition). The animation is set here, on that
        // change only: an `.animation(value:)` over the page made SwiftUI keep the page's layers at their old width
        // when the right sidebar opened, so the cards and the header were drawn half a sidebar to the left.
        if newRows.map(\.path) != rows.map(\.path), !Motion.reduceMotion {
            withAnimation(Motion.Spring.standard.animation) { rows = newRows }
        } else {
            rows = newRows
        }
    }

    // MARK: Actions

    /// Checks or unchecks a day of a habit.
    func toggle(_ row: Row, day: String) {
        let isChecked = rows.first { $0.path == row.path }?.checkedDays.contains(day) ?? false
        run {
            if isChecked { try service.uncheck(row.name, date: day) } else { try service.check(row.name, date: day) }
        }
        if error == nil { playCheck(done: !isChecked, day: day) }
    }

    /// `done` for a check, `allDone` when it was the day's last habit, `undone` for an uncheck.
    private func playCheck(done: Bool, day: String) {
        Sounds.play(!done ? .undone : rows.allSatisfy { $0.checkedDays.contains(day) } ? .allDone : .done)
    }

    /// Creates a habit; nil (and `error` set) when it failed.
    @discardableResult
    func create(_ name: String) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        var path: String?
        run { path = try service.create(trimmed) }
        return path
    }

    /// Creates a habit with an icon, as the empty page's suggestions do.
    func create(_ name: String, icon: String) {
        run {
            _ = try service.create(name)
            try service.setProperty(name, key: "icon", value: icon)
        }
    }

    /// The last `weeks` weeks of the strip, today last: the page shows as many as its width holds.
    func days(weeks: Int) -> [Day] {
        weeks <= 1 ? days : Self.window(endingAt: today, count: weeks * Self.dayCount)
    }

    func setColor(_ row: Row, _ color: String) {
        run { try service.setProperty(row.name, key: "color", value: color) }
    }

    func setIcon(_ row: Row, _ icon: String?) {
        run { try service.setProperty(row.name, key: "icon", value: icon) }
    }

    /// Takes a habit off the page; its note stays, with `archived: true`.
    func archive(_ row: Row) {
        run { try service.setProperty(row.name, key: "archived", value: "true") }
    }

    var selectedRow: Row? { rows.first { $0.path == selected } ?? rows.first }

    func select(_ row: Row) {
        selected = row.path
    }

    /// Selects `row` and shows the right sidebar, where its history and figures are.
    func inspect(_ row: Row) {
        select(row)
        workspace()?.showInspector()
    }

    /// Check-ins of every habit over the last `days` days, today included.
    func checkIns(lastDays days: Int) -> Int {
        let window = Set(Self.window(endingAt: today, count: days).map(\.id))
        return rows.reduce(0) { $0 + $1.checkedDays.intersection(window).count }
    }

    func openNote(_ row: Row) {
        workspace()?.open(.file(row.path), placement: .beside)
    }

    func openBoard() -> String {
        guard let workspace = workspace() else { return "No workspace in this host." }
        workspace.open(HabitsUIPlugin.boardResource, placement: .newTab)
        return "Opened the habits page."
    }

    /// Opens the page with its "New habit" field focused.
    func newHabit() -> String {
        let answer = openBoard()
        focusRequest += 1
        return answer
    }

    /// A popup of the habits; the chosen one is checked today.
    func showCheckToday() -> String {
        guard let quickPick = quickPick() else { return "No quick pick popup in this host." }
        refresh()
        guard !rows.isEmpty else { return "No habit yet." }
        let rows = rows
        quickPick.show(
            placeholder: "Check a habit for today…",
            items: { query in
                Fuzzy.rank(rows, query: query, key: \.name).map { row in
                    QuickPickItem(
                        id: row.path,
                        title: row.name,
                        subtitle: row.currentStreak > 0 ? "\(row.currentStreak) days" : nil,
                        symbol: row.doneToday ? "checkmark.circle.fill" : "circle"
                    )
                }
            },
            choose: { [weak self] item in self?.checkToday(path: item.id) }
        )
        return ""
    }

    private func checkToday(path: String) {
        guard let row = rows.first(where: { $0.path == path }) else { return }
        run { try service.check(row.name, date: nil) }
        if error == nil { playCheck(done: true, day: today) }
    }

    private func run(_ body: () throws -> Void) {
        do {
            try body()
            error = nil
        } catch {
            self.error = Self.describe(error)
        }
        refresh()
    }

    private static func describe(_ error: Error) -> String {
        switch error as? HabitError {
        case .alreadyExists(let name): return "\"\(name)\" already exists."
        case .invalidName(let name): return "\"\(name)\" cannot be a habit name."
        case .invalidDate(let date): return "\(date) is not a day."
        case nil: return "\(error)"
        }
    }

    // MARK: Stats

    /// The share of the last 30 days that are checked, 0 to 1 (counted from the habit's first day when younger).
    func rate(_ row: Row) -> Double {
        let last30 = Self.window(endingAt: today, count: 30).map(\.id)
        let first = row.checkedDays.min() ?? today
        let span = last30.filter { $0 >= first }
        guard !span.isEmpty else { return 0 }
        return Double(span.filter { row.checkedDays.contains($0) }.count) / Double(span.count)
    }

    /// The history grid: `weekCount` columns of seven days, Monday (or the locale's first day) on top, ending with
    /// the current week. Days after today are nil.
    func history(weeks: Int = HabitsBoard.weekCount, calendar: Calendar = .current) -> [[String?]] {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        utc.firstWeekday = calendar.firstWeekday
        let parts = today.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3, let end = utc.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2])),
              let weekStart = utc.dateInterval(of: .weekOfYear, for: end)?.start,
              let first = utc.date(byAdding: .weekOfYear, value: -(weeks - 1), to: weekStart) else { return [] }
        return (0..<weeks).map { week in
            (0..<7).map { offset in
                guard let date = utc.date(byAdding: .day, value: week * 7 + offset, to: first), date <= end else { return nil }
                let c = utc.dateComponents([.year, .month, .day], from: date)
                return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
            }
        }
    }

    // MARK: Days

    /// The `count` days ending on `today` (`YYYY-MM-DD`), oldest first. Empty when `today` is not a valid day.
    static func window(endingAt today: String, count: Int, locale: Locale = .current) -> [Day] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        calendar.locale = locale
        let parts = today.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3,
              let end = calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
        else { return [] }
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = locale
        formatter.setLocalizedDateFormatFromTemplate("EEE")
        return (0..<count).reversed().compactMap { offset in
            guard let date = calendar.date(byAdding: .day, value: -offset, to: end) else { return nil }
            let c = calendar.dateComponents([.year, .month, .day], from: date)
            let id = String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
            return Day(id: id, weekday: formatter.string(from: date), number: c.day ?? 0, isToday: offset == 0)
        }
    }

    /// A colour that stays the same for a name, until one is chosen.
    static func defaultColor(_ name: String) -> String {
        let sum = name.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF }
        return colors[sum % colors.count]
    }

    /// `row`'s colour. A habit whose colour was never picked takes the accent, so the page stays one ink; a picked
    /// colour always shows.
    static func swiftUIColor(_ row: Row, theme: ThemeTokens) -> Color {
        !row.colorChosen ? theme.accent : swiftUIColor(row.color)
    }

    static func swiftUIColor(_ name: String) -> Color {
        switch name {
        case "red": return .red
        case "pink": return .pink
        case "purple": return .purple
        case "indigo": return .indigo
        case "blue": return .blue
        case "teal": return .teal
        case "green": return .green
        // The system yellow is too pale for a white check: a deeper gold.
        case "yellow": return Color(red: 0.93, green: 0.68, blue: 0.08)
        default: return .orange
        }
    }
}
