import PluginKitUI
import ProjectsPlugin
import SwiftUI

/// Under a project note's fields, laid out as one more of them: "Progress", the bar and "3/7" (its task notes that are
/// Done, of all), and how many are late.
struct ProgressBand: View {
    let model: ProjectsModel
    let path: String
    @Environment(\.themeTokens) private var theme

    private var fontSize: CGFloat { (theme.bodySize * 0.94).rounded() }

    var body: some View {
        let tasks = model.project(path)?.tasks ?? TaskCount()
        let item = model.project(path)
        row(symbol: "chart.bar.xaxis", name: "Progress") {
            if model.needsBoard(path) {
                Button { model.addBoard(to: path) } label: {
                    Label("Add task board", symbol: "rectangle.split.3x1")
                        .font(.ui(size: 12, weight: .medium))
                        .foregroundStyle(theme.text.opacity(0.85))
                        .padding(.horizontal, 10)
                        .frame(height: 24)
                        .background(ThemeCapsule().fill(theme.fillSubtle))
                }
                .buttonStyle(.plain)
                .help("Adds the Kanban of this project's tasks at the end of the note")
            } else if tasks.total == 0 {
                Text("Add tasks in the board below")
                    .foregroundStyle(theme.secondaryText.opacity(0.8))
            } else {
                ProgressMeter(tasks: tasks, width: 120)
                if tasks.late > 0 {
                    Text(tasks.late == 1 ? "1 late" : "\(tasks.late) late")
                        .font(.ui(size: 12))
                        .foregroundStyle(theme.danger)
                }
                if item?.overdue ?? false, let due = item?.due {
                    Text("Overdue since \(DueLabel.title(due))")
                        .font(.ui(size: 12))
                        .foregroundStyle(theme.danger)
                }
            }
        }
        .font(.ui(size: fontSize))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(tasks.total == 0 ? "Progress: no tasks" : "Progress: \(tasks.done) of \(tasks.total) tasks done")
    }

    /// One line laid out as a field: its icon and name on the left, its value on the right.
    private func row(symbol: String, name: String, @ViewBuilder value: () -> some View) -> some View {
        let value = value()
        return GeometryReader { geometry in
            HStack(spacing: 0) {
                HStack(spacing: 10) {
                    Image(symbol: symbol)
                        .font(.ui(size: fontSize * 0.85))
                        .frame(width: 18)
                    Text(name).lineLimit(1)
                }
                .foregroundStyle(theme.secondaryText)
                .padding(.horizontal, 6)
                .frame(width: geometry.size.width * 0.42, alignment: .leading)
                HStack(spacing: 10) { value }
                    .padding(.horizontal, 6)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            }
        }
        .frame(height: 32)
    }
}
