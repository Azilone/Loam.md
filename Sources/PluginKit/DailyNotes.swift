import Foundation

/// The daily note of a given day. Dates are `YYYY-MM-DD`; `nil` means today.
public protocol DailyNotesService: AnyObject {
    /// The folder of daily notes, from the vault's root; empty for the root. New notes may go in year or month
    /// folders inside it.
    var folder: String { get }
    /// The path the note has, whether or not it exists yet.
    func path(for date: String?) throws -> String
    /// The text of the note, or nil if the day has no note yet.
    func read(date: String?) throws -> String?
    /// Appends a paragraph, creating the note from the template if needed. Returns the path.
    @discardableResult func append(_ text: String, date: String?) throws -> String
    /// Adds a paragraph below the note's title. Returns the path.
    @discardableResult func prepend(_ text: String, date: String?) throws -> String
    /// Creates the note from the template if it does not exist yet, leaves it alone otherwise. Returns the path.
    @discardableResult func ensure(date: String?) throws -> String
    /// What the note of `date` starts with: its template with the day filled in, empty without a template. For an
    /// app that shows a day's note before it exists and writes it once the user adds to this text.
    func startingText(for date: String?) throws -> String
    /// The days (`YYYY-MM-DD`, sorted) that have a note, in `month` (`YYYY-MM`), or every day when `month` is nil.
    func existingDates(in month: String?) throws -> [String]
}

public extension DailyNotesService {
    /// For a provider written before `folder` existed: the folder of a day's note.
    var folder: String { VaultPath.directory(of: (try? path(for: "2000-01-01")) ?? "") }
}

/// Sent by the provider of `DailyNotesService` after its folder or format changed, so views listing the days follow.
public struct DailyNotesLayoutChanged: PluginEvent, Equatable {
    public init() {}
}

public extension ServiceKey where Service == DailyNotesService {
    static var dailyNotes: ServiceKey<DailyNotesService> { ServiceKey<DailyNotesService>("daily-notes") }
}
