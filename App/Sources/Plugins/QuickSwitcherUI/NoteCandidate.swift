import PluginKitUI

/// A note the switcher can open. Gathered once when the popup opens, so typing only ranks and never touches
/// the disk.
struct NoteCandidate: Equatable, Sendable {
    let path: String
    let title: String
    /// Seconds since 1970; the empty query lists the most recently modified notes first.
    let modified: Double

    /// Every Markdown note, most recently modified first (by path when equal, so the order is stable).
    ///
    /// Titles come from the note graph when it is there (a frontmatter `title` or the first heading), so the
    /// user finds a note by the name they see in it; without it, from the file name.
    static func all(vault: VaultAccess, graph: NoteGraphService?) -> [NoteCandidate] {
        let stamps = (try? vault.stamps()) ?? [:]
        let titled: [(path: String, title: String)]
        if let graph {
            titled = graph.notes.map { ($0.path, $0.title) }
        } else {
            titled = ((try? vault.markdownPaths()) ?? []).map { ($0, Resource.file($0).name) }
        }
        return titled
            .map { NoteCandidate(path: $0.path, title: $0.title, modified: stamps[$0.path]?.modified ?? 0) }
            .sorted { $0.modified != $1.modified ? $0.modified > $1.modified : $0.path < $1.path }
    }
}
