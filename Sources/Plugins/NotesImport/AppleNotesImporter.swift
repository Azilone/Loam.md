import Foundation
import PluginKit

/// Brings Apple Notes in through Notes' own scripting (macOS asks once to let Loam control Notes): every note of every
/// account but the deleted ones, as Markdown in a folder per Notes folder; locked notes stay behind, pictures come along.
public struct AppleNotesImporter {
    /// One note as Notes' scripting gives it.
    struct Note: Decodable {
        let account: String
        let folder: String
        let name: String
        let body: String
        let created: String?
        let modified: String?
        let locked: Bool
    }

    let vault: VaultAccess
    /// Runs the script and returns its output: `osascript` in the app, a fixture in tests.
    let script: (String) throws -> String

    public init(vault: VaultAccess) {
        self.init(vault: vault, script: Self.osascript)
    }

    init(vault: VaultAccess, script: @escaping (String) throws -> String) {
        self.vault = vault
        self.script = script
    }

    static let readNotes = """
        const Notes = Application('Notes');
        const out = [];
        for (const account of Notes.accounts()) {
          const walk = (folder, path) => {
            const name = folder.name();
            if (name === 'Recently Deleted') return;
            const here = path ? path + '/' + name : name;
            for (const note of folder.notes()) {
              const locked = note.passwordProtected();
              out.push({ account: account.name(), folder: here, name: note.name(), body: locked ? '' : note.body(),
                         created: note.creationDate().toISOString(), modified: note.modificationDate().toISOString(),
                         locked: locked });
            }
            for (const child of folder.folders()) walk(child, here);
          };
          for (const folder of account.folders()) {
            if (folder.container().class() === 'account') walk(folder, '');
          }
        }
        JSON.stringify(out);
        """

    public func run(into: String, dryRun: Bool) throws -> NotesImportReport {
        let output = try script(Self.readNotes)
        guard let data = output.data(using: .utf8), let notes = try? JSONDecoder().decode([Note].self, from: data) else {
            throw NotesImportError.denied("Apple Notes")
        }
        var writer = ImportWriter(vault: vault, into: try VaultPath.normalize(into), dryRun: dryRun)
        let accounts = Set(notes.map(\.account))
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let locked = notes.filter(\.locked).count
        if locked > 0 { writer.report.warnings.append("\(locked) locked notes left in Apple Notes.") }
        for note in notes where !note.locked {
            // One account: its folders at the top. Several: a folder per account.
            let folder = (accounts.count > 1 ? [note.account, note.folder] : [note.folder])
                .flatMap { $0.split(separator: "/").map { ImportWriter.safeName(String($0)) } }.joined(separator: "/")
            var converted = HTMLToMarkdown.convert(note.body)
            for (index, image) in converted.images.enumerated() {
                let name = ImportWriter.safeName(note.name) + " \(index + 1)"
                let target = writer.path(folder: "Attachments", name: name, ext: image.ext)
                try writer.file(target, image.data)
                let depth = folder.isEmpty ? 0 : folder.split(separator: "/").count
                let link = String(repeating: "../", count: depth) + String(target.dropFirst(writer.into.isEmpty ? 0 : writer.into.count + 1))
                converted.markdown = converted.markdown.replacingOccurrences(
                    of: image.placeholder, with: link.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? link
                )
            }
            var properties: [(String, String)] = []
            if let created = note.created.flatMap(iso.date(from:)) { properties.append(("created", frontmatterDate(created))) }
            if let modified = note.modified.flatMap(iso.date(from:)) { properties.append(("modified", frontmatterDate(modified))) }
            let path = writer.path(folder: folder, name: ImportWriter.safeName(note.name), ext: "md")
            try writer.note(path, withFrontmatter(properties, converted.markdown))
        }
        return writer.report
    }

    static func osascript(_ source: String) throws -> String {
        #if os(macOS)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-l", "JavaScript", "-e", source]
        let output = Pipe(), errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw NotesImportError.denied("Apple Notes") }
        return String(decoding: data, as: UTF8.self)
        #else
        throw NotesImportError.missing("Apple Notes")
        #endif
    }
}

/// The HTML Notes keeps a note in, as Markdown: headings, bold and italics, lists and checklists, links, line breaks;
/// pictures inlined as data become files (`images`, with a placeholder in the text for their path).
enum HTMLToMarkdown {
    struct Image {
        let placeholder: String
        let data: Data
        let ext: String
    }

    struct Result {
        var markdown: String
        var images: [Image]
    }

    static func convert(_ html: String) -> Result {
        var text = html
        var images: [Image] = []
        func replace(_ pattern: String, _ template: String) {
            let regex = try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators])
            text = regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: template)
        }
        // Pictures inlined as data.
        let image = try! NSRegularExpression(pattern: "<img[^>]*src=\"data:image/([a-z]+);base64,([^\"]+)\"[^>]*>", options: .caseInsensitive)
        for match in image.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
            guard let kind = Range(match.range(at: 1), in: text), let payload = Range(match.range(at: 2), in: text),
                  let whole = Range(match.range, in: text), let data = Data(base64Encoded: String(text[payload]))
            else { continue }
            let placeholder = "LOAM-IMAGE-\(images.count)"
            images.append(Image(placeholder: placeholder, data: data, ext: text[kind] == "jpeg" ? "jpg" : String(text[kind])))
            text.replaceSubrange(whole, with: "\n\n![](\(placeholder))\n\n")
        }
        images.reverse()
        replace("<img[^>]*>", "")
        replace("<h1[^>]*>(.*?)</h1>", "\n# $1\n")
        replace("<h2[^>]*>(.*?)</h2>", "\n## $1\n")
        replace("<h3[^>]*>(.*?)</h3>", "\n### $1\n")
        replace("<(b|strong)>\\s*(.*?)\\s*</(b|strong)>", "**$2**")
        replace("<(i|em)>\\s*(.*?)\\s*</(i|em)>", "*$2*")
        replace("<(strike|s|del)>(.*?)</(strike|s|del)>", "~~$2~~")
        replace("<a[^>]*href=\"([^\"]*)\"[^>]*>(.*?)</a>", "[$2]($1)")
        replace("<li[^>]*class=\"[^\"]*checked[^\"]*\"[^>]*>(.*?)</li>", "- [x] $1\n")
        replace("<ul[^>]*class=\"[^\"]*checklist[^\"]*\"[^>]*>(.*?)</ul>", "$1")
        replace("<li[^>]*>(.*?)</li>", "- $1\n")
        replace("</?(ul|ol)[^>]*>", "\n")
        replace("<br\\s*/?>", "\n")
        replace("</div>\\s*<div[^>]*>", "\n")
        replace("</?(div|p|span|font|u|tt|table|tbody|tr|td|object)[^>]*>", "")
        replace("<[^>]+>", "")
        text = text.replacingOccurrences(of: "&nbsp;", with: " ").replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">").replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'").replacingOccurrences(of: "&amp;", with: "&")
        replace("\n{3,}", "\n\n")
        // Notes repeats the title as the first line; the file is named after it, the heading stays.
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return Result(markdown: trimmed + "\n", images: images)
    }
}
