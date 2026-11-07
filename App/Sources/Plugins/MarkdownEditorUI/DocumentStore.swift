import Foundation
import PluginKitUI

/// The open documents by path: one per note however many tabs show it, counted, and released (saved, then
/// forgotten) when the last view showing it goes away. Owned by one activation of the plugin.
@MainActor
final class DocumentStore {
    let vault: VaultAccess
    /// The headings each note had folded, so they come back with the note.
    private(set) lazy var folds = NoteFoldStore(vault: vault)
    let saveDelay: Duration
    /// How long after typing stops `textChanged` is called.
    let notifyDelay: Duration
    /// Called with the note's path `notifyDelay` after typing in it stops; the plugin sends `DocumentTextChanged`.
    var textChanged: (@MainActor (String) -> Void)?
    private var entries: [String: (document: Document, views: Int)] = [:] {
        didSet { openPathSet.set(entries.keys) }
    }
    /// The open paths, readable from any thread: a plugin may read a note off the main thread (a command), and the
    /// plugin only hops to the main thread for a note that is open.
    nonisolated let openPathSet = PathSet()
    private var notifyTasks: [ObjectIdentifier: Task<Void, Never>] = [:]
    /// Notes announced with `beginDraft` whose file may not exist: they open blank instead of failing, also when a
    /// tab comes back to one ("Back") after it was left empty and dropped.
    private var knownDrafts: [String: String] = [:]
    /// The drafts whose last view went away: no longer shown, so their name is free for a new note.
    private var releasedDrafts: Set<String> = []
    /// Notes this session made (opened missing, so created by typing). One left empty is removed again when it is
    /// closed or the app quits; a note that was on disk before the session is never removed.
    private var createdPaths: Set<String> = []

    init(vault: VaultAccess, saveDelay: Duration = .milliseconds(500), notifyDelay: Duration = .milliseconds(300)) {
        self.vault = vault
        self.saveDelay = saveDelay
        self.notifyDelay = notifyDelay
    }

    /// An editor changed `document`: calls `textChanged` once typing has paused, with the path the note has then.
    private func edited(_ document: Document) {
        let key = ObjectIdentifier(document)
        notifyTasks[key]?.cancel()
        let delay = notifyDelay
        notifyTasks[key] = Task { [weak self, weak document] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self, let document else { return }
            self.notifyTasks[key] = nil
            guard !document.isClosed else { return }
            self.textChanged?(document.path)
        }
    }

    /// The paths of the open documents, sorted.
    var openPaths: [String] { entries.keys.sorted() }

    /// The open document of `path`, without taking it.
    func document(at path: String) -> Document? { entries[path]?.document }

    /// How many views hold the document of `path`.
    func viewCount(at path: String) -> Int { entries[path]?.views ?? 0 }

    /// A new note at `path`, not on disk: the editor shows it blank and only writes the file once it holds text.
    /// Open it with the workspace afterwards. A path that exists is left alone.
    func beginDraft(_ path: String, text: String = "") {
        guard !vault.exists(path) else { return }
        knownDrafts[path] = text
        releasedDrafts.remove(path)
    }

    /// True while `path` is a new note that is shown or waiting to be, and has no file yet.
    func isDraft(_ path: String) -> Bool {
        // An open note emptied by the user is a draft again until it gets text.
        if let entry = entries[path] { return !entry.document.existsOnDisk }
        return knownDrafts[path] != nil && !releasedDrafts.contains(path) && !vault.exists(path)
    }

    /// Takes the document of the note at `path` for one view, reading it on first use; nil when the file cannot
    /// be read. With `allowMissing`, a file that does not exist opens as a blank note that is only created on disk
    /// once it holds text. Every `acquire` is balanced by one `release`.
    func acquire(_ path: String, allowMissing: Bool = false) -> Document? {
        if let entry = entries[path] {
            entries[path] = (entry.document, entry.views + 1)
            return entry.document
        }
        let text: String
        var existsOnDisk = true
        var wasMissing = false
        if let read = try? vault.read(path) {
            text = read
        } else if allowMissing || knownDrafts[path] != nil, !vault.exists(path) {
            text = knownDrafts[path] ?? ""
            existsOnDisk = false
            createdPaths.insert(path)
            releasedDrafts.remove(path)
            wasMissing = true
        } else {
            return nil
        }
        let document = Document(path: path, text: text, vault: vault, saveDelay: saveDelay, existsOnDisk: existsOnDisk)
        document.onEdit = { [weak self] document in self?.edited(document) }
        if wasMissing {
            document.removesWhenEmpty = true
            // Once written, the note is an ordinary file: a vanished one must not reopen blank later.
            document.onFirstWrite = { [weak self] document in self?.knownDrafts[document.path] = nil }
        }
        entries[path] = (document, 1)
        return document
    }

    /// A view stopped showing `document`. The last one saves it and drops it. Found by identity, since the
    /// document may have moved (or been closed and replaced) since it was acquired.
    func release(_ document: Document) {
        guard let entry = entries[document.path], entry.document === document else { return }
        if entry.views > 1 {
            entries[document.path] = (document, entry.views - 1)
        } else {
            document.saveNow()
            entries[document.path] = nil
            discardIfEmpty(document)
        }
    }

    /// Takes a note this session made off the disk when it holds nothing; a draft that never got a file only
    /// frees its name. Returns whether a file was removed.
    @discardableResult
    private func discardIfEmpty(_ document: Document) -> Bool {
        let path = document.path
        if !document.existsOnDisk {
            if knownDrafts[path] != nil { releasedDrafts.insert(path) }
            return false
        }
        guard createdPaths.contains(path), (try? vault.removeIfEmpty(path)) == true else { return false }
        createdPaths.remove(path)
        if knownDrafts[path] != nil { releasedDrafts.insert(path) }
        return true
    }

    /// The app is closing: every note this session made that holds nothing leaves the disk.
    func discardEmptyNotes() {
        for entry in entries.values {
            entry.document.saveNow()
            discardIfEmpty(entry.document)
        }
    }

    /// Follows `VaultChanged`: reloads changed notes, closes deleted ones.
    func vaultChanged(_ changes: [VaultChange]) {
        for change in changes {
            guard let document = entries[change.path]?.document else { continue }
            switch change.kind {
            case .removed:
                // The document removed its own empty file: it stays open as a draft.
                if !document.existsOnDisk, !vault.exists(change.path) { continue }
                // A write that came right after the removal already brought the file back.
                if vault.exists(change.path) {
                    document.reloadFromDisk()
                    continue
                }
                document.close()
                entries[change.path] = nil
            case .added, .modified:
                document.reloadFromDisk()
            @unknown default:
                document.reloadFromDisk()
            }
        }
    }

    /// Another plugin is about to read `path` (`NoteWillRead`): unsaved typing is written first, so a plugin that
    /// reads, edits and writes the note starts from what the user sees. Nothing happens for a saved note.
    func willRead(_ path: String) {
        entries[path]?.document.saveNow()
    }

    /// Another plugin wrote `path` (`NoteDidChange`): show its change now rather than when the file system reports
    /// it. A document with unsaved typing keeps it, as for any outside change (`Document.reloadFromDisk`).
    func didChange(_ path: String) {
        entries[path]?.document.reloadFromDisk()
    }

    /// `NotesWillMove`: pending edits are written before the files move and their links are rewritten.
    func willMove(_ moves: [String: String]) {
        for old in moves.keys { entries[old]?.document.saveNow() }
    }

    /// `NotesMoved`: documents follow their file. Removed first, then re-added, so a chain of moves (A to B, B to C)
    /// does not lose one.
    func didMove(_ moves: [String: String]) {
        var moved: [(String, (document: Document, views: Int))] = []
        for (old, new) in moves {
            guard let entry = entries.removeValue(forKey: old) else { continue }
            moved.append((new, entry))
        }
        for (new, entry) in moved {
            entry.document.move(to: new)
            entries[new] = entry
        }
        for (old, new) in moves {
            if let seed = knownDrafts.removeValue(forKey: old) { knownDrafts[new] = seed }
            if releasedDrafts.remove(old) != nil { releasedDrafts.insert(new) }
            if createdPaths.remove(old) != nil { createdPaths.insert(new) }
        }
        // A moved note's links may have been rewritten on disk.
        for (_, entry) in moved { entry.document.reloadFromDisk() }
    }

    /// Called before `saveAll`: the editors send the typing they have not written yet (a long note's).
    var beforeSave: (@MainActor () -> Void)?

    func saveAll() {
        beforeSave?()
        for entry in entries.values { entry.document.saveNow() }
    }
}

/// A set of paths behind a lock, for checks from any thread.
final class PathSet: @unchecked Sendable {
    private let lock = NSLock()
    private var paths: Set<String> = []

    func set<S: Sequence>(_ paths: S) where S.Element == String {
        let new = Set(paths)
        lock.lock()
        self.paths = new
        lock.unlock()
    }

    func contains(_ path: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return paths.contains(path)
    }
}
