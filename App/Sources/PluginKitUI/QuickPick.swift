/// One row of a quick pick.
public struct QuickPickItem: Identifiable, Hashable, Sendable {
    public let id: String
    public let title: String
    /// A second line, such as the folder of a note.
    public let subtitle: String?
    /// SF Symbol name.
    public let symbol: String?
    /// Trailing text, such as a shortcut.
    public let detail: String?
    /// The heading the row is listed under (`Recent`, a plugin's name). Rows of one section follow each other; nil
    /// rows have no heading.
    public let section: String?
    /// Only shown on the selected row: the subtitle under its title. For long text (a command's summary) that would
    /// make every row two lines.
    public let subtitleOnSelection: Bool

    public init(
        id: String,
        title: String,
        subtitle: String? = nil,
        symbol: String? = nil,
        detail: String? = nil,
        section: String? = nil,
        subtitleOnSelection: Bool = false
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.symbol = symbol
        self.detail = detail
        self.section = section
        self.subtitleOnSelection = subtitleOnSelection
    }
}

/// A filterable list in a popup: the palette and the quick switcher are both one. The shell owns the popup;
/// the plugin owns the items and the action.
@MainActor
public protocol QuickPick: AnyObject {
    /// Shows the popup. `items` is called with the query on every keystroke (the empty string first), so the
    /// plugin filters and ranks, usually with `Fuzzy.rank`. `choose` runs once if the user picks a row, never if
    /// they dismiss the popup.
    func show(
        placeholder: String,
        items: @escaping @MainActor (String) -> [QuickPickItem],
        choose: @escaping @MainActor (QuickPickItem) -> Void
    )

    /// Shows the popup for rows that take time to find, such as a search of every note: `items` runs off the main
    /// thread once typing pauses, and its rows replace the list when they arrive (an older query's never do), so the
    /// field never waits for them. Since SDK 1.5.
    func showSearching(
        placeholder: String,
        items: @escaping @Sendable (String) async -> [QuickPickItem],
        choose: @escaping @MainActor (QuickPickItem) -> Void
    )
}

extension QuickPick {
    /// For a host built before SDK 1.5: the popup lists nothing rather than block the field.
    public func showSearching(
        placeholder: String,
        items: @escaping @Sendable (String) async -> [QuickPickItem],
        choose: @escaping @MainActor (QuickPickItem) -> Void
    ) {
        show(placeholder: placeholder, items: { _ in [] }, choose: choose)
    }
}
