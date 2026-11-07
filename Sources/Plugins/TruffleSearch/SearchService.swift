import Foundation
import PluginKit

/// Search the vault by file name, by content or by meaning.
///
/// Declared here rather than in PluginKit because its only other user is the Search panel (`SearchUI`), which may
/// import this logic module. Other plugins and agents reach the same behaviour through the `search.*` commands.
///
/// Names and content use the Truffle daemon when it runs and a built-in scan of the vault's Markdown files when it
/// does not; meaning needs Truffle. Calls block (a socket round trip or a vault scan), so a UI calls them off the
/// main thread.
public protocol SearchService: AnyObject, Sendable {
    /// Whether Truffle is running, and what it has indexed. Never throws: a daemon that is down is a status.
    func status() -> SearchStatus
    /// At most `limit` hits for `query`, best first. Content hits are one per matching line (a few per note at
    /// most); name and meaning hits one per file. Paths are vault-relative. Throws `SearchError.notRunning` for
    /// `.meaning` without Truffle, `SearchError.emptyQuery` for a blank query.
    func search(_ query: String, kind: SearchKind, limit: Int) throws -> [SearchHit]
}

public extension ServiceKey where Service == SearchService {
    static var search: ServiceKey<SearchService> { ServiceKey<SearchService>("search") }
}

public enum SearchKind: String, Codable, Sendable, CaseIterable {
    /// Fuzzy match on file names.
    case names
    /// Case-insensitive text match in the notes, with the matching line.
    case content
    /// By what the notes say, in any language. Needs Truffle.
    case meaning
}

/// One result. For content, one matching line of a note.
public struct SearchHit: Codable, Sendable, Equatable, Hashable {
    /// Vault-relative path.
    public let path: String
    /// The file name without its extension.
    public let title: String?
    /// The text around the match (content), or the passage that matched (meaning).
    public let snippet: String?
    /// 1-based line of the match, for content.
    public let line: Int?
    /// Higher is better; only the order within one search means anything.
    public let score: Double?

    public init(path: String, title: String? = nil, snippet: String? = nil, line: Int? = nil, score: Double? = nil) {
        self.path = path
        self.title = title
        self.snippet = snippet
        self.line = line
        self.score = score
    }
}

/// What `SearchService.status()` found.
public struct SearchStatus: Codable, Sendable, Equatable {
    /// The Truffle daemon answers on its socket. Search by meaning needs it.
    public let truffleRunning: Bool
    /// Truffle has finished its first index (false while it starts, or when it is not running).
    public let truffleReady: Bool
    /// Files in Truffle's index, when it says.
    public let indexedFiles: Int?
    /// One line for a person: what works and what to do.
    public let message: String

    public init(truffleRunning: Bool, truffleReady: Bool, indexedFiles: Int? = nil, message: String) {
        self.truffleRunning = truffleRunning
        self.truffleReady = truffleReady
        self.indexedFiles = indexedFiles
        self.message = message
    }

    /// Names and content always work (built-in fallback); meaning only with Truffle.
    public func supports(_ kind: SearchKind) -> Bool {
        kind != .meaning || truffleRunning
    }
}

public enum SearchError: Error, Equatable {
    /// Search by meaning without the Truffle daemon.
    case notRunning
    case emptyQuery
}

extension SearchError: LocalizedError {
    public static let truffleURL = "https://github.com/Azilone/truffle"
    public static let installHint = "Install Truffle with `brew install azilone/tap/truffle`, run `truffle setup`, "
        + "or start `truffle serve` (\(truffleURL))."

    public var errorDescription: String? {
        switch self {
        case .notRunning: return "Search by meaning needs Truffle running. " + Self.installHint
        case .emptyQuery: return "Type something to search for."
        }
    }
}
