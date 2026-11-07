import AppKit
import Foundation
import Observation
import PluginKitUI

/// The plugin's state, shared by the commands, every calendar tab and the Calendar panel: which days have a note,
/// today, and the day of the daily note in the focused tab. Notes are created and found through the
/// `daily-notes` service only; this class decides what to open and where.
@MainActor
@Observable
final class DailyCalendar {
    /// Where a calendar tab opens a day: beside, so the calendar stays visible.
    static let tabPlacement = Placement.beside
    /// Where the Calendar panel opens a day: in the focused tab, as the Files panel does.
    static let panelPlacement = Placement.replace

    /// Days (`YYYY-MM-DD`) that have a note.
    private(set) var dates: Set<String> = [] {
        didSet { contentCache.removeAll() }
    }
    /// `YYYY-MM-DD`, as the service sees it.
    private(set) var today = ""
    /// The day of the daily note in the focused tab, nil when it shows something else.
    private(set) var activeDate: String?
    /// The day the focused tab showed before `activeDate`, nil when it was not a daily note: where the week strip's
    /// selection fades from.
    private(set) var previousDate: String?

    /// Grows whenever the notes may have changed, so the agenda reads their text again.
    private(set) var revision = 0

    @ObservationIgnored private let service: DailyNotesService
    /// What each day's note held at `cacheRevision`: the strip, the grid and the agenda ask again and again, and every
    /// ask read and parsed a file.
    @ObservationIgnored private var contentCache: [String: DayContent?] = [:]
    @ObservationIgnored private var cacheRevision = -1
    @ObservationIgnored private let workspace: @MainActor () -> (any Workspace)?
    /// The editor, which keeps a day's note off the disk until it has text. Set by the plugin.
    @ObservationIgnored var editor: @MainActor () -> (any EditorService)? = { nil }
    /// Where a task box ticked in the agenda is written. Set by the plugin.
    @ObservationIgnored var vault: VaultAccess?

    init(service: DailyNotesService, workspace: @escaping @MainActor () -> (any Workspace)?) {
        self.service = service
        self.workspace = workspace
    }

    /// Reads the days with a note and today again (the date changes at midnight).
    func refresh() {
        if let path = try? service.path(for: nil) {
            let day = Resource.file(path).name
            if day != today { today = day }
        }
        let newDates = Set((try? service.existingDates(in: nil)) ?? [])
        if newDates != dates { dates = newDates }
        revision += 1
    }

    /// The day of `resource` when it is a daily note (its path is the one the service gives that day).
    func date(of resource: Resource?) -> String? {
        guard let resource, resource.kind == .file else { return nil }
        let day = resource.name
        guard let path = try? service.path(for: day), path == resource.path else { return nil }
        return day
    }

    /// Follows the focused tab.
    func activeChanged(_ resource: Resource?) {
        let day = date(of: resource)
        if day != activeDate {
            previousDate = activeDate
            activeDate = day
        }
    }

    /// The month to show first: the focused daily note's, else today's.
    var currentMonth: Month {
        Month(activeDate ?? today) ?? Month(today) ?? Month(year: 2000, month: 1)!
    }

    /// The grid of `month` with this state's dots, today and selection.
    func grid(_ month: Month, calendar: Calendar = .current) -> CalendarMonth {
        // Read so the dots follow edits.
        _ = revision
        let filled = Set(dates.filter { $0.hasPrefix(month.string + "-") && content(of: $0) != nil })
        return CalendarMonth.make(month, calendar: calendar, dates: filled, today: today, selected: activeDate)
    }

    // MARK: Opening

    /// Opens the note of `date`. Looking at a day creates nothing: a day without a note opens as a draft, showing
    /// its template, and the editor makes the file when text is added (an empty daily note never exists). Returns
    /// its path.
    @discardableResult
    func openDay(_ date: String, placement: Placement) throws -> String {
        let path = try service.path(for: date)
        if (try? service.read(date: date)) == nil {
            editor()?.beginDraft(at: path, text: (try? service.startingText(for: date)) ?? "")
        }
        workspace()?.open(.file(path), placement: placement)
        activeChanged(.file(path))
        return path
    }

    /// The placement for a click on a date: Command-click opens the day in a new tab, a plain click keeps `base`.
    static func clickPlacement(_ base: Placement, modifiers: NSEvent.ModifierFlags = NSEvent.modifierFlags) -> Placement {
        modifiers.contains(.command) ? .newTab : base
    }

    /// Opens a calendar tab beside the focused one, or says why it cannot (the CLI has no workspace).
    func openCalendar(_ resource: Resource) -> String {
        guard let workspace = workspace() else { return "No workspace in this host." }
        workspace.open(resource, placement: .beside)
        return "Opened the calendar."
    }

    /// Today's note in the focused tab. Returns its path.
    func openToday() throws -> String {
        refresh()
        return try openDay(today, placement: .replace)
    }

    /// The nearest existing daily note before (or after) the focused one, or today when no daily note is focused.
    /// Never creates a note. Returns its path, or says there is none.
    func openAdjacent(forward: Bool) throws -> String {
        refresh()
        let reference = date(of: workspace()?.activeResource) ?? today
        let all = try service.existingDates(in: nil)
        let target = forward ? all.first { $0 > reference } : all.last { $0 < reference }
        guard let target else {
            return "No daily note \(forward ? "after" : "before") \(reference)."
        }
        return try openDay(target, placement: .replace)
    }

    // MARK: The agenda

    /// A day's note as the agenda shows it: its title (a heading that is not just the date), a few lines of plain text
    /// and its tasks.
    struct DayContent: Equatable {
        struct Task: Equatable, Identifiable {
            /// The line, from 0: the task's identity in its note.
            let id: Int
            let text: String
            let done: Bool
        }

        let title: String?
        let preview: [String]
        let tasks: [Task]
    }

    /// What the note of `date` holds; nil when the day has no note or the note is empty (or holds only its date as
    /// a title), which the agenda and the dots treat as no note.
    func content(of date: String) -> DayContent? {
        if cacheRevision != revision {
            contentCache.removeAll()
            cacheRevision = revision
        }
        if let cached = contentCache[date] { return cached }
        var content: DayContent?
        if dates.contains(date), let text = try? service.read(date: date) { content = Self.parse(text, date: date) }
        contentCache[date] = .some(content)
        return content
    }

    /// Reads a note's text for the agenda. Tables, code and images stand as one word each, inline Markdown is
    /// dropped, so the preview reads as text. Nil when nothing is left once the date title is set aside.
    static func parse(_ text: String, date: String) -> DayContent? {
        var lines = text.components(separatedBy: "\n")
        var offset = 0
        if lines.first == "---", let end = lines.dropFirst().firstIndex(of: "---") {
            offset = end + 1
            lines = Array(lines[(end + 1)...])
        }
        var title: String?
        var hasTitle = false
        var preview: [String] = []
        var tasks: [DayContent.Task] = []
        var hasContent = false
        var inFence = false
        var inTable = false
        func note(_ line: String) {
            hasContent = true
            if preview.count < 3 { preview.append(line) }
        }
        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                inTable = false
                if !inFence { note("Code") }
                inFence.toggle()
                continue
            }
            if inFence { continue }
            if trimmed.isEmpty { inTable = false; continue }
            if trimmed.hasPrefix("|") {
                if !inTable { note("Table") }
                inTable = true
                continue
            }
            inTable = false
            if let match = trimmed.firstMatch(of: /^[-*+] \[([ xX])\] ?(.*)$/) {
                hasContent = true
                tasks.append(.init(id: index + offset, text: String(match.2), done: match.1 != " "))
            } else if !hasTitle, let heading = trimmed.firstMatch(of: /^#{1,6} +(.*)$/) {
                hasTitle = true
                // The date is already the page's title.
                if heading.1.trimmingCharacters(in: .whitespaces) != date {
                    title = String(heading.1)
                    hasContent = true
                }
            } else {
                let plain = plainText(trimmed)
                if !plain.isEmpty { note(plain) }
            }
        }
        guard hasContent else { return nil }
        return DayContent(title: title, preview: preview, tasks: tasks)
    }

    /// One line without its Markdown: list, quote and heading marks, emphasis, code ticks, links and images.
    static func plainText(_ line: String) -> String {
        var text = line.replacing(/^(#{1,6} +|[-*+] +|\d+[.)] +|> ?)/, with: "")
        text = text.replacing(/!\[[^\]]*\]\([^)]*\)/, with: "")
        text = text.replacing(/\[\[(?:[^\]|]*\|)?([^\]]*)\]\]/) { String($0.1) }
        text = text.replacing(/\[([^\]]*)\]\([^)]*\)/) { String($0.1) }
        text = text.replacing(/(\*\*|__|~~|`)/, with: "")
        text = text.replacing(/\*([^*\s][^*]*)\*/) { String($0.1) }
        return text.trimmingCharacters(in: .whitespaces)
    }

    /// Ticks or unticks the task on `line` of the note of `date`, as a click on its box asks.
    func toggleTask(date: String, line: Int) throws {
        guard let vault else { return }
        let path = try service.path(for: date)
        var lines = try vault.read(path).components(separatedBy: "\n")
        guard lines.indices.contains(line) else { return }
        let current = lines[line]
        let done: Bool
        if let range = current.range(of: "[ ]") {
            lines[line] = current.replacingCharacters(in: range, with: "[x]")
            done = true
        } else if let range = current.range(of: "[x]") ?? current.range(of: "[X]") {
            lines[line] = current.replacingCharacters(in: range, with: "[ ]")
            done = false
        } else {
            return
        }
        try vault.write(path, lines.joined(separator: "\n"))
        revision += 1
        Sounds.taskChecked(done: done)
    }

    /// Adds a task to the note of `date`, creating the note from the template if needed.
    func addTask(_ text: String, date: String) throws {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        try service.append("- [ ] " + trimmed, date: date)
        dates.insert(date)
        revision += 1
    }

    /// `date` moved by `days`, as `YYYY-MM-DD`.
    static func day(_ date: String, adding days: Int, calendar: Calendar = .current) -> String {
        guard let start = DayFormat.date(date), let moved = calendar.date(byAdding: .day, value: days, to: start) else {
            return date
        }
        return DayFormat.string(from: moved)
    }
}
