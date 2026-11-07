import PluginKitUI

/// A card's checklist: the task lines of its note (`- [ ]`, `- [x]`), done and in all.
struct BoardChecklist: Equatable {
    let done: Int
    let total: Int
}

/// The checklists of the notes on a board, read once per change of a note (its modification time).
@MainActor
final class BoardChecklists {
    private let vault: VaultAccess
    private var cache: [String: (modified: Double, list: BoardChecklist?)] = [:]

    init(vault: VaultAccess) {
        self.vault = vault
    }

    func checklist(of entry: NoteRecord) -> BoardChecklist? {
        if let cached = cache[entry.path], cached.modified == entry.modified { return cached.list }
        let list = (try? vault.read(entry.path)).flatMap(Self.count)
        cache[entry.path] = (entry.modified, list)
        return list
    }

    /// The task lines outside the frontmatter and fenced code; nil when there are none.
    nonisolated static func count(_ text: String) -> BoardChecklist? {
        var done = 0, total = 0
        var lines = text.components(separatedBy: "\n")[...]
        if lines.first?.trimmingCharacters(in: .whitespaces) == "---",
           let close = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) {
            lines = lines[(close + 1)...]
        }
        var inFence = false
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") { inFence.toggle(); continue }
            guard !inFence, let match = trimmed.range(of: #"^([-*+]|\d+[.)]) \[( |x|X)\] \S"#, options: .regularExpression)
            else { continue }
            total += 1
            if trimmed[match].contains("[x]") || trimmed[match].contains("[X]") { done += 1 }
        }
        return total > 0 ? BoardChecklist(done: done, total: total) : nil
    }
}
