import Foundation
import Markdown
import PluginKit

/// Rewrites the destinations of links and images when notes or attachments move, leaving every other
/// character of the text untouched. Links to files that do not move are recomputed only when the note
/// itself moves, and only if their relative form changes.
public enum LinkRewriter {
    /// - Parameters:
    ///   - notePath: where the note lives now (links are resolved from here).
    ///   - newNotePath: where the note will live (links are written relative to here).
    ///   - moves: old vault path to new vault path, for every file being moved (notes and attachments).
    ///   - exists: whether a vault path exists before the move. With it, a link that points nowhere from the note but
    ///     to a file from the vault's root (`assets/photo.png`, as the editor writes dropped files) is followed and
    ///     rewritten as a root link, so moving the note keeps it working.
    public static func rewrite(
        _ text: String,
        notePath: String,
        newNotePath: String,
        moves: [String: String],
        exists: ((String) -> Bool)? = nil
    ) -> String {
        let (raw, _, body) = MarkdownFrontmatter.split(text)
        var finder = Finder()
        finder.visit(Document(parsing: body))

        let bytes = Array(body.utf8)
        var lineStarts = [0]
        for (index, byte) in bytes.enumerated() where byte == UInt8(ascii: "\n") { lineStarts.append(index + 1) }
        func offset(_ location: SourceLocation) -> Int? {
            guard location.line >= 1, location.line <= lineStarts.count else { return nil }
            return lineStarts[location.line - 1] + location.column - 1
        }

        let newDirectory = VaultPath.directory(of: newNotePath)
        var edits: [(range: Range<Int>, replacement: [UInt8])] = []
        for found in finder.links {
            guard let local = LocalLink(destination: found.destination, anyFile: true),
                  var target = try? VaultPath.resolve(local.path, from: notePath),
                  let range = found.range,
                  let start = offset(range.lowerBound), let end = offset(range.upperBound),
                  start <= end, end <= bytes.count
            else { continue }

            var fromDirectory = newDirectory
            if let exists, !exists(target), let root = try? VaultPath.normalize(local.path), !root.isEmpty, exists(root) {
                target = root
                fromDirectory = ""
            }
            let newTarget = moves[target] ?? target
            let destination = VaultPath.relativeDestination(fromDirectory: fromDirectory, to: newTarget)
            if destination.removingPercentEncoding == local.path { continue }

            let slice = Array(bytes[start..<end])
            guard let open = lastIndex(of: Array("](".utf8), in: slice),
                  let at = firstIndex(of: Array(found.destination.utf8), in: slice, from: open + 2)
            else { continue }
            let from = start + at
            edits.append((from..<(from + found.destination.utf8.count), Array((destination + local.suffix).utf8)))
        }
        guard !edits.isEmpty else { return text }

        var result = bytes
        for edit in edits.sorted(by: { $0.range.lowerBound > $1.range.lowerBound }) {
            result.replaceSubrange(edit.range, with: edit.replacement)
        }
        return raw + String(decoding: result, as: UTF8.self)
    }

    private struct Found {
        let destination: String
        let range: SourceRange?
    }

    private struct Finder: MarkupWalker {
        var links: [Found] = []

        mutating func visitLink(_ link: Link) {
            if let destination = link.destination { links.append(Found(destination: destination, range: link.range)) }
            descendInto(link)
        }

        mutating func visitImage(_ image: Image) {
            if let source = image.source { links.append(Found(destination: source, range: image.range)) }
        }
    }

    private static func lastIndex(of pattern: [UInt8], in bytes: [UInt8]) -> Int? {
        guard bytes.count >= pattern.count else { return nil }
        for index in stride(from: bytes.count - pattern.count, through: 0, by: -1)
        where Array(bytes[index..<(index + pattern.count)]) == pattern {
            return index
        }
        return nil
    }

    private static func firstIndex(of pattern: [UInt8], in bytes: [UInt8], from: Int) -> Int? {
        guard !pattern.isEmpty, bytes.count >= pattern.count, from <= bytes.count - pattern.count else { return nil }
        for index in from...(bytes.count - pattern.count)
        where Array(bytes[index..<(index + pattern.count)]) == pattern {
            return index
        }
        return nil
    }
}
