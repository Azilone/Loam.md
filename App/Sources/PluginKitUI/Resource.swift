/// What a view shows: a file or folder in the vault, or a virtual page such as `calendar:2026-10`.
///
/// Plugins name resources instead of views so the shell decides how to show them (which view type, which pane).
public struct Resource: Hashable, Codable, Sendable {
    public enum Kind: String, Codable, Sendable { case file, folder, virtual }

    public let kind: Kind
    /// A vault-relative path, or `scheme:rest` for a virtual resource.
    public let path: String

    public init(kind: Kind, path: String) {
        self.kind = kind
        self.path = path
    }

    public static func file(_ path: String) -> Resource { Resource(kind: .file, path: path) }
    public static func folder(_ path: String) -> Resource { Resource(kind: .folder, path: path) }
    public static func virtual(_ uri: String) -> Resource { Resource(kind: .virtual, path: uri) }

    /// The page of every file `viewType` opens first, as "All Notes" is the page of every note (the drawings, the
    /// boards): `notes:<title>#<viewType>`. The file explorer shows it; `title` names it and its tab.
    public static func notes(titled title: String, openedBy viewType: String) -> Resource {
        .virtual("notes:\(title)#\(viewType)")
    }

    /// The view type of a page made by `notes(titled:openedBy:)`, nil for any other resource.
    public var notesViewType: String? {
        guard kind == .virtual, path.hasPrefix("notes:"), let hash = path.firstIndex(of: "#") else { return nil }
        return String(path[path.index(after: hash)...])
    }

    /// The lowercased extension of a file, used to pick a view type. Folders and virtual pages have none.
    public var pathExtension: String {
        guard kind == .file else { return "" }
        let last = lastComponent
        guard let dot = last.lastIndex(of: "."), dot != last.startIndex else { return "" }
        return last[last.index(after: dot)...].lowercased()
    }

    /// A short title for a tab: the last path component without its extension (`.md`, `.canvas`), or what follows
    /// the scheme of a virtual page, without its `#fragment`.
    public var name: String {
        switch kind {
        case .virtual:
            guard let colon = path.firstIndex(of: ":") else { return path }
            var rest = String(path[path.index(after: colon)...])
            if let hash = rest.firstIndex(of: "#") { rest = String(rest[..<hash]) }
            let scheme = path[..<colon].capitalized
            // `calendar:` alone names the page by its scheme: "Calendar".
            if rest.isEmpty { return scheme }
            // A page about a note (`kanban:Boards/Projects.md`) is named after the note, then the scheme.
            if rest.contains("/") || rest.lowercased().hasSuffix(".md") {
                let file = rest.split(separator: "/").last.map(String.init) ?? rest
                return "\(Self.stem(file)) · \(scheme)"
            }
            return rest
        case .folder:
            return lastComponent
        case .file:
            return Self.stem(lastComponent)
        }
    }

    /// A file name without its extension; a name starting with its only dot (`.env`) is kept whole.
    private static func stem(_ name: String) -> String {
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return name }
        return String(name[..<dot])
    }

    private var lastComponent: String {
        let trimmed = path.hasSuffix("/") ? String(path.dropLast()) : path
        return trimmed.split(separator: "/", omittingEmptySubsequences: false).last.map(String.init) ?? trimmed
    }
}

/// Where to open a resource. A hint: a shell without splits treats `.beside` as `.newTab`.
public enum Placement: String, Codable, Sendable { case replace, newTab, beside }
