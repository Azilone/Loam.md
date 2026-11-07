import PluginKitUI
import SwiftUI

/// The month grid, in a tab (`daily.calendar`) or in the Calendar panel: a header with the month, ‹ › and Today,
/// the weekday names, then the days. A dot marks a day with a note, today is in the accent colour, and the day of
/// the focused daily note is highlighted. Clicking a day opens its note; the file is created when text is typed in it.
struct CalendarView: View {
    let model: DailyCalendar
    /// Where a clicked day opens.
    let placement: Placement
    /// Called with the month shown after ‹, › or Today, so a tab can save it.
    let onMonthChange: @MainActor (Month) -> Void
    @State private var month: Month
    @Environment(\.themeTokens) private var theme

    init(
        model: DailyCalendar,
        month: Month,
        placement: Placement,
        onMonthChange: @escaping @MainActor (Month) -> Void = { _ in }
    ) {
        self.model = model
        self.placement = placement
        self.onMonthChange = onMonthChange
        _month = State(initialValue: month)
    }

    var body: some View {
        let grid = model.grid(month)
        VStack(alignment: .leading, spacing: theme.spacing.medium) {
            header(grid.title)
            Grid(horizontalSpacing: 2, verticalSpacing: 2) {
                GridRow {
                    ForEach(Array(grid.weekdays.enumerated()), id: \.offset) { _, name in
                        Text(name)
                            .font(.ui(.caption))
                            .foregroundStyle(theme.secondaryText)
                            .frame(maxWidth: .infinity)
                    }
                }
                ForEach(Array(grid.weeks.enumerated()), id: \.offset) { _, week in
                    GridRow {
                        ForEach(week) { cell in
                            DayCell(cell: cell) { open(cell) }
                        }
                    }
                }
            }
        }
        .padding(Space.s)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func header(_ title: String) -> some View {
        HStack(spacing: Space.xs) {
            Text(title.uiLocalized).font(.ui(.emphasis)).foregroundStyle(theme.text).lineLimit(1)
            Spacer(minLength: 0)
            Button { show(month.adding(-1)) } label: { Image(symbol: "chevron.left") }
                .help("Previous month")
            Button("Today") { show(Month(model.today) ?? month) }
                .help("Show this month")
            Button { show(month.adding(1)) } label: { Image(symbol: "chevron.right") }
                .help("Next month")
        }
        .buttonStyle(.borderless)
    }

    private func show(_ newMonth: Month) {
        guard newMonth != month else { return }
        month = newMonth
        onMonthChange(newMonth)
    }

    private func open(_ cell: CalendarMonth.Cell) {
        guard let date = cell.date else { return }
        // A failure (a read-only vault) leaves nothing open, which the user sees.
        _ = try? model.openDay(date, placement: DailyCalendar.clickPlacement(placement))
    }
}

/// One day of the grid; an empty square for a blank cell.
private struct DayCell: View {
    let cell: CalendarMonth.Cell
    let action: () -> Void
    @Environment(\.themeTokens) private var theme

    var body: some View {
        if cell.date == nil {
            // A fixed height: Color.clear takes all the height it is offered, which stretched the first week.
            Color.clear.frame(maxWidth: .infinity, minHeight: 28, maxHeight: 28)
        } else {
            Button { action() } label: {
                VStack(spacing: 1) {
                    Text("\(cell.number)")
                        .font(.ui(.body, weight: cell.isToday ? .bold : .regular))
                        .foregroundStyle(cell.isToday ? theme.accent : theme.text)
                    Circle()
                        .fill(theme.secondaryText)
                        .frame(width: 4, height: 4)
                        .opacity(cell.hasNote ? 1 : 0)
                }
                .frame(maxWidth: .infinity, minHeight: 28)
                .background(
                    RoundedRectangle(cornerRadius: Radius.s, style: .continuous)
                        .fill(cell.isSelected ? theme.accent.opacity(0.2) : Color.clear)
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Open \(cell.date ?? "")")
        }
    }
}
