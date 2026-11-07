import PluginKitUI
import SwiftUI
import TasksPlugin

/// The task list (`tasks.list`), after Craft's Tasks page: a large title over "N open · M overdue", the Inbox / Today /
/// Upcoming / All switch and a "…" menu (project, tag, show done), a tall "New task" field, then the tasks in groups
/// (by note in All, by date in Upcoming), each on two lines: its text, then when it is due, its note and its tags. A checkbox toggles a task in its note (⌘Z toggles it back); a task checked here stays in its group,
/// struck through, until the list is opened again. Clicking the text opens the note beside the list, on its line.
struct TaskListView: View {
    let model: TaskBoard
    /// The project of a `tasks:<project>` tab; the project menu is hidden then.
    let scope: String?
    let saveFilter: (TaskBoard.Filter) -> Void
    @State private var filter: TaskBoard.Filter
    @State private var newTask = ""
    @State private var collapsed: Set<String> = []
    /// The tasks checked during this visit of the list, which stay where they were.
    @State private var checkedHere: Set<String> = []
    @FocusState private var addFocused: Bool
    @Environment(\.themeTokens) private var theme
    @Environment(\.undoManager) private var undoManager

    init(model: TaskBoard, scope: String?, initialFilter: TaskBoard.Filter, saveFilter: @escaping (TaskBoard.Filter) -> Void) {
        self.model = model
        self.scope = scope
        self.saveFilter = saveFilter
        _filter = State(initialValue: initialFilter)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .pageColumn(.reading)
                .padding(.bottom, PageMetrics.headerGap)
            let groups = model.groups(filter, scope: scope, keeping: checkedHere)
            let done = model.doneTasks(filter, scope: scope, keeping: checkedHere)
            let shown = groups + (filter.showDone && !done.isEmpty
                ? [TaskBoard.Group(id: "done", title: "Done", notePath: nil, isOverdue: false, tasks: done)] : [])
            // The field stays over the list: it keeps its focus in the page's own SwiftUI tree.
            VStack(alignment: .leading, spacing: 0) {
                addRow
                if let error = model.error {
                    Text(error).font(.ui(.body)).foregroundStyle(theme.danger).fixedSize(horizontal: false, vertical: true)
                        .padding(.top, Space.m)
                }
            }
            .pageColumn(.reading, top: 0)
            if shown.isEmpty {
                ScrollView {
                    emptyState.padding(.top, 26).pageColumn(.reading, top: 0)
                }
            } else {
                // The groups and rows are AppKit (`TaskTable`): hundreds of SwiftUI rows were slow to open.
                TaskTable(
                    groups: shown, collapsed: collapsed, today: model.today,
                    toggleGroup: { id in
                        if collapsed.contains(id) { collapsed.remove(id) } else { collapsed.insert(id) }
                    },
                    toggle: { task in toggle(task) },
                    open: { task in model.open(task) }
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(theme.background)
        .onChange(of: filter) { _, newValue in saveFilter(newValue) }
        .onChange(of: model.focusRequest) { _, _ in addFocused = true }
        .onAppear { if model.focusRequest > 0 { addFocused = true } }
    }

    // MARK: Header

    private var header: some View {
        PageHeader(scope ?? "Tasks", subtitle: summary) {
            ModeSwitch(mode: Binding(get: { filter.currentMode }, set: { filter.mode = $0 }))
            optionsMenu
        }
    }

    /// "34 open · 8 overdue", for the project and tag the list is filtered on, whatever the mode.
    private var summary: String {
        let sections = model.sections(filter, scope: scope)
        let open = sections.filter { $0.kind != .done }.reduce(0) { $0 + $1.tasks.count }
        let overdue = sections.first { $0.kind == .overdue }?.tasks.count ?? 0
        return overdue > 0 ? "\(open) open · \(overdue) overdue" : "\(open) open"
    }

    private var optionsMenu: some View {
        Menu {
            Toggle("Show Done Tasks", isOn: $filter.showDone)
            if scope == nil, !projectChoices.isEmpty {
                Picker("Project", selection: Binding(
                    get: { filter.project ?? "" },
                    set: { value in filter.project = value.isEmpty ? nil : value }
                )) {
                    Text("All Projects").tag("")
                    ForEach(projectChoices, id: \.self) { project in Text(project).tag(project) }
                }
            }
            let tags = tagChoices
            if !tags.isEmpty {
                Picker("Tag", selection: $filter.tag) {
                    Text("All Tags").tag("")
                    ForEach(tags, id: \.self) { tag in Text("#" + tag).tag(tag) }
                }
            }
        } label: {
            Image(symbol: "ellipsis")
                .font(.ui(.body, weight: .bold))
                .foregroundStyle(isFiltered ? theme.accent : theme.secondaryText)
                .frame(width: 32, height: 32)
                .background(Circle().fill(theme.fillSubtle))
                .contentShape(Circle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Filter")
    }

    private var isFiltered: Bool { filter.project != nil || !filter.tag.isEmpty || filter.showDone }

    /// The projects, plus the selected one when no task has it any more, so the picker always has its value.
    private var projectChoices: [String] {
        let projects = model.projects
        guard let selected = filter.project, !projects.contains(selected) else { return projects }
        return projects + [selected]
    }

    private var tagChoices: [String] {
        var seen = Set<String>()
        var tags = model.tasks.flatMap(\.tags).filter { seen.insert($0.lowercased()).inserted }.sorted()
        if !filter.tag.isEmpty, !tags.contains(filter.tag) { tags.append(filter.tag) }
        return tags
    }

    // MARK: Adding

    /// The "New task" field: a plus and a borderless field on a light wash; Return adds to today's note.
    private var addRow: some View {
        HStack(spacing: Space.m) {
            Image(symbol: "plus")
                .font(.ui(.emphasis, weight: .medium))
                .foregroundStyle(addFocused ? theme.accent : theme.secondaryText)
                .frame(width: 19, height: 19)
            TextField("New task", text: $newTask)
                .textFieldStyle(.plain)
                .font(.ui(.emphasis, weight: .medium))
                .focused($addFocused)
                .onSubmit { add() }
        }
        .padding(.horizontal, Space.l)
        .frame(height: 48)
        .background(
            RoundedRectangle(cornerRadius: Radius.l, style: .continuous)
                .fill(theme.codeBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Radius.l, style: .continuous)
                .strokeBorder(theme.accent.opacity(addFocused ? 0.35 : 0), lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onTapGesture { addFocused = true }
        .animation(Motion.hover, value: addFocused)
        .help("Adds the task to today's daily note")
    }

    private func add() {
        if model.quickAdd(newTask) != nil { newTask = "" }
        addFocused = true
    }

    /// Toggles a task and registers the toggle back with the window's undo manager, which then registers the redo.
    private func toggle(_ task: TaskItem) {
        let toggled = Motion.with(Motion.Spring.standard.animation) { () -> TaskItem? in
            guard let toggled = model.toggle(task) else { return nil }
            if toggled.done { checkedHere.insert(toggled.id) }
            return toggled
        }
        guard let toggled, let undoManager else { return }
        undoManager.registerUndo(withTarget: model) { _ in
            MainActor.assumeIsolated { toggle(toggled) }
        }
        undoManager.setActionName(toggled.done ? "Check Task" : "Uncheck Task")
    }

    /// A drawing, the mode's two lines and three ways to add a task, as an empty board shows its starters.
    private var emptyState: some View {
        TaskEmptyState(
            title: emptyContent.title,
            detail: emptyContent.detail,
            write: { addFocused = true },
            plan: {
                // Tomorrow's date on the line, the task's words to type after it.
                let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: Date()) ?? Date()
                // Focused first, filled after: a field filled as it takes focus selects its text, and typing would
                // replace the date.
                addFocused = true
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(60))
                    newTask = "📅 " + tomorrow.formatted(.iso8601.year().month().day()) + " "
                }
            },
            openNote: { model.openTodayNote() }
        )
    }

    private var emptyContent: (symbol: String, title: String, detail: String) {
        switch filter.currentMode {
        case .inbox: ("tray", "Inbox is empty", "Tasks without a date land here.")
        case .today: ("sun.max", "All clear for today", "Tasks due today and those in today's note show here.")
        case .upcoming: ("calendar", "Nothing planned", "Tasks with a date after today show here.")
        case .all: ("checkmark.circle", "No tasks yet", "Type /todo in any note, or add one above.")
        }
    }
}

/// Craft's capsule switch: Inbox, Today, Upcoming, All, the chosen one on a white pill that slides.
private struct ModeSwitch: View {
    @Binding var mode: TaskBoard.Mode
    @Namespace private var pill
    @Environment(\.themeTokens) private var theme
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 2) {
            ForEach(TaskBoard.Mode.allCases, id: \.self) { item in
                Button {
                    Motion.with(Motion.Spring.tap.animation) { mode = item }
                } label: {
                    Text(item.title)
                        .font(.ui(.body, weight: mode == item ? .semibold : .medium))
                        .foregroundStyle(mode == item ? theme.palette.heading.map(Color.init) ?? theme.text : theme.secondaryText)
                        .padding(.horizontal, Space.m)
                        .frame(height: 28)
                        .background {
                            if mode == item {
                                ThemeCapsule()
                                    .fill(colorScheme == .dark ? Color.white.opacity(0.14) : .white)
                                    .shadow(color: .black.opacity(0.08), radius: 1.5, y: 1)
                                    .matchedGeometryEffect(id: "pill", in: pill)
                            }
                        }
                        .contentShape(ThemeCapsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(Space.xxs)
        .background(ThemeCapsule().fill(theme.fillSubtle))
    }
}

/// The "Tasks" panel: open tasks due today or overdue, compact, and a button to the full list.
struct TasksPanelView: View {
    let model: TaskBoard
    @Environment(\.themeTokens) private var theme

    var body: some View {
        let due = model.dueTasks
        InspectorGroup("Due", accessory: due.isEmpty ? nil : "\(due.count)") {
            if due.isEmpty {
                InspectorEmpty("Nothing due today.", systemImage: "checkmark.circle")
            } else {
                InspectorCard(padding: 10) {
                    VStack(alignment: .leading, spacing: theme.spacing.small) {
                        ForEach(due) { task in
                            TaskRow(task: task, today: model.today, toggle: { model.toggle(task) }, open: { model.open(task) })
                        }
                    }
                }
            }
            if let error = model.error {
                Text(error).font(.ui(.caption)).foregroundStyle(theme.danger).fixedSize(horizontal: false, vertical: true)
            }
            Button("All tasks") { _ = model.openList() }
                .buttonStyle(.link)
                .font(.ui(.label))
                .padding(.horizontal, 2)
        }
    }
}

/// A task in the "Due" panel: a rounded checkbox (square or round, as the theme's `tasks.checkbox`), the text (click to
/// open the note on that line), then when it is due ("3 days late" in the accent). The list's rows are AppKit
/// (`TaskRowView`); a panel holds a few.
private struct TaskRow: View {
    let task: TaskItem
    let today: String
    let toggle: () -> Void
    let open: () -> Void
    @Environment(\.themeTokens) private var theme

    var body: some View {
        HStack(alignment: .top, spacing: Space.s) {
            Button { toggle() } label: {
                CheckBox(checked: task.done, size: 16)
            }
            .buttonStyle(.plain)
            .help(task.done ? "Uncheck" : "Check")
            .accessibilityLabel(task.text)
            .accessibilityValue(task.done ? "done" : "not done")

            VStack(alignment: .leading, spacing: Space.xs) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    if task.priority == .high {
                        Image(symbol: "exclamationmark.2").foregroundStyle(theme.warning).help("High priority")
                    }
                    Text(TaskBoard.displayAttributed(task))
                        .font(.ui(.body))
                        .strikethrough(task.done, color: theme.secondaryText)
                        .foregroundStyle(task.done ? theme.secondaryText : theme.text)
                        .lineLimit(2)
                        .truncationMode(.tail)
                        .tappableRow { open() }
                        .help("Open \(task.path), line \(task.line)")
                }
                .frame(minHeight: 16)
                if let due = task.due {
                    let late = !task.done && due < today
                    Text(dueText(due))
                        .themeLabel(size: UIType.caption.size, weight: late ? .semibold : .medium)
                        .foregroundStyle(late ? theme.accent : theme.marker)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, Space.xxs)
        .padding(.horizontal, Space.xs)
    }

    /// "Today", the day, or for a task not done in time how late it is.
    private func dueText(_ due: String) -> String {
        if due == today { return "Today" }
        if !task.done, due < today, let late = TaskBoard.daysBetween(due, today) {
            return late == 1 ? "Yesterday" : "\(late) days late"
        }
        return TaskBoard.dayTitle(due)
    }
}

/// The task's box, as the editor draws it: a rounded square or a circle (`tasks.checkbox`), ringed in the theme's
/// checkbox border, filled with a tick when done.
private struct CheckBox: View {
    let checked: Bool
    let size: CGFloat
    @Environment(\.themeTokens) private var theme

    var body: some View {
        Group {
            if theme.style.checkbox == .square {
                box(RoundedRectangle(cornerRadius: Corners.r(size * 0.36), style: .continuous))
            } else {
                box(Circle())
            }
        }
        .frame(width: size, height: size)
        .contentShape(Rectangle())
        .motion(.pop, value: checked)
    }

    private func box(_ shape: some InsettableShape) -> some View {
        ZStack {
            shape
                .strokeBorder(theme.palette.checkboxBorder.map(Color.init) ?? theme.secondaryText.opacity(0.6),
                              lineWidth: size > 20 ? 2 : 1.2)
                .opacity(checked ? 0 : 1)
            shape
                .fill(theme.palette.checkbox.map(Color.init) ?? theme.accent)
                .opacity(checked ? 1 : 0)
            Image(symbol: "checkmark")
                .font(.ui(size: size * 0.55, weight: .bold))
                .foregroundStyle(.white)
                .scaleEffect(checked ? 1 : 0.4)
                .opacity(checked ? 1 : 0)
        }
    }
}
