import Foundation
import PluginKit

/// Where an import puts the files that Loam keeps in one place: daily notes in the daily notes folder, named
/// `YYYY-MM-DD.md`, and the files notes link to (images, PDFs, audio, video) in the attachments folder. Every other
/// file keeps its path. The converter and the importer both ask it where a source path lands.
struct ImportLayout {
    /// Source path to destination path, for the files that move.
    var paths: [String: String] = [:]
    var dailyNotes = 0
    var attachments = 0
    var warnings: [String] = []

    static let none = ImportLayout()

    var isEmpty: Bool { paths.isEmpty }

    /// Plans the moves. A nil folder leaves that kind of file where it is.
    static func plan(
        notes: [String], files: [String], resolver: NoteResolver, dailyFolder: String?, attachmentsFolder: String?,
        obsidianDailyFolder: String?, read: (String) -> String?
    ) -> ImportLayout {
        var layout = ImportLayout()
        var taken = Set(files.map(key))

        if let dailyFolder {
            layout.planDailyNotes(
                notes: notes, into: dailyFolder, obsidianFolder: obsidianDailyFolder, taken: &taken
            )
        }
        if let attachmentsFolder, !attachmentsFolder.isEmpty {
            layout.planAttachments(
                notes: notes, files: files, into: attachmentsFolder, resolver: resolver, read: read, taken: &taken
            )
        }
        return layout
    }

    // MARK: Daily notes

    private mutating func planDailyNotes(
        notes: [String], into folder: String, obsidianFolder: String?, taken: inout Set<String>
    ) {
        guard let obsidianFolder = obsidianFolder?.trimmingCharacters(in: CharacterSet(charactersIn: "/ ")),
              !obsidianFolder.isEmpty
        else { return }
        // The folder Obsidian names, and its siblings of the same name (`2024/Journalier`, `2025/Journalier`):
        // a vault that files its days by year keeps naming only the current year's folder.
        let name = (obsidianFolder as NSString).lastPathComponent.lowercased()
        var claimed: [String: String] = [:]
        for note in notes {
            let directory = VaultPath.directory(of: note)
            let isDaily = directory.lowercased() == obsidianFolder.lowercased()
                || (directory as NSString).lastPathComponent.lowercased() == name
            guard isDaily, let day = DailyNoteName.day(of: (note as NSString).deletingPathExtension
                .components(separatedBy: "/").last ?? "")
            else { continue }
            let destination = folder.isEmpty ? "\(day).md" : "\(folder)/\(day).md"
            if destination == note { continue }
            if let first = claimed[destination] {
                warnings.append("\(note): same day as \(first), left where it is")
                continue
            }
            claimed[destination] = note
            taken.insert(Self.key(destination))
            paths[note] = destination
            dailyNotes += 1
        }
    }

    // MARK: Attachments

    private mutating func planAttachments(
        notes: [String], files: [String], into folder: String, resolver: NoteResolver,
        read: (String) -> String?, taken: inout Set<String>
    ) {
        var referenced = Set<String>()
        for note in notes {
            guard let text = read(note) else { continue }
            referenced.formUnion(Self.references(in: text, from: note, resolver: resolver))
        }
        for file in files.sorted() where referenced.contains(file) {
            guard Self.isAttachment(file), !file.hasPrefix(folder + "/") else { continue }
            let name = (file as NSString).lastPathComponent
            let stem = (name as NSString).deletingPathExtension
            let ext = (name as NSString).pathExtension
            var candidate = "\(folder)/\(name)"
            var number = 2
            while taken.contains(Self.key(candidate)) {
                candidate = "\(folder)/\(stem) \(number)" + (ext.isEmpty ? "" : ".\(ext)")
                number += 1
            }
            taken.insert(Self.key(candidate))
            paths[file] = candidate
            attachments += 1
        }
    }

    /// Images, PDFs, audio and video: the files Loam's attachments folder takes. Hidden folders (a meeting's `.raw`)
    /// and boards, collections and the like keep their place.
    private static func isAttachment(_ path: String) -> Bool {
        guard !path.split(separator: "/").contains(where: { $0.hasPrefix(".") }) else { return false }
        return AttachmentKind(path: path).isMedia
    }

    /// The files a note links to or embeds, as source paths.
    static func references(in text: String, from notePath: String, resolver: NoteResolver) -> Set<String> {
        var found = Set<String>()
        for target in MarkdownLinks.wikilinkTargets(in: text) {
            guard !(target as NSString).pathExtension.isEmpty, let file = resolver.file(named: target) else { continue }
            found.insert(file)
        }
        for link in MarkdownLinks.destinations(in: text) {
            if let file = resolver.existing(link.path, from: notePath)?.path { found.insert(file) }
        }
        return found
    }

    static func key(_ path: String) -> String {
        path.precomposedStringWithCanonicalMapping.lowercased()
    }
}

/// The day a daily note's name stands for, in the formats Obsidian vaults use: `2026.07.28`, `2026-07-28`,
/// `Mon 14 Jul 2025`, `lun. 14 juil. 2025`.
enum DailyNoteName {
    private static let months: [String: Int] = [
        "jan": 1, "janv": 1, "january": 1, "janvier": 1,
        "feb": 2, "fev": 2, "fevr": 2, "february": 2, "fevrier": 2,
        "mar": 3, "mars": 3, "march": 3,
        "apr": 4, "avr": 4, "april": 4, "avril": 4,
        "may": 5, "mai": 5,
        "jun": 6, "juin": 6, "june": 6,
        "jul": 7, "juil": 7, "july": 7, "juillet": 7,
        "aug": 8, "aout": 8, "august": 8,
        "sep": 9, "sept": 9, "september": 9, "septembre": 9,
        "oct": 10, "october": 10, "octobre": 10,
        "nov": 11, "november": 11, "novembre": 11,
        "dec": 12, "december": 12, "decembre": 12,
    ]

    private static let numeric = try! NSRegularExpression(pattern: "^(\\d{4})[-._](\\d{2})[-._](\\d{2})$")
    private static let named = try! NSRegularExpression(
        pattern: "^(?:[\\p{L}]+\\.?\\s+)?(\\d{1,2})\\s+([\\p{L}]+)\\.?\\s+(\\d{4})$"
    )

    /// `YYYY-MM-DD`, or nil when the name is not a day.
    static func day(of name: String) -> String? {
        // macOS lists accented names decomposed (`e` + accent), which a letter class does not match.
        let name = name.precomposedStringWithCanonicalMapping.trimmingCharacters(in: .whitespaces)
        let range = NSRange(name.startIndex..., in: name)
        func group(_ match: NSTextCheckingResult, _ index: Int) -> String {
            Range(match.range(at: index), in: name).map { String(name[$0]) } ?? ""
        }
        var year = "", month = 0, day = 0
        if let match = numeric.firstMatch(in: name, range: range) {
            year = group(match, 1)
            month = Int(group(match, 2)) ?? 0
            day = Int(group(match, 3)) ?? 0
        } else if let match = named.firstMatch(in: name, range: range) {
            let word = group(match, 2).folding(options: .diacriticInsensitive, locale: nil).lowercased()
            guard let number = months[word] else { return nil }
            year = group(match, 3)
            month = number
            day = Int(group(match, 1)) ?? 0
        } else {
            return nil
        }
        guard (1...12).contains(month), (1...31).contains(day) else { return nil }
        return String(format: "%@-%02d-%02d", year, month, day)
    }
}

/// The destinations of the standard Markdown links of a text, in place: the `](…)` of `[text](…)` and `![alt](…)`.
enum MarkdownLinks {
    struct Destination {
        /// The decoded path, without `<>`, title, `#fragment` or `?query`.
        let path: String
        /// What the link wrote between the parentheses, for a replacement.
        let range: Range<String.Index>
        /// What followed the path: a fragment, a query or a title.
        let suffix: String
    }

    /// The links to a file or note (not `https:`, `mailto:` or `#heading`), balancing the parentheses a file name has
    /// (`Image (2).webp`).
    static func destinations(in text: String) -> [Destination] {
        var result: [Destination] = []
        var index = text.startIndex
        while let open = text.range(of: "](", range: index..<text.endIndex) {
            var depth = 1
            var cursor = open.upperBound
            while cursor < text.endIndex, depth > 0 {
                let character = text[cursor]
                if character == "\n" { break }
                if character == "(" { depth += 1 }
                if character == ")" { depth -= 1 }
                if depth > 0 { cursor = text.index(after: cursor) }
            }
            guard depth == 0 else { index = open.upperBound; continue }
            let range = open.upperBound..<cursor
            index = text.index(after: cursor)
            if let destination = parse(String(text[range]), range: range) { result.append(destination) }
        }
        return result
    }

    private static func parse(_ raw: String, range: Range<String.Index>) -> Destination? {
        var target = raw.trimmingCharacters(in: .whitespaces)
        var title = ""
        if target.hasPrefix("<"), let close = target.firstIndex(of: ">") {
            title = String(target[target.index(after: close)...])
            target = String(target[target.index(after: target.startIndex)..<close])
        } else if let quote = target.range(of: " \"") {
            title = String(target[quote.lowerBound...])
            target = String(target[..<quote.lowerBound])
        }
        var suffix = ""
        if let mark = target.firstIndex(where: { $0 == "#" || $0 == "?" }) {
            suffix = String(target[mark...])
            target = String(target[..<mark])
        }
        guard !target.isEmpty, target.range(of: "^[A-Za-z][A-Za-z0-9+.-]*:", options: .regularExpression) == nil
        else { return nil }
        return Destination(path: target.removingPercentEncoding ?? target, range: range, suffix: suffix + title)
    }

    /// The targets of `[[wikilinks]]` and `![[embeds]]`, without alias or heading.
    static func wikilinkTargets(in text: String) -> [String] {
        var result: [String] = []
        var index = text.startIndex
        while let open = text.range(of: "[[", range: index..<text.endIndex) {
            guard let close = text.range(of: "]]", range: open.upperBound..<text.endIndex) else { break }
            let inner = text[open.upperBound..<close.lowerBound]
            if !inner.contains("\n") {
                let target = inner.prefix { $0 != "|" && $0 != "#" && $0 != "\\" }
                result.append(String(target))
            }
            index = close.upperBound
        }
        return result
    }
}
