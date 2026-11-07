import Foundation
import PluginKit

/// Where the files of an Obsidian vault are, to resolve `[[wikilinks]]` the way Obsidian does:
/// by note name (shortest path wins) or by a path suffix.
struct NoteResolver {
    let notePaths: [String]
    let filePaths: [String]
    /// Every file by its normalized path (macOS stores accents decomposed, links write them composed).
    private let byKey: [String: String]

    init(notePaths: [String], filePaths: [String]) {
        self.notePaths = notePaths
        self.filePaths = filePaths
        byKey = Dictionary(filePaths.map { (ImportLayout.key($0), $0) }, uniquingKeysWith: { first, _ in first })
    }

    /// The file a Markdown link destination points to: relative to the note containing it, else from the vault's root,
    /// else by name as Obsidian does (`![](photo.png)` finds `img/photo.png`); `exact` is false for that last case,
    /// where the link has to be rewritten to work anywhere else.
    func existing(_ destination: String, from notePath: String) -> (path: String, exact: Bool)? {
        if let path = try? VaultPath.resolve(destination, from: notePath), let hit = byKey[ImportLayout.key(path)] {
            return (hit, true)
        }
        if let path = try? VaultPath.normalize(destination), let hit = byKey[ImportLayout.key(path)] { return (hit, true) }
        if let hit = file(named: destination) { return (hit, false) }
        return nil
    }

    /// The note a wikilink target points to, plus a warning if the name was ambiguous.
    func note(named target: String) -> (path: String, warning: String?)? {
        var name = target.trimmingCharacters(in: .whitespaces)
        if name.lowercased().hasSuffix(".md") { name = String(name.dropLast(3)) }
        guard !name.isEmpty else { return nil }
        let wanted = name.lowercased()
        let matches = notePaths.filter { path in
            let withoutExtension = String(path.dropLast(3)).lowercased()
            return withoutExtension == wanted || withoutExtension.hasSuffix("/" + wanted)
        }
        guard let best = matches.min(by: { ($0.count, $0) < ($1.count, $1) }) else { return nil }
        let warning = matches.count > 1 ? "\"\(target)\" matches \(matches.count) notes, linked \(best)" : nil
        return (best, warning)
    }

    /// The attachment (image, PDF, ...) an embed points to.
    func file(named target: String) -> String? {
        let wanted = target.trimmingCharacters(in: .whitespaces).lowercased()
        guard !wanted.isEmpty else { return nil }
        let matches = filePaths.filter { $0.lowercased() == wanted || $0.lowercased().hasSuffix("/" + wanted) }
        return matches.min { ($0.count, $0) < ($1.count, $1) }
    }
}

/// Turns Obsidian-flavoured Markdown into plain CommonMark + GFM:
/// wikilinks and embeds become standard links, callouts become GitHub alerts, comments disappear.
/// Code blocks and inline code are never touched.
struct ObsidianConverter {
    let resolver: NoteResolver
    /// Folder the converted notes are written into, so links are relative to the right place.
    let destinationFolder: String
    /// The files that land elsewhere than their own path: daily notes and attachments.
    var layout = ImportLayout.none

    private static let wikilink = try! NSRegularExpression(
        pattern: "(!?)\\[\\[([^\\]\\|#\\\\\\n]*)(?:#([^\\]\\|\\\\\\n]*))?(?:\\\\?\\|([^\\]\\n]*))?\\]\\]"
    )
    private static let callout = try! NSRegularExpression(pattern: "^(\\s*>\\s?)\\[!([A-Za-z-]+)\\][+-]?\\s*(.*)$")
    private static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "svg", "webp", "bmp", "avif"]

    func convert(_ text: String, notePath: String, warnings: inout [String]) -> String {
        let (raw, _, body) = MarkdownFrontmatter.split(text)
        var output: [String] = []
        var fence: String?
        var inComment = false

        for line in body.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let open = fence {
                output.append(line)
                if trimmed.hasPrefix(open) { fence = nil }
                continue
            }
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                fence = String(trimmed.prefix(3))
                output.append(line)
                continue
            }

            var current = line
            let hadComment = line.contains("%%") || inComment
            current = Self.stripComments(current, inComment: &inComment)
            if hadComment, current.trimmingCharacters(in: .whitespaces).isEmpty { continue }

            var lines = [current]
            if let callout = Self.convertCallout(current) { lines = callout }
            output.append(contentsOf: lines.map {
                convertLinks(in: rewriteStandardLinks(in: $0, notePath: notePath), notePath: notePath, warnings: &warnings)
            })
        }
        return raw + output.joined(separator: "\n")
    }

    // MARK: Comments

    private static func stripComments(_ line: String, inComment: inout Bool) -> String {
        guard line.contains("%%") || inComment else { return line }
        var result = ""
        var rest = Substring(line)
        while !rest.isEmpty {
            if let marker = rest.range(of: "%%") {
                if !inComment { result += rest[..<marker.lowerBound] }
                inComment.toggle()
                rest = rest[marker.upperBound...]
            } else {
                if !inComment { result += rest }
                break
            }
        }
        return result
    }

    // MARK: Callouts

    private static func convertCallout(_ line: String) -> [String]? {
        let range = NSRange(line.startIndex..., in: line)
        guard let match = callout.firstMatch(in: line, range: range),
              let prefix = Range(match.range(at: 1), in: line),
              let type = Range(match.range(at: 2), in: line),
              let title = Range(match.range(at: 3), in: line)
        else { return nil }
        let alert = alertType(String(line[type]).lowercased())
        var lines = ["\(line[prefix])[!\(alert)]"]
        let heading = String(line[title]).trimmingCharacters(in: .whitespaces)
        if !heading.isEmpty { lines.append("\(line[prefix])**\(heading)**") }
        return lines
    }

    private static func alertType(_ type: String) -> String {
        switch type {
        case "tip", "success", "check", "done", "hint": return "TIP"
        case "important": return "IMPORTANT"
        case "warning", "attention", "caution": return type == "caution" ? "CAUTION" : "WARNING"
        case "failure", "fail", "missing", "danger", "error", "bug": return "CAUTION"
        default: return "NOTE"
        }
    }

    // MARK: Links

    /// The `[text](path)` links of the source that point to a file the import moves, sit in a note it moves, or name a
    /// file by its name alone (Obsidian finds it anywhere): rewritten to the new relative path. Code spans and links
    /// to anything else stay as they are.
    private func rewriteStandardLinks(in line: String, notePath: String) -> String {
        guard line.contains("](") else { return line }
        let noteMoved = layout.paths[notePath] != nil
        let directory = VaultPath.directory(of: destinationPath(notePath))
        let parts = line.components(separatedBy: "`")
        var rewritten: [String] = []
        for (offset, part) in parts.enumerated() {
            guard offset % 2 == 0, part.contains("](") else { rewritten.append(part); continue }
            var text = part
            for link in MarkdownLinks.destinations(in: part).reversed() {
                guard let found = resolver.existing(link.path, from: notePath),
                      noteMoved || !found.exact || layout.paths[found.path] != nil
                else { continue }
                let source = found.path
                let relative = VaultPath.relativeDestination(fromDirectory: directory, to: destinationPath(source))
                text.replaceSubrange(link.range, with: relative + link.suffix)
            }
            rewritten.append(text)
        }
        return rewritten.joined(separator: "`")
    }

    private func convertLinks(in line: String, notePath: String, warnings: inout [String]) -> String {
        guard line.contains("[[") else { return line }
        var result = ""
        var local = ""
        var index = line.startIndex
        var found: [String] = []

        func flush() {
            result += convertLinksOutsideCode(local, notePath: notePath, warnings: &found)
            local = ""
        }
        while index < line.endIndex {
            if line[index] == "`" {
                var runEnd = index
                while runEnd < line.endIndex, line[runEnd] == "`" { runEnd = line.index(after: runEnd) }
                let run = String(line[index..<runEnd])
                if let close = line.range(of: run, range: runEnd..<line.endIndex) {
                    flush()
                    result += line[index..<close.upperBound]
                    index = close.upperBound
                    continue
                }
                local += run
                index = runEnd
                continue
            }
            local.append(line[index])
            index = line.index(after: index)
        }
        flush()
        warnings.append(contentsOf: found)
        return result
    }

    private func convertLinksOutsideCode(_ text: String, notePath: String, warnings: inout [String]) -> String {
        let nsText = text as NSString
        var result = ""
        var last = 0
        for match in Self.wikilink.matches(in: text, range: NSRange(location: 0, length: nsText.length)) {
            result += nsText.substring(with: NSRange(location: last, length: match.range.location - last))
            last = match.range.location + match.range.length

            func group(_ index: Int) -> String? {
                let range = match.range(at: index)
                return range.location == NSNotFound ? nil : nsText.substring(with: range)
            }
            let isEmbed = group(1) == "!"
            let target = group(2) ?? ""
            let fragment = group(3)
            let alias = group(4)
            result += replacement(
                isEmbed: isEmbed, target: target, fragment: fragment, alias: alias,
                original: nsText.substring(with: match.range), notePath: notePath, warnings: &warnings
            )
        }
        result += nsText.substring(from: last)
        return result
    }

    private func replacement(
        isEmbed: Bool, target: String, fragment: String?, alias: String?,
        original: String, notePath: String, warnings: inout [String]
    ) -> String {
        let directory = VaultPath.directory(of: destinationPath(notePath))
        func destination(_ sourcePath: String, fragment: String? = nil) -> String {
            let path = VaultPath.relativeDestination(fromDirectory: directory, to: destinationPath(sourcePath))
            guard let fragment, !fragment.isEmpty, !fragment.hasPrefix("^") else { return path }
            return path + "#" + Self.slug(fragment)
        }

        // [[#Heading]]: a link inside the same note.
        if target.trimmingCharacters(in: .whitespaces).isEmpty {
            guard let fragment, !fragment.isEmpty, !fragment.hasPrefix("^") else { return alias ?? original }
            return "[\(alias ?? fragment)](#\(Self.slug(fragment)))"
        }

        let ext = (target as NSString).pathExtension.lowercased()
        if !ext.isEmpty, ext != "md", let file = resolver.file(named: target) {
            let name = (file as NSString).lastPathComponent
            if isEmbed, Self.imageExtensions.contains(ext) {
                let alt = alias.flatMap { Self.isSize($0) ? nil : $0 } ?? (name as NSString).deletingPathExtension
                return "![\(alt)](\(destination(file)))"
            }
            return "[\(alias ?? name)](\(destination(file)))"
        }

        guard let note = resolver.note(named: target) else {
            warnings.append("\(notePath): unresolved link \"\(target)\"")
            return alias ?? target
        }
        if let warning = note.warning { warnings.append("\(notePath): \(warning)") }
        let name = ((note.path as NSString).lastPathComponent as NSString).deletingPathExtension
        var text = alias ?? name
        if alias == nil, let fragment, !fragment.isEmpty, !fragment.hasPrefix("^") { text += " > " + fragment }
        return "[\(text)](\(destination(note.path, fragment: fragment)))"
    }

    /// A board from Obsidian: its cards' files (vault paths) moved with the import, its text cards' Markdown
    /// converted like a note's (links relative to the board). Nil when it is not a JSON object.
    func convertCanvas(_ data: Data, canvasPath: String, warnings: inout [String]) -> Data? {
        guard var board = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        if let nodes = board["nodes"] as? [[String: Any]] {
            let converted = nodes.map { node -> [String: Any] in
                var node = node
                for key in ["file", "background"] {
                    if let file = node[key] as? String, !file.isEmpty { node[key] = destinationPath(file) }
                }
                if let text = node["text"] as? String {
                    node["text"] = convert(text, notePath: canvasPath, warnings: &warnings)
                }
                return node
            }
            // An untouched board keeps its bytes (Obsidian's layout of the file).
            guard !(converted as NSArray).isEqual(to: nodes) else { return data }
            board["nodes"] = converted
        }
        return try? JSONSerialization.data(withJSONObject: board, options: [.prettyPrinted, .sortedKeys,
                                                                              .withoutEscapingSlashes])
    }

    func destinationPath(_ sourcePath: String) -> String {
        if let moved = layout.paths[sourcePath] { return moved }
        return destinationFolder.isEmpty ? sourcePath : destinationFolder + "/" + sourcePath
    }

    private static func isSize(_ alias: String) -> Bool {
        alias.range(of: "^\\d+(x\\d+)?$", options: .regularExpression) != nil
    }

    /// GitHub-style heading anchor: lowercase, punctuation removed, spaces to hyphens.
    static func slug(_ heading: String) -> String {
        let kept = heading.lowercased().unicodeScalars.filter {
            CharacterSet.alphanumerics.contains($0) || $0 == " " || $0 == "-" || $0 == "_"
        }
        return String(String.UnicodeScalarView(kept)).replacingOccurrences(of: " ", with: "-")
    }
}
