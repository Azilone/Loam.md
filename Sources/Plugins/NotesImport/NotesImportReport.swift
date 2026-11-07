import Foundation
import PluginKit

/// What an import from Notion, Bear or Apple Notes did, or would do on a dry run.
public struct NotesImportReport: Codable, Equatable, Sendable {
    public var dryRun: Bool
    /// Notes written as Markdown.
    public var converted = 0
    /// Other files copied: pictures, PDFs.
    public var copied = 0
    /// Collections made from databases (`.base` files).
    public var collections = 0
    /// Files that already existed and were left alone.
    public var skipped: [String] = []
    public var warnings: [String] = []

    public init(dryRun: Bool) {
        self.dryRun = dryRun
    }
}

/// The sources this plugin brings notes from.
public enum NotesSource: String, Codable, CaseIterable, Sendable {
    case notion, bear, appleNotes = "apple-notes"

    public var name: String {
        switch self {
        case .notion: "Notion"
        case .bear: "Bear"
        case .appleNotes: "Apple Notes"
        }
    }
}

/// Writes an import into the vault: unique, safe file names under `into`, nothing overwritten, a dry run writing
/// nothing.
struct ImportWriter {
    let vault: VaultAccess
    let into: String
    var report: NotesImportReport
    private var taken: Set<String> = []

    init(vault: VaultAccess, into: String, dryRun: Bool) {
        self.vault = vault
        self.into = into
        report = NotesImportReport(dryRun: dryRun)
    }

    /// A file name without what file systems and links choke on.
    static func safeName(_ name: String) -> String {
        let cleaned = name.components(separatedBy: CharacterSet(charactersIn: "/\\:*?\"<>|#^[]")).joined(separator: " ")
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let trimmed = cleaned.trimmingCharacters(in: CharacterSet(charactersIn: " ."))
        return trimmed.isEmpty ? "Untitled" : String(trimmed.prefix(120))
    }

    /// `folder/name.ext` under `into`, numbered when the name is taken in this import.
    mutating func path(folder: String, name: String, ext: String) -> String {
        let base = [into, folder].filter { !$0.isEmpty }.joined(separator: "/")
        var candidate = base.isEmpty ? "\(name).\(ext)" : "\(base)/\(name).\(ext)"
        var number = 2
        while taken.contains(candidate.lowercased()) {
            candidate = base.isEmpty ? "\(name) \(number).\(ext)" : "\(base)/\(name) \(number).\(ext)"
            number += 1
        }
        taken.insert(candidate.lowercased())
        return candidate
    }

    mutating func note(_ path: String, _ text: String) throws {
        guard !vault.exists(path) else { return report.skipped.append(path) }
        if !report.dryRun { try vault.write(path, text) }
        report.converted += 1
    }

    mutating func file(_ path: String, _ data: Data) throws {
        guard !vault.exists(path) else { return report.skipped.append(path) }
        if !report.dryRun { try vault.writeData(path, data) }
        report.copied += 1
    }

    mutating func collection(_ path: String, folder: String) throws {
        guard !vault.exists(path) else { return report.skipped.append(path) }
        let quoted = folder.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let yaml = """
        filters:
          and:
            - 'file.inFolder("\(quoted)")'
            - file.ext == "md"
        views:
          - type: table
            name: Table
            order:
              - file.name

        """
        if !report.dryRun { try vault.write(path, yaml) }
        report.collections += 1
    }
}

/// `date` as a frontmatter value, `2026-10-29T14:03:00`.
func frontmatterDate(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
    return formatter.string(from: date)
}

/// `body` under a frontmatter of `properties`, in their order; just `body` without any.
func withFrontmatter(_ properties: [(String, String)], _ body: String) -> String {
    guard !properties.isEmpty else { return body }
    let lines = properties.map { key, value -> String in
        let needsQuotes = value.isEmpty || value.contains(": ") || value.hasSuffix(":") || value.contains(" #")
            || value.hasPrefix("#") || value.hasPrefix("[") || value.hasPrefix("{") || value.hasPrefix("*") || value.hasPrefix("&")
            || value.hasPrefix("-") || value.hasPrefix("'") || value.hasPrefix("\"")
        let escaped = value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        return "\(key): \(needsQuotes ? "\"\(escaped)\"" : value)"
    }
    return "---\n" + lines.joined(separator: "\n") + "\n---\n\n" + body
}
