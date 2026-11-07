import Foundation

/// A Markdown link destination that points at another note of the vault, or at any file of the vault
/// when `anyFile` is set (images and attachments, which must follow moves too).
struct LocalLink: Equatable {
    /// The decoded path part, relative to the note that contains the link.
    let path: String
    /// Everything from the first `#` or `?`, kept as written.
    let suffix: String

    init?(destination: String, anyFile: Bool = false) {
        guard !destination.isEmpty, !destination.hasPrefix("#"),
              destination.range(of: "^[A-Za-z][A-Za-z0-9+.-]*:", options: .regularExpression) == nil
        else { return nil }
        let cut = destination.firstIndex { $0 == "#" || $0 == "?" } ?? destination.endIndex
        let rawPath = String(destination[..<cut])
        let decoded = rawPath.removingPercentEncoding ?? rawPath
        if anyFile {
            // A folder link (`notes/`) has no file to follow.
            guard !decoded.isEmpty, !decoded.hasSuffix("/") else { return nil }
        } else {
            guard decoded.lowercased().hasSuffix(".md") else { return nil }
        }
        self.path = decoded
        self.suffix = String(destination[cut...])
    }
}
