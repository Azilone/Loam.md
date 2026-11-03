import PluginKitUI
import SwiftUI
import TasksPlugin

/// The card under a daily note's date, as Craft draws it: the tasks due that day in other notes, grouped under
/// their note (a collapsible row), each with its box and its date in blue. Tasks written in the daily note itself
/// are already in its text. Nothing is drawn when no task is due.
struct DayTasksHeader: View {
    let model: TaskBoard
    let date: String
    /// The daily note's own path, whose tasks the editor already shows.
    let notePath: String
    @State private var collapsed: Set<String> = []
    @Environment(\.themeTokens) private var theme

    var body: some View {
        let groups = model.dayGroups(date: date, excluding: notePath)
        if !groups.isEmpty {
            let open = groups.flatMap(\.tasks).filter { !$0.done }.count
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(groups.enumerated()), id: \.element.path) { index, group in
                    groupHeader(group, pill: index == 0 ? open : nil)
                    if !collapsed.contains(group.path) {
                        ForEach(group.tasks) { task in row(task) }
                    }
                }
            }
            .padding(.vertical, Space.s)
            .padding(.horizontal, Space.m)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: Radius.m, style: .continuous)
                    .fill(theme.fillSubtle)
            )
            .padding(.bottom, Space.m)
            .pageColumn(.reading, top: 0)
        }
    }

    private func groupHeader(_ group: TaskBoard.DayGroup, pill: Int?) -> some View {
        HStack(spacing: 8) {
            Button {
                Motion.with(Motion.Spring.smooth.animation) {
                    if collapsed.contains(group.path) { collapsed.remove(group.path) } else { collapsed.insert(group.path) }
                }
            } label: {
                HStack(spacing: 8) {
                    Image(symbol: "chevron.down")
                        .font(.ui(.caption, weight: .semibold))
                        .rotationEffect(.degrees(collapsed.contains(group.path) ? -90 : 0))
                        .frame(width: 14)
                    Image(symbol: "doc.text").font(.ui(.label))
                    Text(TaskBoard.noteTitle(group.path)).font(.ui(.body))
                }
                .foregroundStyle(theme.secondaryText)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(TaskBoard.noteTitle(group.path)), \(collapsed.contains(group.path) ? "collapsed" : "expanded")")
            Spacer()
            if let pill {
                Text(pill == 0 ? "All done" : "\(pill) todo")
                    .themeLabel(size: UIType.caption.size, weight: .medium)
                    .foregroundStyle(theme.accent)
                    .padding(.horizontal, 8)
                    .frame(height: 20)
                    .background(ThemeCapsule().fill(theme.accent.opacity(0.12)))
            }
        }
        .padding(.vertical, 4)
    }

    private func row(_ task: TaskItem) -> some View {
        HStack(spacing: 10) {
            Button { model.toggle(task) } label: {
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
            Text(TaskBoard.displayAttributed(task))
                .font(.ui(.body))
                .strikethrough(task.done, color: theme.secondaryText)
                .foregroundStyle(task.done ? theme.secondaryText : theme.text)
                .tappableRow { model.open(task) }
                .help("Open \(task.path), line \(task.line)")
            Spacer(minLength: 0)
            Text(date == model.today ? "Today" : TaskBoard.dayTitle(date))
                .themeLabel(size: UIType.label.size)
                .foregroundStyle(theme.accent)
        }
        .padding(.vertical, 5)
        .padding(.leading, 22)
    }
}
