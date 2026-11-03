import AppKit
import PluginKitUI
import SwiftUI

/// The habits page (`habits:`): the day's progress, a quiet "New habit" line, then one card per habit with its last
/// weeks, as many as the page's width holds (one to four); the last circle checks today. With no habit, suggestions
/// to start from. A click on a card selects it for the right sidebar (its history and figures); a
/// double-click also shows that sidebar.
struct HabitsBoardView: View {
    let model: HabitsBoard
    let view: ViewContext
    @State private var newName = ""
    private static let columnWidth = PageWidth.reading.maxWidth
    @FocusState private var adding: Bool
    @Environment(\.themeTokens) private var theme

    var body: some View {
        // The width offered to the page, not the page's own: the cards are as wide as their weeks, so measuring them
        // kept the page as wide as it was (wider than the window, drawn off both sides) once the window narrowed.
        GeometryReader { proxy in
            page(weeks: HabitCard.weeks(fitting: min(proxy.size.width - 2 * PageMetrics.edge, Self.columnWidth)))
        }
        .background(theme.background)
        .onChange(of: model.focusRequest) { _, _ in adding = true }
        .onAppear {
            if model.focusRequest > 0 { adding = true }
            view.setInspector(viewType: HabitsUIPlugin.viewTypeID, tabs: HabitsInspector.tabs(model))
        }
    }

    private func page(weeks: Int) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .pageColumn(.reading)
                .padding(.bottom, PageMetrics.headerGap)
            ScrollView {
                VStack(alignment: .leading, spacing: Space.s) {
                    addRow.padding(.bottom, Space.xs)
                    if let error = model.error {
                        Text(error).font(.ui(.body)).foregroundStyle(theme.danger)
                    }
                    if model.rows.isEmpty {
                        emptyState
                    }
                    let days = model.days(weeks: weeks)
                    ForEach(model.rows) { row in
                        HabitCard(model: model, row: row, days: days)
                            .transition(.opacity.combined(with: .scale(scale: Motion.Metrics.enterScale)))
                    }
                }
                .pageColumn(.reading, top: 0)
                .padding(.bottom, Space.xxl)
            }
            .softScrollEdges()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var header: some View {
        PageHeader("Habits", subtitle: model.rows.isEmpty ? nil : "\(model.doneToday)/\(model.rows.count) done today") {
            if !model.rows.isEmpty {
                ProgressRing(progress: Double(model.doneToday) / Double(model.rows.count), color: theme.accent, lineWidth: 3)
                    .frame(width: 22, height: 22)
                    .help("Done today")
            }
        }
        .animation(Motion.Spring.standard.animation, value: model.doneToday)
    }

    /// Craft's quiet line: a plus and a borderless field; Return adds the habit.
    private var addRow: some View {
        HStack(spacing: Space.s) {
            Image(symbol: "plus")
                .font(.ui(.label, weight: .semibold))
                .foregroundStyle(adding ? theme.accent : theme.secondaryText)
                .frame(width: 16, height: 16)
            TextField("New habit", text: $newName)
                .textFieldStyle(.plain)
                .font(.ui(.body))
                .focused($adding)
                .onSubmit {
                    if model.create(newName) != nil { newName = "" }
                }
        }
        .padding(.vertical, Space.xs)
    }

    /// A flame in a soft circle, a line on what a habit is, and habits to start from in a click.
    private var emptyState: some View {
        VStack(spacing: 0) {
            EmptyState("No habits yet", message: "Something small, every day. Pick one to start, or type your own above.") {
                PrintIllustration(.habit).frame(width: 96, height: 96)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 175), spacing: Space.s)], spacing: Space.s) {
                ForEach(HabitSuggestion.all) { suggestion in
                    SuggestionChip(suggestion: suggestion) { model.create(suggestion.name, icon: suggestion.icon) }
                }
            }
            .frame(maxWidth: 580)
            .padding(.top, -Space.l)
            .padding(.bottom, Space.xxxl)
        }
        .frame(maxWidth: .infinity)
    }
}

/// A habit the empty page offers to start from.
struct HabitSuggestion: Identifiable {
    var id: String { name }
    let name: String
    let icon: String

    static let all = [
        HabitSuggestion(name: String(localized: "Drink water"), icon: "💧"),
        HabitSuggestion(name: String(localized: "Read"), icon: "📚"),
        HabitSuggestion(name: String(localized: "Exercise"), icon: "🏃"),
        HabitSuggestion(name: String(localized: "Meditate"), icon: "🧘"),
        HabitSuggestion(name: String(localized: "Write in a journal"), icon: "✍️"),
        HabitSuggestion(name: String(localized: "Sleep early"), icon: "🛏️"),
    ]
}

private struct SuggestionChip: View {
    let suggestion: HabitSuggestion
    let action: () -> Void
    @State private var hovered = false
    @Environment(\.themeTokens) private var theme

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                ThemedEmoji(emoji: suggestion.icon, size: 15)
                Text(suggestion.name)
                    .font(.ui(.body, weight: .medium))
                    .foregroundStyle(theme.text)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Image(symbol: "plus")
                    .font(.ui(.caption, weight: .semibold))
                    .foregroundStyle(theme.secondaryText)
                    .opacity(hovered ? 1 : 0)
            }
            .padding(.horizontal, Space.m)
            .padding(.vertical, Space.s)
            .background {
                let shape = RoundedRectangle(cornerRadius: Radius.m, style: .continuous)
                // Paper, a hairline that takes the accent under the pointer.
                shape.fill(hovered ? theme.accent.opacity(0.06) : theme.background)
                    .overlay(shape.strokeBorder(hovered ? theme.accent.opacity(0.8) : theme.separator, lineWidth: 1))
            }
            .contentShape(RoundedRectangle(cornerRadius: Radius.m, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { over in withAnimation(Motion.hover) { hovered = over } }
        .accessibilityLabel(suggestion.name)
    }
}

/// One habit: its icon, name and streak, then its last weeks as circles, a thin rule between two weeks (today last).
private struct HabitCard: View {
    let model: HabitsBoard
    let row: HabitsBoard.Row
    /// Whole weeks, today last.
    let days: [HabitsBoard.Day]
    @State private var hovered = false
    @Environment(\.themeTokens) private var theme

    private var color: Color { HabitsBoard.swiftUIColor(row, theme: theme) }

    /// A week of circles (7 × 30 points, 6 apart), the room between two weeks, and what the badge and the name need.
    private static let weekWidth: CGFloat = 7 * 30 + 6 * 6
    private static let weekSpacing: CGFloat = 20
    private static let nameRoom: CGFloat = 14 * 2 + 34 + 12 + 160

    /// How many weeks a card `width` points wide shows: one at least, four at most.
    static func weeks(fitting width: CGFloat) -> Int {
        // A margin for fonts wider than the system's (a theme's), so the weeks never push the name off the card.
        let room = width - nameRoom - 40 + weekSpacing
        return min(4, max(1, Int(room / (weekWidth + weekSpacing))))
    }

    private var isSelected: Bool { model.selectedRow?.path == row.path }

    /// The badge, the name and the streak: a click selects the habit, a double-click also shows the sidebar.
    private var identity: some View {
        HStack(spacing: 12) {
            HabitBadge(row: row, color: color)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.name)
                    .font(.ui(.emphasis))
                    .foregroundStyle(theme.text)
                    .lineLimit(1)
                StreakLabel(streak: row.currentStreak, color: color)
            }
            Spacer(minLength: 12)
        }
        .contentShape(Rectangle())
        // A click selects at once; the second click of a double-click also shows the sidebar.
        .onTapGesture {
            if (NSApp.currentEvent?.clickCount ?? 1) >= 2 { model.inspect(row) } else { model.select(row) }
        }
        .allowsWindowActivationEvents()
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { model.select(row) }
    }

    /// The weeks as circles, a thin rule between two weeks.
    private var strip: some View {
        HStack(spacing: Self.weekSpacing / 2) {
            ForEach(Array(stride(from: 0, to: days.count, by: HabitsBoard.dayCount)), id: \.self) { start in
                if start > 0 {
                    Rectangle().fill(theme.separator.opacity(0.6)).frame(width: 1, height: 36)
                }
                HStack(spacing: 6) {
                    ForEach(days[start..<min(start + HabitsBoard.dayCount, days.count)]) { day in
                        DayDot(day: day, isChecked: row.checkedDays.contains(day.id), color: color) {
                            model.toggle(row, day: day.id)
                        }
                    }
                }
            }
        }
        .fixedSize()
    }

    var body: some View {
        // The week beside the name while both fit, under it on a narrow page (the right sidebar open on a small window).
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                identity.frame(minWidth: 150)
                strip
            }
            VStack(alignment: .leading, spacing: 12) {
                identity
                strip
            }
        }
        .padding(14)
        .background {
            let shape = RoundedRectangle(cornerRadius: Radius.l, style: .continuous)
            // Paper and a hairline, the accent's when selected or under the pointer, and a faint grain in the top right
            // corner, stronger on the selected habit.
            shape.fill(isSelected ? theme.accent.opacity(0.04) : theme.background)
                .overlay(alignment: .topTrailing) {
                    HalftoneCloud(corner: .topTrailing, step: 2.5, seed: row.name.count + 7,
                                  color: theme.accent.opacity(isSelected ? 0.3 : 0.14))
                        .frame(width: 120, height: 56)
                }
                .clipShape(shape)
        }
        .overlay {
            let shape = RoundedRectangle(cornerRadius: Radius.l, style: .continuous)
            shape.strokeBorder(isSelected || hovered ? color.opacity(isSelected ? 0.8 : 0.45) : theme.separator, lineWidth: 1)
        }
        .animation(Motion.Spring.tap.animation, value: isSelected)
        .contentShape(RoundedRectangle(cornerRadius: Radius.l, style: .continuous))
        .onHover { over in withAnimation(Motion.hover) { hovered = over } }
        .contextMenu { menu }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(row.name)
    }

    @ViewBuilder private var menu: some View {
        Button("Open Note") { model.openNote(row) }
        Menu("Color") {
            ForEach(HabitsBoard.colors, id: \.self) { name in
                Button {
                    model.setColor(row, name)
                } label: {
                    Label(name.capitalized, symbol: name == row.color ? "checkmark.circle.fill" : "circle.fill")
                }
            }
        }
        Menu("Icon") {
            ForEach(["🏃", "📚", "🧘", "💧", "🥗", "💪", "✍️", "🛏️", "🚭", "🎸"], id: \.self) { emoji in
                Button(emoji) { model.setIcon(row, emoji) }
            }
            if row.icon != nil {
                Divider()
                Button("No Icon") { model.setIcon(row, nil) }
            }
        }
        Divider()
        Button("Archive") { model.archive(row) }
    }
}

private struct StreakLabel: View {
    let streak: Int
    let color: Color
    @Environment(\.themeTokens) private var theme

    var body: some View {
        HStack(spacing: 3) {
            Image(symbol: "flame.fill").font(.ui(size: 10))
            Text("\(streak)").monospacedDigit().contentTransition(.numericText())
        }
        .font(.ui(.label, weight: .medium))
        .foregroundStyle(streak > 0 ? color : theme.secondaryText.opacity(0.7))
        .animation(Motion.Spring.pop.animation, value: streak)
        .help("\(streak)-day streak")
    }
}

/// One day of the week: its letter above a circle, filled when done. Every day has the same circle; today's is
/// ringed in the habit's colour while it is not done, the others in a quiet grey.
private struct DayDot: View {
    let day: HabitsBoard.Day
    let isChecked: Bool
    let color: Color
    let action: () -> Void
    @State private var hovered = false
    @Environment(\.themeTokens) private var theme

    private var ring: Color {
        if hovered || day.isToday { return color }
        return theme.secondaryText.opacity(0.3)
    }

    var body: some View {
        VStack(spacing: 4) {
            Text(day.weekday.prefix(1))
                .font(.ui(size: 10, weight: day.isToday ? .bold : .medium))
                .foregroundStyle(day.isToday ? theme.text : theme.secondaryText.opacity(0.8))
            Button(action: action) {
                ZStack {
                    Circle()
                        .strokeBorder(isChecked ? .clear : ring, lineWidth: day.isToday ? 2 : 1.5)
                        .background(Circle().fill(isChecked ? color : .clear))
                    if isChecked {
                        Image(symbol: "checkmark")
                            .font(.ui(size: 11, weight: .bold))
                            .foregroundStyle(.white)
                            .transition(.scale.combined(with: .opacity))
                    }
                }
                .frame(width: 24, height: 24)
                .scaleEffect(hovered ? 1.06 : 1)
                .frame(width: 30, height: 30)
                .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .onHover { over in withAnimation(Motion.hover) { hovered = over } }
            .animation(Motion.Spring.pop.animation, value: isChecked)
        }
        .frame(width: 30)
        .help("\(day.weekday) \(day.number)")
        .accessibilityLabel("\(day.weekday) \(day.number)")
        .accessibilityValue(isChecked ? "done" : "not done")
        .accessibilityAddTraits(.isButton)
    }
}

/// How much of today is done, as a ring.
struct ProgressRing: View {
    let progress: Double
    let color: Color
    var lineWidth: CGFloat = 3

    var body: some View {
        ZStack {
            Circle().stroke(color.opacity(0.18), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: max(0.001, min(1, progress)))
                .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .animation(Motion.Spring.smooth.animation, value: progress)
    }
}
