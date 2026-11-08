import Foundation
import PluginKit

public enum DailyNotesError: Error, Equatable {
    case invalidDate(String)
    case invalidMonth(String)
}

/// The folders a new daily note goes in, written as a template over its day: `yyyy/MM MMMM` gives
/// `2026/11 November`, `yyyy-MM` gives `2026-11`, and an empty pattern keeps the notes flat. The note itself is
/// always named after its day (`2026-11-03.md`).
///
/// Tokens, in either case: `yyyy` (2026), `yy` (26), `MM` (11), `MMM` (Nov), `MMMM` (November) and `dd` (07).
/// Everything else is copied as it is, so `yyyy/Week dd` works too. A last part that names a file
/// (`2026-11-03.md`) is dropped, and so are `.` and `..`: the file name comes from the day.
public struct DailyFolderPattern: Equatable, Sendable, Codable {
    /// One folder per year, then one per month name: what new notes get unless the setting says otherwise.
    public static let month = DailyFolderPattern("yyyy/MM MMMM")
    /// The notes sit directly in the daily folder.
    public static let none = DailyFolderPattern("")
    /// One folder per year.
    public static let year = DailyFolderPattern("yyyy")

    /// The pattern as written in the settings.
    public let rawValue: String
    /// One entry per folder, outermost first, each its tokens.
    private let components: [[Token]]

    public init(_ template: String) {
        var parts = template
            .split(separator: "/", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && $0 != "." && $0 != ".." }
        if let last = parts.last, last.lowercased().hasSuffix(".md") { parts.removeLast() }
        rawValue = parts.joined(separator: "/")
        components = parts.map(Self.parse)
    }

    /// The value a settings file of an older version holds: `none`, `year` or `month`. Anything else is a pattern
    /// as it is, so a pattern written by hand reads back unchanged.
    public init(stored value: String) {
        switch value {
        case "none": self.init("")
        case "year": self.init("yyyy")
        case "month": self.init("yyyy/MM MMMM")
        default: self.init(value)
        }
    }

    public init(from decoder: Decoder) throws {
        self.init(stored: try decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    /// How many folders deep the pattern goes; 0 for a flat layout.
    var folderCount: Int { components.count }

    /// The folders of `day` (`YYYY-MM-DD`), outermost first; none for a flat layout.
    func folders(for day: String) -> [String] {
        let year = Int(day.prefix(4)) ?? 0
        let month = Int(day.dropFirst(5).prefix(2)) ?? 1
        let dayOfMonth = Int(day.suffix(2)) ?? 1
        return components.map { component in
            component.map { $0.string(year: year, month: month, day: dayOfMonth) }.joined()
        }
    }

    private enum Token: Equatable, Sendable {
        case literal(String)
        case year4
        case year2
        case month2
        case monthShort
        case monthLong
        case day2

        func string(year: Int, month: Int, day: Int) -> String {
            switch self {
            case .literal(let text): return text
            case .year4: return String(format: "%04d", year)
            case .year2: return String(format: "%02d", year % 100)
            case .month2: return String(format: "%02d", month)
            case .monthShort: return String(DailyFolderPattern.monthNames[month - 1].prefix(3))
            case .monthLong: return DailyFolderPattern.monthNames[month - 1]
            case .day2: return String(format: "%02d", day)
            }
        }
    }

    private static func parse(_ text: String) -> [Token] {
        var tokens: [Token] = []
        var literal = ""
        func flush() {
            if !literal.isEmpty { tokens.append(.literal(literal)); literal = "" }
        }
        let characters = Array(text)
        var index = 0
        // A token starts a word, follows another token, or comes after a separator. Letters around it keep it as
        // text, so `yyyy/Summer` keeps its folder name while `yyyymm` still reads as two tokens.
        var followsToken = false
        while index < characters.count {
            let rest = String(characters[index...]).uppercased()
            let startsWord = index == 0 || followsToken || !characters[index - 1].isLetter
            let token: (Token, Int)?
            if !startsWord {
                token = nil
            } else if rest.hasPrefix("YYYY") {
                token = (.year4, 4)
            } else if rest.hasPrefix("MMMM") {
                token = (.monthLong, 4)
            } else if rest.hasPrefix("MMM") {
                token = (.monthShort, 3)
            } else if rest.hasPrefix("MM") {
                token = (.month2, 2)
            } else if rest.hasPrefix("DD") {
                token = (.day2, 2)
            } else if rest.hasPrefix("YY") {
                token = (.year2, 2)
            } else {
                token = nil
            }
            if let (found, length) = token {
                flush()
                tokens.append(found)
                index += length
                followsToken = true
            } else {
                literal.append(characters[index])
                index += 1
                followsToken = false
            }
        }
        flush()
        return tokens
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
    public var subfolders: DailyFolderPattern

    public init(
        folder: String = "Journal", templatePath: String = ".loam/templates/daily.md",
        subfolders: DailyFolderPattern = .month
    ) {
        self.folder = folder
        self.templatePath = templatePath
        self.subfolders = subfolders
    }

    /// Where the note of `day` goes in this layout.
    func path(of day: String, sortedBy subfolders: DailyFolderPattern? = nil) -> String {
        let parts = (folder.isEmpty ? [] : [folder]) + (subfolders ?? self.subfolders).folders(for: day) + [day + ".md"]
        return parts.joined(separator: "/")
    }
}

/// The plugin's settings, in `.loam/config.json` under `plugins.daily-notes.settings` and on its page in Settings.
public struct DailyNotesSettings: Codable, Equatable, Sendable {
    /// The folder of daily notes, from the vault's root; empty for the root itself.
    public var folder = "Journal"
    /// A note whose text starts each new daily note; empty for none.
    public var template = ".loam/templates/daily.md"
    /// The folders new notes are sorted into: `none`, `year`, `month`, or a pattern over the day
    /// (`yyyy/MM MMMM`, `yyyy-MM`, `yyyy/MM/dd`).
    public var subfolders = DailyFolderPattern.month

    public init(
        folder: String = "Journal", template: String = ".loam/templates/daily.md",
        subfolders: DailyFolderPattern = .month
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
        let raw = try container.decodeIfPresent(String.self, forKey: .subfolders) ?? DailyFolderPattern.month.rawValue
        subfolders = DailyFolderPattern(stored: raw)
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

/// Creates, reads and appends to the note of a given day (`Journal/2026/11 November/2026-11-03.md`, or whatever
/// the subfolder pattern says).
public final class DailyNotes: DailyNotesService {
    private let vault: VaultAccess
    private let layoutLock = NSLock()
    private var currentLayout: DailyNotesLayout
    private var currentPreviousPatterns: [DailyFolderPattern]
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
        previousPatterns: [DailyFolderPattern] = [],
        calendar: Calendar = .current,
        now: @escaping () -> Date = Date.init
    ) {
        self.vault = vault
        currentLayout = layout
        currentPreviousPatterns = previousPatterns
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

    /// The folders new notes go in, as written in the settings.
    public var subfolderPattern: String { layout.subfolders.rawValue }

    /// The patterns this vault used before the one in the settings: notes written under them are still found.
    public var previousPatterns: [DailyFolderPattern] {
        get {
            layoutLock.lock()
            defer { layoutLock.unlock() }
            return currentPreviousPatterns
        }
        set {
            layoutLock.lock()
            defer { layoutLock.unlock() }
            currentPreviousPatterns = newValue
        }
    }

    /// Where the note of `day` may be besides where this layout puts it: the layouts older versions wrote, and the
    /// patterns this vault used before. A note keeps being found after the pattern changes.
    private func otherPaths(of day: String) -> [String] {
        let layout = layout
        let preferred = layout.path(of: day)
        var seen: Set<String> = []
        return ([DailyFolderPattern.none, .year, .month] + previousPatterns)
            .map { layout.path(of: day, sortedBy: $0) }
            .filter { $0 != preferred && seen.insert($0).inserted }
    }

    /// Where a note created for `date` would go, whether or not one is there yet.
    public func newNotePath(for date: String?) throws -> String {
        layout.path(of: try day(date))
    }

    /// The path the note of `date` has, whether or not it exists yet: where it already is when it was sorted another
    /// way (before the setting changed), else where the layout puts it.
    public func path(for date: String?) throws -> String {
        let day = try day(date)
        let layout = layout
        let preferred = layout.path(of: day)
        if vault.exists(preferred) { return preferred }
        for path in otherPaths(of: day) where vault.exists(path) { return path }
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
    /// `month` (`YYYY-MM`) or in any month when it is nil. Notes are found at the path the pattern gives them and
    /// at the ones older versions wrote, so a vault half sorted one way and half another still shows every day. An
    /// absent folder means no notes.
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
        // As deep as the pattern goes, and always two levels for the layouts older versions wrote.
        let depth = max(layout.subfolders.folderCount, 2)
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
                    if next.depth < depth { folders.append((entry.path, next.depth + 1)) }
                    continue
                }
                let name = entry.path.split(separator: "/").last.map(String.init) ?? entry.path
                guard name.hasSuffix(".md") else { continue }
                let day = String(name.dropLast(3))
                guard Self.isValid(day) else { continue }
                // Only where this layout or an older one would put it: `Daily/Archive/2024-01-01.md` is not a daily note.
                guard entry.path == layout.path(of: day) || otherPaths(of: day).contains(entry.path)
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
