import AppKit
import PluginKitUI
import SwiftUI
import TasksPlugin

// The pieces the four layouts are made of. Cards are the vault's note cards (`interactiveNoteCard`), so the home page
// looks like the rest of Loam; everything that arrives cascades in (`cascadeIn`) and lifts under the pointer.

/// The date over a page title, as "Tuesday 21 October".
struct HomeDateLine: View {
    let date: Date
    var suffix: String?
    @Environment(\.themeTokens) private var theme

    var body: some View {
        let text = date.formatted(.dateTime.weekday(.wide).day().month(.wide))
        Text(suffix.map { "\(text.capitalizedFirst) · \($0)" } ?? text.capitalizedFirst)
            .themeLabel(size: 15, weight: .medium)
            .foregroundStyle(theme.accent)
    }
}

/// A page title: large, bold, tight.
struct HomeTitle: View {
    let text: String
    var size: CGFloat = UIType.display.size
    @Environment(\.themeTokens) private var theme

    var body: some View {
        Text(text.uiLocalized)
            .font(.ui(size: size, weight: .semibold))
            .kerning(-size * 0.04)
            .foregroundStyle(theme.text)
            .lineLimit(1)
            .minimumScaleFactor(0.6)
    }
}

/// Looks like a search field, opens Quick Open (Cmd+O), where a note is found or created.
struct HomeSearchField: View {
    let model: HomeModel
    @Environment(\.themeTokens) private var theme
    @State private var hovered = false

    var body: some View {
        Button { model.run(HomeModel.quickOpenCommand) } label: {
            HStack(spacing: 12) {
                Image(symbol: "magnifyingglass")
                    .font(.ui(size: 16, weight: .medium))
                    .foregroundStyle(theme.secondaryText)
                Text("Open or create a note")
                    .font(.ui(size: 16))
                    .foregroundStyle(theme.secondaryText)
                Spacer(minLength: 0)
                if let shortcut = model.shortcut(HomeModel.quickOpenCommand) {
                    HomeKeyBadge(text: shortcut)
                }
            }
            .padding(.horizontal, 18)
            .frame(height: 52)
            .background {
                // A field on paper: white, a hairline that takes the accent under the pointer.
                let shape = RoundedRectangle(cornerRadius: Corners.r(10), style: .continuous)
                shape.fill(theme.background)
                    .overlay { shape.strokeBorder(hovered ? theme.accent : theme.separator, lineWidth: 1) }
            }
            .contentShape(RoundedRectangle(cornerRadius: Corners.r(14), style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .animation(Motion.hover, value: hovered)
        .accessibilityLabel("Open or create a note")
    }
}

/// A shortcut in a small rounded box (`⌘O`).
struct HomeKeyBadge: View {
    let text: String
    @Environment(\.themeTokens) private var theme

    var body: some View {
        Text(text.uiLocalized)
            .themeLabel(size: 12, weight: .medium)
            .foregroundStyle(theme.secondaryText)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: Corners.r(6), style: .continuous).fill(theme.text.opacity(0.06)))
    }
}

/// A symbol in a tinted rounded square.
struct HomeIconTile: View {
    let symbol: String
    let tint: Color
    var size: CGFloat = 36

    var body: some View {
        Image(symbol: symbol)
            .font(.ui(size: size * 0.44, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: size, height: size)
            .background(RoundedRectangle(cornerRadius: Corners.r(size * 0.28), style: .continuous).fill(tint.opacity(0.13)))
    }
}

/// A card that runs `action` when clicked, growing from where it was clicked when it opens a page.
struct HomeCard<Content: View>: View {
    var padding: CGFloat = 20
    let index: Int?
    let action: (OpenOrigin?) -> Void
    @ViewBuilder let content: () -> Content
    @State private var probe = OpenOriginProbe()

    var body: some View {
        content()
            .padding(padding)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .contentShape(Rectangle())
            .opensFrom(probe)
            .interactiveNoteCard()
            .tappableRow { action(probe.origin) }
            .cascadeIn(index: index)
    }
}

/// A quick action: tinted icon, title, and its shortcut or one line under it.
struct HomeActionCard: View {
    let symbol: String
    let tint: Color
    let title: String
    let detail: String
    var shortcut: String?
    let index: Int
    let action: (OpenOrigin?) -> Void
    @Environment(\.themeTokens) private var theme

    var body: some View {
        HomeCard(padding: 16, index: index, action: action) {
            VStack(alignment: .leading, spacing: 0) {
                // The print look draws each action rather than showing its symbol.
                PrintIllustration(symbol: symbol)
                    .frame(width: 46, height: 46)
                    .padding(.leading, -4)
                Spacer(minLength: 14)
                // A narrow card drops what does not fit whole rather than cutting words: the chevron before the
                // title, the detail before the shortcut.
                ViewThatFits(in: .horizontal) {
                    titleLine(chevron: true)
                    titleLine(chevron: false)
                }
                ViewThatFits(in: .horizontal) {
                    detailLine(detail: true, shortcut: shortcut)
                    detailLine(detail: true, shortcut: nil)
                    // Without a shortcut the detail stays, cut if it must.
                    detailLine(detail: shortcut == nil, shortcut: shortcut)
                }
                .padding(.top, 4)
            }
        }
        // Over the card's paper, in its empty top-right corner.
        .overlay(alignment: .topTrailing) {
            // A corner of the card, never more than a third of it: a narrow card keeps its icon clear.
            GeometryReader { card in
                // Each card's own cloud: its seed sets the outline, and its size varies a little too.
                let share = [0.36, 0.3, 0.4][index % 3]
                let width = min(150, card.size.width * share)
                HalftoneCloud(corner: .topTrailing, step: 2.5, seed: index * 7 + 3)
                    .frame(width: width, height: width * [0.62, 0.8, 0.5][index % 3])
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .clipShape(RoundedRectangle(cornerRadius: Corners.r(10), style: .continuous))
            .allowsHitTesting(false)
        }
        .frame(height: 136)
    }

    private func titleLine(chevron: Bool) -> some View {
        HStack(spacing: 6) {
            Text(title.uiLocalized)
                .font(.ui(size: 15, weight: .semibold))
                .kerning(-0.3)
                .foregroundStyle(theme.text)
                .lineLimit(1)
            if chevron {
                Spacer(minLength: 0)
                Image(symbol: "chevron.right")
                    .font(.ui(size: 11, weight: .semibold))
                    .foregroundStyle(theme.accent)
            }
        }
    }

    private func detailLine(detail: Bool, shortcut: String?) -> some View {
        HStack(spacing: 8) {
            if detail {
                Text(self.detail.uiLocalized)
                    .font(.ui(size: 13))
                    .foregroundStyle(theme.secondaryText)
                    .lineLimit(1)
            }
            if let shortcut {
                Spacer(minLength: 0)
                HomeKeyBadge(text: shortcut)
            }
        }
    }
}

/// A section's title, with a link on the right ("All notes").
struct HomeSectionHeader: View {
    let title: String
    var link: String?
    var action: (() -> Void)?
    @Environment(\.themeTokens) private var theme

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title.uiLocalized)
                .themeLabel(size: 15, weight: .semibold)
                .foregroundStyle(theme.secondaryText)
            Spacer(minLength: 8)
            if let link, let action {
                HomeLink(title: link, action: action)
            }
        }
        .padding(.horizontal, 4)
    }
}

/// A coloured text button, as Craft's "See all".
struct HomeLink: View {
    let title: String
    let action: () -> Void
    @Environment(\.themeTokens) private var theme
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Text(title.uiLocalized)
                .font(.ui(size: 14, weight: .medium))
                .foregroundStyle(theme.link.opacity(hovered ? 0.75 : 1))
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .animation(Motion.hover, value: hovered)
    }
}

/// A note to pick up again: an icon, its title, when it changed.
struct HomeNoteRow: View {
    let note: HomeDigest.Note
    let model: HomeModel
    @Environment(\.themeTokens) private var theme
    @State private var probe = OpenOriginProbe()

    var body: some View {
        HStack(spacing: 14) {
            Image(symbol: "doc")
                .font(.ui(size: 15))
                .foregroundStyle(theme.secondaryText)
                .frame(width: 18)
            Text(note.title)
                .font(.ui(size: 16))
                .foregroundStyle(theme.text)
                .lineLimit(1)
            Spacer(minLength: 12)
            // In sentence case even on the print look: a column of capitals beside the titles shouts over them.
            Text(HomeTime.relative(note.modified, now: model.now).capitalizedFirst)
                .font(.ui(size: 13))
                .foregroundStyle(theme.secondaryText)
        }
        .padding(.horizontal, 14)
        .frame(height: 50)
        .contentShape(Rectangle())
        .opensFrom(probe)
        .collectionHover(cornerRadius: Corners.r(10), strength: 0.045)
        .tappableRow { model.open(note.path, from: probe.origin, newTab: NSEvent.modifierFlags.contains(.command)) }
        .draggableResource(.file(note.path))
    }
}

/// A note as a small card: where it is and when it changed, its title, its first lines.
struct HomeNoteCard: View {
    let note: HomeDigest.Note
    let model: HomeModel
    let index: Int
    var showsMeta = true
    @Environment(\.themeTokens) private var theme

    var body: some View {
        HomeCard(padding: 20, index: index, action: { model.open(note.path, from: $0) }) {
            VStack(alignment: .leading, spacing: 8) {
                if showsMeta {
                    HStack(spacing: 6) {
                        Circle().fill(FolderTint.color(for: note.folder)).frame(width: 7, height: 7)
                        Text(meta)
                            .font(.ui(size: 13))
                            .foregroundStyle(theme.secondaryText)
                            .lineLimit(1)
                    }
                }
                Text(note.title)
                    .font(.ui(size: 17, weight: .semibold))
                    .foregroundStyle(theme.text)
                    .lineLimit(2)
                if !note.excerpt.isEmpty {
                    Text(note.excerpt)
                        .font(.ui(size: 13))
                        .foregroundStyle(theme.secondaryText)
                        .lineSpacing(3)
                        .lineLimit(4)
                }
            }
        }
        .draggableResource(.file(note.path))
    }

    private var meta: String {
        let place = note.folder.isEmpty ? "Notes" : (note.folder.split(separator: "/").last.map(String.init) ?? note.folder)
        return "\(place) · \(HomeTime.relative(note.modified, now: model.now))"
    }
}

/// A big number with a line under it.
struct HomeStatTile: View {
    let value: String
    let label: String
    let index: Int
    @Environment(\.themeTokens) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(value)
                .font(.ui(size: 30, weight: .bold))
                .kerning(-0.4)
                .foregroundStyle(theme.text)
                .contentTransition(.numericText())
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(label.uiLocalized)
                .font(.ui(size: 14))
                .foregroundStyle(theme.secondaryText)
                .lineLimit(1)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .noteCard()
        .cascadeIn(index: index)
    }
}

/// A task: its round box, which checks it, its text, and when it is due.
struct HomeTaskRow: View {
    let task: TaskItem
    let model: HomeModel
    @Environment(\.themeTokens) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var probe = OpenOriginProbe()

    var body: some View {
        HStack(spacing: 14) {
            Button { model.toggle(task) } label: {
                ZStack {
                    Circle().strokeBorder(task.done ? Color.clear : theme.secondaryText.opacity(0.55), lineWidth: 1.5)
                    if task.done {
                        Circle().fill(Color.green)
                            .transition(.scale.combined(with: .opacity))
                    }
                }
                .frame(width: 22, height: 22)
                .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .animation(reduceMotion ? Motion.fade : Motion.Spring.pop.animation, value: task.done)
            .accessibilityLabel(task.done ? "Uncheck" : "Check")
            Text(task.text)
                .font(.ui(size: 16))
                .foregroundStyle(task.done ? theme.secondaryText : theme.text)
                .strikethrough(task.done)
                .lineLimit(1)
            Spacer(minLength: 8)
            if let due = task.due, !task.done {
                Text(HomeTime.dueLabel(due, today: model.digest.today))
                    .font(.ui(size: 13))
                    .foregroundStyle(due < model.digest.today ? theme.danger : theme.secondaryText)
            }
        }
        .frame(height: 44)
        .contentShape(Rectangle())
        .opensFrom(probe)
        .onTapGesture { model.open(task.path, from: probe.origin) }
    }
}

/// The days of the past weeks as small squares, darker for busier days, as GitHub draws contributions. Weeks are
/// columns (Monday at the top), the oldest on the left; today has a ring.
struct HomeHeatmap: View {
    let activity: [String: Int]
    let now: Date
    let weeks: Int
    var showsLabels = true
    var cell: CGFloat = 18
    var gap: CGFloat = 5
    @Environment(\.themeTokens) private var theme

    private var calendar: Calendar {
        var calendar = Calendar.current
        calendar.firstWeekday = 2
        return calendar
    }

    /// The Monday of the oldest column.
    private var start: Date {
        let thisWeek = calendar.dateInterval(of: .weekOfYear, for: now)?.start ?? now
        return calendar.date(byAdding: .weekOfYear, value: -(weeks - 1), to: thisWeek) ?? thisWeek
    }

    var body: some View {
        let start = start
        let today = HomeDigest.day(now, calendar)
        let max = Swift.max(activity.values.max() ?? 1, 1)
        VStack(alignment: .leading, spacing: 8) {
            if showsLabels { monthLabels(start: start) }
            HStack(alignment: .top, spacing: gap) {
                if showsLabels { weekdayLabels }
                ForEach(0..<weeks, id: \.self) { week in
                    VStack(spacing: gap) {
                        ForEach(0..<7, id: \.self) { weekday in
                            square(week: week, weekday: weekday, start: start, today: today, max: max)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder private func square(week: Int, weekday: Int, start: Date, today: String, max: Int) -> some View {
        let date = calendar.date(byAdding: .day, value: week * 7 + weekday, to: start) ?? start
        let day = HomeDigest.day(date, calendar)
        let shape = RoundedRectangle(cornerRadius: Corners.r(cell * 0.24), style: .continuous)
        if day > today {
            Color.clear.frame(width: cell, height: cell)
        } else {
            shape
                .fill(color(count: activity[day] ?? 0, max: max))
                .frame(width: cell, height: cell)
                .overlay {
                    if day == today {
                        shape.inset(by: -2.5).strokeBorder(theme.text.opacity(0.85), lineWidth: 1.5)
                    }
                }
                .help("\(date.formatted(date: .abbreviated, time: .omitted)): \(activity[day] ?? 0)")
        }
    }

    func color(count: Int, max: Int) -> Color {
        guard count > 0 else { return theme.text.opacity(0.06) }
        return theme.accent.opacity(Self.levels[HomeHeatmap.level(count: count, max: max) - 1])
    }

    static let levels: [Double] = [0.28, 0.48, 0.72, 0.95]

    /// 1...4: how busy a day was against the busiest one.
    static func level(count: Int, max: Int) -> Int {
        guard count > 0 else { return 0 }
        let ratio = Double(count) / Double(Swift.max(max, 1))
        return ratio > 0.75 ? 4 : ratio > 0.45 ? 3 : ratio > 0.2 ? 2 : 1
    }

    /// Monday, Wednesday and Friday, beside their rows.
    private var weekdayLabels: some View {
        let symbols = calendar.shortWeekdaySymbols
        return VStack(alignment: .leading, spacing: gap) {
            ForEach(0..<7, id: \.self) { row in
                Text(row % 2 == 0 && row < 6 ? symbols[(row + 1) % 7].lowercased() : "")
                    .font(.ui(size: 11))
                    .foregroundStyle(theme.secondaryText)
                    .frame(width: 30, height: cell, alignment: .leading)
            }
        }
        .accessibilityHidden(true)
    }

    private func monthLabels(start: Date) -> some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: 30 + gap)
            ZStack(alignment: .leading) {
                ForEach(0..<weeks, id: \.self) { week in
                    let monday = calendar.date(byAdding: .weekOfYear, value: week, to: start) ?? start
                    let previous = calendar.date(byAdding: .weekOfYear, value: week - 1, to: start) ?? start
                    if week == 0 ? calendar.component(.day, from: monday) <= 7 : calendar.component(.month, from: monday) != calendar.component(.month, from: previous) {
                        Text(monday.formatted(.dateTime.month(.abbreviated)))
                            .font(.ui(size: 12))
                            .foregroundStyle(theme.secondaryText)
                            .fixedSize()
                            .offset(x: CGFloat(week) * (cell + gap))
                    }
                }
            }
        }
        .frame(height: 14, alignment: .leading)
    }
}

/// "Less ▢▢▢▢ More" under a heatmap.
struct HomeHeatmapLegend: View {
    @Environment(\.themeTokens) private var theme

    var body: some View {
        HStack(spacing: 5) {
            Text("Less").font(.ui(size: 12)).foregroundStyle(theme.secondaryText)
            RoundedRectangle(cornerRadius: Corners.r(4)).fill(theme.text.opacity(0.06)).frame(width: 13, height: 13)
            ForEach(HomeHeatmap.levels, id: \.self) { level in
                RoundedRectangle(cornerRadius: Corners.r(4)).fill(theme.accent.opacity(level)).frame(width: 13, height: 13)
            }
            Text("More").font(.ui(size: 12)).foregroundStyle(theme.secondaryText)
        }
    }
}

/// Dates as the home page says them.
enum HomeTime {
    /// "5 min ago", "yesterday", "Monday", "12 Oct".
    static func relative(_ date: Date, now: Date, calendar: Calendar = .current) -> String {
        let seconds = now.timeIntervalSince(date)
        if seconds < 60 { return "just now" }
        if seconds < 3600 { return "\(Int(seconds / 60)) min ago" }
        if calendar.isDate(date, inSameDayAs: now) { return "\(Int(seconds / 3600)) h ago" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            return "yesterday"
        }
        if seconds < 6 * 86_400 { return date.formatted(.dateTime.weekday(.wide)) }
        return date.formatted(.dateTime.day().month(.abbreviated))
    }

    /// "today", "tomorrow", "yesterday", "Thursday", "12 Oct" for a `YYYY-MM-DD` due date.
    static func dueLabel(_ due: String, today: String, calendar: Calendar = .current) -> String {
        guard let date = HomeDigest.date(due, calendar), let now = HomeDigest.date(today, calendar) else { return due }
        let days = calendar.dateComponents([.day], from: now, to: date).day ?? 0
        switch days {
        case 0: return "today"
        case 1: return "tomorrow"
        case -1: return "yesterday"
        case 2..<7: return date.formatted(.dateTime.weekday(.wide))
        default: return date.formatted(.dateTime.day().month(.abbreviated))
        }
    }

    static func clock(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }
}

extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
