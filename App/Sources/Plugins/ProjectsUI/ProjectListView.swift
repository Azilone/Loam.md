import AppKit
import PluginKitUI
import ProjectsPlugin
import SwiftUI

/// The `projects` view of a collection: its notes grouped by status (the view's "Group by"), each a row with where its
/// tasks stand, its progress (Done task notes of all), its late tasks and its due date, red once passed. "+" beside a
/// status names a new project there. Done is folded until opened.
struct ProjectListView: View {
    let collection: CollectionViewModel
    let projects: ProjectsModel
    @State private var collapsed: Set<String>?
    /// The status whose group shows the name field of a project being created.
    @State private var naming: String?
    @State private var newName = ""
    @FocusState private var nameFocused: Bool
    @Environment(\.themeTokens) private var theme

    private var statusRef: PropertyRef { collection.view?.groupBy?.property ?? PropertyRef("status") }
    private var options: [String] { collection.property(statusRef).options }

    private var groups: [CollectionGroup] {
        collection.groups ?? [CollectionGroup(value: nil, entries: collection.entries)]
    }

    var body: some View {
        let groups = groups
        ScrollView {
            if collection.entries.isEmpty && collection.searchText.isEmpty {
                empty
            } else {
                if !projects.looseNotes.isEmpty {
                    TidyBanner(count: projects.looseNotes.count) { projects.tidy() }
                        .padding(.top, 6)
                }
                LazyVStack(alignment: .leading, spacing: 18) {
                    ForEach(groups, id: \.key) { group in
                        section(group)
                    }
                }
                .padding(.top, 6)
                .padding(.bottom, 32)
                .collectionAnimation(value: groups.map { $0.entries.map(\.path) })
            }
        }
        .softScrollEdges()
        .onAppear {
            if collapsed == nil {
                collapsed = Set(groups.compactMap(Self.name).filter { ProjectListView.isDone($0) })
            }
        }
    }

    private var empty: some View {
        VStack(spacing: 0) {
            EmptyState(
                "Start your first project",
                symbol: ProjectsUIPlugin.symbol,
                message: "A project is a note with a status, a due date and its tasks.",
                actionTitle: naming == nil ? "New project" : nil,
                action: naming == nil ? { newProject(status: "Active") } : nil
            )
            if naming != nil {
                nameField(status: naming ?? "Active").frame(width: 320)
            }
        }
        .padding(.top, Space.xxl)
    }

    @ViewBuilder
    private func section(_ group: CollectionGroup) -> some View {
        let name = Self.name(group)
        let key = name ?? ""
        let isCollapsed = collapsed?.contains(key) ?? false
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 0) {
                Button {
                    Motion.with(Motion.Spring.standard.animation) {
                        var set = collapsed ?? []
                        if set.contains(key) { set.remove(key) } else { set.insert(key) }
                        collapsed = set
                    }
                } label: {
                    HStack(spacing: 8) {
                        Image(symbol: "chevron.down")
                            .font(.ui(size: 11, weight: .semibold))
                            .rotationEffect(.degrees(isCollapsed ? -90 : 0))
                            .foregroundStyle(theme.secondaryText)
                            .frame(width: 12)
                        if let name {
                            OptionPill(name, options: options, size: 12)
                        } else {
                            Text("No status").themeLabel(size: UIType.label.size, weight: .medium).foregroundStyle(theme.secondaryText)
                        }
                        Text("\(group.entries.count)")
                            .themeLabel(size: UIType.label.size)
                            .foregroundStyle(theme.secondaryText)
                        Spacer()
                    }
                    .contentShape(Rectangle())
                    .padding(.vertical, 4)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(name ?? "No status"), \(group.entries.count) projects, \(isCollapsed ? "collapsed" : "expanded")")
                if let name {
                    Button { newProject(status: name) } label: {
                        Image(symbol: "plus")
                            .font(.ui(size: 12, weight: .medium))
                            .foregroundStyle(theme.secondaryText)
                            .frame(width: 26, height: 24)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(HoverRowStyle())
                    .help("New \(name) project")
                    .accessibilityLabel("New \(name) project")
                }
            }

            if !isCollapsed && (!group.entries.isEmpty || (name != nil && naming == name)) {
                VStack(spacing: 0) {
                    ForEach(Array(group.entries.enumerated()), id: \.element.path) { index, entry in
                        if index > 0 { Divider().overlay(theme.separator.opacity(0.4)).padding(.leading, 40) }
                        ProjectRow(
                            entry: entry, item: projects.project(entry.path), options: options, statusRef: statusRef,
                            collection: collection, projects: projects
                        )
                        .collectionTransition(.opacity.combined(with: .offset(y: -4)))
                    }
                    if let name, naming == name {
                        nameField(status: name)
                    } else if name != nil {
                        newRow(status: name)
                    }
                }
                .padding(4)
                .background(RoundedRectangle(cornerRadius: Corners.r(12), style: .continuous).fill(theme.background))
                .overlay(RoundedRectangle(cornerRadius: Corners.r(12), style: .continuous).strokeBorder(theme.separator.opacity(0.5)))
            }
        }
    }

    private func newRow(status: String?) -> some View {
        Button { newProject(status: status) } label: {
            HStack(spacing: 10) {
                Image(symbol: "plus").font(.ui(size: 12, weight: .medium)).frame(width: 22)
                Text("New project").font(.ui(size: 13))
                Spacer()
            }
            .foregroundStyle(theme.secondaryText)
            .padding(.horizontal, 10)
            .frame(height: 34)
            .contentShape(Rectangle())
        }
        .buttonStyle(HoverRowStyle())
    }

    /// The row where a new project's name is typed: Return creates it with that status and opens it, Escape cancels.
    private func nameField(status: String) -> some View {
        HStack(spacing: 10) {
            Image(symbol: "doc.text")
                .font(.ui(size: 13))
                .foregroundStyle(theme.secondaryText)
                .frame(width: 22)
            TextField("Project name", text: $newName)
                .textFieldStyle(.plain)
                .font(.ui(size: 13, weight: .medium))
                .focused($nameFocused)
                .onSubmit { create(status: status) }
                .onExitCommand { naming = nil }
                .onAppear { DispatchQueue.main.async { nameFocused = true } }
        }
        .padding(.horizontal, 10)
        .frame(height: 44)
        .background(RoundedRectangle(cornerRadius: Corners.r(8), style: .continuous).strokeBorder(theme.accent.opacity(0.6)))
    }

    /// Opens the name field in the group of `status` (Active without one).
    private func newProject(status: String?) {
        let status = status ?? "Active"
        newName = ""
        Motion.with(Motion.Spring.standard.animation) {
            collapsed?.remove(status)
            naming = status
        }
    }

    private func create(status: String) {
        let title = newName.trimmingCharacters(in: .whitespaces)
        naming = nil
        guard !title.isEmpty else { return }
        projects.newProject(title: title, status: status)
    }

    static func name(_ group: CollectionGroup) -> String? {
        switch group.value {
        case .string(let text)?: text
        case .number(let number)?: String(number)
        case .bool(let flag)?: flag ? "true" : "false"
        default: nil
        }
    }

    static func isDone(_ status: String) -> Bool {
        ["done", "fait", "terminé", "completed", "finished", "archived"].contains(status.lowercased())
    }
}

/// One project: its title, its progress, its due date. A click opens it; the menu changes its status.
private struct ProjectRow: View {
    let entry: NoteRecord
    let item: ProjectItem?
    let options: [String]
    let statusRef: PropertyRef
    let collection: CollectionViewModel
    let projects: ProjectsModel
    @State private var probe = OpenOriginProbe()
    @Environment(\.themeTokens) private var theme

    var body: some View {
        Button {
            let placement: Placement = NSEvent.modifierFlags.contains(.command) ? .newTab : .replace
            collection.open(entry.path, placement: placement, from: probe.origin)
        } label: {
            HStack(alignment: .center, spacing: 10) {
                Image(symbol: "doc.text")
                    .font(.ui(size: 13))
                    .foregroundStyle(theme.secondaryText)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 3) {
                    Text(entry.title)
                        .font(.ui(size: 13, weight: .medium))
                        .foregroundStyle(theme.text)
                        .lineLimit(1)
                    TaskStateLine(tasks: item?.tasks ?? TaskCount())
                }
                Spacer(minLength: 12)
                if let late = item?.tasks.late, late > 0 {
                    Text(late == 1 ? "1 late" : "\(late) late")
                        .font(.ui(size: 11, weight: .medium))
                        .foregroundStyle(theme.danger)
                        .padding(.horizontal, 7)
                        .frame(height: 18)
                        .background(ThemeCapsule().fill(theme.danger.opacity(0.1)))
                        .help("Open tasks past their due date")
                }
                if let due = item?.due {
                    DueLabel(due: due, overdue: item?.overdue ?? false)
                }
                ProgressMeter(tasks: item?.tasks ?? TaskCount(), width: 72)
                    .frame(width: 112, alignment: .trailing)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(minHeight: 52)
            .contentShape(Rectangle())
        }
        .buttonStyle(HoverRowStyle())
        .opensFrom(probe)
        .contextMenu {
            Button("Open") { collection.open(entry.path, placement: .replace) }

            Button("Open in New Tab") { collection.open(entry.path, placement: .newTab) }
            if !options.isEmpty {
                Divider()
                Menu("Status") {
                    ForEach(options, id: \.self) { option in
                        Button(option) { collection.set(statusRef, to: .string(option), on: entry.path) }
                    }
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibility)
    }

    private var accessibility: String {
        var parts = [entry.title]
        if let tasks = item?.tasks, tasks.total > 0 { parts.append("\(tasks.done) of \(tasks.total) tasks done") }
        if let tasks = item?.tasks { parts.append(TaskStateLine.text(tasks)) }
        if let due = item?.due { parts.append((item?.overdue ?? false ? "overdue since " : "due ") + DueLabel.title(due)) }
        return parts.joined(separator: ", ")
    }
}

/// Under a project's name, where its tasks stand: "1 in progress · 3 to do", "All 4 tasks done" or "No tasks yet".
struct TaskStateLine: View {
    let tasks: TaskCount
    @Environment(\.themeTokens) private var theme

    var body: some View {
        Text(Self.text(tasks))
            .font(.ui(size: 12))
            .foregroundStyle(theme.secondaryText)
            .lineLimit(1)
    }

    static func text(_ tasks: TaskCount) -> String {
        guard tasks.total > 0 else { return "No tasks yet" }
        guard tasks.done < tasks.total else { return tasks.total == 1 ? "Its task is done" : "All \(tasks.total) tasks done" }
        let toDo = tasks.total - tasks.done - tasks.inProgress
        var parts: [String] = []
        if tasks.inProgress > 0 { parts.append("\(tasks.inProgress) in progress") }
        if toDo > 0 { parts.append("\(toDo) to do") }
        return parts.joined(separator: " · ")
    }
}

/// Above the projects when notes sit directly in the projects folder (an older layout, a note dropped there): one
/// click gives each its own folder, so it becomes a project with its tasks beside it. Asks first.
private struct TidyBanner: View {
    let count: Int
    let tidy: () -> Void
    @State private var asking = false
    @Environment(\.themeTokens) private var theme

    var body: some View {
        HStack(spacing: 10) {
            Image(symbol: "folder.badge.gearshape").foregroundStyle(theme.secondaryText)
            Text(count == 1 ? "1 note sits loose in Projects." : "\(count) notes sit loose in Projects.")
                .font(.ui(size: 13))
                .foregroundStyle(theme.text)
            Text("Each project keeps its note and its tasks in one folder.")
                .font(.ui(size: 12))
                .foregroundStyle(theme.secondaryText)
                .lineLimit(1)
            Spacer(minLength: 8)
            Button("Tidy up") { asking = true }
                .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .frame(height: 40)
        .background(RoundedRectangle(cornerRadius: Corners.r(10), style: .continuous).fill(theme.fillSubtle))
        .confirmationDialog("Move each loose note into a folder of its own?", isPresented: $asking) {
            Button("Tidy up") { tidy() }
        } message: {
            Text("Projects/Name.md becomes Projects/Name/Name.md. Links and open tabs follow.")
        }
    }
}

/// A row that lights up under the pointer (`hoverFill`) and a little more while pressed.
struct HoverRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        HoverRow(configuration: configuration)
    }

    private struct HoverRow: View {
        let configuration: Configuration
        @Environment(\.themeTokens) private var theme

        var body: some View {
            configuration.label
                .background(
                    RoundedRectangle(cornerRadius: Radius.s, style: .continuous)
                        .fill(configuration.isPressed ? theme.fillHover : .clear)
                )
                .hoverFill(radius: Radius.s)
        }
    }
}

/// A thin bar and "3/7"; "No tasks" in grey when there are none.
struct ProgressMeter: View {
    let tasks: TaskCount
    var width: CGFloat = 72
    @Environment(\.themeTokens) private var theme

    var body: some View {
        HStack(spacing: 8) {
            if tasks.total == 0 {
                Text("No tasks").font(.ui(size: 12)).foregroundStyle(theme.secondaryText.opacity(0.8))
            } else {
                let fraction = Double(tasks.done) / Double(tasks.total)
                ZStack(alignment: .leading) {
                    ThemeCapsule().fill(theme.fillHover)
                    ThemeCapsule()
                        .fill(fraction >= 1 ? Color.green.opacity(0.85) : theme.accent)
                        .frame(width: max(5, width * fraction))
                }
                .frame(width: width, height: 5)
                .motion(Motion.Spring.standard, value: fraction)
                Text("\(tasks.done)/\(tasks.total)")
                    .font(.ui(size: 12).monospacedDigit())
                    .foregroundStyle(theme.secondaryText)
            }
        }
    }
}

/// A due date as Craft writes days: "Today", "Tomorrow", "Nov 19"; red once passed.
struct DueLabel: View {
    let due: String
    let overdue: Bool
    @Environment(\.themeTokens) private var theme

    var body: some View {
        HStack(spacing: 4) {
            Image(symbol: overdue ? "exclamationmark.circle" : "calendar").font(.ui(size: 11))
            Text(Self.title(due)).font(.ui(size: 12))
        }
        .foregroundStyle(overdue ? theme.danger : theme.secondaryText)
        .help(overdue ? "Overdue: due \(due)" : "Due \(due)")
    }

    static func title(_ day: String) -> String {
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.dateFormat = "yyyy-MM-dd"
        guard let date = parser.date(from: day) else { return day }
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "Today" }
        if calendar.isDateInTomorrow(date) { return "Tomorrow" }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate(
            calendar.component(.year, from: date) == calendar.component(.year, from: Date()) ? "MMM d" : "MMM d, yyyy"
        )
        return formatter.string(from: date)
    }
}

private extension CollectionGroup {
    /// The group's identity in the list: its value as text, empty for the entries without one.
    var key: String { ProjectListView.name(self) ?? "" }
}
