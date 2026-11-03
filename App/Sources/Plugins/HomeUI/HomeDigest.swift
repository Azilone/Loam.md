import Foundation
import TasksPlugin

/// Everything the home page shows, worked out from the vault in one pass: the notes changed last, today's note, the
/// tasks, and the activity of the past year. Foundation only, so it is tested without a window.
///
/// Activity is what the files say, no more: a day counts the notes created and changed that day (from the file
/// dates), the tasks checked that day (their `✅` date) and its daily note. A note changed twice the same day counts
/// once, and only its last change is known.
struct HomeDigest: Equatable {
    struct Note: Equatable, Identifiable {
        let path: String
        let title: String
        /// The folder the note is in, `""` at the vault root.
        let folder: String
        let created: Date?
        let modified: Date
        /// The first lines of the note as plain text, joined with " · ".
        let excerpt: String
        var id: String { path }
    }

    struct Daily: Equatable {
        /// `YYYY-MM-DD`.
        let date: String
        let path: String
        let exists: Bool
        /// The note's first lines as plain text, without its title.
        let lines: [String]
        /// Every non-empty line under the title.
        let lineCount: Int
    }

    struct Tasks: Equatable {
        var open = 0
        var overdue: [TaskItem] = []
        var today: [TaskItem] = []
        /// Due after today, the soonest first.
        var upcoming: [TaskItem] = []
        var doneToday: [TaskItem] = []
        var doneTotal = 0
    }

    /// One line of the activity log: a note created or changed, or tasks checked in a note.
    struct Event: Equatable, Identifiable {
        enum Kind: Equatable { case created, edited, tasksDone(Int) }
        let kind: Kind
        let path: String
        let title: String
        /// When it happened; for checked tasks only the day is known.
        let date: Date
        let showsTime: Bool
        var id: String { "\(path)|\(kind)" }
    }

    struct FolderShare: Equatable, Identifiable {
        let folder: String
        let count: Int
        var id: String { folder }
    }

    var today = ""
    /// The notes, the one changed last first.
    var recent: [Note] = []
    var daily: Daily?
    /// Nil without the tasks service.
    var tasks: Tasks?
    /// `YYYY-MM-DD` to how much happened that day, over the last year.
    var activity: [String: Int] = [:]
    /// Days in a row with something, up to today (or yesterday, while today is still empty).
    var streak = 0
    var bestStreak = 0
    /// Days with something in the last 365.
    var activeDays = 0
    /// Notes created this month (from their file dates).
    var createdThisMonth = 0
    /// Words in the notes changed this month.
    var wordsThisMonth = 0
    /// Today's and yesterday's events, the latest first.
    var log: [Event] = []
    /// Where the notes changed in the last 30 days are, by top folder, the busiest first.
    var folders: [FolderShare] = []

    /// What `make` reads about one note.
    struct FileDates: Equatable {
        let created: Date?
        let modified: Date
    }

    /// - Parameters:
    ///   - files: every note's dates, by vault-relative path.
    ///   - read: a note's text, nil when it cannot be read.
    ///   - dailyDates: the days with a daily note (`YYYY-MM-DD`); `dailyPath` today's note's path, nil without the
    ///     daily notes service.
    ///   - tasks: every task of the vault, nil without the tasks service.
    static func make(
        now: Date,
        calendar: Calendar,
        files: [String: FileDates],
        read: (String) -> String?,
        dailyDates: [String],
        dailyPath: String?,
        tasks: [TaskItem]?
    ) -> HomeDigest {
        var digest = HomeDigest()
        let today = day(now, calendar)
        digest.today = today
        let notes = files.sorted { $0.value.modified > $1.value.modified }

        // The notes changed last, with their first lines.
        digest.recent = notes.prefix(recentLimit).map { path, dates in
            let text = read(path) ?? ""
            return Note(
                path: path, title: title(of: path), folder: folder(of: path), created: dates.created,
                modified: dates.modified, excerpt: excerpt(of: text, title: title(of: path))
            )
        }

        if let dailyPath {
            let text = files[dailyPath] != nil ? read(dailyPath) : nil
            let lines = text.map { bodyLines(of: $0, title: title(of: dailyPath)) } ?? []
            digest.daily = Daily(
                date: today, path: dailyPath, exists: text != nil, lines: Array(lines.prefix(6)), lineCount: lines.count
            )
        }

        if let tasks {
            var summary = Tasks()
            for task in tasks {
                if task.done {
                    summary.doneTotal += 1
                    if task.completed == today { summary.doneToday.append(task) }
                    continue
                }
                summary.open += 1
                guard let due = task.due else { continue }
                if due < today { summary.overdue.append(task) }
                else if due == today { summary.today.append(task) }
                else { summary.upcoming.append(task) }
            }
            summary.upcoming.sort { ($0.due ?? "", $0.path, $0.line) < ($1.due ?? "", $1.path, $1.line) }
            digest.tasks = summary
        }

        // Activity per day, over the last year.
        let yearAgo = calendar.date(byAdding: .day, value: -activityDays, to: now) ?? now
        var activity: [String: Int] = [:]
        for (_, dates) in files {
            if dates.modified >= yearAgo { activity[day(dates.modified, calendar), default: 0] += 1 }
            if let created = dates.created, created >= yearAgo, day(created, calendar) != day(dates.modified, calendar) {
                activity[day(created, calendar), default: 0] += 1
            }
        }
        let firstDay = day(yearAgo, calendar)
        for task in tasks ?? [] {
            if let completed = task.completed, completed >= firstDay, completed <= today { activity[completed, default: 0] += 1 }
        }
        for date in dailyDates where date >= firstDay && date <= today { activity[date, default: 0] += 1 }
        digest.activity = activity
        digest.activeDays = activity.values.filter { $0 > 0 }.count
        (digest.streak, digest.bestStreak) = streaks(activity, now: now, calendar: calendar)

        // This month.
        let month = String(today.prefix(7))
        var words = 0
        for (path, dates) in notes where day(dates.modified, calendar).hasPrefix(month) {
            words += wordCount(read(path) ?? "")
        }
        digest.wordsThisMonth = words
        digest.createdThisMonth = files.values.filter { $0.created.map { day($0, calendar).hasPrefix(month) } ?? false }.count

        // Today's and yesterday's log.
        let yesterday = day(calendar.date(byAdding: .day, value: -1, to: now) ?? now, calendar)
        var log: [Event] = []
        for (path, dates) in notes {
            let changed = day(dates.modified, calendar)
            guard changed == today || changed == yesterday else { break }
            let createdSameDay = dates.created.map { day($0, calendar) == changed } ?? false
            log.append(Event(
                kind: createdSameDay ? .created : .edited, path: path, title: title(of: path), date: dates.modified,
                showsTime: true
            ))
        }
        var checked: [String: Int] = [:]
        for task in tasks ?? [] where task.done && (task.completed == today || task.completed == yesterday) {
            checked["\(task.completed ?? "")|\(task.path)", default: 0] += 1
        }
        for (key, count) in checked {
            let parts = key.split(separator: "|", maxSplits: 1).map(String.init)
            guard parts.count == 2, let date = date(parts[0], calendar) else { continue }
            // Late in the day, after that day's edits, which are timed.
            let evening = calendar.date(bySettingHour: 23, minute: 59, second: 0, of: date) ?? date
            log.append(Event(kind: .tasksDone(count), path: parts[1], title: title(of: parts[1]), date: evening, showsTime: false))
        }
        digest.log = log.sorted { $0.date > $1.date }.prefix(logLimit).map { $0 }

        // Where the notes changed this month are.
        let monthAgo = calendar.date(byAdding: .day, value: -30, to: now) ?? now
        var shares: [String: Int] = [:]
        for (path, dates) in files where dates.modified >= monthAgo {
            let top = path.split(separator: "/").count > 1 ? String(path.split(separator: "/")[0]) : ""
            shares[top, default: 0] += 1
        }
        digest.folders = shares
            .map { FolderShare(folder: $0.key, count: $0.value) }
            .sorted { ($0.count, $1.folder) > ($1.count, $0.folder) }
            .prefix(folderLimit).map { $0 }
        return digest
    }

    static let recentLimit = 8
    static let activityDays = 371
    static let logLimit = 6
    static let folderLimit = 4

    // MARK: Helpers

    static func day(_ date: Date, _ calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    static func date(_ day: String, _ calendar: Calendar) -> Date? {
        let parts = day.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }

    /// The current run of active days (ending today, or yesterday when today has nothing yet) and the longest one.
    static func streaks(_ activity: [String: Int], now: Date, calendar: Calendar) -> (current: Int, best: Int) {
        let active = Set(activity.filter { $0.value > 0 }.keys)
        var best = 0
        var run = 0
        var current = 0
        var cursor = calendar.date(byAdding: .day, value: -activityDays, to: now) ?? now
        while cursor <= now {
            run = active.contains(day(cursor, calendar)) ? run + 1 : 0
            best = max(best, run)
            cursor = calendar.date(byAdding: .day, value: 1, to: cursor) ?? now.addingTimeInterval(1)
        }
        var back = active.contains(day(now, calendar)) ? now : (calendar.date(byAdding: .day, value: -1, to: now) ?? now)
        while active.contains(day(back, calendar)) {
            current += 1
            back = calendar.date(byAdding: .day, value: -1, to: back) ?? back
        }
        return (current, best)
    }

    static func title(of path: String) -> String {
        let name = path.split(separator: "/").last.map(String.init) ?? path
        return name.lowercased().hasSuffix(".md") ? String(name.dropLast(3)) : name
    }

    static func folder(of path: String) -> String {
        guard let slash = path.lastIndex(of: "/") else { return "" }
        return String(path[..<slash])
    }

    /// The lines under the frontmatter and a first `# heading` repeating the title, as plain text, without empty lines.
    static func bodyLines(of text: String, title: String) -> [String] {
        var lines = text.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        if lines.first == "---", let end = lines.dropFirst().firstIndex(where: { $0 == "---" || $0 == "..." }) {
            lines.removeSubrange(0...end)
        }
        if let first = lines.firstIndex(where: { !$0.isEmpty }), lines[first].hasPrefix("# "),
           lines[first].dropFirst(2).trimmingCharacters(in: .whitespaces).caseInsensitiveCompare(title) == .orderedSame {
            lines.remove(at: first)
        }
        return lines.compactMap { line in
            let plain = plainText(line)
            return plain.isEmpty ? nil : plain
        }
    }

    /// The first lines of a note, joined with " · ", at most about 160 characters.
    static func excerpt(of text: String, title: String) -> String {
        var result = ""
        for line in bodyLines(of: text, title: title) {
            if line == title { continue }
            result += result.isEmpty ? line : " · " + line
            if result.count > 160 { break }
        }
        return result.count > 160 ? String(result.prefix(160)) + "…" : result
    }

    /// A Markdown line without its block marks (`#`, `-`, `1.`, `>`, `- [ ]`) and inline marks (`**`, `_`, `` ` ``,
    /// `[[ ]]`, link targets).
    static func plainText(_ line: String) -> String {
        var text = line
        if text.hasPrefix("```") || text.hasPrefix("|") || text == "---" { return "" }
        for prefix in ["- [ ] ", "- [x] ", "- [X] ", "* [ ] ", "* [x] "] where text.hasPrefix(prefix) {
            text = String(text.dropFirst(prefix.count))
        }
        while let first = text.first, "#>-*+".contains(first) {
            text = String(text.dropFirst()).trimmingCharacters(in: .whitespaces)
        }
        if let dot = text.firstIndex(of: "."), text[..<dot].allSatisfy(\.isNumber), !text[..<dot].isEmpty {
            text = String(text[text.index(after: dot)...]).trimmingCharacters(in: .whitespaces)
        }
        // A task's dates and priority (`✅ 2026-10-21`, `📅 2026-10-22`, `due:2026-10-22`, `⏫`) are not text.
        text = text.replacingOccurrences(of: #"\s*(✅|📅|⏳|🛫|due:)\s*\d{4}-\d{2}-\d{2}"#, with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: #"\s*(⏫|🔼|🔽|🔺|⏬)"#, with: "", options: .regularExpression)
        // `[label](target)` keeps its label; `[[note|label]]` its label, else the note.
        text = text.replacingOccurrences(of: #"\[\[([^\]|]*\|)?([^\]]*)\]\]"#, with: "$2", options: .regularExpression)
        text = text.replacingOccurrences(of: #"!?\[([^\]]*)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
        text = text.replacingOccurrences(of: #"(\*\*|__|\*|_|`|~~|==)"#, with: "", options: .regularExpression)
        return text.trimmingCharacters(in: .whitespaces)
    }

    static func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: { $0.isWhitespace }).filter { $0.contains(where: \.isLetter) }.count
    }
}
