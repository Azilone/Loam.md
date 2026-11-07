import Foundation
import Observation
import PluginKitUI
import TasksPlugin

/// The home page's layouts, picked in the plugin's settings.
enum HomeLayout: String, CaseIterable, Codable {
    /// A greeting, Quick Open, three actions and the notes to pick up again: the calm one.
    case welcome
    /// Today's note, the tasks and what comes next, and the notes changed lately.
    case today
    /// The year's activity, the month in numbers and where you write.
    case activity
    /// A bit of everything: the greeting, today in three cards, the notes to pick up, the rhythm.
    case overview

    var title: String {
        switch self {
        case .welcome: "Welcome"
        case .today: "Today"
        case .activity: "Activity"
        case .overview: "Overview"
        }
    }
}

/// The plugin's settings, in `.loam/config.json` under `home-ui`.
struct HomeSettings: Codable, Equatable {
    var layout = HomeLayout.welcome.rawValue
    /// The name the greeting uses; empty for the first name of the Mac's user.
    var name = ""

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        layout = try container.decodeIfPresent(String.self, forKey: .layout) ?? HomeLayout.welcome.rawValue
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
    }
}

/// What the home page shows and does. Worked out again (`refresh`) when notes change, a little after the last change
/// so typing in a note does not redo it on every save.
@MainActor @Observable
final class HomeModel {
    private(set) var digest = HomeDigest()
    var layout: HomeLayout = .welcome
    var settingsName = ""
    /// The time the greeting and "today" are about, refreshed with the rest.
    private(set) var now = Date()

    @ObservationIgnored private let vault: () -> VaultAccess?
    @ObservationIgnored private let dailyNotes: () -> DailyNotesService?
    @ObservationIgnored private let tasks: () -> TasksService?
    @ObservationIgnored private let workspace: () -> (any Workspace)?
    @ObservationIgnored private let commands: () -> (any CommandLauncher)?
    @ObservationIgnored private var pending: Task<Void, Never>?
    @ObservationIgnored var calendar = Calendar.current
    @ObservationIgnored var clock: () -> Date = Date.init

    init(
        vault: @escaping () -> VaultAccess?,
        dailyNotes: @escaping () -> DailyNotesService?,
        tasks: @escaping () -> TasksService?,
        workspace: @escaping () -> (any Workspace)?,
        commands: @escaping () -> (any CommandLauncher)?
    ) {
        self.vault = vault
        self.dailyNotes = dailyNotes
        self.tasks = tasks
        self.workspace = workspace
        self.commands = commands
    }

    // MARK: Data

    /// The name the greeting uses.
    var name: String {
        let set = settingsName.trimmingCharacters(in: .whitespaces)
        if !set.isEmpty { return set }
        let first = NSFullUserName().split(separator: " ").first.map(String.init) ?? ""
        return first.prefix(1).uppercased() + first.dropFirst()
    }

    var greeting: String {
        let hour = calendar.component(.hour, from: now)
        let part = switch hour {
        case 5..<12: "Good morning"
        case 12..<18: "Good afternoon"
        default: "Good evening"
        }
        return name.isEmpty ? part.uiLocalized : "\(part.uiLocalized), \(name)"
    }

    var hasDailyNotes: Bool { dailyNotes() != nil }
    var hasTasks: Bool { tasks() != nil }

    /// Works the digest out now, on the main thread (tests, and a page shown before any digest exists).
    func refresh() {
        pending?.cancel()
        pending = nil
        guard let inputs = refreshInputs() else { return }
        now = inputs.now
        digest = Self.digest(inputs)
    }

    /// Works the digest out on a background queue, then shows it: reading the vault and the month's notes took ~60 ms
    /// of the main thread, in the middle of the new tab's animation.
    func refreshInBackground() {
        pending?.cancel()
        pending = nil
        guard let inputs = refreshInputs() else { return }
        generation += 1
        let generation = generation
        let result = DigestBox()
        nonisolated(unsafe) let sent = inputs
        LaunchWork.run({ result.digest = Self.digest(sent) }, then: { [weak self] in
            guard let self, self.generation == generation, let digest = result.digest else { return }
            self.now = sent.now
            self.digest = digest
        })
    }

    @ObservationIgnored private var generation = 0

    private final class DigestBox: @unchecked Sendable {
        var digest: HomeDigest?
    }

    /// What a refresh reads: the services, taken on the main thread; the daily notes' dates, which their service
    /// works out there.
    private struct RefreshInputs {
        let vault: VaultAccess
        let tasks: TasksService?
        let now: Date
        let calendar: Calendar
        let dailyDates: [String]
        let dailyPath: String?
    }

    private func refreshInputs() -> RefreshInputs? {
        guard let vault = vault() else { return nil }
        let now = clock()
        refreshedAt = now
        isStale = false
        let daily = dailyNotes()
        return RefreshInputs(
            vault: vault, tasks: tasks(), now: now, calendar: calendar,
            dailyDates: (try? daily?.existingDates(in: nil)) ?? [], dailyPath: try? daily?.path(for: nil)
        )
    }

    nonisolated private static func digest(_ inputs: RefreshInputs) -> HomeDigest {
        let vault = inputs.vault
        let paths = (try? vault.markdownPaths()) ?? []
        let stamps = (try? vault.stamps()) ?? [:]
        let created = creationDates(under: vault.rootURL)
        var files: [String: HomeDigest.FileDates] = [:]
        for path in paths {
            guard let stamp = stamps[path] else { continue }
            files[path] = HomeDigest.FileDates(created: created[path], modified: Date(timeIntervalSince1970: stamp.modified))
        }
        var reads = 0
        return HomeDigest.make(
            now: inputs.now,
            calendar: inputs.calendar,
            files: files,
            read: { path in
                // The month's word count reads the notes changed this month: a few hundred at most.
                reads += 1
                guard reads <= readLimit else { return nil }
                return try? vault.read(path)
            },
            dailyDates: inputs.dailyDates,
            dailyPath: inputs.dailyPath,
            tasks: try? inputs.tasks?.tasks(filter: TaskFilter())
        )
    }

    /// Whether a home page is on screen. Only then do vault changes refresh the digest (it reads the month's notes);
    /// a page appearing refreshes it if notes changed meanwhile or it is a minute old.
    var shownViews = 0
    var isShown: Bool { shownViews > 0 }
    /// When the digest was last worked out, and whether notes changed since while no home page was shown.
    @ObservationIgnored private var refreshedAt: Date?
    @ObservationIgnored private var isStale = true

    /// A home page appeared (a new tab shows one): the digest is shown as it is and worked out again just after, if
    /// it may be out of date. Working it out reads the vault and the month's notes, which held every new tab back.
    func appeared() {
        shownViews += 1
        guard let refreshedAt else { return refreshInBackground() }
        if !isStale, clock().timeIntervalSince(refreshedAt) <= 60 { return }
        pending?.cancel()
        // After the page's arrival: the digest it brings redraws the page, which would cost frames of the motion.
        pending = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(450))
            guard !Task.isCancelled else { return }
            self?.refreshInBackground()
        }
    }

    /// Refreshes a little later, once: notes saved while typing come one after the other.
    func scheduleRefresh() {
        pending?.cancel()
        guard isShown else {
            pending = nil
            isStale = true
            return
        }
        pending = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            self?.refreshInBackground()
        }
    }

    nonisolated static let readLimit = 400

    /// The creation date of every note under `root`, by vault-relative path, in one walk (hidden folders skipped).
    nonisolated static func creationDates(under root: URL) -> [String: Date] {
        let keys: [URLResourceKey] = [.creationDateKey, .isRegularFileKey]
        guard let walker = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [:] }
        let base = root.standardizedFileURL.path
        var dates: [String: Date] = [:]
        for case let url as URL in walker where url.pathExtension.lowercased() == "md" {
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true,
                  let date = values.creationDate else { continue }
            let full = url.standardizedFileURL.path
            guard full.hasPrefix(base) else { continue }
            dates[String(full.dropFirst(base.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))] = date
        }
        return dates
    }

    // MARK: Actions

    func open(_ path: String, from origin: OpenOrigin?, newTab: Bool = false) {
        workspace()?.open(.file(path), placement: newTab ? .newTab : .replace, from: origin)
    }

    func open(_ resource: Resource, from origin: OpenOrigin?) {
        workspace()?.open(resource, placement: .replace, from: origin)
    }

    /// Opens today's note: through its command when there is one (it creates the note from the template), else
    /// creating it here.
    func openToday(from origin: OpenOrigin?) {
        if let commands = commands(), commands.isAvailable(Self.todayCommand) {
            commands.run(Self.todayCommand)
        } else if let daily = dailyNotes(), let path = try? daily.ensure(date: nil) {
            open(path, from: origin)
        }
    }

    func run(_ command: String) { commands()?.run(command) }
    func canRun(_ command: String) -> Bool { commands()?.isAvailable(command) ?? false }
    func shortcut(_ command: String) -> String? { commands()?.shortcut(for: command) }

    /// Checks or unchecks a task, then shows the change at once.
    func toggle(_ task: TaskItem) {
        guard let service = tasks() else { return }
        guard let toggled = try? service.toggle(path: task.path, line: task.line, expectedText: task.text) else {
            return refresh()
        }
        Sounds.taskChecked(done: toggled.done)
        refresh()
    }

    func showLayout(_ layout: HomeLayout) {
        open(.virtual("home:\(layout.rawValue)"), from: nil)
    }

    static let todayCommand = "daily.open-today"
    static let newNoteCommand = "explorer.new-note"
    /// Cmd+N: the same note in a tab of its own; only its shortcut is shown.
    static let newNoteInTabCommand = "explorer.new-note-in-tab"
    static let quickOpenCommand = "switcher.open"
    static let mindmapCommand = "mindmap.new"
    static let allNotes = Resource.virtual("notes:")
    static let tasksPage = Resource.virtual("tasks:")
}
