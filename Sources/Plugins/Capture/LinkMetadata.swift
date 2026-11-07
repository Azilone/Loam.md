import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// What a web page says about itself: its title, description and preview picture (`og:` tags, else `<title>` and
/// the description meta), and its readable text for the agent. Parsing is plain string work, testable offline.
public struct LinkMetadata: Codable, Sendable, Equatable {
    public var title: String?
    public var description: String?
    /// Absolute URL of the preview picture.
    public var image: String?
    /// The page's words without tags, scripts or styles, cut at `textLimit`.
    public var text: String

    public static let textLimit = 12_000

    public init(title: String? = nil, description: String? = nil, image: String? = nil, text: String = "") {
        self.title = title
        self.description = description
        self.image = image
        self.text = text
    }

    /// Reads the page, 8 s at most. Nil when it cannot be read (offline, not HTML): the capture stays a plain link.
    public static func fetch(_ url: URL, session: URLSession = .shared) async -> LinkMetadata? {
        var request = URLRequest(url: url, timeoutInterval: 8)
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15", forHTTPHeaderField: "User-Agent")
        request.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return nil }
        let type = http.value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? "text/html"
        guard type.contains("html") else { return nil }
        let html = String(decoding: data.prefix(3_000_000), as: UTF8.self)
        return parse(html, base: http.url ?? url)
    }

    /// Downloads a picture, 5 MB at most.
    public static func download(_ url: URL, session: URLSession = .shared) async -> Data? {
        let request = URLRequest(url: url, timeoutInterval: 8)
        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              data.count <= 5_000_000, !data.isEmpty else { return nil }
        return data
    }

    public static func parse(_ html: String, base: URL) -> LinkMetadata {
        let head = html.range(of: "</head>", options: .caseInsensitive).map { String(html[..<$0.upperBound]) } ?? html
        var metas: [String: String] = [:]
        for tag in tags(named: "meta", in: head) {
            let attributes = attributes(of: tag)
            guard let content = attributes["content"].map(decodeEntities)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !content.isEmpty else { continue }
            if let key = (attributes["property"] ?? attributes["name"])?.lowercased(), metas[key] == nil {
                metas[key] = content
            }
        }
        let titleTag = firstMatch(#"<title[^>]*>([\s\S]*?)</title>"#, in: head).map(decodeEntities)
        let title = (metas["og:title"] ?? metas["twitter:title"] ?? titleTag)?
            .trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\n", with: " ")
        let description = metas["og:description"] ?? metas["twitter:description"] ?? metas["description"]
        let image = (metas["og:image"] ?? metas["og:image:url"] ?? metas["twitter:image"])
            .flatMap { URL(string: $0, relativeTo: base)?.absoluteURL.absoluteString }
        return LinkMetadata(
            title: title?.isEmpty == true ? nil : title, description: description, image: image, text: readableText(html)
        )
    }

    /// The body's words: scripts, styles and tags removed, entities decoded, blank runs collapsed.
    static func readableText(_ html: String) -> String {
        var text = html.range(of: "<body", options: .caseInsensitive).map { String(html[$0.lowerBound...]) } ?? html
        for block in ["script", "style", "noscript", "svg", "nav", "footer", "header"] {
            text = text.replacingOccurrences(of: "<\(block)\\b[\\s\\S]*?</\(block)>", with: " ", options: [.regularExpression, .caseInsensitive])
        }
        text = text.replacingOccurrences(of: "<(br|p|div|li|h[1-6]|tr)\\b[^>]*>", with: "\n", options: [.regularExpression, .caseInsensitive])
        text = text.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        text = decodeEntities(text)
        let lines = text.split(separator: "\n").map {
            $0.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        }.filter { !$0.isEmpty }
        let joined = lines.joined(separator: "\n")
        return joined.count > textLimit ? String(joined.prefix(textLimit)) : joined
    }

    static func tags(named name: String, in html: String) -> [String] {
        matches("<\(name)\\b[^>]*>", in: html)
    }

    static func attributes(of tag: String) -> [String: String] {
        var result: [String: String] = [:]
        let pattern = #"([a-zA-Z_:][-a-zA-Z0-9_:.]*)\s*=\s*("([^"]*)"|'([^']*)'|([^\s>]+))"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return result }
        let ns = tag as NSString
        for match in regex.matches(in: tag, range: NSRange(location: 0, length: ns.length)) {
            let key = ns.substring(with: match.range(at: 1)).lowercased()
            for group in 3...5 where match.range(at: group).location != NSNotFound {
                result[key] = ns.substring(with: match.range(at: group))
                break
            }
        }
        return result
    }

    static func decodeEntities(_ text: String) -> String {
        var text = text
        for (entity, value) in ["&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'", "&apos;": "'", "&nbsp;": " ", "&#x27;": "'", "&mdash;": "—", "&ndash;": "–", "&hellip;": "…", "&rsquo;": "’", "&lsquo;": "‘", "&ldquo;": "“", "&rdquo;": "”"] {
            text = text.replacingOccurrences(of: entity, with: value)
        }
        guard let regex = try? NSRegularExpression(pattern: "&#(x?)([0-9a-fA-F]+);") else { return text }
        let ns = text as NSString
        var result = ""
        var last = 0
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            result += ns.substring(with: NSRange(location: last, length: match.range.location - last))
            let hex = ns.substring(with: match.range(at: 1)) == "x"
            let digits = ns.substring(with: match.range(at: 2))
            if let code = UInt32(digits, radix: hex ? 16 : 10), let scalar = Unicode.Scalar(code) {
                result.unicodeScalars.append(scalar)
            } else {
                result += ns.substring(with: match.range)
            }
            last = match.range.location + match.range.length
        }
        result += ns.substring(from: last)
        return result
    }

    private static func matches(_ pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        let ns = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range) }
    }

    private static func firstMatch(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let ns = text as NSString
        guard let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)),
              match.numberOfRanges > 1 else { return nil }
        return ns.substring(with: match.range(at: 1))
    }
}
