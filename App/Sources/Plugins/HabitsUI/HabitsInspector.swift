import AppKit
import PluginKitUI
import SwiftUI

/// The habits page's right sidebar: the selected habit (its figures, history, colour and icon), the week of every
/// habit, and the figures of all of them.
enum HabitsInspector {
    @MainActor static func tabs(_ model: HabitsBoard) -> [InspectorTab] {
        [
            InspectorTab(id: "habits.habit", title: "Habit") { AnyView(HabitTab(model: model)) },
            InspectorTab(id: "habits.week", title: "Week") { AnyView(WeekTab(model: model)) },
            InspectorTab(id: "habits.stats", title: "Stats") { AnyView(StatsTab(model: model)) },
        ]
    }

    static let icons = ["🏃", "📚", "🧘", "💧", "🥗", "💪", "✍️", "🛏️", "🚭", "🎸", "🌱", "🧠", "🦷", "☀️", "🙏"]
}

/// Padding and spacing of every tab.
private struct InspectorColumnLayout<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: InspectorStyle.groupSpacing) { content }
                .padding(.horizontal, InspectorStyle.padding)
                .padding(.vertical, 12)
        }
        .softScrollEdges()
    }
}

// MARK: Habit

private struct HabitTab: View {
    let model: HabitsBoard
    @Environment(\.themeTokens) private var theme

    var body: some View {
        InspectorColumnLayout {
            if let row = model.selectedRow {
                let color = HabitsBoard.swiftUIColor(row, theme: theme)
                HStack(spacing: 12) {
                    HabitBadge(row: row, color: color, size: 44)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.name)
                            .font(.ui(size: 17, weight: .semibold))
                            .foregroundStyle(theme.text)
                            .lineLimit(1)
                        Text(row.doneToday ? "Done today" : "Not yet today")
                            .font(.ui(size: 12))
                            .foregroundStyle(row.doneToday ? color : theme.secondaryText)
                    }
                }
                .padding(.horizontal, 2)
                .id(row.path)
                .transition(.opacity)

                InspectorTileGrid(columns: 2) {
                    InspectorFigure("\(row.currentStreak)", "Streak", symbol: "flame")
                    InspectorFigure("\(row.longestStreak)", "Best", symbol: "trophy")
                    InspectorFigure("\(row.checkedDays.count)", "Total", symbol: "checkmark")
                    InspectorFigure("\(Int((model.rate(row) * 100).rounded()))%", "30 days", symbol: "chart.bar")
                }

                InspectorGroup("History", accessory: "16 weeks") {
                    InspectorCard(padding: 12) {
                        Heatmap(model: model, row: row, color: color, weeks: 16)
                    }
                }

                InspectorGroup("Color") {
                    InspectorSwatches(
                        ["orange", "red", "purple", "blue", "teal", "green"].map { (id: $0, color: HabitsBoard.swiftUIColor($0), name: $0.capitalized) },
                        selection: row.colorChosen ? row.color : nil
                    ) { model.setColor(row, $0) }
                }

                InspectorGroup("Icon") {
                    InspectorCard(padding: 8) {
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: 5), spacing: 2) {
                            ForEach(HabitsInspector.icons, id: \.self) { emoji in
                                IconChoice(emoji: emoji, isSelected: row.icon == emoji, color: color) {
                                    model.setIcon(row, row.icon == emoji ? nil : emoji)
                                }
                            }
                        }
                    }
                }

                InspectorCard {
                    InspectorRow("Open Note", symbol: "doc.text", action: { model.openNote(row) }) { EmptyView() }
                    InspectorRow("Archive", symbol: "archivebox", action: { model.archive(row) }) { EmptyView() }
                }
            } else {
                InspectorEmpty("No habit yet", systemImage: "flame")
            }
        }
        .animation(Motion.Spring.standard.animation, value: model.selectedRow?.path)
    }
}

/// An emoji to pick, its circle tinted when chosen.
private struct IconChoice: View {
    let emoji: String
    let isSelected: Bool
    let color: Color
    let action: () -> Void
    @State private var hovered = false
    @Environment(\.themeTokens) private var theme

    var body: some View {
        Button(action: action) {
            ThemedEmoji(emoji: emoji, size: 18)
                .frame(width: 36, height: 36)
                .background(Circle().fill(isSelected ? color.opacity(0.22) : hovered ? theme.fillHover : .clear))
                .overlay(Circle().strokeBorder(isSelected ? color : .clear, lineWidth: 1.5))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { over in withAnimation(Motion.hover) { hovered = over } }
        .animation(Motion.Spring.tap.animation, value: isSelected)
    }
}

/// Weeks as columns of seven days; a click checks or unchecks a day.
struct Heatmap: View {
    let model: HabitsBoard
    let row: HabitsBoard.Row
    let color: Color
    let weeks: Int
    @Environment(\.themeTokens) private var theme

    var body: some View {
        let grid = model.history(weeks: weeks)
        GeometryReader { proxy in
            let gap: CGFloat = 3
            let side = max(4, (proxy.size.width - gap * CGFloat(weeks - 1)) / CGFloat(weeks))
            HStack(alignment: .top, spacing: gap) {
                ForEach(Array(grid.enumerated()), id: \.offset) { _, week in
                    VStack(spacing: gap) {
                        ForEach(Array(week.enumerated()), id: \.offset) { _, day in
                            cell(day, side: side)
                        }
                    }
                }
            }
        }
        .aspectRatio(CGFloat(weeks) / 7, contentMode: .fit)
    }

    @ViewBuilder private func cell(_ day: String?, side: CGFloat) -> some View {
        let shape = RoundedRectangle(cornerRadius: Corners.r(side * 0.28), style: .continuous)
        if let day {
            let done = row.checkedDays.contains(day)
            Button { model.toggle(row, day: day) } label: {
                shape.fill(done ? color : theme.text.opacity(0.07))
                    .overlay(shape.strokeBorder(day == model.today ? theme.text.opacity(0.45) : .clear, lineWidth: 1))
                    .frame(width: side, height: side)
            }
            .buttonStyle(.plain)
            .help(day)
            .animation(Motion.Spring.tap.animation, value: done)
        } else {
            Color.clear.frame(width: side, height: side)
        }
    }
}

// MARK: Week

private struct WeekTab: View {
    let model: HabitsBoard
    @Environment(\.themeTokens) private var theme

    var body: some View {
        InspectorColumnLayout {
            if model.rows.isEmpty {
                InspectorEmpty("No habit yet", systemImage: "flame")
            } else {
                InspectorCard(padding: 16) {
                    HStack(spacing: 16) {
                        ZStack {
                            ProgressRing(progress: Double(model.doneToday) / Double(model.rows.count), color: theme.accent, lineWidth: 7)
                            Text("\(model.doneToday)/\(model.rows.count)")
                                .font(.ui(size: 15, weight: .bold).monospacedDigit())
                                .foregroundStyle(theme.text)
                                .contentTransition(.numericText())
                        }
                        .frame(width: 64, height: 64)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Today").font(.ui(size: 15, weight: .semibold)).foregroundStyle(theme.text)
                            Text(model.doneToday == model.rows.count ? "All done" : "\(model.rows.count - model.doneToday) to go")
                                .font(.ui(size: 12))
                                .foregroundStyle(theme.secondaryText)
                        }
                        Spacer(minLength: 0)
                    }
                }

                InspectorGroup("This week") {
                    InspectorCard(padding: 14) {
                        WeekChart(model: model)
                    }
                }

                InspectorGroup("Check") {
                    InspectorCard {
                        ForEach(model.rows) { row in
                            let color = HabitsBoard.swiftUIColor(row, theme: theme)
                            InspectorRow(row.name, isSelected: row.path == model.selectedRow?.path, action: { model.select(row) }) {
                                CheckCircle(isChecked: row.doneToday, color: color) {
                                    model.toggle(row, day: model.today)
                                }
                            }
                        }
                    }
                }
            }
        }
        .animation(Motion.Spring.standard.animation, value: model.doneToday)
    }
}

/// A bar per day of the week: how many habits were done, today last.
private struct WeekChart: View {
    let model: HabitsBoard
    @Environment(\.themeTokens) private var theme

    var body: some View {
        let total = max(1, model.rows.count)
        HStack(alignment: .bottom, spacing: 8) {
            ForEach(Array(model.days.enumerated()), id: \.element.id) { index, day in
                let done = model.rows.filter { $0.checked[index] }.count
                VStack(spacing: 6) {
                    GeometryReader { proxy in
                        VStack {
                            Spacer(minLength: 0)
                            RoundedRectangle(cornerRadius: Corners.r(4), style: .continuous)
                                .fill(day.isToday ? theme.accent : theme.accent.opacity(0.35))
                                .frame(height: max(4, proxy.size.height * CGFloat(done) / CGFloat(total)))
                        }
                    }
                    .frame(height: 70)
                    Text(day.weekday.prefix(1))
                        .font(.ui(size: 10, weight: day.isToday ? .bold : .medium))
                        .foregroundStyle(day.isToday ? theme.text : theme.secondaryText)
                }
                .frame(maxWidth: .infinity)
                .help("\(day.weekday) \(day.number): \(done)/\(total)")
            }
        }
        .animation(Motion.Spring.smooth.animation, value: model.rows.map(\.checked))
    }
}

/// A round check, filled with the habit's colour when done.
struct CheckCircle: View {
    let isChecked: Bool
    let color: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle().strokeBorder(isChecked ? .clear : color.opacity(0.45), lineWidth: 1.5)
                    .background(Circle().fill(isChecked ? color : .clear))
                if isChecked {
                    Image(symbol: "checkmark").font(.ui(size: 9, weight: .bold)).foregroundStyle(.white)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .frame(width: 20, height: 20)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .animation(Motion.Spring.pop.animation, value: isChecked)
    }
}

// MARK: Stats

private struct StatsTab: View {
    let model: HabitsBoard
    @Environment(\.themeTokens) private var theme

    var body: some View {
        InspectorColumnLayout {
            if model.rows.isEmpty {
                InspectorEmpty("No habit yet", systemImage: "flame")
            } else {
                let rates = model.rows.map { model.rate($0) }
                InspectorTileGrid(columns: 2) {
                    InspectorFigure("\(Int((rates.reduce(0, +) / Double(rates.count) * 100).rounded()))%", "30 days", symbol: "chart.bar")
                    InspectorFigure("\(model.rows.map(\.longestStreak).max() ?? 0)", "Best streak", symbol: "trophy")
                    InspectorFigure("\(model.checkIns(lastDays: 7))", "This week", symbol: "calendar")
                    InspectorFigure("\(model.rows.filter { $0.currentStreak > 0 }.count)", "On a streak", symbol: "flame")
                }
                InspectorGroup("Last 30 days") {
                    InspectorCard {
                        ForEach(Array(model.rows.enumerated()), id: \.element.id) { index, row in
                            ShareRow(name: row.name, share: rates[index], label: "\(Int((rates[index] * 100).rounded()))%",
                                     color: HabitsBoard.swiftUIColor(row, theme: theme)) { model.select(row) }
                        }
                    }
                }
                InspectorGroup("Streaks") {
                    InspectorCard {
                        ForEach(model.rows.sorted { $0.currentStreak > $1.currentStreak }) { row in
                            ShareRow(name: row.name, share: Double(row.currentStreak) / Double(max(1, model.rows.map(\.currentStreak).max() ?? 1)),
                                     label: "\(row.currentStreak)", color: HabitsBoard.swiftUIColor(row, theme: theme)) { model.select(row) }
                        }
                    }
                }
            }
        }
    }
}

/// A habit's name, a bar of its share and the figure, in a row of a card.
private struct ShareRow: View {
    let name: String
    let share: Double
    let label: String
    let color: Color
    let action: () -> Void

    var body: some View {
        InspectorRow(name, action: action) {
            HStack(spacing: 8) {
                ThemeCapsule().fill(color.opacity(0.15))
                    .frame(width: 60, height: 6)
                    .overlay(alignment: .leading) { ThemeCapsule().fill(color).frame(width: 60 * max(0.04, min(1, share))) }
                Text(label.uiLocalized)
                    .monospacedDigit()
                    .lineLimit(1)
                    .fixedSize()
                    .frame(width: 34, alignment: .trailing)
            }
            .animation(Motion.Spring.smooth.animation, value: share)
        }
    }
}

/// The emoji, or the first letter, on a tinted circle.
struct HabitBadge: View {
    let row: HabitsBoard.Row
    let color: Color
    var size: CGFloat = 34
    @Environment(\.themeTokens) private var theme

    var body: some View {
        Circle()
            .fill(color.opacity(0.16))
            .frame(width: size, height: size)
            .overlay {
                if let icon = row.icon {
                    ThemedEmoji(emoji: icon, size: size * 0.5)
                } else {
                    Text(row.name.first.map { String($0).uppercased() } ?? "")
                        .font(.ui(size: size * 0.42, weight: .bold))
                        .foregroundStyle(color)
                }
            }
    }
}

