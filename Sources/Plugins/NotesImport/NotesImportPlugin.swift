import Foundation
import PluginKit

/// What the `notes-import` service offers: the sources on this Mac and the import from each.
public protocol NotesImporting: AnyObject {
    /// The sources that can be imported here: Apple Notes always on a Mac, Bear when it is installed. Notion needs its
    /// export, so it is always offered.
    func available() -> [NotesSource]
    /// Imports `source` into the folder `into`; `file` is Notion's export (a folder or a .zip).
    func run(_ source: NotesSource, file: URL?, into: String, dryRun: Bool) throws -> NotesImportReport
}

public extension ServiceKey where Service == any NotesImporting {
    static var notesImport: ServiceKey<any NotesImporting> { ServiceKey<any NotesImporting>("notes-import") }
}

/// `import.notion`, `import.bear` and `import.apple-notes`: notes from other apps as plain Markdown in the vault. The
/// sources are only read.
public final class NotesImportPlugin: Plugin, NotesImporting {
    public static var manifest: PluginManifest {
        PluginManifest(
            id: "notes-import",
            name: "Notes import",
            version: "0.1.0",
            description: "Brings notes from Notion, Bear and Apple Notes as plain Markdown.",
            icon: "tray.and.arrow.down",
            provides: ["notes-import"],
            permissions: ["vault.read", "vault.write", "disk.read", "shell"]
        )
    }

    public required init() {}

    private var vault: VaultAccess?

    public func activate(context: PluginContext) throws {
        vault = context.vault
        try context.provide(.notesImport, self)
        let options = "Optional: into (folder of this vault; Imported/<source> by default), dry-run=true."
        try context.registerCommand(Command(
            id: "import.notion",
            title: "Import a Notion export",
            summary: "Converts a Notion export (Markdown & CSV, a folder or its .zip) into plain Markdown: ids off "
                + "names and links, page properties as frontmatter, databases as collections. Arguments: source "
                + "(the export's path). \(options) Returns the report as JSON.",
            isInPalette: false
        ) { [weak self] arguments in
            let source = URL(fileURLWithPath: (try arguments.require("source") as NSString).expandingTildeInPath)
            return try JSON.string(try self?.command(.notion, file: source, arguments) ?? NotesImportReport(dryRun: true))
        })
        try context.registerCommand(Command(
            id: "import.bear",
            title: "Import Bear notes",
            summary: "Copies Bear's notes (read from its database) as Markdown, archived ones in Archive/, with their "
                + "pictures and files. \(options) Returns the report as JSON.",
            isInPalette: false
        ) { [weak self] arguments in
            try JSON.string(try self?.command(.bear, file: nil, arguments) ?? NotesImportReport(dryRun: true))
        })
        try context.registerCommand(Command(
            id: "import.apple-notes",
            title: "Import Apple Notes",
            summary: "Copies every Apple Notes note (through Notes' scripting; macOS asks once) as Markdown, a folder "
                + "per Notes folder, with their pictures. \(options) Returns the report as JSON.",
            isInPalette: false
        ) { [weak self] arguments in
            try JSON.string(try self?.command(.appleNotes, file: nil, arguments) ?? NotesImportReport(dryRun: true))
        })
    }

    private func command(_ source: NotesSource, file: URL?, _ arguments: [String: String]) throws -> NotesImportReport {
        try run(source, file: file, into: arguments["into"] ?? "Imported/\(source.name)", dryRun: arguments["dry-run"] == "true")
    }

    public func available() -> [NotesSource] {
        var sources: [NotesSource] = [.notion]
        if BearImporter.isInstalled() { sources.append(.bear) }
        #if os(macOS)
        sources.append(.appleNotes)
        #endif
        return sources
    }

    public func run(_ source: NotesSource, file: URL?, into: String, dryRun: Bool) throws -> NotesImportReport {
        guard let vault else { throw NotesImportError.missing("The vault") }
        switch source {
        case .notion:
            guard let file else { throw CommandError.missingArgument(name: "source") }
            return try NotionImporter(vault: vault).run(source: file, into: into, dryRun: dryRun)
        case .bear: return try BearImporter(vault: vault).run(into: into, dryRun: dryRun)
        case .appleNotes: return try AppleNotesImporter(vault: vault).run(into: into, dryRun: dryRun)
        }
    }
}
