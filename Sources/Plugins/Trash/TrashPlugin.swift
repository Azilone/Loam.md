import Foundation
import PluginKit

/// The vault's trash: provides the `trash` service and the `trash.*` commands. Things are put into `.trash/` by
/// `files.trash` (which tells this plugin, so the date is kept); here they are listed, restored, deleted for good,
/// and deleted automatically once they are older than the retention (30 days by default, the `retentionDays`
/// setting, 0 to keep everything). The purge runs when asked: the app does it when a vault opens and every hour
/// (`TrashUI`), agents with `trash.purge`.
public final class TrashPlugin: Plugin {
    public static var manifest: PluginManifest {
        PluginManifest(
            id: "trash",
            name: "Trash",
            version: "0.1.0",
            description: "Deleted notes and files wait in the vault's .trash folder, then go for good after 30 days.",
            icon: "trash",
            provides: ["trash"],
            permissions: ["vault.read", "vault.write"],
            settings: [
                SettingDescription(
                    "retentionDays", title: "Keep deleted items for",
                    help: "Days before an item in Recently Deleted is deleted for good; 0 keeps them.",
                    default: .number(Double(TrashStore.defaultRetentionDays))
                ),
            ]
        )
    }

    /// Stored in `.loam/config.json` under `plugins.trash.settings`.
    public struct Settings: Codable, Equatable {
        /// Days an item stays in the trash before it is deleted for good. 0 never deletes by itself.
        public var retentionDays = TrashStore.defaultRetentionDays

        public init(retentionDays: Int = TrashStore.defaultRetentionDays) {
            self.retentionDays = retentionDays
        }
    }

    public required init() {}

    public func activate(context: PluginContext) throws {
        let store = TrashStore(
            vault: context.vault,
            retentionDays: { [weak context] in context?.settings.value(default: Settings()).retentionDays ?? 30 },
            changed: { [weak context] in context?.emit(TrashChanged()) },
            restored: { [weak context] paths in
                context?.emit(VaultChanged(changes: paths.map { VaultChange(kind: .added, path: $0) }))
            }
        )
        try context.provide(.trash, store)

        try context.registerCommand(Command(
            id: "trash.list",
            title: "List the trash",
            summary: "Lists what is in the vault's .trash/: path (inside the trash), originalPath, isFolder, trashedAt, "
                + "expiresAt and daysLeft (items are deleted for good after the retention, 30 days by default), most "
                + "recently trashed first.",
            isInPalette: false
        ) { _ in
            try JSON.string(try store.items())
        })

        try context.registerCommand(Command(
            id: "trash.restore",
            title: "Restore from the trash",
            summary: "Moves an item of the trash back to its original path, or to a free \"Name 2\" variant when "
                + "that is taken. Writes to the vault. Argument: path (as trash.list gives it). Returns the new path.",
            isInPalette: false
        ) { arguments in
            try JSON.string(["path": try store.restore(try arguments.require("path"))])
        })

        try context.registerCommand(Command(
            id: "trash.delete",
            title: "Delete from the trash for good",
            summary: "Permanently deletes one item of the trash. It cannot be undone. Argument: path (as "
                + "trash.list gives it).",
            isInPalette: false
        ) { arguments in
            let path = try arguments.require("path")
            try store.deleteForever(path)
            return try JSON.string(["deleted": path])
        })

        try context.registerCommand(Command(
            id: "trash.empty",
            title: "Empty the trash",
            summary: "Permanently deletes everything in the trash. It cannot be undone. Returns how many items went.",
            isInPalette: false
        ) { _ in
            try JSON.string(["deleted": try store.empty()])
        })

        try context.registerCommand(Command(
            id: "trash.purge",
            title: "Purge the expired trash",
            summary: "Permanently deletes the items trashed more than the retention ago (30 days by default). "
                + "Returns the paths it deleted.",
            isInPalette: false
        ) { _ in
            try JSON.string(["deleted": try store.purgeExpired()])
        })
    }
}
