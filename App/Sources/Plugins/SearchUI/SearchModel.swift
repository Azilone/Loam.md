import Foundation
import Observation
import PluginKitUI
import TruffleSearchPlugin

/// The Search panel's state and actions: the query, the kind of search, Truffle's status and the results grouped
/// by note. The view only reads it and calls its methods, so tests drive the panel through it.
///
/// Searches run off the main thread (`Task.detached`, the service blocks) after a short pause in typing, and only
/// the latest one's results are kept.
@MainActor
@Observable
final class SearchModel {
    /// The hits of one note, in the order the service ranked them.
    struct Group: Identifiable, Hashable, Sendable {
        /// Distinct from the rows' ids: groups and rows sit in one list, and SwiftUI blanks duplicate ids.
        var id: String { "note:" + path }
        let path: String
        let title: String
        /// The folder it is in, empty at the root.
        let folder: String
        let rows: [Row]
    }

    /// One hit under its note.
    struct Row: Identifiable, Hashable, Sendable {
        /// The hit's position in the results makes it unique, even for two hits on one line.
        let id: String
        let hit: SearchHit
    }

    static let resultLimit = 100
    nonisolated static let quickPickLimit = 30
    /// The pause in typing before a search starts.
    static let debounce: Duration = .milliseconds(250)
    static let meaningUnavailable = "Search by meaning needs Truffle running"
    static let truffleURL = URL(string: SearchError.truffleURL)!

    private(set) var query = ""
    private(set) var kind: SearchKind = .content
    private(set) var groups: [Group] = []
    /// Nil until the first status check returns.
    private(set) var status: SearchStatus?
    private(set) var isSearching = false
    /// Why the last search failed, shown in place of the results.
    private(set) var message: String?

    /// The running search, debounce included. Tests await it.
    @ObservationIgnored private(set) var pending: Task<Void, Never>?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private let service: SearchService
    @ObservationIgnored private let workspace: @MainActor () -> (any Workspace)?
    @ObservationIgnored private let quickPick: @MainActor () -> (any QuickPick)?

    init(
        service: SearchService,
        workspace: @escaping @MainActor () -> (any Workspace)?,
        quickPick: @escaping @MainActor () -> (any QuickPick)?
    ) {
        self.service = service
        self.workspace = workspace
        self.quickPick = quickPick
    }

    /// Names and content always work (built-in fallback); meaning only once Truffle is known to run.
    var meaningAvailable: Bool { status?.supports(.meaning) ?? false }

    // MARK: Typing

    func setQuery(_ text: String) {
        guard text != query else { return }
        query = text
        schedule(after: Self.debounce)
    }

    /// Picking a segment searches again at once. Meaning is refused while Truffle is not running.
    func setKind(_ newKind: SearchKind) {
        guard newKind != kind else { return }
        guard newKind != .meaning || meaningAvailable else { return }
        kind = newKind
        schedule(after: .zero)
    }

    /// Runs the current search again, such as after the vault changed.
    func rerun() {
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        schedule(after: Self.debounce)
    }

    private func schedule(after delay: Duration) {
        generation += 1
        let generation = generation
        pending?.cancel()
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            groups = []
            message = nil
            isSearching = false
            pending = nil
            return
        }
        let kind = kind
        let service = service
        let limit = Self.resultLimit
        isSearching = true
        pending = Task { [weak self] in
            if delay > .zero {
                try? await Task.sleep(for: delay)
                guard !Task.isCancelled else { return }
            }
            let result = await Task.detached {
                try service.search(query, kind: kind, limit: limit)
            }.result
            guard !Task.isCancelled else { return }
            self?.finish(result, generation: generation)
        }
    }

    private func finish(_ result: Result<[SearchHit], Error>, generation: Int) {
        guard generation == self.generation else { return }
        isSearching = false
        switch result {
        case .success(let hits):
            groups = Self.group(hits)
            message = nil
        case .failure(let error):
            groups = []
            message = error.localizedDescription
            if error as? SearchError == .notRunning { refreshStatus() }
        }
    }

    static func group(_ hits: [SearchHit]) -> [Group] {
        var order: [String] = []
        var byPath: [String: [Row]] = [:]
        for (index, hit) in hits.enumerated() {
            if byPath[hit.path] == nil { order.append(hit.path) }
            byPath[hit.path, default: []].append(Row(id: "hit:\(index):" + hit.path, hit: hit))
        }
        return order.map { path in
            let rows = byPath[path] ?? []
            return Group(
                path: path,
                title: rows.first?.hit.title ?? lastComponent(path),
                folder: VaultPath.directory(of: path),
                rows: rows
            )
        }
    }

    nonisolated static func lastComponent(_ path: String) -> String {
        path.split(separator: "/").last.map(String.init) ?? path
    }

    // MARK: Status

    /// Asks the service, off the main thread, whether Truffle runs. Falls back from meaning when it does not.
    @discardableResult
    func refreshStatus() -> Task<Void, Never> {
        let service = service
        return Task { [weak self] in
            let status = await Task.detached { service.status() }.value
            guard let self else { return }
            if status != self.status { self.status = status }
            if self.kind == .meaning, !status.supports(.meaning) {
                self.kind = .content
                self.schedule(after: .zero)
            }
        }
    }

    // MARK: Opening

    /// A click opens the note in the focused tab; Cmd-click beside it.
    func open(_ path: String, beside: Bool) {
        workspace()?.open(.file(path), placement: beside ? .beside : .replace)
    }

    // MARK: Quick pick

    /// `search.focus`: opens the popup, or says why it cannot (the CLI has no popup).
    func showQuickPick() -> String {
        guard let quickPick = quickPick() else { return "No popup in this host: use search.content." }
        let service = service
        quickPick.showSearching(
            placeholder: "Search in notes…",
            items: { query in Self.quickPickItems(query, service: service) },
            choose: { [weak self] item in
                if let path = Self.path(ofQuickPickItem: item) { self?.open(path, beside: false) }
            }
        )
        // Empty: the popup is the feedback; the palette shows no toast for an empty result.
        return ""
    }

    /// The rows of the `search.focus` popup: content hits for `query`, searched off the main thread as the user
    /// types (a content search of a big vault takes a second).
    nonisolated static func quickPickItems(_ query: String, service: SearchService) -> [QuickPickItem] {
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty,
              let hits = try? service.search(query, kind: .content, limit: Self.quickPickLimit) else { return [] }
        return hits.enumerated().map { index, hit in
            let folder = VaultPath.directory(of: hit.path)
            return QuickPickItem(
                id: "\(index):" + hit.path,
                title: hit.snippet.map(Self.plainSnippet).flatMap { $0.isEmpty ? nil : $0 } ?? hit.title ?? hit.path,
                subtitle: (hit.title ?? Self.lastComponent(hit.path)) + (folder.isEmpty ? "" : " — " + folder),
                symbol: "text.magnifyingglass",
                detail: hit.line.map { "line \($0)" }
            )
        }
    }

    /// A content hit's line as text, without its Markdown marks (`#`, `-`, `>`, `- [ ]`, `**`, `_`, `` ` ``, link
    /// targets) or HTML tags (`<mark>`), as the Home digest shows lines.
    nonisolated static func plainSnippet(_ line: String) -> String {
        var text = line.trimmingCharacters(in: .whitespaces)
        let ellipsis = text.hasPrefix("…")
        if ellipsis { text.removeFirst() }
        for prefix in ["- [ ] ", "- [x] ", "- [X] ", "* [ ] ", "* [x] "] where text.hasPrefix(prefix) {
            text = String(text.dropFirst(prefix.count))
        }
        while let first = text.first, "#>-+".contains(first) || (first == "*" && text.dropFirst().first == " ") {
            text = String(text.dropFirst()).trimmingCharacters(in: .whitespaces)
        }
        if let dot = text.firstIndex(of: "."), !text[..<dot].isEmpty, text[..<dot].allSatisfy(\.isNumber) {
            text = String(text[text.index(after: dot)...]).trimmingCharacters(in: .whitespaces)
        }
        text = text.replacingOccurrences(of: #"\[\[([^\]|]*\|)?([^\]]*)\]\]"#, with: "$2", options: .regularExpression)
        text = text.replacingOccurrences(of: #"!?\[([^\]]*)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
        text = text.replacingOccurrences(of: #"</?[A-Za-z][^>]*>"#, with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: #"(\*\*|__|\*|`|~~|==)"#, with: "", options: .regularExpression)
        text = text.trimmingCharacters(in: .whitespaces)
        return ellipsis ? "…" + text : text
    }

    /// The note of a quick pick row.
    static func path(ofQuickPickItem item: QuickPickItem) -> String? {
        guard let colon = item.id.firstIndex(of: ":") else { return nil }
        return String(item.id[item.id.index(after: colon)...])
    }
}
