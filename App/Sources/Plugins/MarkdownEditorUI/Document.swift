import Foundation
import Observation
import PluginKitUI

/// One open note: its text, saved shortly after typing stops and reloaded when the file changes outside the app.
/// Every tab showing the note shares this object, so two editors on one file never overwrite each other.
@MainActor
@Observable
final class Document {
    private(set) var path: String
    private(set) var text: String
    /// Bumped on every change of `text`, with `lastEditor` saying which editor made it (nil: read from disk), so an
    /// editor refreshes for changes made elsewhere and not for its own typing.
    private(set) var revision = 0
    private(set) var lastEditor: UUID?
    private(set) var hasUnsavedChanges = false
    private(set) var errorMessage: String?
    /// The file was deleted: the document no longer saves, and its views say so.
    private(set) var isClosed = false
    /// False for a note opened before its file exists (a new note, a day's daily note): the file is only created once
    /// the note holds some text, so looking at one never leaves an empty note behind.
    private(set) var existsOnDisk: Bool

    /// What a new note starts with (a template): saving it unchanged writes nothing.
    @ObservationIgnored private let seed: String
    @ObservationIgnored private let vault: VaultAccess
    @ObservationIgnored private let saveDelay: Duration
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    /// The file's text as last written or read here: a reload that finds something else was changed outside the app.
    @ObservationIgnored private var diskText: String?
    /// Says where the other version went after such a change; a later successful save shows it again, not nothing.
    @ObservationIgnored private var conflictNotice: String?
    /// Called after every edit from an editor (not a reload from disk); the store uses it to send
    /// `DocumentTextChanged`.
    @ObservationIgnored var onEdit: (@MainActor (Document) -> Void)?
    /// Set for a note this session made: once it holds nothing again its file is removed at once, and the note goes
    /// back to being a draft (the tab stays open), so an emptied note never lingers on disk.
    @ObservationIgnored var removesWhenEmpty = false
    /// Called when the file is first written.
    @ObservationIgnored var onFirstWrite: (@MainActor (Document) -> Void)?

    init(path: String, text: String, vault: VaultAccess, saveDelay: Duration, existsOnDisk: Bool = true) {
        seed = existsOnDisk ? "" : text
        self.path = path
        self.text = text
        self.existsOnDisk = existsOnDisk
        diskText = existsOnDisk ? text : nil
        self.vault = vault
        self.saveDelay = saveDelay
    }

    /// An editor changed the text: save it `saveDelay` after typing stops.
    func edit(_ newText: String, from editor: UUID) {
        // The editor's string is a bridged NSString: comparing it with a native one (here, and when `text` notifies
        // its observers) goes character by character through Unicode normalisation, milliseconds on a long note.
        var newText = newText
        if !newText.isContiguousUTF8 { newText.makeContiguousUTF8() }
        guard !isClosed, newText != text else { return }
        text = newText
        lastEditor = editor
        revision += 1
        hasUnsavedChanges = true
        onEdit?(self)
        saveTask?.cancel()
        let delay = saveDelay
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    /// Writes the note now if it has unsaved changes.
    func saveNow() {
        saveTask?.cancel()
        saveTask = nil
        guard hasUnsavedChanges, !isClosed else { return }
        if !existsOnDisk, NoteContent.isEmpty(text) || text == seed {
            hasUnsavedChanges = false
            return
        }
        if existsOnDisk, removesWhenEmpty, NoteContent.isEmpty(text) {
            do {
                // The file holds the last saved text, not this one: write it, then remove it (only if empty).
                try vault.write(path, text)
                try vault.removeIfEmpty(path)
                existsOnDisk = false
                hasUnsavedChanges = false
                errorMessage = conflictNotice
            } catch {
                errorMessage = "Could not save \(path): \(error)"
            }
            return
        }
        do {
            try vault.write(path, text)
            diskText = text
            if !existsOnDisk { onFirstWrite?(self) }
            existsOnDisk = true
            hasUnsavedChanges = false
            errorMessage = conflictNotice
        } catch {
            errorMessage = "Could not save \(path): \(error)"
        }
    }

    /// The file changed on disk. With an edit waiting to be saved the editor's version wins, and the other one is kept
    /// beside the note so nothing is lost; otherwise the document takes the file as it is now. Our own save reads back
    /// the same text, so it changes nothing.
    func reloadFromDisk() {
        guard !isClosed, let disk = try? vault.read(path) else { return }
        if hasUnsavedChanges {
            if disk != text, disk != diskText, existsOnDisk { keepCopy(of: disk) }
            diskText = disk
            return
        }
        existsOnDisk = true
        diskText = disk
        guard disk != text else { return }
        text = disk
        lastEditor = nil
        revision += 1
    }

    /// Writes `disk`, the version this note's next save replaces, to a new note beside it.
    private func keepCopy(of disk: String) {
        let base = path.hasSuffix(".md") ? String(path.dropLast(3)) : path
        var copy = "\(base) (changed on disk).md"
        var number = 2
        while vault.exists(copy) {
            copy = "\(base) (changed on disk \(number)).md"
            number += 1
        }
        do {
            try vault.write(copy, disk)
            conflictNotice = "\(path) changed outside Loam while you were typing: the other version is in \(copy)."
            errorMessage = conflictNotice
        } catch {
            errorMessage = "\(path) changed outside Loam while you were typing, and its other version could not be kept: \(error)"
        }
    }

    /// The note moved (`NotesMoved`): later saves go to the new path.
    func move(to newPath: String) {
        path = newPath
    }

    /// The file was deleted outside the app: drop the pending save, which would bring it back.
    func close() {
        saveTask?.cancel()
        saveTask = nil
        hasUnsavedChanges = false
        isClosed = true
    }
}
