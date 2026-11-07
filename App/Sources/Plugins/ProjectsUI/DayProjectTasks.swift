import PluginKitUI
import ProjectsPlugin
import SwiftUI

/// Above a daily note, as the day's tasks are: the project task notes due that day (today, the late ones too), each
/// with its project and its day; a click opens the task. Nothing is drawn when none is due.
struct DayProjectTasks: View {
    let model: ProjectsModel
    let date: String
    @Environment(\.themeTokens) private var theme
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        // Read again when the projects change, so a task moved to Done leaves.
        let _ = model.projects
        let tasks = model.tasks(dueOn: date)
        if !tasks.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Image(symbol: ProjectsUIPlugin.symbol).font(.ui(size: 12))
                    Text("Project tasks").font(.ui(size: 13))
                    Spacer()
                }
                .foregroundStyle(theme.secondaryText)
                .padding(.vertical, 4)
                ForEach(tasks) { task in
                    Button { model.open(task.path) } label: {
                        HStack(spacing: 10) {
                            Image(symbol: "doc.text").font(.ui(size: 12)).foregroundStyle(theme.secondaryText)
                            Text(task.title).font(.ui(size: 13)).foregroundStyle(theme.text).lineLimit(1)
                            Text(ProjectStore.basename(task.project))
                                .font(.ui(size: 12))
                                .foregroundStyle(theme.secondaryText)
                                .lineLimit(1)
                            Spacer(minLength: 0)
                            if let due = task.due {
                                DueLabel(due: due, overdue: due < model.service.today)
                            }
                        }
                        .padding(.vertical, 5)
                        .padding(.leading, 20)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(task.title), \(ProjectStore.basename(task.project))")
                }
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: Corners.r(12), style: .continuous)
                    .fill(Color.primary.opacity(colorScheme == .dark ? 0.06 : 0.03))
            )
            .padding(.horizontal, 28)
            .padding(.bottom, 12)
            .frame(maxWidth: 760 + 56)
            .frame(maxWidth: .infinity)
        }
    }
}
