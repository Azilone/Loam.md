import Foundation
import Observation
import PluginKitUI

/// The Backlinks panel's state: the note it follows, the notes linking to it with the lines where they do, and the
/// notes mentioning its title without a link. The view only reads it and calls `open`, so tests drive the panel
/// through it.
@MainActor
@Observable
final class BacklinksModel {
    /// A piece of a context line; `isMatch` marks the link (or the mention) to the followed note.
    struct Fragment: Hashable, Sendable {
        let text: String
        let isMatch: Bool
    }

    /// One line of a source note, its Markdown links shown as their text.
    struct ContextLine: Identifiable, Hashable, Sendable {
        /// The line number in the source note: unique within one entry.
        let id: Int
        let fragments: [Fragment]

        var text: String { fragments.map(\.text).joined() }
    }

    enum Kind: String, Sendable { case backlink, mention, board }

    /// A note listed in the panel.
    struct Entry: Identifiable, Hashable, Sendable {
        /// Prefixed by the section: a note may not be in both, but the two lists share one scroll view, and SwiftUI
        /// draws duplicate ids as empty rows.
        var id: String { kind.rawValue + ":" + path }
        let kind: Kind
        let path: String
        let title: String
        /// The folder it is in, empty at the root.
        let folder: String
        let lines: [ContextLine]
    }

    /// The context lines shown per note.
    nonisolated static let maxLines = 2
    /// The unlinked mentions listed at most.
    nonisolated static let maxMentions = 20
    /// Shorter titles match too many words to be useful mentions.
    nonisolated static let minMentionLength = 3
    /// The pause, in milliseconds, before the mentions scan starts: switching notes quickly scans only the last one.
    static let mentionsDelay = 120

    /// The note followed: the focused tab's Markdown file, nil when none is open.
    private(set) var active: String?
    private(set) var activeTitle = ""
    private(set) var backlinks: [Entry] = []
    private(set) var mentions: [Entry] = []
    /// The boards with a card for the followed note, when the canvas plugin runs.
    private(set) var boards: [Entry] = []

    @ObservationIgnored private let vault: VaultAccess
    @ObservationIgnored private let graph: NoteGraphService
    @ObservationIgnored private let workspace: @MainActor () -> (any Workspace)?
    @ObservationIgnored private let noteBoards: @MainActor () -> NoteBoardsService?

    init(vault: VaultAccess, graph: NoteGraphService, workspace: @escaping @MainActor () -> (any Workspace)?,
         boards: @escaping @MainActor () -> NoteBoardsService? = { nil }) {
        self.vault = vault
        self.graph = graph
        self.workspace = workspace
        self.noteBoards = boards
    }

    // MARK: Following the open note

    /// Follows the focused tab: a Markdown file, or nothing.
    func activeChanged(_ resource: Resource?) {
        let path = resource.flatMap { $0.kind == .file && Self.isNote($0.path) ? $0.path : nil }
        guard path != active else { return }
        active = path
        // The previous note's mentions are not this note's: drop them now, the scan fills them in a moment.
        if !mentions.isEmpty { mentions = [] }
        refresh()
    }

    /// Keeps following the note when it, or its folder, moved.
    func notesMoved(_ moves: [String: String]) {
        if let active, let moved = moves[active] { self.active = moved }
        refresh()
    }

    @ObservationIgnored private var waitsForGraph = false

    /// The note graph finished its first read: refreshes if a refresh was skipped for it.
    func graphLoaded() {
        if waitsForGraph { refresh() }
    }

    /// Reads the backlinks and mentions of the followed note again.
    func refresh() {
        guard let active else {
            mentionsTask?.cancel()
            update(title: "", backlinks: [], mentions: [])
            if !boards.isEmpty { boards = [] }
            return
        }
        // At launch the graph may still be reading the vault: `graphLoaded()` refreshes once it has.
        guard (graph as? NoteGraphLoading)?.isLoaded ?? true else {
            waitsForGraph = true
            return
        }
        waitsForGraph = false
        let title = title(of: active)
        let linking = graph.backlinks(to: active)
        let newBacklinks = linking.compactMap { source -> Entry? in
            guard let text = try? vault.read(source) else { return nil }
            return Entry(
                kind: .backlink,
                path: source,
                title: self.title(of: source),
                folder: VaultPath.directory(of: source),
                lines: Self.linkLines(in: text, source: source, target: active)
            )
        }
        update(title: title, backlinks: newBacklinks, mentions: nil)
        scheduleMentions(of: title, target: active, excluding: Set(linking))
        let newBoards = ((try? noteBoards()?.boards(showing: active)) ?? []).map { board in
            Entry(kind: .board, path: board, title: ((board as NSString).lastPathComponent as NSString).deletingPathExtension,
                  folder: VaultPath.directory(of: board), lines: [])
        }
        if newBoards != boards { boards = newBoards }
    }

    private func update(title: String, backlinks: [Entry], mentions: [Entry]?) {
        // Assigning only on change keeps SwiftUI from redrawing the panel on every unrelated vault change.
        if title != activeTitle { activeTitle = title }
        if backlinks != self.backlinks { self.backlinks = backlinks }
        if let mentions, mentions != self.mentions { self.mentions = mentions }
    }

    /// The scan reads every note of the vault, so it runs off the main thread, a moment after the last change, and
    /// only the newest scan is kept. It reads the files directly: a note being typed in is at most one autosave old,
    /// and the save refreshes the panel again.
    @ObservationIgnored private var mentionsTask: Task<Void, Never>?

    /// Waits for the scan started by the last `refresh` (tests, and anything that needs the final list).
    func settled() async {
        await mentionsTask?.value
    }

    private func scheduleMentions(of title: String, target: String, excluding: Set<String>) {
        mentionsTask?.cancel()
        let candidates = graph.notes.map(\.path).sorted()
        let root = vault.rootURL
        mentionsTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(Self.mentionsDelay))
            guard !Task.isCancelled else { return }
            let found = await Task.detached(priority: .utility) {
                Self.unlinkedMentions(
                    of: title, target: target, candidates: candidates, excluding: excluding,
                    read: { try? String(contentsOf: root.appendingPathComponent($0), encoding: .utf8) },
                    isCancelled: { Task.isCancelled }
                )
            }.value
            guard !Task.isCancelled, let self, active == target else { return }
            let entries = found.map { mention in
                Entry(
                    kind: .mention,
                    path: mention.path,
                    title: self.title(of: mention.path),
                    folder: VaultPath.directory(of: mention.path),
                    lines: mention.lines
                )
            }
            if entries != mentions { mentions = entries }
        }
    }

    private func title(of path: String) -> String {
        if let title = graph.note(at: path)?.title, !title.isEmpty { return title }
        return Resource.file(path).name
    }

    static func isNote(_ path: String) -> Bool { path.lowercased().hasSuffix(".md") }

    // MARK: Actions

    /// A click on a note: in the focused tab, or beside it with Command held.
    func open(_ path: String, beside: Bool) {
        workspace()?.open(.file(path), placement: beside ? .beside : .replace)
    }

    /// The unlinked mentions of `path` (or of the followed note), for the `backlinks.mentions` command.
    func mentionsReport(for path: String?) throws -> String {
        let normalized = try path.map { try VaultPath.normalize($0) }
        guard let target = normalized ?? active else { return "No note is open." }
        let mentions = Self.unlinkedMentions(
            of: title(of: target),
            target: target,
            candidates: graph.notes.map(\.path).sorted(),
            excluding: Set(graph.backlinks(to: target)),
            read: { [vault] in try? vault.read($0) }
        )
        return try JSON.string(mentions.map { mention in
            MentionReport(path: mention.path, title: title(of: mention.path), lines: mention.lines.map(\.text))
        })
    }

    private struct MentionReport: Encodable {
        let path: String
        let title: String
        let lines: [String]
    }

    // MARK: Scanning text (pure, so tested without a vault)

    /// `[text](destination)`, optionally an image (`!`), the destination maybe in angle brackets and followed by a
    /// title.
    private static let linkPattern = try! NSRegularExpression(
        pattern: #"(!?)\[((?:[^\[\]]|\[[^\]]*\])*)\]\(\s*(<[^>]*>|[^)\s]*)(?:\s+(?:"[^"]*"|'[^']*'))?\s*\)"#
    )

    /// The lines of `text` (written in the note at `source`) with a Markdown link resolving to `target`, at most
    /// `maxLines`, trimmed. Links show as their text; those to `target` are marked.
    static func linkLines(in text: String, source: String, target: String) -> [ContextLine] {
        var result: [ContextLine] = []
        for (number, line) in bodyLines(of: text) {
            let ns = line as NSString
            var fragments: [Fragment] = []
            var cursor = 0
            var found = false
            for match in linkPattern.matches(in: line, range: NSRange(location: 0, length: ns.length)) {
                let isImage = match.range(at: 1).length > 0
                let label = ns.substring(with: match.range(at: 2))
                var destination = ns.substring(with: match.range(at: 3))
                if destination.hasPrefix("<") { destination = String(destination.dropFirst().dropLast()) }
                if match.range.location > cursor {
                    fragments.append(Fragment(text: ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor)), isMatch: false))
                }
                let isTarget = !isImage && resolve(destination, from: source) == target
                found = found || isTarget
                fragments.append(Fragment(text: isImage ? ns.substring(with: match.range) : label, isMatch: isTarget))
                cursor = match.range.location + match.range.length
            }
            guard found else { continue }
            if cursor < ns.length {
                fragments.append(Fragment(text: ns.substring(from: cursor), isMatch: false))
            }
            result.append(ContextLine(id: number, fragments: trimmed(fragments)))
            if result.count == maxLines { break }
        }
        return result
    }

    /// The vault path a link destination points at, nil for anything but a note of the vault (a URL, an anchor).
    static func resolve(_ destination: String, from source: String) -> String? {
        guard !destination.isEmpty, !destination.hasPrefix("#"),
              destination.range(of: "^[A-Za-z][A-Za-z0-9+.-]*:", options: .regularExpression) == nil
        else { return nil }
        let cut = destination.firstIndex { $0 == "#" || $0 == "?" } ?? destination.endIndex
        let raw = String(destination[..<cut])
        let decoded = raw.removingPercentEncoding ?? raw
        guard isNote(decoded) else { return nil }
        return try? VaultPath.resolve(decoded, from: source)
    }

    /// The notes among `candidates` whose text has `title` as a whole word, case-insensitive, except `target`
    /// itself and `excluding` (the notes that already link to it). At most `maxMentions`, in `candidates` order;
    /// none when the title is shorter than `minMentionLength`.
    nonisolated static func unlinkedMentions(
        of title: String,
        target: String,
        candidates: [String],
        excluding: Set<String>,
        read: (String) -> String?,
        isCancelled: () -> Bool = { false }
    ) -> [(path: String, lines: [ContextLine])] {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard title.count >= minMentionLength,
              let pattern = try? NSRegularExpression(
                  pattern: #"(?<![\p{L}\p{N}_])"# + NSRegularExpression.escapedPattern(for: title) + #"(?![\p{L}\p{N}_])"#,
                  options: [.caseInsensitive]
              )
        else { return [] }
        var found: [(path: String, lines: [ContextLine])] = []
        for path in candidates where path != target && !excluding.contains(path) {
            if isCancelled() { return [] }
            // A quick test on the whole text first: most notes do not mention the title at all.
            guard let text = read(path), text.range(of: title, options: .caseInsensitive) != nil else { continue }
            let lines = mentionLines(in: text, pattern: pattern)
            guard !lines.isEmpty else { continue }
            found.append((path, lines))
            if found.count == maxMentions { break }
        }
        return found
    }

    private nonisolated static func mentionLines(in text: String, pattern: NSRegularExpression) -> [ContextLine] {
        var result: [ContextLine] = []
        for (number, line) in bodyLines(of: text) {
            let ns = line as NSString
            let matches = pattern.matches(in: line, range: NSRange(location: 0, length: ns.length))
            guard !matches.isEmpty else { continue }
            var fragments: [Fragment] = []
            var cursor = 0
            for match in matches {
                if match.range.location > cursor {
                    fragments.append(Fragment(text: ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor)), isMatch: false))
                }
                fragments.append(Fragment(text: ns.substring(with: match.range), isMatch: true))
                cursor = match.range.location + match.range.length
            }
            if cursor < ns.length { fragments.append(Fragment(text: ns.substring(from: cursor), isMatch: false)) }
            result.append(ContextLine(id: number, fragments: trimmed(fragments)))
            if result.count == maxLines { break }
        }
        return result
    }

    /// The lines after the YAML frontmatter, numbered from 0 in the whole text.
    private nonisolated static func bodyLines(of text: String) -> [(Int, String)] {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map {
            $0.hasSuffix("\r") ? String($0.dropLast()) : String($0)
        }
        var start = 0
        if lines.first == "---", let end = lines.dropFirst().firstIndex(where: { $0 == "---" || $0 == "..." }) {
            start = end + 1
        }
        return (start..<lines.count).map { ($0, lines[$0]) }
    }

    /// Removes the leading and trailing whitespace of the line, and empty fragments.
    private nonisolated static func trimmed(_ fragments: [Fragment]) -> [Fragment] {
        var fragments = fragments.filter { !$0.text.isEmpty }
        if let first = fragments.first {
            fragments[0] = Fragment(text: String(first.text.drop { $0.isWhitespace }), isMatch: first.isMatch)
        }
        if let last = fragments.last {
            var text = last.text
            while text.last?.isWhitespace == true { text.removeLast() }
            fragments[fragments.count - 1] = Fragment(text: text, isMatch: last.isMatch)
        }
        return fragments.filter { !$0.text.isEmpty }
    }
}
