import Observation
import PluginKitUI

/// The shell's `QuickPick` (`ui.quick-pick`): the state of the popup the palette and the quick switcher show.
/// `QuickPickView` draws it; everything it does is here, so it is tested without a window.
///
/// One request at a time: `show` while the popup is up replaces the current request.
@MainActor
@Observable
public final class QuickPickController: QuickPick {
    /// The most rows the popup shows; the provider's later rows are dropped.
    public static let maxResults = 500

    public private(set) var placeholder = ""
    /// What the user typed. Setting it asks the provider again and selects the first row.
    public var query = "" {
        didSet { if query != oldValue { refresh() } }
    }
    public private(set) var results: [QuickPickItem] = []
    public var selectedIndex = 0
    public private(set) var isPresented = false
    /// Changes on every `show` but a switch of tab, so the view starts fresh (focus, scroll) for a new request.
    public private(set) var presentation = 0
    /// Changes when a switch of tab brings its rows, so the view cross-fades the old rows into the new ones.
    public private(set) var rowsGeneration = 0
    /// A switch of tab whose rows have not come yet: the old ones stay on screen meanwhile (the panel neither
    /// collapses nor jumps), but cannot be chosen.
    @ObservationIgnored private var switchPending = false

    /// A popup the shell can switch to from the field (Notes ⌘O, Commands ⌘P): the command that opens it.
    public struct Tab: Equatable, Sendable {
        public let commandID: String
        public let title: String
        /// The keys that open it, as the menus show them (`⌘O`).
        public let shortcut: String
        /// The field's symbol while it is open.
        public let symbol: String
        /// What the footer counts (`notes`, `commands`).
        public let noun: String
    }

    /// The tabs shown above the rows, when the popup came from one of them.
    public var tabs: [Tab] = []
    /// The tab the popup shows now, nil when it came from elsewhere (`search.focus`): then no tabs are drawn.
    public private(set) var activeTabID: String?
    /// Runs the command of a tab the user switched to. The shell sets it.
    @ObservationIgnored public var openTab: (@MainActor (String) -> Void)?
    @ObservationIgnored private var preparedTab: String?
    @ObservationIgnored private var carriedQuery: String?

    public var activeTab: Tab? { tabs.first { $0.commandID == activeTabID } }

    @ObservationIgnored private var items: (@MainActor (String) -> [QuickPickItem])?
    @ObservationIgnored private var onChoose: (@MainActor (QuickPickItem) -> Void)?
    /// Set by `showSearching`: the rows are found off the main thread.
    @ObservationIgnored private var searchItems: (@Sendable (String) async -> [QuickPickItem])?
    @ObservationIgnored private var search: Task<Void, Never>?
    /// How long typing must pause before a slow provider is asked.
    static let searchPause: Duration = .milliseconds(120)

    public init() {}

    public func show(
        placeholder: String,
        items: @escaping @MainActor (String) -> [QuickPickItem],
        choose: @escaping @MainActor (QuickPickItem) -> Void
    ) {
        present(placeholder: placeholder, items: items, searchItems: nil, choose: choose)
    }

    public func showSearching(
        placeholder: String,
        items: @escaping @Sendable (String) async -> [QuickPickItem],
        choose: @escaping @MainActor (QuickPickItem) -> Void
    ) {
        present(placeholder: placeholder, items: nil, searchItems: items, choose: choose)
    }

    private func present(
        placeholder: String,
        items: (@MainActor (String) -> [QuickPickItem])?,
        searchItems: (@Sendable (String) async -> [QuickPickItem])?,
        choose: @escaping @MainActor (QuickPickItem) -> Void
    ) {
        search?.cancel()
        // A tab opened while the popup is up, by its tab, Tab or its shortcut (⌘O over ⌘P), is a switch in place,
        // whichever way: the panel stays and its rows cross-fade.
        let switching = isPresented && (carriedQuery != nil || (preparedTab != nil && activeTabID != nil))
        switchPending = switching
        if searchItems != nil, !switching { results = [] }
        self.items = items
        self.searchItems = searchItems
        self.onChoose = choose
        self.placeholder = placeholder
        // A switch of tab keeps the popup in place: only a new request starts the view afresh.
        if !switching { presentation += 1 }
        isPresented = true
        activeTabID = preparedTab
        preparedTab = nil
        let next = carriedQuery ?? (switching ? query : "")
        carriedQuery = nil
        if query == next { refresh() } else { query = next }
    }

    /// Told every command about to run: the next `show` belongs to that command's tab, or to none.
    public func prepare(commandID: String) {
        preparedTab = tabs.contains { $0.commandID == commandID } ? commandID : nil
    }

    /// Opens another tab in place, keeping what was typed.
    public func switchTab(to commandID: String) {
        guard isPresented, commandID != activeTabID, tabs.contains(where: { $0.commandID == commandID }) else { return }
        carriedQuery = query
        openTab?(commandID)
    }

    /// Tab: the next tab, wrapping around. Does nothing without tabs.
    public func cycleTab() {
        guard let current = tabs.firstIndex(where: { $0.commandID == activeTabID }) else { return }
        switchTab(to: tabs[(current + 1) % tabs.count].commandID)
    }

    /// Moves the selection by `delta` rows, wrapping around at both ends.
    public func move(_ delta: Int) {
        guard !results.isEmpty else { return }
        let count = results.count
        selectedIndex = ((selectedIndex + delta) % count + count) % count
    }

    /// Chooses the selected row: the popup closes, then the requester's `choose` runs.
    public func chooseSelected() {
        choose(at: selectedIndex)
    }

    /// Chooses a row by index (a click). Does nothing for an index out of range.
    public func choose(at index: Int) {
        guard isPresented, !switchPending, results.indices.contains(index), let onChoose else { return }
        let item = results[index]
        dismiss()
        onChoose(item)
    }

    /// Closes the popup without choosing: the requester's `choose` never runs.
    public func dismiss() {
        guard isPresented else { return }
        isPresented = false
        activeTabID = nil
        items = nil
        searchItems = nil
        search?.cancel()
        onChoose = nil
        switchPending = false
        // The rows stay while the popup leaves: emptying them now had the panel shrink to its field and lay its list
        // out on every frame of the exit. The next `show` replaces them.
        selectedIndex = 0
        query = ""
    }

    private func refresh() {
        guard isPresented else { return }
        if let items {
            results = Array(items(query).prefix(Self.maxResults))
            selectedIndex = 0
            endSwitch()
            return
        }
        guard let searchItems else { return }
        search?.cancel()
        let query = query
        search = Task { [weak self] in
            if !query.isEmpty {
                try? await Task.sleep(for: Self.searchPause)
                guard !Task.isCancelled else { return }
            }
            let rows = await Task.detached { await searchItems(query) }.value
            guard !Task.isCancelled, let self, self.isPresented, self.query == query else { return }
            self.results = Array(rows.prefix(Self.maxResults))
            self.selectedIndex = 0
            self.endSwitch()
        }
    }

    /// The rows of a switched tab have come: the view cross-fades to them.
    private func endSwitch() {
        guard switchPending else { return }
        switchPending = false
        rowsGeneration += 1
    }

    /// Waits for the rows a slow provider is finding. Tests await it.
    func settle() async {
        await search?.value
    }
}
