import Foundation
import MarkdownEditor
import PluginKitUI

/// Where a link destination points.
enum LinkTarget: Equatable, Sendable {
    case note(String)
    /// Any other file in the vault, by vault-relative path: a `.canvas` board, an image.
    case file(String)
    case external(URL)
}

enum NoteLinks {
    /// Where a link destination written in the note at `notePath` points: a note or file inside the vault, or an
    /// outside URL. Nil for a missing file or a path leaving the vault.
    static func resolve(_ destination: String, from notePath: String, vault: VaultAccess) -> LinkTarget? {
        if destination.hasPrefix(MarkdownTheme.noteLinkScheme) {
            return note(named: String(destination.dropFirst(MarkdownTheme.noteLinkScheme.count)), from: notePath, vault: vault)
        }
        if let url = URL(string: destination), let scheme = url.scheme, !scheme.isEmpty {
            return .external(url)
        }
        let withoutFragment = destination.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
            .first.map(String.init) ?? ""
        let decoded = withoutFragment.removingPercentEncoding ?? withoutFragment
        // Relative to the note, as links are written; from the vault's root as some apps write them.
        let candidates = [try? VaultPath.resolve(decoded, from: notePath), try? VaultPath.normalize(decoded)]
        guard !decoded.isEmpty, let path = candidates.compactMap({ $0 }).first(where: { !$0.isEmpty && vault.exists($0) }) else {
            return nil
        }
        return path.lowercased().hasSuffix(".md") ? .note(path) : .file(path)
    }

    /// The note a `[[Name#Heading]]` link names: by path from the note or the root when it is one, else the note of
    /// that name nearest to it (in its folder first), as Obsidian finds it. `[[#Heading]]` is the note itself.
    static func note(named target: String, from notePath: String, vault: VaultAccess) -> LinkTarget? {
        let name = (target.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? "")
            .trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return .note(notePath) }
        let file = name.lowercased().hasSuffix(".md") || name.contains(".") && !name.hasSuffix(".") ? name : name + ".md"
        for candidate in [try? VaultPath.resolve(file, from: notePath), try? VaultPath.normalize(file)] {
            if let candidate, !candidate.isEmpty, vault.exists(candidate) {
                return candidate.lowercased().hasSuffix(".md") ? .note(candidate) : .file(candidate)
            }
        }
        let wanted = (file as NSString).lastPathComponent.lowercased()
        let folder = (notePath as NSString).deletingLastPathComponent
        let matches = ((try? vault.markdownPaths()) ?? []).filter { ($0 as NSString).lastPathComponent.lowercased() == wanted }
        let nearest = matches.first { ($0 as NSString).deletingLastPathComponent == folder } ?? matches.first
        return nearest.map { .note($0) }
    }

    /// The heading a note link names, `Heading` in `[[Note#Heading]]`; nil without one.
    static func heading(of destination: String) -> String? {
        guard destination.hasPrefix(MarkdownTheme.noteLinkScheme), let hash = destination.firstIndex(of: "#") else { return nil }
        let heading = destination[destination.index(after: hash)...].trimmingCharacters(in: .whitespaces)
        return heading.isEmpty ? nil : heading
    }

    /// The line (1-based, in the note's text) of the `#` heading saying `heading`, ignoring case and outside code.
    static func line(ofHeading heading: String, in text: String) -> Int? {
        let wanted = heading.lowercased()
        var fence: String?
        for (index, raw) in text.components(separatedBy: "\n").enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if let open = fence {
                if line.hasPrefix(open) { fence = nil }
                continue
            }
            if line.hasPrefix("```") || line.hasPrefix("~~~") { fence = String(line.prefix(3)); continue }
            let hashes = line.prefix { $0 == "#" }.count
            guard (1...6).contains(hashes), line.dropFirst(hashes).first == " " else { continue }
            var title = line.dropFirst(hashes).trimmingCharacters(in: .whitespaces)
            if let closing = title.range(of: #"\s+#+$"#, options: .regularExpression) { title.removeSubrange(closing) }
            if title.lowercased() == wanted { return index + 1 }
        }
        return nil
    }

    /// The file an image link in the note at `notePath` shows, inside the vault: relative to the note, else from the
    /// vault's root (as some apps write them). Nil for a web address, a missing file or a path leaving the vault.
    static func embeddedFile(_ destination: String, from notePath: String, vault: VaultAccess) -> String? {
        let trimmed = destination.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed.range(of: "^[A-Za-z][A-Za-z0-9+.-]*:", options: .regularExpression) == nil else {
            return nil
        }
        let cut = trimmed.firstIndex { $0 == "#" || $0 == "?" } ?? trimmed.endIndex
        let raw = String(trimmed[..<cut])
        let decoded = raw.removingPercentEncoding ?? raw
        for candidate in [try? VaultPath.resolve(decoded, from: notePath), try? VaultPath.normalize(decoded)] {
            if let candidate, !candidate.isEmpty, vault.exists(candidate) { return candidate }
        }
        return nil
    }
}
