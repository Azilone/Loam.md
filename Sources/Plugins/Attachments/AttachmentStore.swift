import Foundation
import PluginKit

/// The Attachments plugin's settings, in `.loam/config.json` under `plugins.attachments.settings`.
public struct AttachmentSettings: Codable, Equatable, Sendable {
    /// The folder at the vault's root that receives every attachment.
    public var folder = AttachmentSettings.defaultFolder
    /// Keeps the folder out of the file explorer; the files stay on disk and in links.
    public var hideFolder = false

    public static let defaultFolder = "Attachments"
    /// The folder vaults made before Loam named it `Attachments`: kept for a vault that already has it.
    public static let legacyFolder = "assets"

    /// The stored keys read as titles in the settings form: "Attachments folder", "Hide attachments folder".
    enum CodingKeys: String, CodingKey {
        case folder = "attachmentsFolder"
        case hideFolder = "hideAttachmentsFolder"
    }

    public init(folder: String = AttachmentSettings.defaultFolder, hideFolder: Bool = false) {
        self.folder = folder
        self.hideFolder = hideFolder
    }

    /// The folder as a vault path: normalized, never hidden, never empty or outside the vault (the default then).
    public var folderPath: String {
        guard let path = try? VaultPath.normalize(folder.trimmingCharacters(in: .whitespacesAndNewlines)), !path.isEmpty,
              !path.split(separator: "/").contains(where: { $0.hasPrefix(".") }) else { return Self.defaultFolder }
        return path
    }
}

/// The `attachments` service over a vault: copies files into one folder, unsorted, through the processors other
/// plugins added, and links them with plain Markdown.
///
/// Thread-safe: imports run wherever their caller's task runs, the processors and the reserved names behind a lock.
/// Events go out on the main thread, as the event bus expects.
public final class AttachmentStore: AttachmentsService, @unchecked Sendable {
    private let vault: VaultAccess
    private let settings: () -> AttachmentSettings
    private let noteGraph: () -> NoteGraphService?
    private let announce: (any PluginEvent) -> Void
    private let lock = NSLock()
    private var processors: [(token: Int, processor: AttachmentProcessor)] = []
    private var nextToken = 0
    /// Paths picked by imports still being written, so two imports at once never take the same name.
    private var reserved: Set<String> = []

    /// - Parameters:
    ///   - settings: the plugin's settings now, read at each import.
    ///   - noteGraph: the note graph if it is there now, to rewrite links when `replace` renames a file.
    ///   - announce: sends an event; called on the main thread.
    public init(
        vault: VaultAccess,
        settings: @escaping () -> AttachmentSettings = { AttachmentSettings() },
        noteGraph: @escaping () -> NoteGraphService? = { nil },
        announce: @escaping (any PluginEvent) -> Void = { _ in }
    ) {
        self.vault = vault
        self.settings = settings
        self.noteGraph = noteGraph
        self.announce = announce
    }

    public var folder: String { settings().folderPath }

    public func importFile(_ file: AttachmentImport) async throws -> ImportedAttachment {
        var file = file
        file.name = AttachmentNames.sanitized(file.name)
        // The same picture pasted twice is linked where it already is, not copied again.
        if let existing = existingCopy(of: try file.contents.data()) { return linked(existing, from: file.notePath) }
        for processor in currentProcessors() where processor.kinds.isEmpty || processor.kinds.contains(file.kind) {
            guard var processed = try? await processor.process(file) else { continue }
            processed.name = AttachmentNames.sanitized(processed.name)
            // The note stays the one the user dropped on.
            processed.notePath = file.notePath
            file = processed
        }
        let data = try file.contents.data()
        if let existing = existingCopy(of: data) { return linked(existing, from: file.notePath) }
        let path = reserve(file.name, in: folder)
        defer { release(path) }
        try vault.writeData(path, data)
        let imported = ImportedAttachment(
            path: path, kind: AttachmentKind(path: path), markdown: markdownLink(to: path, from: file.notePath)
        )
        await send(AttachmentImported(path: path, kind: imported.kind, notePath: file.notePath))
        return imported
    }

    public func markdownLink(to path: String, from notePath: String?) -> String {
        AttachmentNames.markdownLink(to: path)
    }

    public func addProcessor(_ processor: AttachmentProcessor) -> @Sendable () -> Void {
        lock.lock()
        defer { lock.unlock() }
        let token = nextToken
        nextToken += 1
        processors.append((token, processor))
        return { [weak self] in
            guard let self else { return }
            self.lock.lock()
            defer { self.lock.unlock() }
            self.processors.removeAll { $0.token == token }
        }
    }

    public func replace(_ path: String, with contents: AttachmentContents, name: String?) async throws -> AttachmentReplacement {
        let path = try VaultPath.normalize(path)
        guard !path.isEmpty, vault.exists(path) else { throw VaultError.notFound(path: path) }
        let data = try contents.data()
        // The old file stays recoverable, as a note moved to the trash does.
        let trashed = AttachmentNames.unique(
            (path as NSString).lastPathComponent, in: ".trash/" + VaultPath.directory(of: path), vault: vault
        )
        try vault.writeData(trashed, try Data(contentsOf: vault.rootURL.appendingPathComponent(path), options: .mappedIfSafe))

        // The new contents go in first, under the old name: a crash between the two steps leaves a file that is
        // whole, not a renamed copy of the old one.
        try vault.writeData(path, data)
        var newPath = path
        var updated: [String] = []
        do {
            if let name, AttachmentNames.sanitized(name) != (path as NSString).lastPathComponent {
                newPath = AttachmentNames.unique(AttachmentNames.sanitized(name), in: VaultPath.directory(of: path), vault: vault)
                if let graph = noteGraph() {
                    // The note graph announces the move to the app (open tabs follow it), which expects the main thread.
                    let target = newPath
                    updated = try await MainActor.run { try graph.move([path: target]).updated }
                } else {
                    try vault.move(path, to: newPath)
                }
            }
        } catch {
            // The move failed: the old contents go back under the old name, so no file holds bytes of another format.
            if let old = try? Data(contentsOf: vault.rootURL.appendingPathComponent(trashed), options: .mappedIfSafe) {
                try? vault.writeData(path, old)
            }
            try? FileManager.default.removeItem(at: vault.rootURL.appendingPathComponent(trashed))
            throw error
        }
        await send(AttachmentReplaced(oldPath: path, newPath: newPath))
        return AttachmentReplacement(path: newPath, trashed: trashed, updated: updated)
    }

    /// The files in the folder, by name, with their kind and size in bytes.
    public func list() throws -> [AttachmentEntry] {
        let folder = folder
        guard vault.exists(folder) else { return [] }
        return try vault.list(folder).filter { !$0.isFolder }.map { entry in
            let url = vault.rootURL.appendingPathComponent(entry.path)
            let size = ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int) ?? 0
            return AttachmentEntry(path: entry.path, kind: AttachmentKind(path: entry.path), size: size)
        }
    }

    // MARK: Private

    /// A file of the vault holding exactly `data` (not a note), the attachments folder's first; nil for an empty
    /// file, which says nothing about what it is. Only files of the same size are read.
    func existingCopy(of data: Data) -> String? {
        guard !data.isEmpty, let stamps = try? vault.stamps() else { return nil }
        let prefix = folder + "/"
        let candidates = stamps.filter { $0.value.size == data.count && !$0.key.lowercased().hasSuffix(".md") }.keys
            .sorted { ($0.hasPrefix(prefix) ? 0 : 1, $0) < ($1.hasPrefix(prefix) ? 0 : 1, $1) }
        return candidates.first { path in
            (try? Data(contentsOf: vault.rootURL.appendingPathComponent(path), options: .mappedIfSafe)) == data
        }
    }

    private func linked(_ path: String, from notePath: String?) -> ImportedAttachment {
        ImportedAttachment(path: path, kind: AttachmentKind(path: path), markdown: markdownLink(to: path, from: notePath))
    }

    private func currentProcessors() -> [AttachmentProcessor] {
        lock.lock()
        defer { lock.unlock() }
        return processors.map(\.processor)
    }

    private func reserve(_ name: String, in folder: String) -> String {
        lock.lock()
        defer { lock.unlock() }
        let path = AttachmentNames.unique(name, in: folder, vault: vault, taken: reserved)
        reserved.insert(path)
        return path
    }

    private func release(_ path: String) {
        lock.lock()
        defer { lock.unlock() }
        reserved.remove(path)
    }

    private func send(_ event: any PluginEvent) async {
        let announce = announce
        await MainActor.run { announce(event) }
    }
}

/// One file of the attachments folder, as `attachments.list` returns it.
public struct AttachmentEntry: Codable, Sendable, Equatable {
    public let path: String
    public let kind: AttachmentKind
    /// In bytes.
    public let size: Int
}
