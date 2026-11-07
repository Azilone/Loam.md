import PluginKitUI

/// A `QuickPick` that keeps the last popup a plugin asked for, so a test can type a query and pick a row.
@MainActor
public final class RecordingQuickPick: QuickPick {
    public private(set) var placeholder: String?
    public private(set) var items: (@MainActor (String) -> [QuickPickItem])?
    public private(set) var choose: (@MainActor (QuickPickItem) -> Void)?
    /// Set when the plugin used `showSearching`.
    public private(set) var searchItems: (@Sendable (String) async -> [QuickPickItem])?
    /// How many times `show` was called.
    public private(set) var shownCount = 0
    private var lastQuery = ""
    private var lastRows: [QuickPickItem] = []

    public init() {}

    public func show(
        placeholder: String,
        items: @escaping @MainActor (String) -> [QuickPickItem],
        choose: @escaping @MainActor (QuickPickItem) -> Void
    ) {
        self.placeholder = placeholder
        self.items = items
        searchItems = nil
        self.choose = choose
        shownCount += 1
        lastQuery = ""
    }

    public func showSearching(
        placeholder: String,
        items: @escaping @Sendable (String) async -> [QuickPickItem],
        choose: @escaping @MainActor (QuickPickItem) -> Void
    ) {
        self.placeholder = placeholder
        self.items = nil
        searchItems = items
        self.choose = choose
        shownCount += 1
        lastQuery = ""
    }

    /// The rows a `showSearching` popup finds for `q`, as if the user typed it and waited.
    public func search(_ q: String) async -> [QuickPickItem] {
        lastQuery = q
        lastRows = await searchItems?(q) ?? []
        return lastRows
    }

    /// The rows for `q`, as if the user typed it. Empty if nothing was shown.
    public func query(_ q: String) -> [QuickPickItem] {
        lastQuery = q
        return items?(q) ?? []
    }

    /// Picks the row with this id among the rows of the last query (the empty query if none was typed).
    /// Returns false, without calling the plugin, when no such row is listed.
    @discardableResult
    public func choose(id: String) -> Bool {
        let rows = items.map { $0(lastQuery) } ?? lastRows
        guard let choose, let item = rows.first(where: { $0.id == id }) else { return false }
        choose(item)
        return true
    }
}
