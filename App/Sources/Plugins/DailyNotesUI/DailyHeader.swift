import PluginKitUI
import SwiftUI

/// The band above a daily note, as Craft draws it: the week as a strip of days (a dot marks the days with a note,
/// the open day sits on an accent capsule, arrows turn the weeks, "Today" jumps back), then the weekday in red over
/// the date in large type. A day opens in the same tab and is created from the template if it has no note yet.
struct DailyHeader: View {
    let model: DailyCalendar
    /// `YYYY-MM-DD`, the note this header sits on.
    let date: String
    @State private var weekShift = 0
    /// The side the last week turned towards (+1 next, -1 previous), so the new days come in from that side.
    @State private var weekDirection: CGFloat = 1
    @Namespace private var capsule
    /// The day drawn as selected: the previous day first when it is in the same week, so the capsule slides from it
    /// to `date` instead of jumping.
    @State private var shown: String
    @State private var error: String?
    @Environment(\.themeTokens) private var theme

    /// The pane width from which the strip has room for "• Mon 19" labels, and for the Today button.
    static let fullLabelsWidth: CGFloat = 800
    static let todayButtonWidth: CGFloat = 420

    init(model: DailyCalendar, date: String) {
        self.model = model
        self.date = date
        let previous = model.previousDate
        _shown = State(initialValue: previous.flatMap { Self.week(of: date, shift: 0).contains($0) ? $0 : nil } ?? date)
    }

    var body: some View {
        // A dot marks a day whose note holds something; read the revision so the dots follow edits.
        let _ = model.revision
        let days = Self.week(of: date, shift: weekShift)
        let notes = Set(days.filter { model.content(of: $0) != nil })
        VStack(alignment: .leading, spacing: 0) {
            // The strip adapts to the pane in one layout pass (no flash, and cheaper than trying every form): full
            // labels when the pane is wide, stacked ones below, and no Today button in a very narrow pane.
            GeometryReader { proxy in
                strip(
                    days: days, notes: notes, compact: proxy.size.width < Self.fullLabelsWidth,
                    showsToday: proxy.size.width >= Self.todayButtonWidth
                )
                .frame(width: proxy.size.width, height: proxy.size.height)
            }
            .padding(.horizontal, Space.m)
            .frame(minWidth: 0, maxWidth: .infinity)
            .clipped()
            .frame(height: 52)
            .onAppear {
                guard shown != date else { return }
                Motion.with(Motion.Spring.standard.animation) { shown = date }
            }
            Divider()
            VStack(alignment: .leading, spacing: Space.xs) {
                Text(Self.format(date, "EEEE"))
                    .themeLabel(size: UIType.body.size, weight: .semibold)
                    .textCase(.uppercase)
                    .foregroundStyle(theme.danger)
                    .fadingOverflow()
                // Cut and faded in a narrow pane rather than broken over several lines.
                Text(Self.format(date, "MMM d, yyyy"))
                    .font(.ui(.title))
                    .tracking(-0.4)
                    .foregroundStyle(theme.text)
                    .fadingOverflow(length: 32)
                if let error { Text(error).font(.ui(.body)).foregroundStyle(theme.danger) }
            }
            // On the note's own column, so the date lines up with the text under it.
            .frame(maxWidth: theme.columnWidth, alignment: .leading)
            .padding(.horizontal, PageMetrics.edge)
            .padding(.top, Space.xl)
            .padding(.bottom, Space.m)
            .frame(maxWidth: .infinity)
            .accessibilityElement(children: .combine)
        }
        .background(theme.background)
    }

    private func strip(days: [String], notes: Set<String>, compact: Bool, showsToday: Bool) -> some View {
        HStack(spacing: compact ? 2 : 4) {
            arrow("chevron.left", label: "Previous week") { turnWeek(-1) }
            Spacer(minLength: 0)
            // A week turned is the next page: it pushes the old one out the other side, within the days' own
            // room, so the two weeks never overlap and nothing passes under the arrows.
            ZStack {
                HStack(spacing: compact ? 2 : 4) {
                    ForEach(days, id: \.self) { day in
                        DayButton(
                            day: day, hasNote: notes.contains(day), isSelected: day == shown, isCurrent: day == date,
                            isToday: day == model.today, compact: compact, capsule: capsule
                        ) { open(day) }
                    }
                }
                .id(weekShift)
                .motionTransition(.push(from: weekDirection > 0 ? .trailing : .leading))
            }
            .clipped()
            Spacer(minLength: 0)
            arrow("chevron.right", label: "Next week") { turnWeek(1) }
            if showsToday {
                TodayButton(isCurrent: model.today.isEmpty || model.today == date) { open(model.today) }
            }
        }
    }

    private func arrow(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(symbol: symbol).font(.ui(.label, weight: .semibold)).frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(theme.secondaryText)
        .accessibilityLabel(label)
    }

    private func turnWeek(_ step: Int) {
        weekDirection = CGFloat(step)
        Motion.with(Motion.Spring.smooth.animation) { weekShift += step }
    }

    private func open(_ day: String) {
        guard day != date else { return }
        do {
            try model.openDay(day, placement: DailyCalendar.clickPlacement(.replace))
            error = nil
        } catch {
            self.error = "Could not open the note of \(day): \(error)"
        }
    }

    /// The seven days, Monday to Sunday, of the week of `date` moved by `shift` weeks.
    static func week(of date: String, shift: Int) -> [String] {
        guard let start = DayFormat.date(date) else { return [date] }
        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = DayFormat.timeZone
        let monday = calendar.dateInterval(of: .weekOfYear, for: start)?.start ?? start
        return (0..<7).compactMap { calendar.date(byAdding: .day, value: shift * 7 + $0, to: monday) }
            .map { DayFormat.string(from: $0) }
    }

    static func format(_ date: String, _ pattern: String) -> String { DayFormat.string(date, pattern) }
}

/// One day of the strip: "Mon 1" with a dot in front when the day has a note, or, in the compact form, the weekday
/// over the number with the dot underneath.
private struct DayButton: View {
    let day: String
    let hasNote: Bool
    let isSelected: Bool
    /// The day of the open note, which VoiceOver announces as selected while the capsule is still moving.
    let isCurrent: Bool
    let isToday: Bool
    let compact: Bool
    /// Where the accent capsule lives, so it slides from the day it leaves to the day chosen.
    let capsule: Namespace.ID
    /// Shrinks below its usual width (down to its label) when the strip is short of room.
    var flexible = false
    let action: () -> Void
    @State private var isHovered = false
    @Environment(\.themeTokens) private var theme

    var body: some View {
        Button(action: action) {
            label
                .foregroundStyle(foreground)
                .fixedSize()
                .padding(.horizontal, compact && !flexible ? 6 : compact ? 2 : 12)
                .frame(minWidth: compact && !flexible ? 34 : nil, maxWidth: flexible ? 34 : nil, minHeight: compact ? 40 : 28)
                .background {
                    let shape = RoundedRectangle(cornerRadius: Corners.r(compact ? 10 : 14), style: .continuous)
                    if isSelected {
                        shape.fill(theme.accent).matchedGeometryEffect(id: "selected", in: capsule)
                    } else {
                        shape.fill(isHovered ? theme.fillHover : .clear)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .animation(Motion.hover, value: isHovered)
        .accessibilityLabel(DailyHeader.format(day, "EEEE, MMMM d") + (hasNote ? ", has a note" : ""))
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
    }

    @ViewBuilder private var label: some View {
        if compact {
            VStack(spacing: 1) {
                Text(DailyHeader.format(day, "EEE")).font(.ui(.caption))
                Text(DailyHeader.format(day, "d"))
                    .font(.ui(.body, weight: isSelected || isToday ? .semibold : .regular))
                Circle().fill(dotColor).frame(width: 4, height: 4).opacity(hasNote ? 1 : 0)
            }
        } else {
            HStack(spacing: 5) {
                if hasNote { Circle().fill(dotColor).frame(width: 4, height: 4) }
                Text(DailyHeader.format(day, "EEE"))
                Text(DailyHeader.format(day, "d"))
            }
            .font(.ui(.body, weight: isSelected || isToday ? .semibold : .regular))
        }
    }

    private var dotColor: Color { isSelected ? .white : theme.accent }

    private var foreground: Color {
        if isSelected { return .white }
        return hasNote || isToday ? theme.accent : theme.secondaryText
    }
}

/// The "Today" button: a soft rounded label, dimmed when today's note is the one open.
private struct TodayButton: View {
    let isCurrent: Bool
    let action: () -> Void
    @State private var isHovered = false
    @Environment(\.themeTokens) private var theme

    var body: some View {
        Button(action: action) {
            Text("Today")
                .font(.ui(.label, weight: .medium))
                .foregroundStyle(theme.accent)
                .padding(.horizontal, Space.s + 2)
                .frame(height: 26)
                .background(
                    RoundedRectangle(cornerRadius: Radius.s, style: .continuous)
                        .fill(theme.accent.opacity(isHovered && !isCurrent ? 0.18 : 0.1))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .opacity(isCurrent ? 0.4 : 1)
        .allowsHitTesting(!isCurrent)
        .onHover { isHovered = $0 }
        .animation(Motion.hover, value: isHovered)
        .help("Open today's note")
        .accessibilityLabel("Today")
    }
}
