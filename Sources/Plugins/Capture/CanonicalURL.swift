import Crypto
import Foundation

/// The forms a duplicate is recognised by: one spelling of a URL, and a hash of bytes or text.
public enum CaptureIdentity {
    /// Query keys that only say where a click came from.
    static let trackingKeys: Set<String> = ["fbclid", "gclid", "dclid", "msclkid", "mc_cid", "mc_eid", "ref", "ref_src", "igshid", "si"]

    /// `https`, the host in lower case without `www.`, no fragment, no trailing slash, tracking keys dropped and the
    /// others sorted. Nil for a string that is not an http(s) URL.
    public static func canonicalURL(_ text: String) -> String? {
        guard var components = URLComponents(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = components.host?.lowercased(), !host.isEmpty else { return nil }
        components.scheme = "https"
        components.host = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        components.fragment = nil
        if components.port == 443 || components.port == 80 { components.port = nil }
        let items = (components.queryItems ?? []).filter { item in
            let key = item.name.lowercased()
            return !key.hasPrefix("utm_") && !trackingKeys.contains(key)
        }
        components.queryItems = items.isEmpty ? nil : items.sorted { ($0.name, $0.value ?? "") < ($1.name, $1.value ?? "") }
        while components.path.count > 1, components.path.hasSuffix("/") { components.path.removeLast() }
        if components.path == "/" { components.path = "" }
        return components.string
    }

    /// One plain URL alone in the text (what "Copy Link" puts as text), or nil.
    public static func singleURL(in text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(where: \.isWhitespace) else { return nil }
        return canonicalURL(trimmed) == nil ? nil : trimmed
    }

    public static func hash(_ data: Data) -> String {
        "sha256:" + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// The text in lower case with its whitespace collapsed, so a copy with other line breaks counts as the same.
    public static func hash(text: String) -> String {
        let words = text.lowercased().split(whereSeparator: { $0.isWhitespace || $0.isNewline })
        return hash(Data(words.joined(separator: " ").utf8))
    }
}
