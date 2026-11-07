import Foundation

/// The public list of themes anyone can install by id (docs/THEMES.md): `themes.json` in the community repository,
/// next to a `themes/<id>.json` file per theme, changed by pull request.
///
///     { "themes": [ { "id": "paper", "name": "Paper", "author": "loam", "description": "…", "version": "1.0.0",
///       "appearance": "auto" } ] }
public struct ThemeCatalog: Codable, Equatable, Sendable {
    public struct Entry: Codable, Equatable, Sendable, Identifiable {
        public var id: String
        public var name: String
        public var author: String?
        public var description: String?
        public var version: String?
        /// `light`, `dark` or `auto`, as in the theme file.
        public var appearance: String?

        public init(id: String, name: String, author: String? = nil, description: String? = nil, version: String? = nil,
                    appearance: String? = nil) {
            self.id = id
            self.name = name
            self.author = author
            self.description = description
            self.version = version
            self.appearance = appearance
        }

        /// Whether `query` (lowercased) is in its id, name, author or description.
        public func matches(_ query: String) -> Bool {
            query.isEmpty || [id, name, author ?? "", description ?? ""].contains { $0.lowercased().contains(query) }
        }
    }

    public var themes: [Entry]

    public init(themes: [Entry]) { self.themes = themes }

    public func entry(_ id: String) -> Entry? { themes.first { $0.id == id } }

    /// The catalog's address: `LOAM_THEME_CATALOG` when set (a URL or a path), else the public one.
    public static var defaultURL: URL {
        if let value = ProcessInfo.processInfo.environment["LOAM_THEME_CATALOG"], let url = url(value) { return url }
        return URL(string: "https://raw.githubusercontent.com/Azilone/loam-community/main/themes.json")!
    }

    /// A catalog given as a URL or a path; nil when empty.
    public static func url(_ value: String) -> URL? {
        value.isEmpty ? nil : value.contains("://") ? URL(string: value) : URL(fileURLWithPath: value)
    }

    /// Whether `id` can name a file: lowercase letters, digits, `-` and `_`, so a catalog cannot write outside
    /// `.loam/themes/`.
    public static func isValidID(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 64 && id.allSatisfy { ($0.isASCII && ($0.isLowercase || $0.isNumber)) || $0 == "-" || $0 == "_" }
    }

    /// Where the theme `id` of the catalog at `catalog` is: `themes/<id>.json` next to the catalog file.
    public static func themeURL(id: String, catalog: URL = defaultURL) -> URL {
        catalog.deletingLastPathComponent().appendingPathComponent("themes").appendingPathComponent("\(id).json")
    }

    /// Reads the catalog at `url` (https or a file).
    public static func fetch(_ url: URL = defaultURL) async throws -> ThemeCatalog {
        let data = try await download(url, what: "the theme catalog")
        do {
            return try JSONDecoder().decode(ThemeCatalog.self, from: data)
        } catch {
            throw ThemeCatalogError.unreadable("the theme catalog \(url.absoluteString) cannot be read: \(error)")
        }
    }

    /// The file of the theme `id` of the catalog at `catalog`, not checked: the app decodes it as a theme.
    public static func fetchTheme(id: String, catalog: URL = defaultURL) async throws -> Data {
        guard isValidID(id) else { throw ThemeCatalogError.unreadable("“\(id)” is not a theme id") }
        return try await download(themeURL(id: id, catalog: catalog), what: "the theme \(id)")
    }

    private static func download(_ url: URL, what: String) async throws -> Data {
        if url.isFileURL {
            do {
                return try Data(contentsOf: url)
            } catch {
                throw ThemeCatalogError.unreadable("\(what) cannot be read at \(url.path)")
            }
        }
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 20
        let (body, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw ThemeCatalogError.unreadable("\(what) at \(url.absoluteString) answered \(http.statusCode)")
        }
        return body
    }
}

public enum ThemeCatalogError: Error, Equatable, LocalizedError {
    case unreadable(String)

    public var errorDescription: String? {
        switch self {
        case .unreadable(let reason): reason
        }
    }
}
