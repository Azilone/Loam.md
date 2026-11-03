import Foundation
import PluginKit

/// Reads a Notion export ("Markdown & CSV", a folder or its .zip) and writes it as plain Markdown: Notion's ids are
/// taken off every file and folder name and every link, the properties above a page's text become its frontmatter,
/// and each database becomes a collection of its pages' folder.
public struct NotionImporter {
    let vault: VaultAccess

    public init(vault: VaultAccess) {
        self.vault = vault
    }

    public func run(source: URL, into: String, dryRun: Bool) throws -> NotesImportReport {
        let root = try Self.unpacked(source)
        defer { if root != source { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) } }
        var writer = ImportWriter(vault: vault, into: try VaultPath.normalize(into), dryRun: dryRun)
        let files = try Self.files(in: root)
        let csvFolders = Set(files.filter { $0.hasSuffix(".csv") && !$0.hasSuffix("_all.csv") }.map { ($0 as NSString).deletingPathExtension })

        for path in files {
            let url = root.appendingPathComponent(path)
            let clean = Self.withoutIDs(path)
            let ext = (path as NSString).pathExtension.lowercased()
            let folder = (clean as NSString).deletingLastPathComponent
            let name = ((clean as NSString).lastPathComponent as NSString).deletingPathExtension
            switch ext {
            case "md":
                guard let text = try? String(contentsOf: url, encoding: .utf8) else {
                    writer.report.warnings.append("\(path): not valid UTF-8, skipped")
                    continue
                }
                let target = writer.path(folder: folder, name: ImportWriter.safeName(name), ext: "md")
                try writer.note(target, Self.convert(text))
            case "csv":
                // A database: its pages are the folder of the same name; `_all.csv` repeats it.
                if path.hasSuffix("_all.csv") { continue }
                let pages = (path as NSString).deletingPathExtension
                if files.contains(where: { $0.hasPrefix(pages + "/") }) {
                    let pagesFolder = [writer.into, Self.withoutIDs(pages)].filter { !$0.isEmpty }.joined(separator: "/")
                    try writer.collection(pagesFolder + "/" + ImportWriter.safeName(name) + ".base", folder: pagesFolder)
                } else {
                    try writer.file(writer.path(folder: folder, name: ImportWriter.safeName(name), ext: "csv"), Data(contentsOf: url))
                }
            default:
                _ = csvFolders
                try writer.file(writer.path(folder: folder, name: ImportWriter.safeName(name), ext: ext), Data(contentsOf: url))
            }
        }
        return writer.report
    }

    /// A folder to read: `source` itself, or the zip unpacked in a temporary folder.
    static func unpacked(_ source: URL) throws -> URL {
        guard source.pathExtension.lowercased() == "zip" else { return source }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("loam-notion-\(UUID().uuidString)")
        let target = folder.appendingPathComponent("export")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        #if os(macOS)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", source.path, target.path]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw NotesImportError.unreadable(source.path) }
        #else
        throw NotesImportError.unreadable(source.path)
        #endif
        // Notion's zip may hold another zip, or one folder: read inside them.
        let inside = (try? FileManager.default.contentsOfDirectory(atPath: target.path)) ?? []
        if inside.count == 1, inside[0].lowercased().hasSuffix(".zip") {
            let inner = try unpacked(target.appendingPathComponent(inside[0]))
            return inner
        }
        return target
    }

    static func files(in root: URL) throws -> [String] {
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]) else {
            throw NotesImportError.unreadable(root.path)
        }
        let base = root.standardizedFileURL.path
        var files: [String] = []
        for case let url as URL in enumerator {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
            let full = url.standardizedFileURL.path
            guard full.hasPrefix(base + "/"), url.lastPathComponent != ".DS_Store" else { continue }
            files.append(String(full.dropFirst(base.count + 1)))
        }
        return files.sorted()
    }

    private static let id = try! NSRegularExpression(pattern: "\\s[0-9a-f]{32}(?=$|\\.)")

    /// `path` with the ids Notion adds after each name ("Plan 3f1c…e9a.md" → "Plan.md").
    static func withoutIDs(_ path: String) -> String {
        path.split(separator: "/", omittingEmptySubsequences: false).map { component in
            let text = String(component)
            return id.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "")
        }.joined(separator: "/")
    }

    /// A page's text: the property lines under its title as frontmatter, the links without ids.
    static func convert(_ text: String) -> String {
        var lines = text.components(separatedBy: "\n")
        var properties: [(String, String)] = []
        if let first = lines.first, first.hasPrefix("# ") {
            var index = 1
            while index < lines.count, lines[index].isEmpty { index += 1 }
            var block: [(String, String)] = []
            var end = index
            while end < lines.count, !lines[end].isEmpty {
                let line = lines[end]
                guard let colon = line.firstIndex(of: ":"), line.distance(from: line.startIndex, to: colon) <= 40,
                      !line.hasPrefix("#"), !line.hasPrefix("-"), !line.hasPrefix("!")
                else { block = []; break }
                let key = line[..<colon].trimmingCharacters(in: .whitespaces)
                let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                guard !key.isEmpty, !key.contains("](") else { block = []; break }
                block.append((key, value))
                end += 1
            }
            if !block.isEmpty {
                properties = block
                // The block and the blank line under it.
                let through = end < lines.count && lines[end].isEmpty ? end + 1 : end
                lines.removeSubrange(index..<through)
            }
        }
        let body = relink(lines.joined(separator: "\n"))
        return withFrontmatter(properties, body)
    }

    private static let link = try! NSRegularExpression(pattern: "\\]\\(([^)\\s]+)\\)")

    /// Markdown links to other files of the export, without the ids in their paths.
    static func relink(_ text: String) -> String {
        let range = NSRange(text.startIndex..., in: text)
        var result = text
        for match in link.matches(in: text, range: range).reversed() {
            guard let target = Range(match.range(at: 1), in: text) else { continue }
            let href = String(text[target])
            guard !href.contains("://"), let decoded = href.removingPercentEncoding else { continue }
            let clean = withoutIDs(decoded)
            guard clean != decoded, let encoded = clean.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
                  let replace = Range(match.range(at: 1), in: result)
            else { continue }
            result.replaceSubrange(replace, with: encoded)
        }
        return result
    }
}

enum NotesImportError: Error, CustomStringConvertible, Equatable {
    case unreadable(String)
    case denied(String)
    case missing(String)

    var description: String {
        switch self {
        case .unreadable(let path): "Could not read \(path)."
        case .denied(let what): "macOS did not let Loam read \(what). Allow it in System Settings > Privacy & Security, then try again."
        case .missing(let what): "\(what) is not on this Mac."
        }
    }
}
