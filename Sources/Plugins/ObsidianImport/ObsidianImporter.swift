import Foundation
import PluginKit

public struct ImportOptions {
    public var source: URL
    /// Folder of the current vault to import into; empty means the vault root.
    public var into: String
    public var dryRun: Bool
    public var overwrite: Bool
    /// Keeps every file at its own path. By default, importing at the vault's root puts daily notes in the daily notes
    /// folder (`YYYY-MM-DD.md`) and the files notes link to in the attachments folder, as Loam does.
    public var keepLayout: Bool

    public init(
        source: URL, into: String = "", dryRun: Bool = false, overwrite: Bool = false, keepLayout: Bool = false
    ) {
        self.source = source
        self.into = into
        self.dryRun = dryRun
        self.overwrite = overwrite
        self.keepLayout = keepLayout
    }
}

public struct ImportReport: Codable, Equatable {
    public struct DailyNotesHint: Codable, Equatable {
        public let folder: String
        public let format: String
        public let template: String
    }

    public let dryRun: Bool
    /// Notes converted to plain Markdown.
    public var converted = 0
    /// Other files copied: images and PDFs as they are; `.canvas` boards (already JSON Canvas) with their file paths
    /// moved into the destination folder and the wikilinks of their text cards made standard links.
    public var copied = 0
    /// Daily notes put in the daily notes folder, named `YYYY-MM-DD.md`.
    public var dailyNotesMoved = 0
    /// Files put in the attachments folder (they are among `copied`).
    public var attachmentsMoved = 0
    /// Files that already existed in the destination and were left alone.
    public var skipped: [String] = []
    public var warnings: [String] = []
    /// Obsidian's daily notes settings, so you can match them in this app.
    public var dailyNotes: DailyNotesHint?
    /// The community plugins the vault had on (`dataview`, `templater-obsidian`): what plain Markdown loses.
    public var communityPlugins: [String] = []

    public init(dryRun: Bool) {
        self.dryRun = dryRun
    }
}

/// Where an import stands: `done` of the `total` notes, the one being copied and the next few.
public struct ImportProgress: Sendable, Equatable {
    public var done: Int
    public var total: Int
    /// The note being copied, relative to the Obsidian vault; nil before the first and after the last.
    public var file: String?
    /// The notes after it, at most three.
    public var next: [String]

    public init(done: Int, total: Int, file: String? = nil, next: [String] = []) {
        self.done = done
        self.total = total
        self.file = file
        self.next = next
    }
}

/// A file of the Obsidian vault that could not be copied: the import stops there.
public struct ImportFailure: Error, CustomStringConvertible {
    /// Relative to the Obsidian vault.
    public let file: String
    public let reason: String
    /// The notes copied before it.
    public let done: Int
    public let total: Int

    public var description: String { "\(file): \(reason)" }
}

/// Reads an Obsidian vault (never modifies it) and writes a converted copy into the current vault.
public final class ObsidianImporter: ObsidianImporting {
    private let vault: VaultAccess
    private static let ignoredFolders: Set<String> = [".obsidian", ".trash", ".git"]

    private let list: URL
    private let dailyNotesFolder: () -> String?
    private let attachmentsFolder: () -> String?

    /// `dailyNotesFolder` and `attachmentsFolder` give the folders of the vault's daily notes and attachments, nil
    /// when it has none: without them, files keep their paths.
    public init(
        vault: VaultAccess, list: URL = ObsidianVaults.defaultList,
        dailyNotesFolder: @escaping () -> String? = { nil }, attachmentsFolder: @escaping () -> String? = { nil }
    ) {
        self.vault = vault
        self.list = list
        self.dailyNotesFolder = dailyNotesFolder
        self.attachmentsFolder = attachmentsFolder
    }

    public func vaults() -> [ObsidianVault] {
        ObsidianVaults.find(list: list)
    }

    public func run(_ options: ImportOptions) throws -> ImportReport {
        var run = try start(options)
        while try run.step() {}
        return run.report
    }

    /// The same import, giving the caller's thread back every few milliseconds (so a window on it stays drawn) and
    /// telling `progress` where it stands after each note.
    public func run(
        _ options: ImportOptions, progress: @escaping (ImportProgress) -> Void,
        isolation: isolated (any Actor)? = #isolation
    ) async throws -> ImportReport {
        var run = try start(options)
        progress(run.progress)
        let clock = ContinuousClock()
        var slice = clock.now
        while try run.step() {
            progress(run.progress)
            if clock.now - slice > .milliseconds(12) {
                try await Task.sleep(for: .milliseconds(1))
                slice = clock.now
            }
        }
        progress(run.progress)
        return run.report
    }

    private func start(_ options: ImportOptions) throws -> ImportRun {
        let into = try VaultPath.normalize(options.into)
        let files = try listFiles(in: options.source)
        let notes = files.filter { $0.lowercased().hasSuffix(".md") }
        let resolver = NoteResolver(notePaths: notes, filePaths: files)
        var converter = ObsidianConverter(resolver: resolver, destinationFolder: into)
        var report = ImportReport(dryRun: options.dryRun)
        report.dailyNotes = dailyNotesHint(in: options.source)
        report.communityPlugins = communityPlugins(in: options.source)
        if into.isEmpty, !options.keepLayout {
            let layout = ImportLayout.plan(
                notes: notes, files: files, resolver: resolver,
                dailyFolder: dailyNotesFolder(), attachmentsFolder: attachmentsFolder(),
                obsidianDailyFolder: report.dailyNotes?.folder,
                read: { try? String(contentsOf: options.source.appendingPathComponent($0), encoding: .utf8) }
            )
            converter.layout = layout
            report.dailyNotesMoved = layout.dailyNotes
            report.attachmentsMoved = layout.attachments
            report.warnings.append(contentsOf: layout.warnings)
        }
        return ImportRun(vault: vault, options: options, converter: converter, files: files, notes: notes, report: report)
    }

    private func listFiles(in source: URL) throws -> [String] {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: source.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw VaultError.notFound(path: source.path)
        }
        guard let enumerator = FileManager.default.enumerator(
            at: source, includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey], options: []
        ) else { return [] }

        let root = source.standardizedFileURL.path
        var files: [String] = []
        for case let url as URL in enumerator {
            let full = url.standardizedFileURL.path
            guard full.hasPrefix(root + "/") else { continue }
            let relative = String(full.dropFirst(root.count + 1))
            let first = String(relative.split(separator: "/").first ?? "")
            if Self.ignoredFolders.contains(first) {
                // Only on a folder: after a file (a `.git` file, as git worktrees have) it skips the next folder.
                let isFolder = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
                if first == (relative as NSString).lastPathComponent, isFolder { enumerator.skipDescendants() }
                continue
            }
            if (relative as NSString).lastPathComponent == ".DS_Store" { continue }
            if (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true { files.append(relative) }
        }
        return files.sorted()
    }

    private func communityPlugins(in source: URL) -> [String] {
        let url = source.appendingPathComponent(".obsidian/community-plugins.json")
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([String].self, from: data)) ?? []
    }

    private func dailyNotesHint(in source: URL) -> ImportReport.DailyNotesHint? {
        let url = source.appendingPathComponent(".obsidian/daily-notes.json")
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return ImportReport.DailyNotesHint(
            folder: json["folder"] as? String ?? "",
            format: json["format"] as? String ?? "YYYY-MM-DD",
            template: json["template"] as? String ?? ""
        )
    }
}

/// One import, a file at a time.
private struct ImportRun {
    let vault: VaultAccess
    let options: ImportOptions
    let converter: ObsidianConverter
    let files: [String]
    let notes: [String]
    private let noteSet: Set<String>
    var report: ImportReport
    private var index = 0
    private var notesDone = 0

    init(vault: VaultAccess, options: ImportOptions, converter: ObsidianConverter, files: [String], notes: [String], report: ImportReport) {
        self.vault = vault
        self.options = options
        self.converter = converter
        self.files = files.sorted()
        self.notes = notes.sorted()
        noteSet = Set(notes)
        self.report = report
    }

    var progress: ImportProgress {
        let upcoming = notes.dropFirst(notesDone)
        return ImportProgress(done: notesDone, total: notes.count, file: upcoming.first, next: Array(upcoming.dropFirst().prefix(3)))
    }

    /// Copies the next file; false once every file is done.
    mutating func step() throws -> Bool {
        guard index < files.count else { return false }
        let path = files[index]
        index += 1
        do {
            try copy(path)
        } catch {
            throw ImportFailure(file: path, reason: Self.reason(error), done: notesDone, total: notes.count)
        }
        if noteSet.contains(path) { notesDone += 1 }
        return index < files.count
    }

    private mutating func copy(_ path: String) throws {
        let destination = converter.destinationPath(path)
        if vault.exists(destination), !options.overwrite {
            report.skipped.append(destination)
            return
        }
        let sourceURL = options.source.appendingPathComponent(path)
        if noteSet.contains(path) {
            guard let text = try? String(contentsOf: sourceURL, encoding: .utf8) else {
                report.warnings.append("\(path): not valid UTF-8, skipped")
                return
            }
            let converted = converter.convert(text, notePath: path, warnings: &report.warnings)
            if !options.dryRun { try vault.write(destination, converted) }
            report.converted += 1
        } else if (path as NSString).pathExtension.lowercased() == "canvas" {
            let data = try Data(contentsOf: sourceURL)
            let converted = converter.convertCanvas(data, canvasPath: path, warnings: &report.warnings)
            if !options.dryRun { try vault.writeData(destination, converted ?? data) }
            if converted == nil { report.warnings.append("\(path): not a JSON Canvas file, copied as it is") }
            report.copied += 1
        } else {
            if !options.dryRun { try vault.writeData(destination, try Data(contentsOf: sourceURL)) }
            report.copied += 1
        }
    }

    /// The error in a few words, as a person would say it.
    private static func reason(_ error: Error) -> String {
        switch (error as? CocoaError)?.code {
        case .fileReadNoPermission?, .fileWriteNoPermission?: "permission denied"
        case .fileWriteOutOfSpace?: "the disk is full"
        case .fileReadNoSuchFile?, .fileNoSuchFile?: "the file is gone"
        case .fileLocking?: "locked by another app"
        default: (error as NSError).localizedDescription
        }
    }
}
