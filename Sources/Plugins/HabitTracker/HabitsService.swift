import Foundation
import PluginKit

/// The habit tracker's operations, for its own UI module (`HabitsUI`), which may import this logic module.
/// Other plugins, the CLI and agents reach the same behaviour through the `habits.*` commands.
public protocol HabitsService: AnyObject {
    /// Today, `YYYY-MM-DD`, as the tracker sees it: streaks are counted up to this day.
    var today: String { get }
    /// The folder of habit notes (`Habits` unless the plugin's settings say otherwise).
    var folder: String { get }
    /// Every habit note directly in the habits folder, sorted by name.
    func habits() throws -> [Habit]
    /// Records a day (today when nil) for a habit, creating its note if needed. Checking a day twice changes
    /// nothing. Writes to the vault.
    func check(_ name: String, date: String?) throws
    /// Removes a day (today when nil) from a habit's check-ins; the rest of the note is kept. Writes to the vault.
    func uncheck(_ name: String, date: String?) throws
    /// Creates `<folder>/<name>.md` with a short header, and returns its path. Throws if it exists. Writes to the
    /// vault.
    func create(_ name: String) throws -> String
    /// Sets (or removes, with nil) a frontmatter property of a habit's note: `color`, `icon`, `archived`. The rest of
    /// the note is kept. Writes to the vault.
    func setProperty(_ name: String, key: String, value: String?) throws
}

/// Sent by the provider of `HabitsService` after its folder changed, so views listing the habits follow.
public struct HabitsFolderChanged: PluginEvent, Equatable {
    public init() {}
}

public extension ServiceKey where Service == HabitsService {
    static var habits: ServiceKey<HabitsService> { ServiceKey<HabitsService>("habits") }
}

/// One habit note, as `HabitsService.habits()` reads it.
public struct Habit: Codable, Equatable, Sendable {
    public let name: String
    /// Vault-relative path of the note, `<folder>/<name>.md`.
    public let path: String
    /// The days checked, `YYYY-MM-DD`.
    public let checkedDays: Set<String>
    /// Consecutive days up to today, or up to yesterday while today is not checked yet.
    public let currentStreak: Int
    public let longestStreak: Int
    /// The `created` frontmatter property (`YYYY-MM-DD`) that `create` writes, else the first check-in, else nil.
    public let created: String?
    /// The `color` property: a colour name (`orange`, `blue`…) the board draws the habit in.
    public let color: String?
    /// The `icon` property: an emoji shown before the name.
    public let icon: String?
    /// `archived: true`: kept, but off the board.
    public let archived: Bool

    public init(
        name: String,
        path: String,
        checkedDays: Set<String>,
        currentStreak: Int,
        longestStreak: Int,
        created: String?,
        color: String? = nil,
        icon: String? = nil,
        archived: Bool = false
    ) {
        self.name = name
        self.path = path
        self.checkedDays = checkedDays
        self.currentStreak = currentStreak
        self.longestStreak = longestStreak
        self.created = created
        self.color = color
        self.icon = icon
        self.archived = archived
    }
}
