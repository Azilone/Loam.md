import Foundation

/// Which notes to find and in what order: the shared base of tasks, Kanban and other views over notes.
/// `Codable`, so commands and agents pass it as JSON; every field may be left out of the JSON.
///
/// Matching rules (`NoteQueryService` implementations follow them):
/// - `folder`: notes anywhere under that vault-relative folder; nil or `""` is the whole vault.
/// - `tags`: every tag must be on the note, compared without `#` and ignoring case; a nested tag counts for its
///   parent (`project` matches `#project/home`).
/// - `filters`: every filter must match (see `PropertyFilter`).
/// - `sort`: keys in order; ties keep the vault order (by path), so sorting is stable. Default: title ascending.
/// - `limit`: at most that many notes, after sorting.
public struct NoteQuery: Codable, Sendable, Equatable {
    public var folder: String?
    public var tags: [String]
    public var filters: [PropertyFilter]
    public var sort: [SortKey]
    public var limit: Int?

    public init(
        folder: String? = nil,
        tags: [String] = [],
        filters: [PropertyFilter] = [],
        sort: [SortKey] = [],
        limit: Int? = nil
    ) {
        self.folder = folder
        self.tags = tags
        self.filters = filters
        self.sort = sort
        self.limit = limit
    }

    private enum CodingKeys: String, CodingKey { case folder, tags, filters, sort, limit }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        folder = try container.decodeIfPresent(String.self, forKey: .folder)
        tags = try container.decodeIfPresent([String].self, forKey: .tags) ?? []
        filters = try container.decodeIfPresent([PropertyFilter].self, forKey: .filters) ?? []
        sort = try container.decodeIfPresent([SortKey].self, forKey: .sort) ?? []
        limit = try container.decodeIfPresent(Int.self, forKey: .limit)
    }
}

/// A condition on one frontmatter property (keys are matched exactly, then ignoring case).
///
/// - `exists`: the property is there and not null; `missing`: absent or null.
/// - `equals` / `notEquals`: strings ignore case; numbers compare numerically, also against a numeric string;
///   booleans also against `"true"` / `"false"`; lists and maps compare element by element. `notEquals` matches
///   notes without the property.
/// - `contains`: a list holds an element `equals` the value; a string holds the value as a substring, ignoring case.
/// - `lessThan` / `greaterThan`: numbers numerically, strings lexically ignoring case (so ISO dates such as
///   `2026-10-18` compare by date). A missing property, a list or a map never matches.
public struct PropertyFilter: Codable, Sendable, Equatable {
    public enum Op: String, Codable, Sendable {
        case exists, missing, equals, notEquals, contains, lessThan, greaterThan
    }

    public var key: String
    public var op: Op
    public var value: PropertyValue?

    public init(key: String, op: Op, value: PropertyValue? = nil) {
        self.key = key
        self.op = op
        self.value = value
    }
}

/// One sort level. `key` is a frontmatter property, or one of the reserved names `title`, `path` and `modified`
/// (the note's title, path and modification time), which win over a property of the same name. Notes missing the
/// value come last, in both directions.
public struct SortKey: Codable, Sendable, Equatable {
    public var key: String
    public var descending: Bool

    public init(key: String, descending: Bool = false) {
        self.key = key
        self.descending = descending
    }

    private enum CodingKeys: String, CodingKey { case key, descending }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        key = try container.decode(String.self, forKey: .key)
        descending = try container.decodeIfPresent(Bool.self, forKey: .descending) ?? false
    }
}

/// A note a query found. `modified` is the file's modification time (seconds since 1970).
public struct NoteRecord: Codable, Sendable, Equatable {
    public let path: String
    public let title: String
    public let properties: [String: PropertyValue]
    public let tags: [String]
    public let modified: Double

    public init(path: String, title: String, properties: [String: PropertyValue], tags: [String], modified: Double) {
        self.path = path
        self.title = title
        self.properties = properties
        self.tags = tags
        self.modified = modified
    }
}

public enum NoteQueryError: Error, Equatable {
    /// A property key that is empty or spans lines.
    case invalidKey(String)
    /// A command argument that is not valid JSON of the expected shape.
    case invalidArgument(name: String)
}

/// Finds notes by folder, tag and property, and edits one property in place.
public protocol NoteQueryService: AnyObject {
    func run(_ query: NoteQuery) -> [NoteRecord]
    /// Distinct values of a property across the notes the query matches (for Kanban columns, filters).
    /// List values count element by element; nulls are left out; strings that differ only in case count once.
    /// Sorted ascending with the `SortKey` rules.
    func values(of key: String, in query: NoteQuery) -> [PropertyValue]
    /// Sets (or removes, with nil) one frontmatter property of a note, keeping the rest of the file byte-for-byte
    /// where possible (other keys, their order, comments, the body). Creates the frontmatter if missing.
    /// Throws `VaultError.notFound` for a path that is not an existing note.
    func setProperty(_ key: String, to value: PropertyValue?, in path: String) throws
}

public extension ServiceKey where Service == NoteQueryService {
    static var noteQuery: ServiceKey<NoteQueryService> { ServiceKey<NoteQueryService>("note-query") }
}
