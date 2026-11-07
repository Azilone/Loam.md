import Foundation
import PluginKit

public enum HabitError: Error, Equatable {
    case invalidName(String)
    case invalidDate(String)
    /// `create` refuses a habit whose note exists.
    case alreadyExists(String)
}

public struct HabitStatus: Codable, Equatable {
    public let name: String
    public let checkIns: Int
    public let currentStreak: Int
    public let longestStreak: Int
    public let lastCheckIn: String?
}

/// A habit is a plain note, `Habits/<name>.md` (the folder is a setting), with one task-list line per day it was
/// done:
///
///     # Meditate
///
///     ## Check-ins
///     - [x] 2026-10-18
///
/// Everything else in the note belongs to the user.
///
/// `create` adds a `created` property in YAML frontmatter.
public final class HabitTracker: HabitsService {
    private let vault: VaultAccess
    private let folderLock = NSLock()
    private var currentFolder: String
    private let clock: () -> String

    public init(vault: VaultAccess, folder: String = "Habits", today: @escaping () -> String = HabitTracker.systemToday) {
        self.vault = vault
        currentFolder = folder
        self.clock = today
    }

    /// The folder of habit notes, from the vault's root; the plugin changes it when its settings change. Read from
    /// any thread.
    public var folder: String {
        get {
            folderLock.lock()
            defer { folderLock.unlock() }
            return currentFolder
        }
        set {
            folderLock.lock()
            defer { folderLock.unlock() }
            currentFolder = newValue
        }
    }

    public static func systemToday() -> String {
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        return String(format: "%04d-%02d-%02d", parts.year!, parts.month!, parts.day!)
    }

    /// Records a check-in (today by default). Checking the same day twice changes nothing.
    @discardableResult
    public func check(name: String, date: String?) throws -> HabitStatus {
        let day = date ?? clock()
        guard Day(day) != nil else { throw HabitError.invalidDate(day) }
        let path = try path(for: name)
        var contents = vault.exists(path) ? try vault.read(path) : "# \(name)\n"
        if !checkIns(in: contents).contains(day) {
            if !contents.hasSuffix("\n") { contents += "\n" }
            if !contents.contains("\n## Check-ins") { contents += "\n## Check-ins\n" }
            contents += "- [x] \(day)\n"
            try vault.write(path, contents)
        }
        return status(name: name, contents: contents)
    }

    /// Removes the check-in lines of a day (today by default). Unchecking a day that is not checked changes nothing.
    public func uncheck(_ name: String, date: String?) throws {
        let day = date ?? clock()
        guard Day(day) != nil else { throw HabitError.invalidDate(day) }
        let path = try path(for: name)
        let contents = try vault.read(path)
        let lines = contents.components(separatedBy: "\n")
        let kept = lines.filter { checkIn(in: $0) != day }
        if kept.count != lines.count { try vault.write(path, kept.joined(separator: "\n")) }
    }

    public func status(name: String) throws -> HabitStatus {
        let path = try path(for: name)
        return status(name: name, contents: try vault.read(path))
    }

    public func all() throws -> [HabitStatus] {
        try habitPaths().map { name, path in status(name: name, contents: try vault.read(path)) }
    }

    // MARK: HabitsService

    public var today: String { clock() }

    public func habits() throws -> [Habit] {
        try habitPaths().map { name, path in habit(name: name, path: path, contents: try vault.read(path)) }
    }

    public func check(_ name: String, date: String?) throws {
        try check(name: name, date: date)
    }

    public func create(_ name: String) throws -> String {
        let path = try path(for: name)
        guard !vault.exists(path) else { throw HabitError.alreadyExists(name) }
        let title = name.trimmingCharacters(in: .whitespaces)
        try vault.write(path, "---\ncreated: \(clock())\n---\n# \(title)\n\n## Check-ins\n")
        return path
    }

    // MARK: Reading notes

    /// The name and path of every note directly in the folder, sorted by path.
    private func habitPaths() throws -> [(name: String, path: String)] {
        let folder = folder
        return try vault.markdownPaths()
            .filter { VaultPath.directory(of: $0) == folder }
            .map { path in
                let file = String(path.split(separator: "/").last!)
                return (String(file.dropLast(3)), path)
            }
    }

    private func habit(name: String, path: String, contents: String) -> Habit {
        let status = status(name: name, contents: contents)
        let days = Set(checkIns(in: contents))
        return Habit(
            name: name,
            path: path,
            checkedDays: days,
            currentStreak: status.currentStreak,
            longestStreak: status.longestStreak,
            created: created(in: contents) ?? days.min(),
            color: property("color", in: contents),
            icon: property("icon", in: contents),
            archived: property("archived", in: contents)?.lowercased() == "true"
        )
    }

    /// The `created` frontmatter property, when it is a valid day.
    private func created(in contents: String) -> String? {
        property("created", in: contents).flatMap { Day($0) != nil ? $0 : nil }
    }

    /// A one-line top-level frontmatter property, unquoted; nil when missing or empty.
    private func property(_ key: String, in contents: String) -> String? {
        guard let yaml = MarkdownFrontmatter.split(contents).yaml else { return nil }
        for line in yaml.components(separatedBy: "\n") where line.hasPrefix(key + ":") {
            let value = line.dropFirst(key.count + 1)
                .trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "\"'")))
            return value.isEmpty ? nil : value
        }
        return nil
    }

    public func setProperty(_ name: String, key: String, value: String?) throws {
        let path = try path(for: name)
        let contents = try vault.read(path)
        let edited = FrontmatterEditor.setting(key, to: value.map { $0 == "true" ? .bool(true) : .string($0) }, in: contents)
        if edited != contents { try vault.write(path, edited) }
    }

    private func path(for name: String) throws -> String {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.contains("/"), !trimmed.hasPrefix(".") else {
            throw HabitError.invalidName(name)
        }
        return "\(folder)/\(trimmed).md"
    }

    private func checkIns(in contents: String) -> [String] {
        contents.components(separatedBy: "\n").compactMap(checkIn(in:))
    }

    /// The day of a check-in line, `- [x] YYYY-MM-DD`, else nil.
    private func checkIn(in line: String) -> String? {
        guard line.hasPrefix("- ["), line.count >= 6,
              line[line.index(line.startIndex, offsetBy: 3)].lowercased() == "x",
              line[line.index(line.startIndex, offsetBy: 4)] == "]"
        else { return nil }
        let day = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
        return Day(day) != nil ? day : nil
    }

    private func status(name: String, contents: String) -> HabitStatus {
        let days = Set(checkIns(in: contents)).compactMap { Day($0) }.sorted { $0.number < $1.number }
        var longest = 0
        var run = 0
        var previous: Int?
        for day in days {
            run = previous == day.number - 1 ? run + 1 : 1
            longest = max(longest, run)
            previous = day.number
        }
        let todayNumber = Day(clock())?.number
        let current: Int
        if let last = days.last, let todayNumber, last.number >= todayNumber - 1 { current = run } else { current = 0 }
        return HabitStatus(
            name: name,
            checkIns: days.count,
            currentStreak: current,
            longestStreak: longest,
            lastCheckIn: days.last?.text
        )
    }

    /// A calendar day, `YYYY-MM-DD`, as a number that grows by one per day.
    private struct Day {
        let text: String
        let number: Int

        init?(_ text: String) {
            guard text.range(of: "^\\d{4}-\\d{2}-\\d{2}$", options: .regularExpression) != nil else { return nil }
            let parts = text.split(separator: "-").compactMap { Int($0) }
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: "UTC")!
            var components = DateComponents()
            components.year = parts[0]
            components.month = parts[1]
            components.day = parts[2]
            guard let date = calendar.date(from: components) else { return nil }
            let check = calendar.dateComponents([.year, .month, .day], from: date)
            guard check.year == parts[0], check.month == parts[1], check.day == parts[2] else { return nil }
            self.text = text
            self.number = Int(date.timeIntervalSince1970 / 86_400)
        }
    }
}

/// The plugin's settings, in `.loam/config.json` under `plugins.habit-tracker.settings` and on its page in Settings.
public struct HabitTrackerSettings: Codable, Equatable, Sendable {
    /// The folder of habit notes, from the vault's root.
    public var folder = "Habits"

    public init(folder: String = "Habits") {
        self.folder = folder
    }

    /// `folder` without slashes or spaces around it; the default when that leaves nothing, so the notes at the
    /// vault's root never count as habits.
    public var resolvedFolder: String {
        let trimmed = folder.trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "/")))
        return trimmed.isEmpty ? HabitTrackerSettings().folder : trimmed
    }
}
