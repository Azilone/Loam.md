import Foundation

// Collections: views over notes (a table, a board, a gallery), defined by an Obsidian Bases `.base` file or by the
// same YAML in a ` ```base ` block of a note. The entries are notes, their fields frontmatter. See docs/DESIGN.md.

/// A value of an entry, as a `.base` file names it: `status` or `note.status` (a frontmatter property),
/// `file.name`, `file.mtime`… (the file), `formula.x` (a formula, not computed by Loam).
/// Encoded as that text, the way `.base` files write it.
public struct PropertyRef: Hashable, Codable, Sendable, CustomStringConvertible {
    public enum Namespace: String, Codable, Sendable { case note, file, formula }
    public let namespace: Namespace
    public let name: String

    public init(_ namespace: Namespace, _ name: String) {
        self.namespace = namespace
        self.name = name
    }

    /// `note.x` and `x` are the property `x`; `file.x` and `formula.x` their namespace.
    public init(_ text: String) {
        let text = text.trimmingCharacters(in: .whitespaces)
        for namespace in [Namespace.note, .file, .formula] where text.hasPrefix(namespace.rawValue + ".") {
            self.init(namespace, String(text.dropFirst(namespace.rawValue.count + 1)))
            return
        }
        self.init(.note, text)
    }

    /// The entry's title, the first column of a table.
    public static let title = PropertyRef(.file, "name")

    /// The text a `.base` file writes: the bare name for a property, `file.name` for the others.
    public var description: String { namespace == .note ? name : namespace.rawValue + "." + name }

    public init(from decoder: Decoder) throws {
        self.init(try decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }
}

/// What a field holds, which decides how a view shows and edits it. Stored as `type:` under the field in the
/// `.base` (a Loam key); inferred from the values when missing.
public enum PropertyKind: String, Codable, Sendable, CaseIterable {
    case text, number, checkbox, date, url, select, multiselect
}

/// A field's settings in the collection (`properties.<name>` of the `.base`).
public struct CollectionProperty: Codable, Sendable, Equatable {
    public var ref: PropertyRef
    public var displayName: String?
    public var kind: PropertyKind?
    /// The ordered choices of a select or multiselect: a board's columns, in order; their colours follow the order.
    public var options: [String]

    public init(ref: PropertyRef, displayName: String? = nil, kind: PropertyKind? = nil, options: [String] = []) {
        self.ref = ref
        self.displayName = displayName
        self.kind = kind
        self.options = options
    }
}

/// One sort level, or a board's grouping (`{property, direction}` in the `.base`).
public struct CollectionSort: Codable, Sendable, Equatable {
    public var property: PropertyRef
    public var descending: Bool

    public init(property: PropertyRef, descending: Bool = false) {
        self.property = property
        self.descending = descending
    }
}

/// One view of a collection (an item of `views:`). `type` picks the plugin that draws it (`table`, `kanban`,
/// `cards`, a third party's); `options` holds every other key as written (`image`, `columnSize`, a plugin's own).
public struct CollectionViewConfig: Codable, Sendable, Equatable {
    public var type: String
    public var name: String
    /// The fields shown, in order.
    public var order: [PropertyRef]
    public var sort: [CollectionSort]
    public var groupBy: CollectionSort?
    public var limit: Int?
    public var options: [String: PropertyValue]

    public init(
        type: String,
        name: String,
        order: [PropertyRef] = [],
        sort: [CollectionSort] = [],
        groupBy: CollectionSort? = nil,
        limit: Int? = nil,
        options: [String: PropertyValue] = [:]
    ) {
        self.type = type
        self.name = name
        self.order = order
        self.sort = sort
        self.groupBy = groupBy
        self.limit = limit
        self.options = options
    }
}

/// Where a collection's YAML lives: a `.base` file, or a ` ```base ` block in the note `host` (whose `this` it is).
public enum CollectionSource: Codable, Hashable, Sendable {
    case file(String)
    case inline(yaml: String, host: String?)
}

/// A collection as read from its YAML.
public struct CollectionDefinition: Codable, Sendable, Equatable {
    public let source: CollectionSource
    /// The `.base` file's name, or "Collection" for a block.
    public let name: String
    /// Where new entries go: the folder of the filter's `file.inFolder(...)`; nil sends them to the Inbox.
    public let home: String?
    public let properties: [CollectionProperty]
    public let views: [CollectionViewConfig]
    /// What Loam could not read (unknown filter functions, formulas); entries it cannot decide on are shown.
    public let warnings: [String]

    public init(
        source: CollectionSource,
        name: String,
        home: String?,
        properties: [CollectionProperty],
        views: [CollectionViewConfig],
        warnings: [String] = []
    ) {
        self.source = source
        self.name = name
        self.home = home
        self.properties = properties
        self.views = views
        self.warnings = warnings
    }

    /// A field's settings, with defaults when the `.base` has none.
    public func property(_ ref: PropertyRef) -> CollectionProperty {
        properties.first { $0.ref == ref } ?? CollectionProperty(ref: ref)
    }
}

/// The entries of one value of a board's grouping, in the view's order. `value` nil holds the entries without one.
public struct CollectionGroup: Codable, Sendable, Equatable {
    public let value: PropertyValue?
    public let entries: [NoteRecord]

    public init(value: PropertyValue?, entries: [NoteRecord]) {
        self.value = value
        self.entries = entries
    }
}

/// What one view shows: its entries, filtered, sorted and limited.
public struct CollectionResult: Codable, Sendable, Equatable {
    public let view: CollectionViewConfig
    public let entries: [NoteRecord]
    /// With a `groupBy`: the select's options in order (empty ones too), then other values found, then the
    /// entries without a value (only when there are some).
    public let groups: [CollectionGroup]?
    /// Each shown field's kind (declared, else inferred), by `PropertyRef.description`.
    public let kinds: [String: PropertyKind]
    public let warnings: [String]

    public init(
        view: CollectionViewConfig,
        entries: [NoteRecord],
        groups: [CollectionGroup]?,
        kinds: [String: PropertyKind],
        warnings: [String] = []
    ) {
        self.view = view
        self.entries = entries
        self.groups = groups
        self.kinds = kinds
        self.warnings = warnings
    }
}

/// A change to a collection's YAML. Keys Loam does not know are kept.
public enum CollectionEdit: Codable, Sendable, Equatable {
    case addView(type: String, name: String)
    case removeView(name: String)
    case renameView(name: String, to: String)
    case moveView(name: String, to: Int)
    case setOrder(view: String, order: [PropertyRef])
    case setSort(view: String, sort: [CollectionSort])
    case setGroupBy(view: String, groupBy: CollectionSort?)
    case setLimit(view: String, limit: Int?)
    case setViewOption(view: String, key: String, value: PropertyValue?)
    case setProperty(property: CollectionProperty)
    case removeProperty(ref: PropertyRef)
    /// Adds an expression to the global filter (`view` nil) or a view's, joined with `and`.
    case addFilter(view: String?, expression: String)
    case removeFilter(view: String?, expression: String)
}

public enum CollectionError: Error, Equatable {
    case notACollection(String)
    case invalidYAML(String)
    case unknownView(String)
    case invalidArgument(String)
}

/// Collections over the notes: read one, run its views, edit it.
public protocol CollectionService: AnyObject {
    /// Every `.base` file of the vault, sorted.
    func collections() -> [String]
    func definition(_ source: CollectionSource) throws -> CollectionDefinition
    /// The `.base` files whose notes include the note at `path` (by their global filter, not a view's), the one
    /// nearest to the note first: the collections whose fields the note shows under its title.
    func collections(containing path: String) -> [String]
    /// One view's entries (`view` by name; nil is the first view, or a table of every field when there is none).
    func entries(_ source: CollectionSource, view: String?) throws -> CollectionResult
    /// Turns a folder into a collection: writes `<folder>/<name>.base` with a table of its notes, or returns the
    /// existing one. Returns its path.
    func create(folder: String) throws -> String
    /// Applies edits and writes the file. For a block, returns `.inline` with the new YAML for the editor to write.
    func apply(_ edits: [CollectionEdit], to source: CollectionSource) throws -> CollectionSource
    /// Writes a new note in the collection's home folder, with `values` and what the filter asks for (its tags,
    /// its `x == "v"` conditions), so the note shows in the collection. Returns its path.
    func newEntry(in source: CollectionSource, title: String?, values: [String: PropertyValue]) throws -> String
}

public extension ServiceKey where Service == CollectionService {
    static var collections: ServiceKey<CollectionService> { ServiceKey<CollectionService>("collections") }
}
