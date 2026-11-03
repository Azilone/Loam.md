import Foundation
import PluginKit

/// Something that answers Truffle requests: the real `TruffleClient`, or a stand-in in tests.
public protocol TruffleTransport: Sendable {
    func request(_ request: [String: Any]) throws -> [String: Any]
}

/// The `search` service: the built-in scan of the vault for names and content, light and always there. Truffle is
/// only asked when one is given (off in the app for now: its daemon indexes the whole Mac); it then also brings
/// search by meaning. Thread-safe; every call blocks.
public final class VaultSearchService: SearchService, @unchecked Sendable {
    private let truffle: TruffleTransport?
    private let builtin: BuiltinSearch
    /// The vault's absolute path, to scope Truffle's searches and turn its paths into vault-relative ones.
    private let root: String

    /// - Parameter truffle: nil for the built-in search alone; `TruffleClient(timeoutSeconds:)` for the daemon.
    public init(vault: VaultAccess, truffle: TruffleTransport? = nil) {
        self.truffle = truffle
        self.builtin = BuiltinSearch(vault: vault)
        self.root = vault.rootURL.standardizedFileURL.path
    }

    /// The host calls `vaultChanged` on every `VaultChanged` from now on, so the built-in search walks the vault once
    /// per change instead of once per keystroke.
    public func followChanges() {
        builtin.followsChanges = true
    }

    public func vaultChanged() {
        builtin.vaultChanged()
    }

    public func status() -> SearchStatus {
        guard let truffle else {
            return SearchStatus(
                truffleRunning: false,
                truffleReady: false,
                message: "Built-in search: names and content. Search by meaning is off."
            )
        }
        do {
            let reply = try truffle.request(["op": "status"])
            let entries = reply["entries"] as? Int
            return SearchStatus(
                truffleRunning: true,
                truffleReady: true,
                indexedFiles: entries,
                message: "Truffle is running" + (entries.map { ": \($0) files indexed." } ?? ".")
            )
        } catch TruffleError.daemon(let message) {
            // It answers, but cannot serve yet (usually its first index).
            return SearchStatus(truffleRunning: true, truffleReady: false, message: "Truffle is starting: \(message)")
        } catch {
            return SearchStatus(
                truffleRunning: false,
                truffleReady: false,
                message: "Truffle is not running: names and content use the built-in search; meaning needs Truffle. "
                    + SearchError.installHint
            )
        }
    }

    public func search(_ query: String, kind: SearchKind, limit: Int) throws -> [SearchHit] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { throw SearchError.emptyQuery }
        switch kind {
        case .names:
            do { return try truffleNames(query, limit: limit) } catch is TruffleError {}
            return try builtin.names(query, limit: limit)
        case .content:
            do { return try truffleContent(query, limit: limit) } catch is TruffleError {}
            return try builtin.content(query, limit: limit)
        case .meaning:
            guard truffle != nil else { throw SearchError.notRunning }
            do {
                return try truffleMeaning(query, limit: limit)
            } catch TruffleError.daemonNotRunning {
                throw SearchError.notRunning
            }
        }
    }

    // MARK: Truffle

    /// The daemon, or `daemonNotRunning` when this service has none, so callers fall back as for a stopped daemon.
    private func daemon() throws -> TruffleTransport {
        guard let truffle else { throw TruffleError.daemonNotRunning(socket: "") }
        return truffle
    }

    private func truffleNames(_ query: String, limit: Int) throws -> [SearchHit] {
        let request: [String: Any] = ["op": "search", "q": query, "in": root, "limit": limit]
        let reply = try daemon().request(request)
        let hits = (reply["hits"] as? [[String: Any]] ?? []).compactMap { hit -> SearchHit? in
            guard let path = relative(hit["path"]), !isDirectory(path) else { return nil }
            return SearchHit(path: path, title: BuiltinSearch.title(of: path), score: number(hit["score"]))
        }
        return Array(hits.prefix(max(limit, 0)))
    }

    private func truffleContent(_ query: String, limit: Int) throws -> [SearchHit] {
        let request: [String: Any] = [
            "op": "grep", "pattern": query, "in": root, "limit": limit, "per_file": BuiltinSearch.maxLinesPerNote,
        ]
        let reply = try daemon().request(request)
        var hits: [SearchHit] = []
        for file in reply["files"] as? [[String: Any]] ?? [] {
            guard let path = relative(file["path"]) else { continue }
            for match in (file["matches"] as? [[String: Any]] ?? []).prefix(BuiltinSearch.maxLinesPerNote) {
                let text = (match["text"] as? String) ?? ""
                let snippet = text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive])
                    .map { BuiltinSearch.snippet(text, around: $0) } ?? text.trimmingCharacters(in: .whitespaces)
                hits.append(SearchHit(
                    path: path, title: BuiltinSearch.title(of: path), snippet: snippet, line: match["line"] as? Int
                ))
                if hits.count >= limit { return hits }
            }
        }
        return hits
    }

    /// Meaning search covers whatever Truffle indexed; hits outside the vault are dropped.
    private func truffleMeaning(_ query: String, limit: Int) throws -> [SearchHit] {
        let request: [String: Any] = ["op": "meaning.search", "q": query, "limit": limit]
        let reply = try daemon().request(request)
        let hits = (reply["hits"] as? [[String: Any]] ?? []).compactMap { hit -> SearchHit? in
            guard let path = relative(hit["path"]) else { return nil }
            let excerpt = (hit["excerpt"] as? String)?
                .replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespaces)
            return SearchHit(
                path: path,
                title: BuiltinSearch.title(of: path),
                snippet: excerpt.flatMap { $0.isEmpty ? nil : String($0.prefix(BuiltinSearch.snippetLength)) },
                line: hit["line"] as? Int,
                score: number(hit["score"])
            )
        }
        return Array(hits.prefix(max(limit, 0)))
    }

    /// The vault-relative path of an absolute path Truffle returned, nil outside the vault.
    private func relative(_ value: Any?) -> String? {
        guard let path = value as? String, path.hasPrefix(root + "/") else { return nil }
        return String(path.dropFirst(root.count + 1))
    }

    private func isDirectory(_ path: String) -> Bool {
        var directory: ObjCBool = false
        return FileManager.default.fileExists(atPath: root + "/" + path, isDirectory: &directory) && directory.boolValue
    }

    private func number(_ value: Any?) -> Double? {
        if let value = value as? Int { return Double(value) }
        return value as? Double
    }
}
