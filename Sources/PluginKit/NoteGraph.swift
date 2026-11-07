import Foundation

/// A frontmatter value, encoded as the matching plain JSON value. Frozen: JSON has no other kind of value, so
/// plugins may switch over it exhaustively.
@frozen
public enum PropertyValue: Codable, Sendable, Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case list([PropertyValue])
    case map([String: PropertyValue])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([PropertyValue].self) {
            self = .list(value)
        } else {
            self = .map(try container.decode([String: PropertyValue].self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .list(let value): try container.encode(value)
        case .map(let value): try container.encode(value)
        }
    }
}

/// A link from one note to another note, as a vault-relative path.
public struct NoteLink: Codable, Sendable, Equatable {
    public let text: String
    public let target: String

    public init(text: String, target: String) {
        self.text = text
        self.target = target
    }
}

/// What the graph knows about one note.
public struct NoteInfo: Codable, Sendable, Equatable {
    public let path: String
    public let title: String
    public let properties: [String: PropertyValue]
    public let tags: [String]
    public let links: [NoteLink]

    public init(
        path: String,
        title: String,
        properties: [String: PropertyValue],
        tags: [String],
        links: [NoteLink]
    ) {
        self.path = path
        self.title = title
        self.properties = properties
        self.tags = tags
        self.links = links
    }
}

/// The note graph: titles, properties, tags, links and backlinks of every note in the vault.
public protocol NoteGraphService: AnyObject {
    var notes: [NoteInfo] { get }
    func note(at path: String) -> NoteInfo?
    /// Paths of the notes that link to `path`, sorted.
    func backlinks(to path: String) -> [String]
    /// Notes carrying `tag` (case-insensitive, without the leading `#`).
    func notes(tagged tag: String) -> [NoteInfo]
    /// Rebuilds the graph from the files on disk.
    func reindex() throws
    /// Moves notes, attachments or folders (old path to new path) and rewrites every link to them, plus
    /// the relative links inside the moved notes. Nothing changes on disk if a move is invalid.
    func move(_ moves: [String: String]) throws -> MoveResult
}

/// Sent once the note graph has read the vault after launch, from a background thread. Until then a reader of
/// the graph waits for it; a view that showed without the graph refreshes on this.
public struct NoteGraphLoaded: PluginEvent {
    public init() {}
}

/// A note graph that reads the vault after launch. While `isLoaded` is false every read of the graph waits, so a
/// view shown at launch checks it, shows without the graph and refreshes on `NoteGraphLoaded`. Apart from
/// `NoteGraphService` so plugins built against it keep working.
public protocol NoteGraphLoading: AnyObject {
    var isLoaded: Bool { get }
}

public extension ServiceKey where Service == NoteGraphService {
    static var noteGraph: ServiceKey<NoteGraphService> { ServiceKey<NoteGraphService>("note-graph") }
}
