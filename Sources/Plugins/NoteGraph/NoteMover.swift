import Foundation
import PluginKit

extension NoteGraphIndex {
    /// Every check runs and every new text is computed before the first file moves, so an invalid
    /// move or an unreadable note leaves the vault untouched. `NotesWillMove` is sent after the checks
    /// and before the texts are read, so an editor saving pending edits on it does not lose them.
    public func move(_ moves: [String: String]) throws -> MoveResult {
        let requested = try MovePlan.validate(moves, in: vault)
        let files = try MovePlan.expand(requested, in: vault)
        willMove(files)

        var writes: [(path: String, text: String)] = []
        for path in try vault.markdownPaths() {
            let text = try vault.read(path)
            let newPath = files[path] ?? path
            let rewritten = LinkRewriter.rewrite(text, notePath: path, newNotePath: newPath, moves: files, exists: { self.vault.exists($0) })
            if rewritten != text { writes.append((newPath, rewritten)) }
        }

        for (from, to) in requested.sorted(by: { $0.key < $1.key }) { try vault.move(from, to: to) }
        for write in writes { try vault.write(write.path, write.text) }
        // Only the notes that moved or were rewritten change: a full `reindex()` here read every note again, in
        // parallel, while the caller (the sidebar's drop, on the main thread) waited, and a read that hops to the
        // main thread (an editor flushing unsaved typing on `NoteWillRead`) then waited for it: a frozen app.
        refresh(removed: Array(files.keys), changed: Array(Set(files.values).union(writes.map(\.path))))
        didMove(files)
        return MoveResult(moves: files, updated: writes.map(\.path).sorted())
    }
}

/// Checks and expansion for `NoteGraphIndex.move`, kept apart from the disk changes.
enum MovePlan {
    /// Normalized moves, or the first problem found.
    static func validate(_ moves: [String: String], in vault: VaultAccess) throws -> [String: String] {
        var normalized: [String: String] = [:]
        for (from, to) in moves {
            let from = try VaultPath.normalize(from)
            let to = try VaultPath.normalize(to)
            guard !from.isEmpty else { throw VaultError.outsideVault(path: from) }
            guard !to.isEmpty else { throw VaultError.outsideVault(path: to) }
            normalized[from] = to
        }
        for (from, to) in normalized.sorted(by: { $0.key < $1.key }) {
            guard vault.exists(from) else { throw VaultError.notFound(path: from) }
            if isFolder(from, in: vault) {
                guard to != from, !to.hasPrefix(from + "/") else { throw NoteGraphError.moveIntoItself(path: to) }
            } else if from.lowercased().hasSuffix(".md"), !to.lowercased().hasSuffix(".md") {
                throw NoteGraphError.notMarkdown(path: to)
            }
            guard !vault.exists(to) else { throw VaultError.alreadyExists(path: to) }
            // Moving `a` and `a/b`, or into a folder that is itself moving, would depend on the order.
            for other in normalized.keys where other != from {
                if from.hasPrefix(other + "/") { throw NoteGraphError.conflictingMoves(path: from) }
                if to == other || to.hasPrefix(other + "/") { throw NoteGraphError.conflictingMoves(path: to) }
            }
        }
        return normalized
    }

    /// File moves: a folder becomes one entry per file under it, hidden files excepted.
    static func expand(_ moves: [String: String], in vault: VaultAccess) throws -> [String: String] {
        var files: [String: String] = [:]
        var targets: Set<String> = []
        func add(_ from: String, _ to: String) throws {
            guard targets.insert(to).inserted else { throw NoteGraphError.conflictingMoves(path: to) }
            files[from] = to
        }
        for (from, to) in moves {
            guard isFolder(from, in: vault) else {
                try add(from, to)
                continue
            }
            for file in try filesUnder(from, in: vault) {
                try add(file, to + file.dropFirst(from.count))
            }
        }
        return files
    }

    /// Only folders can be listed; this also works for hidden ones, such as a folder in `.trash`.
    private static func isFolder(_ path: String, in vault: VaultAccess) -> Bool {
        (try? vault.list(path)) != nil
    }

    private static func filesUnder(_ folder: String, in vault: VaultAccess) throws -> [String] {
        try vault.list(folder).flatMap { $0.isFolder ? try filesUnder($0.path, in: vault) : [$0.path] }
    }
}
