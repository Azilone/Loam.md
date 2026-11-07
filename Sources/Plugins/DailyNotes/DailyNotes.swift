import Foundation
import PluginKit

public enum DailyNotesError: Error, Equatable {
    case invalidDate(String)
    case invalidMonth(String)
}

/// How daily notes are sorted inside their folder.
public enum DailyNotesSubfolders: String, Codable, CaseIterable, Sendable {
    /// `Journal/2026-11-03.md`
    case none
    /// `Journal/2026/2026-11-03.md`
    case year
    /// `Journal/2026/11 November/2026-11-03.md`, the default
    case month

    /// The folders between the daily folder and the note of `day` (`YYYY-MM-DD`), empty for `none`.
    func components(of day: String) -> [String] {
        let year = String(day.prefix(4))
        switch self {
        case .none: return []
        case .year: return [year]
        case .month:
            let month = Int(day.dropFirst(5).prefix(2)) ?? 1
            return [year, String(format: "%02d %@", month, Self.monthNames[month - 1])]
        }
    }

    /// English on purpose: folder names are part of the vault, not of the interface, and must not change with the
    /// Mac's language.
    private static let monthNames = [
        "January", "February", "March", "April", "May", "June",
        "July", "August", "September", "October", "November", "December",
    ]
}

/// Where daily notes live and what a new one contains.
public struct DailyNotesLayout {
    public var folder: String
    /// Vault path of an optional template. `{{date}}` is replaced by the day (`YYYY-MM-DD`).
    public var templatePath: String
    /// Where a new note goes inside `folder`. Notes already sorted another way are still found.
    public var subfolders: DailyNotesSubfolders

    public init(
        folder: String = "Journal", templatePath: String = ".loam/templates/daily.md",
        subfolders: DailyNotesSubfolders = .month
    ) {
        self.folder = folder
        self.templatePath = templatePath
        self.subfolders = subfolders
    }

    /// Where the note of `day` goes in this layout.
    func path(of day: String, sortedBy subfolders: DailyNotesSubfolders? = nil) -> String {
        let parts = (folder.isEmpty ? [] : [folder]) + (subfolders ?? self.subfolders).components(of: day) + [day + ".md"]
        return parts.joined(separator: "/")
    }
}

/// The plugin's settings, in `.loam/config.json` under `plugins.daily-notes.settings` and on its page in Settings.
public struct DailyNotesSettings: Codable, Equatable, Sendable {
    /// The folder of daily notes, from the vault's root; empty for the root itself.
    public var folder = "Journal"
    /// A note whose text starts each new daily note; empty for none.
    public var template = ".loam/templates/daily.md"
    /// `none`, `year` or `month`: the folders new notes are sorted into.
    public var subfolders = DailyNotesSubfolders.month

    public init(
        folder: String = "Journal", template: String = ".loam/templates/daily.md",
        subfolders: DailyNotesSubfolders = .month
    ) {
        self.folder = folder
        self.template = template
        self.subfolders = subfolders
    }

    private enum CodingKeys: String, CodingKey { case folder, template, subfolders }

    /// A missing key, or a value this version does not know, reads as the default.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        folder = try container.decodeIfPresent(String.self, forKey: .folder) ?? "Journal"
        template = try container.decodeIfPresent(String.self, forKey: .template) ?? ".loam/templates/daily.md"
        let raw = try container.decodeIfPresent(String.self, forKey: .subfolders) ?? ""
        subfolders = DailyNotesSubfolders(rawValue: raw) ?? .month
    }

    /// The layout these settings give: the folder without slashes or spaces around it.
    public var layout: DailyNotesLayout {
        let trim = CharacterSet.whitespaces.union(CharacterSet(charactersIn: "/"))
        return DailyNotesLayout(
            folder: folder.trimmingCharacters(in: trim),
            templatePath: template.trimmingCharacters(in: .whitespaces),
            subfolders: subfolders
        )
    }
}

/// Creates, reads and appends to the note of a given day (`Journal/YYYY/MM Month/YYYY-MM-DD.md`, or flat or in
/// year folders).
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

    /// The folder of daily notes, from the vault's root; empty for the root itself.
    public var folder: String { layout.folder }

    /// The path the note of `date` has, whether or not it exists yet: where it already is when it was sorted another
    /// way (before the setting changed), else where the layout puts it.
    public func path(for date: String?) throws -> String {
        let day = try day(date)
        let layout = layout
        let preferred = layout.path(of: day)
        if vault.exists(preferred) { return preferred }
        for other in DailyNotesSubfolders.allCases where other != layout.subfolders {
            let path = layout.path(of: day, sortedBy: other)
            if vault.exists(path) { return path }
        }
        return preferred
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
    /// `month` (`YYYY-MM`) or in any month when it is nil. Notes are found at the path any `DailyNotesSubfolders`
    /// gives them, so a vault half sorted one way and half another still shows every day. An absent folder means no
    /// notes.
    public func existingDates(in month: String?) throws -> [String] {
        if let month, month.range(of: "^\\d{4}-(0[1-9]|1[0-2])$", options: .regularExpression) == nil {
            throw DailyNotesError.invalidMonth(month)
        }
        return try notes().keys.filter { day in month.map { day.hasPrefix($0 + "-") } ?? true }.sorted()
    }

    /// The moves (old path to new path) that put every note, and its `YYYY-MM-DD.assets` folder, where the layout
    /// puts it now. A note whose new path is taken stays where it is.
    public func reorganizationMoves() throws -> [String: String] {
        let layout = layout
        var moves: [String: String] = [:]
        for (day, path) in try notes() {
            let target = layout.path(of: day)
            guard target != path, !vault.exists(target) else { continue }
            moves[path] = target
            let assets = String(path.dropLast(3)) + ".assets"
            let targetAssets = String(target.dropLast(3)) + ".assets"
            if vault.exists(assets), !vault.exists(targetAssets) { moves[assets] = targetAssets }
        }
        return moves
    }

    /// Every daily note, by day. When a day has notes in two layouts, the current layout's wins.
    private func notes() throws -> [String: String] {
        let layout = layout
        var found: [String: String] = [:]
        // Two levels at most: a year folder, then a month folder.
        var folders = [(path: layout.folder, depth: 0)]
        while let next = folders.popLast() {
            let entries: [VaultEntry]
            do {
                entries = try vault.list(next.path)
            } catch VaultError.notFound {
                continue
            }
            for entry in entries {
                if entry.isFolder {
                    if next.depth < 2 { folders.append((entry.path, next.depth + 1)) }
                    continue
                }
                let name = entry.path.split(separator: "/").last.map(String.init) ?? entry.path
                guard name.hasSuffix(".md") else { continue }
                let day = String(name.dropLast(3))
                guard Self.isValid(day) else { continue }
                // Only where some layout would put it: `Daily/Archive/2024-01-01.md` is not a daily note.
                guard DailyNotesSubfolders.allCases.contains(where: { layout.path(of: day, sortedBy: $0) == entry.path })
                else { continue }
                if found[day] == nil || entry.path == layout.path(of: day) { found[day] = entry.path }
            }
        }
        return found
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
