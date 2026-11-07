import PluginKitUI
import SwiftUI
import TasksPlugin

/// The home page in the layout the settings pick, or the one its resource names (`home:activity`). Changing the
/// setting cross-fades from one layout to the next.
struct HomeView: View {
    let model: HomeModel
    let pinned: HomeLayout?
    @Environment(\.themeTokens) private var theme
    @Environment(\.pageChromeInset) private var chromeInset

    private var layout: HomeLayout { pinned ?? model.layout }

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    Group {
                        switch layout {
                        case .welcome: WelcomeLayout(model: model, width: proxy.size.width)
                        case .today: TodayLayout(model: model, width: proxy.size.width)
                        case .activity: ActivityLayout(model: model, width: proxy.size.width)
                        case .overview: OverviewLayout(model: model, width: proxy.size.width)
                        }
                    }
                    .id(layout)
                    .transition(.opacity.animation(Motion.crossfade))
                    .padding(.top, chromeInset)
                    .frame(maxWidth: .infinity)
                    // The landscape is the page's footer: across the whole page, on its bottom edge when the page
                    // is short, after the last section when it is long.
                    Spacer(minLength: 0)
                    DitherLandscape()
                        .frame(height: min(260, max(170, proxy.size.width * 0.2)))
                        .frame(maxWidth: .infinity)
                }
                .frame(minHeight: proxy.size.height, alignment: .top)
            }
            .scrollIndicators(.automatic)
            // Up under the toolbar's glass, which `chromeInset` above leaves room for: laid out below it, the page
            // would keep that room twice.
            .ignoresSafeArea(.container, edges: .top)
        }
        .background(theme.background)
        .animation(Motion.crossfade, value: layout)
        .onAppear { model.appeared() }
        .onDisappear { model.shownViews = max(0, model.shownViews - 1) }
    }
}

/// The page's side margin, the same as every other page's (`PageMetrics.edge`).
private func gutter(_ width: CGFloat) -> CGFloat {
    PageMetrics.edge
}

// MARK: - Welcome

/// A greeting, Quick Open, three actions and the notes to pick up again, in a narrow centred column.
private struct WelcomeLayout: View {
    let model: HomeModel
    let width: CGFloat
    @Environment(\.themeTokens) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HomeDateLine(date: model.now)
            HomeTitle(text: model.greeting)
                .padding(.top, 6)
            HomeSearchField(model: model)
                .padding(.top, 34)
            HStack(spacing: 16) {
                ForEach(Array(actions.enumerated()), id: \.offset) { index, action in
                    HomeActionCard(
                        symbol: action.symbol, tint: action.tint, title: action.title, detail: action.detail,
                        shortcut: action.shortcut, index: index, action: action.run
                    )
                }
            }
            .padding(.top, 22)
            if !model.digest.recent.isEmpty {
                // The label and the rows' icons line up with the title; the rows' hover reaches past them instead.
                HomeSectionHeader(title: "Recent")
                    .padding(.top, 40)
                    .padding(.horizontal, -4)
                VStack(spacing: 2) {
                    ForEach(model.digest.recent.prefix(4)) { note in
                        HomeNoteRow(note: note, model: model)
                    }
                }
                .padding(.horizontal, -14)
                .padding(.top, 10)
            }
        }
        .frame(maxWidth: 780)
        .padding(.horizontal, gutter(width))
        .padding(.top, 24)
        .padding(.bottom, 60)
    }

    private struct Action {
        let symbol: String
        let tint: Color
        let title: String
        let detail: String
        var shortcut: String?
        let run: (OpenOrigin?) -> Void
    }

    private var actions: [Action] {
        var actions: [Action] = []
        if model.hasDailyNotes {
            actions.append(Action(
                symbol: "calendar", tint: .orange, title: "Today's note", detail: "Capture the day",
                shortcut: model.shortcut(HomeModel.todayCommand), run: { model.openToday(from: $0) }
            ))
        }
        if model.canRun(HomeModel.newNoteCommand) {
            actions.append(Action(
                symbol: "plus", tint: .blue, title: "New note", detail: "Start on a blank page",
                shortcut: model.shortcut(HomeModel.newNoteInTabCommand) ?? model.shortcut(HomeModel.newNoteCommand),
                run: { _ in model.run(HomeModel.newNoteCommand) }
            ))
        }
        if model.canRun(HomeModel.mindmapCommand) {
            actions.append(Action(
                symbol: LoamSymbol.mindmap, tint: .purple, title: "Mindmap",
                detail: "Map out an idea", run: { _ in model.run(HomeModel.mindmapCommand) }
            ))
        }
        return actions
    }
}

// MARK: - Today

/// Today's note beside the tasks and what comes next; under it, the notes changed lately.
private struct TodayLayout: View {
    let model: HomeModel
    let width: CGFloat

    private var wide: Bool { width > 940 }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HomeDateLine(date: model.now, suffix: "week \(Calendar.current.component(.weekOfYear, from: model.now))")
            HomeTitle(text: "Today")
                .padding(.top, 6)
            Group {
                if wide {
                    HStack(alignment: .top, spacing: 24) {
                        leftColumn.frame(maxWidth: .infinity)
                        rightColumn.frame(width: min(max(width * 0.32, 320), 440))
                    }
                } else {
                    VStack(alignment: .leading, spacing: 24) {
                        leftColumn
                        rightColumn
                    }
                }
            }
            .padding(.top, 32)
        }
        .padding(.horizontal, gutter(width))
        .padding(.top, 20)
        .padding(.bottom, 60)
        .frame(maxWidth: 1400, alignment: .leading)
    }

    private var leftColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            if model.hasDailyNotes {
                DailyCard(model: model)
            }
            if !model.digest.recent.isEmpty {
                HomeSectionHeader(title: "Recently edited", link: "All notes") {
                    model.open(HomeModel.allNotes, from: nil)
                }
                .padding(.top, model.hasDailyNotes ? 32 : 0)
                HStack(alignment: .top, spacing: 16) {
                    ForEach(Array(recentCards.enumerated()), id: \.element.id) { index, note in
                        HomeNoteCard(note: note, model: model, index: index + 1, showsMeta: false)
                            .frame(height: 170)
                    }
                }
                .padding(.top, 12)
            }
        }
    }

    /// The notes changed lately, today's note left out (it has its card above).
    private var recentCards: [HomeDigest.Note] {
        Array(model.digest.recent.filter { $0.path != model.digest.daily?.path }.prefix(width > 700 ? 3 : 2))
    }

    @ViewBuilder private var rightColumn: some View {
        if model.hasTasks {
            VStack(spacing: 24) {
                ComingUpCard(model: model)
                TasksCard(model: model)
            }
        }
    }
}

/// Today's note: its first lines and a button to go on writing in it.
private struct DailyCard: View {
    let model: HomeModel
    @Environment(\.themeTokens) private var theme
    @State private var probe = OpenOriginProbe()

    var body: some View {
        let daily = model.digest.daily
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label("Today's note", symbol: "calendar")
                    .font(.ui(size: 15, weight: .medium))
                    .foregroundStyle(theme.secondaryText)
                    .labelStyle(TintedIconLabel(tint: .orange))
                Spacer()
                if let daily, daily.exists {
                    HomeLink(title: String(daily.path.dropLast(daily.path.hasSuffix(".md") ? 3 : 0))) {
                        model.open(daily.path, from: probe.origin)
                    }
                }
            }
            Text(daily.map { HomeDigest.title(of: $0.path) } ?? model.digest.today)
                .font(.ui(.title))
                .kerning(-0.4)
                .foregroundStyle(theme.text)
                .padding(.top, 18)
            VStack(alignment: .leading, spacing: 10) {
                if let daily, !daily.lines.isEmpty {
                    ForEach(Array(daily.lines.enumerated()), id: \.offset) { _, line in
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text("•").foregroundStyle(theme.text)
                            Text(line).foregroundStyle(theme.text).lineLimit(2)
                        }
                        .font(.ui(size: 17))
                    }
                } else {
                    Text("Nothing written yet today.")
                        .font(.ui(size: 16))
                        .foregroundStyle(theme.secondaryText)
                }
            }
            .padding(.top, 16)
            Spacer(minLength: 28)
            Button { model.openToday(from: probe.origin) } label: {
                Text(daily?.exists == true ? "Continue writing" : "Start writing")
                    .font(.ui(size: 15, weight: .semibold))
                    .foregroundStyle(theme.background)
                    .padding(.horizontal, 20)
                    .frame(height: 42)
                    .background(ThemeCapsule().fill(theme.text))
            }
            .buttonStyle(.press)
            .opensFrom(probe)
        }
        .padding(28)
        .frame(maxWidth: .infinity, minHeight: 360, alignment: .topLeading)
        .noteCard()
        .cascadeIn(index: 0)
    }
}

/// The tasks with a due date after today: the closest four, each under its day.
private struct ComingUpCard: View {
    let model: HomeModel
    @Environment(\.themeTokens) private var theme

    private static let tints: [Color] = [.blue, .orange, .green, .purple]

    var body: some View {
        let upcoming = Array(model.digest.tasks?.upcoming.prefix(4) ?? [])
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("Coming up", symbol: "calendar.badge.clock")
                    .font(.ui(size: 15, weight: .medium))
                    .foregroundStyle(theme.secondaryText)
                    .labelStyle(TintedIconLabel(tint: theme.danger))
                Spacer()
                if model.canRun("calendar.open") {
                    HomeLink(title: "Calendar") { model.run("calendar.open") }
                }
            }
            if upcoming.isEmpty {
                Text("Nothing scheduled. Add a date to a task with @tomorrow.")
                    .font(.ui(size: 14))
                    .foregroundStyle(theme.secondaryText)
            }
            ForEach(Array(upcoming.enumerated()), id: \.element.id) { index, task in
                let tint = Self.tints[index % Self.tints.count]
                HStack(alignment: .top, spacing: 14) {
                    Text(HomeTime.dueLabel(task.due ?? "", today: model.digest.today))
                        .font(.ui(size: 13))
                        .foregroundStyle(theme.secondaryText)
                        .frame(width: 70, alignment: .leading)
                        .padding(.top, 10)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(task.text).font(.ui(size: 15, weight: .semibold)).lineLimit(1)
                        Text(HomeDigest.title(of: task.path)).font(.ui(size: 13)).opacity(0.8).lineLimit(1)
                    }
                    .foregroundStyle(tint)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: Corners.r(10), style: .continuous).fill(tint.opacity(0.1)))
                    .contentShape(Rectangle())
                    .onTapGesture { model.open(task.path, from: nil) }
                }
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .noteCard()
        .cascadeIn(index: 1)
    }
}

/// What is overdue and due today, then what was checked today.
private struct TasksCard: View {
    let model: HomeModel
    @Environment(\.themeTokens) private var theme

    var body: some View {
        let tasks = model.digest.tasks ?? HomeDigest.Tasks()
        let rows = Array((tasks.overdue + tasks.today + tasks.doneToday).prefix(6))
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label("Tasks", symbol: "checkmark.circle")
                    .font(.ui(size: 15, weight: .medium))
                    .foregroundStyle(theme.secondaryText)
                    .labelStyle(TintedIconLabel(tint: .green))
                Spacer()
                HomeLink(title: "\(tasks.open) open") { model.open(HomeModel.tasksPage, from: nil) }
            }
            .padding(.bottom, 6)
            if rows.isEmpty {
                Text("Nothing due today.")
                    .font(.ui(size: 14))
                    .foregroundStyle(theme.secondaryText)
            }
            ForEach(rows) { task in
                HomeTaskRow(task: task, model: model)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .noteCard()
        .cascadeIn(index: 2)
    }
}

// MARK: - Activity

/// The past year as a heatmap, the month in four numbers, today's log and where the writing goes.
private struct ActivityLayout: View {
    let model: HomeModel
    let width: CGFloat
    @Environment(\.themeTokens) private var theme

    var body: some View {
        let digest = model.digest
        let inner = min(width, 1400) - gutter(width) * 2
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 14) {
                HomeTitle(text: "Your vault this year")
                Text("\(digest.activeDays) active days out of 365")
                    .font(.ui(size: 15))
                    .foregroundStyle(theme.secondaryText)
                    .lineLimit(1)
            }
            VStack(alignment: .trailing, spacing: 14) {
                HomeHeatmap(activity: digest.activity, now: model.now, weeks: weeks(for: inner - 64), cell: 18)
                    .frame(maxWidth: .infinity, alignment: .leading)
                HomeHeatmapLegend()
            }
            .padding(28)
            .noteCard()
            .cascadeIn(index: 0)
            .padding(.top, 28)

            stats(digest)
                .padding(.top, 20)

            HStack(alignment: .top, spacing: 40) {
                ActivityLog(model: model)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if inner > 760, !digest.folders.isEmpty {
                    FolderShares(folders: digest.folders)
                        .frame(width: min(inner * 0.36, 460))
                }
            }
            .padding(.top, 36)
        }
        .padding(.horizontal, gutter(width))
        .padding(.top, 20)
        .padding(.bottom, 60)
        .frame(maxWidth: 1400, alignment: .leading)
    }

    @ViewBuilder private func stats(_ digest: HomeDigest) -> some View {
        let tiles: [(String, String)] = [
            (digest.streak == 1 ? "1 day" : "\(digest.streak) days", "in a row, best \(digest.bestStreak)"),
            (digest.wordsThisMonth.formatted(), "words in this month's notes"),
            ("\(digest.createdThisMonth)", "notes created in \(model.now.formatted(.dateTime.month(.wide)))"),
            ("\(digest.tasks?.doneTotal ?? 0)", "tasks done"),
        ]
        let columns = width > 900 ? 4 : 2
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 16), count: columns), spacing: 16) {
            ForEach(Array(tiles.enumerated()), id: \.offset) { index, tile in
                HomeStatTile(value: tile.0, label: tile.1, index: index + 1)
            }
        }
    }

    private func weeks(for width: CGFloat) -> Int {
        max(8, min(53, Int((width - 35) / 23)))
    }
}

/// Today's and yesterday's notes created, edited and tasks checked.
private struct ActivityLog: View {
    let model: HomeModel
    @Environment(\.themeTokens) private var theme

    var body: some View {
        let log = model.digest.log
        let today = log.filter { Calendar.current.isDate($0.date, inSameDayAs: model.now) }
        let earlier = log.filter { !Calendar.current.isDate($0.date, inSameDayAs: model.now) }
        VStack(alignment: .leading, spacing: 4) {
            if log.isEmpty {
                HomeSectionHeader(title: "Today")
                Text("Nothing yet today.")
                    .font(.ui(size: 14))
                    .foregroundStyle(theme.secondaryText)
                    .padding(.horizontal, 4)
            }
            if !today.isEmpty {
                HomeSectionHeader(title: "Today")
                ForEach(today) { row($0) }
            }
            if !earlier.isEmpty {
                HomeSectionHeader(title: "Yesterday").padding(.top, today.isEmpty ? 0 : 16)
                ForEach(earlier) { row($0) }
            }
        }
    }

    private func row(_ event: HomeDigest.Event) -> some View {
        let (symbol, tint, verb): (String, Color, String) = switch event.kind {
        case .created: ("plus", .orange, "Created")
        case .edited: ("pencil", .blue, "Edited")
        case .tasksDone(let count): ("checkmark", .green, count == 1 ? "1 task done in" : "\(count) tasks done in")
        }
        return HStack(spacing: 14) {
            HomeIconTile(symbol: symbol, tint: tint, size: 32)
            Text(verb.uiLocalized).foregroundStyle(theme.text)
            Text(event.title).fontWeight(.semibold).foregroundStyle(theme.text).lineLimit(1)
            Spacer(minLength: 8)
            if event.showsTime {
                Text(HomeTime.clock(event.date)).foregroundStyle(theme.secondaryText).font(.ui(size: 14))
            }
        }
        .font(.ui(size: 16))
        .padding(.horizontal, 4)
        .frame(height: 54)
        .contentShape(Rectangle())
        .collectionHover(cornerRadius: Corners.r(10), strength: 0.04)
        .tappableRow { model.open(event.path, from: nil) }
    }
}

/// The top folders of the notes changed this month, with a bar each.
private struct FolderShares: View {
    let folders: [HomeDigest.FolderShare]
    @Environment(\.themeTokens) private var theme
    @State private var grown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let most = max(folders.map(\.count).max() ?? 1, 1)
        VStack(alignment: .leading, spacing: 4) {
            HomeSectionHeader(title: "Where you write most")
            ForEach(Array(folders.enumerated()), id: \.element.id) { index, share in
                HStack(spacing: 16) {
                    Text(share.folder.isEmpty ? "Vault root" : share.folder)
                        .font(.ui(size: 16))
                        .foregroundStyle(theme.text)
                        .lineLimit(1)
                    Spacer(minLength: 12)
                    ThemeCapsule()
                        .fill(FolderTint.color(for: share.folder))
                        .frame(width: 180 * CGFloat(share.count) / CGFloat(most) * (grown || reduceMotion ? 1 : 0.02), height: 6)
                        .animation(Motion.Spring.standard.animation.delay(Motion.stagger(index: index)), value: grown)
                }
                .padding(.horizontal, 4)
                .frame(height: 50)
            }
        }
        .onAppear { grown = true }
    }
}

// MARK: - Overview

/// The greeting and Quick Open, today in three cards, the notes to pick up again, and the rhythm of the past months.
private struct OverviewLayout: View {
    let model: HomeModel
    let width: CGFloat
    @Environment(\.themeTokens) private var theme

    var body: some View {
        let inner = min(width - gutter(width) * 2, 1220)
        VStack(alignment: .leading, spacing: 0) {
            HomeDateLine(date: model.now)
            HomeTitle(text: model.greeting)
                .padding(.top, 6)
            HomeSearchField(model: model)
                .padding(.top, 28)

            HomeSectionHeader(title: "Today")
                .padding(.top, 40)
            HStack(spacing: 16) {
                if model.hasDailyNotes { dailyCard }
                if model.hasTasks {
                    tasksCard
                    nextCard
                }
            }
            .frame(height: 140)
            .padding(.top, 12)

            if !model.digest.recent.isEmpty {
                HomeSectionHeader(title: "Pick up again", link: "All notes") { model.open(HomeModel.allNotes, from: nil) }
                    .padding(.top, 40)
                HStack(alignment: .top, spacing: 16) {
                    ForEach(Array(model.digest.recent.prefix(inner > 900 ? 4 : inner > 640 ? 3 : 2).enumerated()), id: \.element.id) { index, note in
                        HomeNoteCard(note: note, model: model, index: index + 3)
                            .frame(height: 200)
                    }
                }
                .padding(.top, 12)
            }

            HomeSectionHeader(title: "Your rhythm", link: "See activity") { model.showLayout(.activity) }
                .padding(.top, 40)
            HStack(alignment: .center, spacing: 40) {
                HomeHeatmap(
                    activity: model.digest.activity, now: model.now,
                    weeks: max(8, min(30, Int((inner * 0.62) / 22))), showsLabels: false, cell: 17
                )
                VStack(alignment: .leading, spacing: 6) {
                    Text(model.digest.streak == 1 ? "1 day" : "\(model.digest.streak) days")
                        .font(.ui(.title))
                        .kerning(-0.4)
                        .foregroundStyle(theme.text)
                    Text("in a row")
                        .font(.ui(size: 16))
                        .foregroundStyle(theme.secondaryText)
                }
                Spacer(minLength: 0)
            }
            .padding(.top, 14)
            .padding(.horizontal, 4)
        }
        .frame(maxWidth: 1220)
        .padding(.horizontal, gutter(width))
        .padding(.top, 36)
        .padding(.bottom, 60)
    }

    private var dailyCard: some View {
        let daily = model.digest.daily
        return HomeCard(padding: 22, index: 0, action: { model.openToday(from: $0) }) {
            CardText(
                label: "Today's note", symbol: "calendar", tint: .orange,
                title: daily.map { HomeDigest.title(of: $0.path) } ?? model.digest.today,
                detail: daily?.exists == true
                    ? "\(daily?.lineCount ?? 0) \(daily?.lineCount == 1 ? "line" : "lines") · continue"
                    : "Not started · start writing",
                detailTint: nil
            )
        }
    }

    private var tasksCard: some View {
        let tasks = model.digest.tasks ?? HomeDigest.Tasks()
        let due = tasks.today.count + tasks.overdue.count
        return HomeCard(padding: 22, index: 1, action: { model.open(HomeModel.tasksPage, from: $0) }) {
            CardText(
                label: "Tasks", symbol: "checkmark.circle", tint: .green,
                title: due == 0 ? "All clear" : "\(due) for today",
                detail: tasks.overdue.isEmpty ? "\(tasks.open) open in all" : "\(tasks.overdue.count) overdue",
                detailTint: tasks.overdue.isEmpty ? nil : theme.danger
            )
        }
    }

    private var nextCard: some View {
        let next = model.digest.tasks?.upcoming.first ?? model.digest.tasks?.today.first
        return HomeCard(padding: 22, index: 2, action: { origin in
            if let next { model.open(next.path, from: origin) } else { model.open(HomeModel.tasksPage, from: origin) }
        }) {
            CardText(
                label: next.map { "Coming up · \(HomeTime.dueLabel($0.due ?? "", today: model.digest.today))" } ?? "Coming up",
                symbol: "calendar.badge.clock", tint: .blue,
                title: next?.text ?? "Nothing scheduled",
                detail: next.map { HomeDigest.title(of: $0.path) } ?? "Dated tasks show here",
                detailTint: nil
            )
        }
    }
}

/// A small card's text: a tinted label, a title, one line.
private struct CardText: View {
    let label: String
    let symbol: String
    let tint: Color
    let title: String
    let detail: String
    let detailTint: Color?
    @Environment(\.themeTokens) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Label(label, symbol: symbol)
                .font(.ui(size: 14, weight: .semibold))
                .foregroundStyle(tint)
                .lineLimit(1)
            Text(title.uiLocalized)
                .font(.ui(size: 19, weight: .semibold))
                .foregroundStyle(theme.text)
                .lineLimit(1)
                .padding(.top, 14)
            Text(detail.uiLocalized)
                .font(.ui(size: 14))
                .foregroundStyle(detailTint ?? theme.secondaryText)
                .lineLimit(1)
                .padding(.top, 8)
        }
    }
}

/// A label whose icon takes `tint` and whose text keeps the label's style.
private struct TintedIconLabel: LabelStyle {
    let tint: Color

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 8) {
            configuration.icon.foregroundStyle(tint)
            configuration.title
        }
    }
}

