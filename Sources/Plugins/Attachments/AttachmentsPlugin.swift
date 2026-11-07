import Foundation
import PluginKit

/// Files in notes: images, audio, video, PDFs and any other file dropped or pasted into a note are copied into one
/// folder at the vault's root (`Attachments`, unsorted, configurable) and linked with plain Markdown, `![](Attachments/a.png)`.
/// Provides the `attachments` service, whose processors let another plugin change a file on its way in (a
/// compressor), and the `attachments.*` commands. The editor side (drops, pastes, the players) is `AttachmentsUI`.
public final class AttachmentsPlugin: Plugin {
    public static var manifest: PluginManifest {
        PluginManifest(
            id: "attachments",
            name: "Attachments",
            version: "0.1.0",
            description: "Files dropped or pasted into a note go into one folder of the vault, linked from the note.",
            icon: "paperclip",
            provides: ["attachments"],
            optionalRequires: ["note-graph"],
            permissions: ["vault.read", "vault.write"],
            settings: [
                SettingDescription(
                    "attachmentsFolder", title: "Folder", help: "At the vault's root; every attachment goes there, unsorted.",
                    default: .string(AttachmentSettings.defaultFolder)
                ),
                SettingDescription(
                    "hideAttachmentsFolder", title: "Hide the folder", help: "Keeps it out of the file explorer; the files stay on disk.",
                    default: .bool(false)
                ),
            ]
        )
    }

    public required init() {}

    public func activate(context: PluginContext) throws {
        // The settings form lists what is stored: the defaults go in once, so "folder" and "hideFolder" show there.
        if context.settings.value(default: AttachmentSettings(folder: "")).folder.isEmpty {
            // A vault that already keeps its files in assets/ (and has no Attachments/) goes on doing so: one folder.
            let legacy = context.vault.exists(AttachmentSettings.legacyFolder) && !context.vault.exists(AttachmentSettings.defaultFolder)
            try? context.settings.update(AttachmentSettings(folder: legacy ? AttachmentSettings.legacyFolder : AttachmentSettings.defaultFolder))
        }
        let settings = context.settings
        let vault = context.vault
        let store = AttachmentStore(
            vault: context.vault,
            settings: { settings.value(default: AttachmentSettings()) },
            noteGraph: { [weak context] in context?.service(.noteGraph) },
            announce: { [weak context] event in context?.emit(event) }
        )
        try context.provide(.attachments, store as AttachmentsService)

        context.intercept(HiddenFolders.self) { event, next in
            var event = event
            let current = settings.value(default: AttachmentSettings())
            if current.hideFolder { event.paths.insert(current.folderPath) }
            return next(event)
        }
        context.intercept(ManagedFolders.self) { event, next in
            var event = event
            event.paths.insert(settings.value(default: AttachmentSettings()).folderPath)
            return next(event)
        }
        context.intercept(FolderIcons.self) { event, next in
            var event = event
            event.symbols[settings.value(default: AttachmentSettings()).folderPath] = "paperclip"
            return next(event)
        }
        let id = Self.manifest.id
        context.on(PluginSettingsChanged.self) { [weak context] event in
            if event.pluginID == id {
                context?.emit(HiddenFoldersChanged())
                context?.emit(ManagedFoldersChanged())
            }
        }

        try context.registerCommand(Command(
            id: "attachments.import",
            title: "Import a file into the attachments folder",
            summary: "Copies a file into the vault's attachments folder (\"Attachments\" by default) under a free name and "
                + "returns its path, kind and the Markdown link to it. Writes to the vault. Arguments: file (absolute "
                + "path on disk); optional: note (vault path of the note the link is for, so it is relative to it), "
                + "name (file name to use), append (\"true\" also appends the link to the end of the note).",
            isInPalette: false
        ) { arguments in
            let file = URL(fileURLWithPath: (try arguments.require("file") as NSString).expandingTildeInPath)
            guard FileManager.default.fileExists(atPath: file.path) else { throw VaultError.notFound(path: file.path) }
            let note = try arguments["note"].map(VaultPath.normalize)
            let imported = try await store.importFile(AttachmentImport(
                name: arguments["name"] ?? file.lastPathComponent, contents: .file(file), notePath: note
            ))
            if let note, Self.isTrue(arguments["append"]) {
                try Self.append(imported.markdown, to: note, in: vault)
            }
            return try JSON.string(imported)
        })

        try context.registerCommand(Command(
            id: "attachments.list",
            title: "List attachments",
            summary: "The files in the attachments folder, by name, with their kind (image, audio, video, pdf, file) "
                + "and size in bytes.",
            isInPalette: false
        ) { _ in
            try JSON.string(try store.list())
        })

        try context.registerCommand(Command(
            id: "attachments.replace",
            title: "Replace an attachment",
            summary: "Puts a new version of a file in place of an attachment (a compressed copy): the old one goes to "
                + ".trash/; a new name moves it and rewrites the links to it. Writes to the vault. Arguments: path "
                + "(vault path of the attachment), file (absolute path of the new version); optional: name.",
            isInPalette: false
        ) { arguments in
            let file = URL(fileURLWithPath: (try arguments.require("file") as NSString).expandingTildeInPath)
            return try JSON.string(try await store.replace(try arguments.require("path"), with: .file(file), name: arguments["name"]))
        })

        try context.registerCommand(Command(
            id: "attachments.hide-folder",
            title: "Hide or show the attachments folder",
            summary: "Hides the attachments folder from the file explorer, or shows it again; the files stay on disk. "
                + "Optional argument: hidden (\"true\" or \"false\", default: the opposite of now). Returns the folder "
                + "and whether it is hidden."
        ) { arguments in
            var current = settings.value(default: AttachmentSettings())
            current.hideFolder = arguments["hidden"].map(Self.isTrue) ?? !current.hideFolder
            try settings.update(current)
            return try JSON.string(HiddenState(folder: current.folderPath, hidden: current.hideFolder))
        })
    }

    static func isTrue(_ value: String?) -> Bool {
        ["true", "yes", "1"].contains(value?.lowercased() ?? "")
    }

    /// Appends `markdown` to the note as a paragraph of its own, reading the note right before writing it.
    static func append(_ markdown: String, to note: String, in vault: VaultAccess) throws {
        var text = vault.exists(note) ? try vault.read(note) : ""
        if !text.isEmpty {
            if !text.hasSuffix("\n") { text += "\n" }
            if !text.hasSuffix("\n\n") { text += "\n" }
        }
        try vault.write(note, text + markdown + "\n")
    }

    private struct HiddenState: Encodable {
        let folder: String
        let hidden: Bool
    }
}
