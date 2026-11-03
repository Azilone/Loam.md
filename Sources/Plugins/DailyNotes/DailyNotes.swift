import Foundation
import PluginKit

public enum DailyNotesError: Error, Equatable {
    case invalidDate(String)
    case invalidMonth(String)
}

/// Where daily notes live and what a new one contains.
public struct DailyNotesLayout {
    public var folder: String
    /// Vault path of an optional template. `{{date}}` is replaced by the day (`YYYY-MM-DD`).
    public var templatePath: String

    public init(folder: String = "Daily", templatePath: String = ".loam/templates/daily.md") {
        self.folder = folder
        self.templatePath = templatePath
    }
}

/// The plugin's settings, in `.loam/config.json` under `plugins.daily-notes.settings` and on its page in Settings.
public struct DailyNotesSettings: Codable, Equatable, Sendable {
    /// The folder of daily notes, from the vault's root; empty for the root itself.
    public var folder = "Daily"
    /// A note whose text starts each new daily note; empty for none.
    public var template = ".loam/templates/daily.md"

    public init(folder: String = "Daily", template: String = ".loam/templates/daily.md") {
        self.folder = folder
        self.template = template
    }

    /// The layout these settings give: the folder without slashes or spaces around it.
    public var layout: DailyNotesLayout {
        let trim = CharacterSet.whitespaces.union(CharacterSet(charactersIn: "/"))
        return DailyNotesLayout(
            folder: folder.trimmingCharacters(in: trim),
            templatePath: template.trimmingCharacters(in: .whitespaces)
        )
    }
}

/// Creates, reads and appends to the note of a given day (`Daily/YYYY-MM-DD.md`).
public final class DailyNotes: DailyNotesService {
    private let vault: VaultAccess
    private let layoutLock = NSLock()
    private var currentLayout: DailyNotesLayout
    private let now: () -> Date
    private let calendar: Calendar

    /// Where notes go and what a new one contains; the plugin changes it when its settings change. Read from any
    /// thread.
    public var layout: DailyNotesLayout {
        get {
            layoutLock.lock()
            defer { layoutLock.unlock() }
            return currentLayout
        }
        set {
            layoutLock.lock()
            defer { layoutLock.unlock() }
            currentLayout = newValue
        }
    }

    public init(
        vault: VaultAccess,
        layout: DailyNotesLayout = DailyNotesLayout(),
        calendar: Calendar = .current,
        now: @escaping () -> Date = Date.init
    ) {
        self.vault = vault
        currentLayout = layout
        self.calendar = calendar
        self.now = now
    }

    /// `date` is `YYYY-MM-DD`; nil means today.
    public func day(_ date: String?) throws -> String {
        guard let date else { return format(now()) }
        guard Self.isValid(date) else { throw DailyNotesError.invalidDate(date) }
        return date
    }

    /// The path the note of `date` has, whether or not it exists yet.
    public func path(for date: String?) throws -> String {
        let day = try day(date)
        let layout = layout
        return layout.folder.isEmpty ? "\(day).md" : "\(layout.folder)/\(day).md"
    }

    /// The text of the note, or nil if the day has no note yet.
    public func read(date: String?) throws -> String? {
        let path = try path(for: date)
        return vault.exists(path) ? try vault.read(path) : nil
    }

    /// Appends `text` as a new paragraph, creating the note from the template first if needed.
    @discardableResult
    public func append(_ text: String, date: String?) throws -> String {
        let day = try day(date)
        let path = try path(for: day)
        var contents = vault.exists(path) ? try vault.read(path) : try initialContents(day: day)
        if !contents.isEmpty, !contents.hasSuffix("\n") { contents += "\n" }
        if !contents.isEmpty, !contents.hasSuffix("\n\n") { contents += "\n" }
        contents += text.hasSuffix("\n") ? text : text + "\n"
        try vault.write(path, contents)
        return path
    }

    /// Adds `text` right after the first heading block (or at the top without a template).
    @discardableResult
    public func prepend(_ text: String, date: String?) throws -> String {
        let day = try day(date)
        let path = try path(for: day)
        let contents = vault.exists(path) ? try vault.read(path) : try initialContents(day: day)
        let line = text.hasSuffix("\n") ? text : text + "\n"
        if contents.isEmpty {
            try vault.write(path, line)
            return path
        }
        var lines = contents.components(separatedBy: "\n")
        var insertAt = 0
        if let heading = lines.firstIndex(where: { $0.hasPrefix("# ") }) {
            insertAt = heading + 1
            while insertAt < lines.count, lines[insertAt].isEmpty { insertAt += 1 }
        }
        lines.insert(contentsOf: [String(line.dropLast()), ""], at: insertAt)
        try vault.write(path, lines.joined(separator: "\n"))
        return path
    }

    /// Creates the note of `date` from the template when it does not exist; never changes an existing one. A day
    /// whose template is empty gets no file: empty notes do not exist, the note appears with its first text.
    @discardableResult
    public func ensure(date: String?) throws -> String {
        let day = try day(date)
        let path = try path(for: day)
        if !vault.exists(path) {
            let contents = try initialContents(day: day)
            if !NoteContent.hasNoBody(contents) { try vault.write(path, contents) }
        }
        return path
    }

    public func startingText(for date: String?) throws -> String {
        try initialContents(day: try day(date))
    }

    /// The days with a note in the daily folder, sorted: files named `YYYY-MM-DD.md` that are valid dates, in
    /// `month` (`YYYY-MM`) or in any month when it is nil. An absent folder means no notes.
    public func existingDates(in month: String?) throws -> [String] {
        if let month, month.range(of: "^\\d{4}-(0[1-9]|1[0-2])$", options: .regularExpression) == nil {
            throw DailyNotesError.invalidMonth(month)
        }
        let layout = layout
        let entries: [VaultEntry]
        do {
            entries = try vault.list(layout.folder)
        } catch VaultError.notFound {
            return []
        }
        let prefix = layout.folder.isEmpty ? "" : layout.folder + "/"
        return entries
            .filter { !$0.isFolder && $0.path.hasPrefix(prefix) && $0.path.hasSuffix(".md") }
            .map { String($0.path.dropFirst(prefix.count).dropLast(3)) }
            .filter { day in Self.isValid(day) && (month.map { day.hasPrefix($0 + "-") } ?? true) }
            .sorted()
    }

    private func initialContents(day: String) throws -> String {
        let layout = layout
        if !layout.templatePath.isEmpty, vault.exists(layout.templatePath) {
            return try vault.read(layout.templatePath).replacingOccurrences(of: "{{date}}", with: day)
        }
        // No title: the note is named by its file, and the app shows the date above the text.
        return ""
    }

    private func format(_ date: Date) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year!, parts.month!, parts.day!)
    }

    private static func isValid(_ date: String) -> Bool {
        guard date.range(of: "^\\d{4}-\\d{2}-\\d{2}$", options: .regularExpression) != nil else { return false }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let parts = date.split(separator: "-").compactMap { Int($0) }
        var components = DateComponents()
        components.year = parts[0]
        components.month = parts[1]
        components.day = parts[2]
        guard let built = calendar.date(from: components) else { return false }
        let check = calendar.dateComponents([.year, .month, .day], from: built)
        return check.year == parts[0] && check.month == parts[1] && check.day == parts[2]
    }
}
