import Foundation

/// What a web address is, to show it well on a board: a video (YouTube, Vimeo), a post (X, LinkedIn…), a PDF, or a
/// page. Known from the address alone, before anything is fetched.
public enum CanvasLinkKind: Equatable, Sendable {
    /// A YouTube video, by id: its picture and player need no page to be read.
    case youtube(id: String)
    case vimeo
    /// A post on X (Twitter), read through X's oEmbed.
    case tweet
    case pdf
    case page

    public init(_ url: URL) {
        var host = (url.host() ?? "").lowercased()
        for prefix in ["www.", "m.", "mobile."] where host.hasPrefix(prefix) { host.removeFirst(prefix.count) }
        let parts = url.pathComponents.filter { $0 != "/" }
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        switch host {
        case "youtube.com", "music.youtube.com":
            if let id = query.first(where: { $0.name == "v" })?.value, !id.isEmpty {
                self = .youtube(id: id)
            } else if parts.count >= 2, ["shorts", "embed", "live"].contains(parts[0]) {
                self = .youtube(id: parts[1])
            } else {
                self = .page
            }
        case "youtu.be":
            self = parts.first.map { .youtube(id: $0) } ?? .page
        case "vimeo.com":
            self = parts.first.map { Int($0) != nil } == true ? .vimeo : .page
        case "twitter.com", "x.com":
            self = parts.count >= 3 && parts[1] == "status" ? .tweet : .page
        default:
            self = url.pathExtension.lowercased() == "pdf" ? .pdf : .page
        }
    }

    /// The size a new card for this kind gets: a video is 16:9 with a line for its title.
    public var cardSize: (width: Double, height: Double) {
        switch self {
        case .youtube, .vimeo: return (480, 330)
        case .tweet: return (400, 280)
        case .pdf: return (360, 466)
        case .page: return CanvasDocument.linkSize
        }
    }

    /// What plays or shows the link inside its card once it is entered.
    public func embedURL(for url: URL) -> URL {
        switch self {
        case .youtube(let id): return URL(string: "https://www.youtube-nocookie.com/embed/\(id)?autoplay=1&rel=0") ?? url
        default: return url
        }
    }
}

/// What a link card shows of the page behind it: its Open Graph (or Twitter card) title, description, picture and
/// site, read from the page's HTML; for a post on X, its text and author from X's oEmbed.
public struct CanvasLinkPreview: Codable, Equatable, Sendable {
    public var title: String?
    public var summary: String?
    public var image: URL?
    public var site: String?
    public var icon: URL?
    /// For a post: who wrote it.
    public var author: String?

    public init(title: String? = nil, summary: String? = nil, image: URL? = nil, site: String? = nil, icon: URL? = nil,
                author: String? = nil) {
        self.title = title
        self.summary = summary
        self.image = image
        self.site = site
        self.icon = icon
        self.author = author
    }

    /// What can be known without fetching: a YouTube video's picture.
    public static func offline(_ url: URL) -> CanvasLinkPreview? {
        guard case .youtube(let id) = CanvasLinkKind(url) else { return nil }
        return CanvasLinkPreview(image: URL(string: "https://i.ytimg.com/vi/\(id)/hqdefault.jpg"), site: "YouTube")
    }

    /// The preview of a page from its HTML (only the head matters). Relative addresses are resolved against `url`.
    public init(html: String, url: URL) {
        let head = String(html.prefix(400_000))
        var meta: [String: String] = [:]
        var icon: String?
        var rest = Substring(head)
        while let open = rest.range(of: "<") {
            guard let close = rest[open.upperBound...].range(of: ">") else { break }
            let tag = rest[open.upperBound..<close.lowerBound]
            rest = rest[close.upperBound...]
            let lower = tag.prefix(5).lowercased()
            if lower.hasPrefix("meta") {
                let attributes = Self.attributes(String(tag))
                if let key = (attributes["property"] ?? attributes["name"] ?? attributes["itemprop"])?.lowercased(),
                   let content = attributes["content"], meta[key] == nil {
                    meta[key] = content
                }
            } else if lower.hasPrefix("link") {
                let attributes = Self.attributes(String(tag))
                let rel = attributes["rel"]?.lowercased() ?? ""
                if rel.split(separator: " ").contains(where: { $0 == "icon" || $0 == "apple-touch-icon" }),
                   let href = attributes["href"], icon == nil || rel.contains("apple-touch-icon") {
                    icon = href
                }
            } else if lower.hasPrefix("/head") || lower.hasPrefix("body") {
                break
            }
        }
        var pageTitle: String?
        if let start = head.range(of: "<title", options: .caseInsensitive),
           let open = head[start.upperBound...].range(of: ">"),
           let end = head[open.upperBound...].range(of: "</title>", options: .caseInsensitive) {
            pageTitle = String(head[open.upperBound..<end.lowerBound])
        }
        func clean(_ value: String?) -> String? {
            guard let value else { return nil }
            let text = Self.decodeEntities(value).trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : text
        }
        func address(_ value: String?) -> URL? {
            guard let value = clean(value) else { return nil }
            return URL(string: value, relativeTo: url)?.absoluteURL
        }
        self.init(
            title: clean(meta["og:title"] ?? meta["twitter:title"] ?? pageTitle),
            summary: clean(meta["og:description"] ?? meta["twitter:description"] ?? meta["description"]),
            image: address(meta["og:image"] ?? meta["og:image:url"] ?? meta["twitter:image"] ?? meta["twitter:image:src"]),
            site: clean(meta["og:site_name"]) ?? url.host()?.replacingOccurrences(of: "www.", with: ""),
            icon: address(icon) ?? URL(string: "/favicon.ico", relativeTo: url)?.absoluteURL
        )
    }

    /// A post on X from the JSON of `publish.twitter.com/oembed`: its text and author.
    public init?(tweetOEmbed data: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let html = object["html"] as? String else { return nil }
        // The post's text is the first paragraph of the blockquote.
        var text = html
        if let start = html.range(of: "<p"), let open = html[start.upperBound...].range(of: ">"),
           let end = html[open.upperBound...].range(of: "</p>") {
            text = String(html[open.upperBound..<end.lowerBound])
        }
        text = text.replacingOccurrences(of: "<br>", with: "\n")
        while let tag = text.range(of: "<[^>]*>", options: .regularExpression) { text.removeSubrange(tag) }
        self.init(title: object["author_name"] as? String,
                  summary: Self.decodeEntities(text).trimmingCharacters(in: .whitespacesAndNewlines),
                  site: "X", author: (object["author_url"] as? String).flatMap { URL(string: $0)?.lastPathComponent }
                      .map { "@" + $0 })
    }

    /// Where X's oEmbed describes a post.
    public static func tweetOEmbed(for url: URL) -> URL? {
        var components = URLComponents(string: "https://publish.twitter.com/oembed")
        components?.queryItems = [URLQueryItem(name: "url", value: url.absoluteString),
                                  URLQueryItem(name: "omit_script", value: "1"), URLQueryItem(name: "dnt", value: "1")]
        return components?.url
    }

    static func attributes(_ tag: String) -> [String: String] {
        var result: [String: String] = [:]
        let pattern = #"([A-Za-z_:\-]+)\s*=\s*("([^"]*)"|'([^']*)')"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return result }
        let range = NSRange(tag.startIndex..., in: tag)
        for match in regex.matches(in: tag, range: range) {
            guard let key = Range(match.range(at: 1), in: tag) else { continue }
            let value = Range(match.range(at: 3), in: tag) ?? Range(match.range(at: 4), in: tag)
            result[tag[key].lowercased()] = value.map { String(tag[$0]) } ?? ""
        }
        return result
    }

    static func decodeEntities(_ text: String) -> String {
        var out = text
        for (entity, character) in [("&amp;", "&"), ("&quot;", "\""), ("&#39;", "'"), ("&#x27;", "'"), ("&apos;", "'"),
                                    ("&lt;", "<"), ("&gt;", ">"), ("&nbsp;", " "), ("&mdash;", "—"), ("&ndash;", "–"),
                                    ("&hellip;", "…"), ("&rsquo;", "’"), ("&lsquo;", "‘"), ("&ldquo;", "“"), ("&rdquo;", "”")] {
            out = out.replacingOccurrences(of: entity, with: character)
        }
        // Numeric entities left: &#123; and &#x1F600;.
        while let range = out.range(of: "&#x?[0-9A-Fa-f]+;", options: .regularExpression) {
            let body = out[range].dropFirst(2).dropLast()
            let value = body.hasPrefix("x") || body.hasPrefix("X") ? UInt32(body.dropFirst(), radix: 16) : UInt32(body)
            out.replaceSubrange(range, with: value.flatMap(Unicode.Scalar.init).map { String($0) } ?? "")
        }
        return out
    }
}
