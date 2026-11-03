import Foundation
import MarkdownEditor
import PluginKitUI

/// The pages the `@` and `[[` menus offer, Craft's "link to a page": notes, and the files of Loam's own formats other
/// plugins open (boards, drawings, mindmaps). Choosing one writes a standard Markdown link to it, relative to the
/// note being edited (`[Plan](../Projects/Plan.md)`).
enum NoteMentions {
    static let section = "Notes"
    /// Under the days in the `@` menu, a few notes are enough; `[[` is only notes, so it lists more.
    static let mentionLimit = 5
    static let linkLimit = 8

    /// A note the menus can link.
    struct Candidate: Equatable, Sendable {
        let path: String
        let title: String
        /// Seconds since 1970; with nothing typed, the most recently modified notes come first.
        let modified: Double
    }

    /// Whether the menus offer the file at `path`: a note, or a file whose view is one of Loam's own formats (a
    /// board), not a viewer of outside files (pictures, PDFs), which links show in place instead.
    @MainActor
    static func isPage(_ path: String, views: (any ViewRegistry)?) -> Bool {
        if path.lowercased().hasSuffix(".md") { return true }
        guard let view = views?.viewTypes(for: .file(path)).first else { return false }
        return !view.keepsExtension
    }

    /// Every page, most recently modified first (by path when equal). `stamps` are the pages' files, read once until
    /// files come or go, so typing never touches the disk. A note's title comes from the note graph when it is there
    /// (a frontmatter `title` or the first heading), anything else's from its file name.
    static func candidates(stamps: [String: FileStamp], graph: NoteGraphService?) -> [Candidate] {
        let titles = Dictionary(graph?.notes.map { ($0.path, $0.title) } ?? [], uniquingKeysWith: { first, _ in first })
        return stamps
            .map { path, stamp in
                Candidate(path: path, title: titles[path] ?? Resource.file(path).name, modified: stamp.modified)
            }
            .sorted { $0.modified != $1.modified ? $0.modified > $1.modified : $0.path < $1.path }
    }

    /// The notes for `query`, best first, never the note being edited. `fuzzy`: the query's letters in order (`[[`,
    /// where only notes are typed); otherwise the title must contain it, so `@tomorrow` does not list every note
    /// with a t, an o and an m.
    static func rank(_ query: String, in candidates: [Candidate], excluding notePath: String, fuzzy: Bool,
                     limit: Int) -> [Candidate] {
        let others = candidates.filter { $0.path != notePath }
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return Array(others.prefix(limit)) }
        let scored = others.enumerated().compactMap { offset, note -> (Int, Candidate, Int)? in
            if !fuzzy, note.title.range(of: trimmed, options: [.caseInsensitive, .diacriticInsensitive]) == nil {
                return nil
            }
            return Fuzzy.score(trimmed, in: note.title).map { (offset, note, $0) }
        }
        return scored.sorted { $0.2 != $1.2 ? $0.2 > $1.2 : $0.0 < $1.0 }.prefix(limit).map(\.1)
    }

    /// The names the menu shows: each page's title, but the file name for pages sharing a title (three mindmaps
    /// titled "Mindmap"), and the folder after it when files share their name too.
    static func displayNames(_ pages: [Candidate]) -> [String: String] {
        let titles = Dictionary(grouping: pages, by: \.title)
        var names: [String: String] = [:]
        for page in pages {
            guard titles[page.title, default: []].count > 1 else {
                names[page.path] = page.title
                continue
            }
            let name = Resource.file(page.path).name
            let sameName = pages.filter { Resource.file($0.path).name == name }.count > 1
            let folder = VaultPath.directory(of: page.path)
            names[page.path] = sameName && !folder.isEmpty ? "\(name) — \(folder)" : name
        }
        return names
    }

    /// Replaces `trigger` (`@` or `[[` and the words after it) with a link to `path` from the note at `notePath`,
    /// followed by a space unless one follows already; the caret after it.
    static func change(in text: String, trigger: NSRange, linking path: String, titled title: String,
                       from notePath: String) -> TextEdit {
        let ns = text as NSString
        var range = trigger
        // `[[Plan]]`: closing brackets typed after the name go with it.
        if NSMaxRange(range) + 2 <= ns.length, ns.substring(with: NSRange(location: NSMaxRange(range), length: 2)) == "]]" {
            range.length += 2
        }
        let destination = VaultPath.relativeDestination(fromDirectory: VaultPath.directory(of: notePath), to: path)
        let following = NSMaxRange(range) < ns.length ? ns.character(at: NSMaxRange(range)) : 10
        let link = "[\(linkText(title))](\(destination))" + (following == 32 ? "" : " ")
        let caret = range.location + (link as NSString).length + (following == 32 ? 1 : 0)
        return TextEdit(range: range, replacement: link, selection: NSRange(location: caret, length: 0))
    }

    /// `title` as link text: brackets and backslashes escaped, so the link stays one link.
    static func linkText(_ title: String) -> String {
        var result = ""
        for character in title {
            if character == "[" || character == "]" || character == "\\" { result.append("\\") }
            result.append(character)
        }
        return result
    }
}
