import Foundation
import PluginKit

public extension ServiceKey where Service == CaptureStore {
    /// Saving captures into the capture collection; `CaptureUI` draws the window and asks the agent.
    static var capture: ServiceKey<CaptureStore> { ServiceKey<CaptureStore>("capture") }
}

/// Quick capture: a link, a picture, a PDF, some text or any file saved as a note in one collection ("Saved for
/// later" by default), at once and without any agent; exact duplicates are recognised and not saved twice. The window,
/// the shortcut and the agent's sorting are `CaptureUI` (docs/design/CAPTURE-PLUGIN-PLAN.md).
public final class CapturePlugin: Plugin {
    public static var manifest: PluginManifest {
        PluginManifest(
            id: "capture",
            name: "Quick capture",
            version: "0.1.0",
            description: "Saves what you copied into one collection, then lets your agent title, summarize and tag it.",
            icon: "tray.and.arrow.down",
            provides: ["capture"],
            optionalRequires: ["attachments", "note-query", "trash"],
            permissions: ["vault.read", "vault.write", "network"],
            settings: [
                SettingDescription(
                    "collection", title: "Collection",
                    help: "The folder captures go into. It opens as a collection with a gallery.",
                    default: .string(CaptureSettings.defaultCollection), folder: true
                ),
                SettingDescription(
                    "agent", title: "Agent",
                    help: "Who titles, summarizes and tags captures. Auto uses the Assistant's agent: the one you are signed in to with a plan.",
                    default: .string("auto"),
                    choices: [SettingChoice(.string("auto"), title: "Auto")] + [
                        ("claude", "Claude Code"), ("codex", "Codex"), ("antigravity", "Antigravity CLI"), ("pi", "Pi"),
                        ("opencode", "OpenCode"),
                    ].map { SettingChoice(.string($0.0), title: $0.1) }
                ),
                SettingDescription(
                    "useAgent", title: "Sort and summarize with my agent",
                    help: "What you capture is sent to your agent's provider. Off: captures are only saved.",
                    default: .bool(true)
                ),
            ]
        )
    }

    public required init() {}

    public func activate(context: PluginContext) throws {
        _ = context.settings.value(default: CaptureSettings())
        let settings = context.settings
        let vault = context.vault
        let store = CaptureStore(
            vault: context.vault,
            settings: { settings.value(default: CaptureSettings()) },
            attachments: { [weak context] in context?.service(.attachments) },
            noteQuery: { [weak context] in context?.service(.noteQuery) },
            trash: { [weak context] in context?.service(.trash) }
        )
        try context.provide(.capture, store)

        try context.registerCommand(Command(
            id: "capture.add",
            title: "Capture a link, text or file",
            summary: "Saves one item into the capture collection (\"Saved for later\" by default) as a note, with its "
                + "file in the attachments folder; a link also gets its page's title, description and picture. An item "
                + "already saved is not saved again. Writes to the vault. Arguments: url, text or file (absolute path); "
                + "optional: note (a few words to keep with it). Returns JSON: path, title, kind, duplicate, files.",
            isInPalette: false
        ) { arguments in
            let note = arguments["note"] ?? ""
            let item: CaptureContent
            if let url = arguments["url"] {
                item = .link(url: url, title: arguments["title"])
            } else if let file = arguments["file"] {
                let url = URL(fileURLWithPath: (file as NSString).expandingTildeInPath)
                guard FileManager.default.fileExists(atPath: url.path) else { throw VaultError.notFound(path: url.path) }
                item = .file(name: url.lastPathComponent, contents: .file(url))
            } else {
                item = .text(try arguments.require("text"))
            }
            var outcome = try await store.save(item, note: note)
            if case let .link(url, _) = item, !outcome.duplicate, let address = URL(string: url),
               let metadata = await LinkMetadata.fetch(address) {
                let cover = await Self.cover(for: metadata)
                outcome.path = try await store.enrich(outcome.path, with: metadata, cover: cover)
                outcome.title = CaptureStore.title(of: outcome.path)
            }
            return try JSON.string(outcome)
        })

        try context.registerCommand(Command(
            id: "capture.recent",
            title: "List recent captures",
            summary: "The captures of this session, newest first: path, title, kind, duplicate, files.",
            isInPalette: false
        ) { _ in
            try JSON.string(store.recent())
        })

        try context.registerCommand(Command(
            id: "capture.undo",
            title: "Undo last capture",
            summary: "Moves the last capture (or the one at path) and its files to the trash, where it stays 30 days. "
                + "Writes to the vault. Optional argument: path.",
            isInPalette: false
        ) { arguments in
            let recent = store.recent()
            let wanted = arguments["path"].map { path in recent.first { $0.path == path } } ?? recent.first { !$0.duplicate }
            guard let outcome = wanted else { return "Nothing to undo." }
            try store.undo(outcome)
            return "Moved \(outcome.title) to the trash."
        })

        try context.registerCommand(Command(
            id: "capture.set-collection",
            title: "Set the capture collection",
            summary: "Makes captures go into the folder at path (created, with a gallery, at the next capture). Writes "
                + "the plugin's settings. Argument: path.",
            isInPalette: false
        ) { arguments in
            let folder = try VaultPath.normalize(try arguments.require("path"))
            guard !folder.isEmpty, !folder.hasPrefix(".") else { throw CommandError.missingArgument(name: "path") }
            var current = settings.value(default: CaptureSettings())
            current.collection = folder
            try settings.update(current)
            return "Captures now go into \(folder)."
        })

        // A collection folder renamed in the app keeps receiving captures.
        context.on(NotesMoved.self) { event in
            let folder = store.folder
            // A folder rename moves every note in it; the note moves name the new folder.
            let renamed = event.moves.first { from, to in
                VaultPath.directory(of: from) == folder && (to as NSString).lastPathComponent == (from as NSString).lastPathComponent
                    && VaultPath.directory(of: to) != folder
            }
            // Only a rename of the folder itself: a note dragged out of it leaves the folder where it is.
            guard let renamed, !vault.exists(folder) else { return }
            var current = settings.value(default: CaptureSettings())
            current.collection = VaultPath.directory(of: renamed.value)
            try? settings.update(current)
        }
    }

    /// The page's preview picture, downloaded, with a file name for the attachments folder.
    public static func cover(for metadata: LinkMetadata) async -> (name: String, data: Data)? {
        guard let image = metadata.image, let url = URL(string: image), let data = await LinkMetadata.download(url) else { return nil }
        let ext = url.pathExtension.lowercased()
        let known = ["png", "jpg", "jpeg", "gif", "webp", "heic"]
        return ("cover." + (known.contains(ext) ? ext : "jpg"), data)
    }
}
