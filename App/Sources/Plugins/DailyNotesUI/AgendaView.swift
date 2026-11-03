import PluginKitUI
import SwiftUI

/// The calendar tab (`daily.calendar`), as Craft's Calendar page: the days one under the other from today, each with
/// a date card on the left and, on the right, its daily note (title and first lines, a click opens it), the note's
/// tasks with their boxes, then "Add Task" and "Create Daily Note". Today sits on a raised white card. Earlier days
/// come with "Show Previous Days", later ones with "Show More Days". In a narrow pane the date goes above the day's
/// content, and lines too long for their card fade out at its edge.
struct AgendaView: View {
    let model: DailyCalendar
    /// Where a clicked note opens.
    let placement: Placement
    @State private var pastDays = 0
    @State private var futureDays = 14
    @State private var error: String?
    @State private var width: CGFloat = 0
    @Environment(\.themeTokens) private var theme

    /// Below this width, a day's date card goes above its content rather than beside it.
    static let narrowWidth: CGFloat = 420

    var body: some View {
        let today = model.today
        let narrow = width > 0 && width < Self.narrowWidth
        // Read so the rows read their note again after any change.
        let revision = model.revision
        VStack(alignment: .leading, spacing: 0) {
            PageHeader("Calendar", subtitle: Self.dayTitle(today))
                .pageColumn(.reading)
                .padding(.bottom, PageMetrics.headerGap)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: Space.s) {
                        QuietButton(title: "Show Previous Days", symbol: "clock.arrow.circlepath") {
                            Motion.with(Motion.Spring.smooth.animation) { pastDays += 7 }
                        }
                        .padding(.leading, 16)
                        if let error {
                            Text(error).font(.ui(.body)).foregroundStyle(theme.danger)
                        }
                        ForEach(-pastDays...futureDays, id: \.self) { offset in
                            let date = DailyCalendar.day(today, adding: offset)
                            DayRow(
                                model: model, date: date, offset: offset, placement: placement, revision: revision,
                                narrow: narrow
                            ) {
                                error = $0
                            }
                            .id(date)
                        }
                        QuietButton(title: "Show More Days", symbol: "arrow.down") {
                            Motion.with(Motion.Spring.smooth.animation) { futureDays += 14 }
                        }
                        .padding(.leading, 16)
                    }
                    .pageColumn(.reading, top: 0)
                    .padding(.bottom, Space.xxl)
                }
                .softScrollEdges()
                .onAppear { proxy.scrollTo(today, anchor: .top) }
            }
        }
        .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .motion(Motion.Spring.smooth, value: narrow)
        .background(theme.background)
    }

    /// "Saturday, October 31".
    private static func dayTitle(_ date: String) -> String? {
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.dateFormat = "yyyy-MM-dd"
        guard let day = parser.date(from: date) else { return nil }
        return day.formatted(.dateTime.weekday(.wide).month(.wide).day())
    }
}

/// One day: the date card and what the day holds.
private struct DayRow: View {
    let model: DailyCalendar
    let date: String
    /// Days from today.
    let offset: Int
    let placement: Placement
    let revision: Int
    /// The date card above the content instead of beside it.
    let narrow: Bool
    let fail: (String?) -> Void
    @State private var newTask = ""
    @State private var isAdding = false
    /// The pointer is over the day: its actions show, as Craft's do.
    @State private var isHovered = false
    @FocusState private var addFocused: Bool
    @Environment(\.themeTokens) private var theme
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let content = model.content(of: date)
        let isToday = offset == 0
        let layout = narrow
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
            : AnyLayout(HStackLayout(alignment: .top, spacing: 14))
        layout {
            DateCard(date: date, offset: offset, inline: narrow, hovered: isHovered)
                .onTapGesture { run { try model.openDay(date, placement: DailyCalendar.clickPlacement(placement)) } }
                .help("Open the note of \(date)")
            VStack(alignment: .leading, spacing: 6) {
                if let content {
                    if content.title != nil || !content.preview.isEmpty { noteCard(content) }
                    ForEach(content.tasks) { task in taskRow(task) }
                }
                if isAdding {
                    addField
                }
                // Today always offers them; another day when the pointer is over it. They keep their room, so the
                // list does not move as the pointer runs down it.
                let showsActions = isToday || isHovered || isAdding
                if isToday || content != nil || isAdding || !narrow {
                    HStack(spacing: 8) {
                        if !isAdding {
                            QuietButton(title: "Add Task", symbol: "checkmark.square") {
                                isAdding = true
                                addFocused = true
                            }
                        }
                        if content == nil {
                            QuietButton(title: "Create Daily Note", symbol: "calendar.badge.plus") {
                                run { try model.openDay(date, placement: DailyCalendar.clickPlacement(placement)) }
                            }
                        }
                    }
                    .opacity(showsActions ? 1 : 0)
                    .allowsHitTesting(showsActions)
                    .animation(Motion.hover, value: showsActions)
                }
            }
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            .padding(.top, narrow ? 0 : 2)
        }
        .padding(isToday ? (narrow ? 12 : 16) : 0)
        .padding(.leading, isToday ? 0 : (narrow ? 12 : 16))
        .background {
            if isToday {
                RoundedRectangle(cornerRadius: Radius.l, style: .continuous)
                    .fill(colorScheme == .dark ? Color.white.opacity(0.06) : .white)
                    .shadow(color: .black.opacity(0.07), radius: 8, y: 2)
                    .overlay(
                        RoundedRectangle(cornerRadius: Radius.l, style: .continuous)
                            .strokeBorder(theme.separator, lineWidth: 0.5)
                    )
            }
        }
        .padding(.vertical, isToday ? 10 : 0)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .contextMenu {
            Button("Open Daily Note") { run { try model.openDay(date, placement: DailyCalendar.clickPlacement(placement)) } }
            Button("Add Task") { isAdding = true; addFocused = true }
        }
    }

    private func noteCard(_ content: DailyCalendar.DayContent) -> some View {
        Button { run { try model.openDay(date, placement: DailyCalendar.clickPlacement(placement)) } } label: {
            // Each line on one line, whole: one that runs past the card fades out at its edge (Craft's).
            VStack(alignment: .leading, spacing: 3) {
                if let title = content.title {
                    HStack(spacing: 6) {
                        Image(symbol: "doc.text").font(.ui(.caption)).foregroundStyle(theme.secondaryText)
                        Text(title.uiLocalized).font(.ui(.emphasis)).foregroundStyle(theme.text)
                    }
                    .fixedSize()
                }
                ForEach(Array(content.preview.enumerated()), id: \.offset) { _, line in
                    Text(line).font(.ui(.body)).foregroundStyle(theme.text.opacity(0.8))
                        .fixedSize()
                }
            }
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            .clipped()
            .fadingEdges(.trailing, length: 28)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: Radius.m, style: .continuous).fill(theme.fillSubtle))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Open the note of \(date)")
    }

    private func taskRow(_ task: DailyCalendar.DayContent.Task) -> some View {
        HStack(spacing: 9) {
            Button {
                Motion.with(Motion.Spring.standard.animation) { run { try model.toggleTask(date: date, line: task.id) } }
            } label: {
                ZStack {
                    RoundedRectangle(cornerRadius: Corners.r(4), style: .continuous)
                        .strokeBorder(theme.secondaryText.opacity(0.7), lineWidth: 1.2)
                        .opacity(task.done ? 0 : 1)
                    RoundedRectangle(cornerRadius: Corners.r(4), style: .continuous).fill(theme.accent).opacity(task.done ? 1 : 0)
                    Image(symbol: "checkmark").font(.ui(size: 9, weight: .bold)).foregroundStyle(.white)
                        .opacity(task.done ? 1 : 0)
                }
                .frame(width: 15, height: 15)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(task.text)
            .accessibilityValue(task.done ? "done" : "not done")
            Text(task.text)
                .font(.ui(.body))
                .strikethrough(task.done, color: theme.secondaryText)
                .foregroundStyle(task.done ? theme.secondaryText : theme.text)
        }
        .padding(.leading, 4)
        .padding(.vertical, 2)
    }

    private var addField: some View {
        HStack(spacing: 9) {
            RoundedRectangle(cornerRadius: Corners.r(4), style: .continuous)
                .strokeBorder(theme.secondaryText.opacity(0.5), lineWidth: 1.2)
                .frame(width: 15, height: 15)
            TextField("New task", text: $newTask)
                .textFieldStyle(.plain)
                .font(.ui(.body))
                .focused($addFocused)
                .onSubmit {
                    let text = newTask
                    run { try model.addTask(text, date: date) }
                    newTask = ""
                    addFocused = true
                }
                .onExitCommand { isAdding = false; newTask = "" }
                .onChange(of: addFocused) { _, focused in
                    if !focused, newTask.isEmpty { isAdding = false }
                }
        }
        .padding(.leading, 4)
        .padding(.vertical, 2)
    }

    private func run(_ action: () throws -> Void) {
        do {
            try action()
            fail(nil)
        } catch {
            fail("Could not change the note of \(date): \(error)")
        }
    }

    private func run(_ action: () throws -> String) {
        run { _ = try action() }
    }
}

/// Craft's grey date card: "Oct 19", then Today / Tomorrow / Yesterday, then the weekday.
private struct DateCard: View {
    let date: String
    let offset: Int
    /// On one line across the row ("Oct 19 Today … Monday"), for a narrow pane.
    var inline = false
    /// The pointer is over its day: on the print look, a grain of the accent rises from its corner.
    var hovered = false
    @Environment(\.themeTokens) private var theme

    var body: some View {
        let layout = inline
            ? AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 6))
            : AnyLayout(VStackLayout(alignment: .leading, spacing: 1))
        layout {
            Text(Self.format(date, "MMM d")).font(.ui(.body, weight: .semibold)).foregroundStyle(theme.text)
            if let relative {
                Text(relative)
                    .font(.ui(.body, weight: .semibold))
                    .foregroundStyle(offset == 0 ? theme.accent : theme.secondaryText)
            }
            if inline { Spacer(minLength: 4) }
            Text(Self.format(date, "EEEE")).themeLabel(size: UIType.caption.size).foregroundStyle(theme.secondaryText)
        }
        .lineLimit(1)
        .modifier(FadeWhenInline(inline: inline))
        .padding(inline ? 8 : 10)
        .padding(.horizontal, inline ? 2 : 0)
        .frame(width: inline ? nil : 92, alignment: .leading)
        .frame(maxWidth: inline ? .infinity : nil, minHeight: inline ? nil : 64, alignment: .topLeading)
        .background {
            let shape = RoundedRectangle(cornerRadius: Radius.m, style: .continuous)
            ZStack {
                shape.fill(offset == 0 ? theme.fillHover : theme.fillSubtle)
                // Today keeps a faint grain at rest; any day gathers one on hover, as the cards do.
                HalftoneCloud(corner: .bottomTrailing, step: 2, seed: 23 + offset, color: theme.accent.opacity(0.35),
                              progress: hovered ? 1 : offset == 0 ? 0.45 : 0)
                    .clipShape(shape)
                    .animation(Motion.hover, value: hovered)
            }
            .overlay {
                shape.strokeBorder(theme.accent.opacity(hovered ? 0.35 : 0), lineWidth: 1).animation(Motion.hover, value: hovered)
            }
        }
    }

    private var relative: String? {
        switch offset {
        case 0: "Today"
        case 1: "Tomorrow"
        case -1: "Yesterday"
        default: nil
        }
    }

    static func format(_ date: String, _ pattern: String) -> String { DayFormat.localized(date, pattern) }
}

/// On one line, the date card's words keep their full width and fade out at its edge when the pane is too narrow.
private struct FadeWhenInline: ViewModifier {
    let inline: Bool

    func body(content: Content) -> some View {
        if inline { content.fadingOverflow(length: 16) } else { content }
    }
}

/// A light button with an icon, as Craft's "Add Task" and "Show Previous Days".
private struct QuietButton: View {
    let title: String
    let symbol: String
    let action: () -> Void
    @State private var isHovered = false
    @Environment(\.themeTokens) private var theme

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(symbol: symbol).font(.ui(.caption))
                Text(title.uiLocalized).font(.ui(.label, weight: .medium))
            }
            .fixedSize()
            .foregroundStyle(isHovered ? theme.accent : theme.secondaryText)
            .padding(.horizontal, 9)
            .frame(height: 26)
            .background(
                RoundedRectangle(cornerRadius: Radius.m, style: .continuous)
                    .fill(isHovered ? theme.fillHover : theme.fillSubtle)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .animation(Motion.hover, value: isHovered)
    }
}
