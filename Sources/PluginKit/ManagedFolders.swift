import Foundation

/// Asked, as a waterfall, by a file browser: the folders whose files a plugin owns and gives a meaning (daily notes,
/// habits, projects, meetings, attachments). A browser lists them after the user's own folders and never drops a new,
/// unrelated note into them (it goes to the inbox instead), so a note does not turn into a habit or a project by
/// accident. The folders stay ordinary folders: shown, browsable, editable.
public struct ManagedFolders: PluginEvent, Sendable, Equatable {
    /// Vault-relative folder paths.
    public var paths: Set<String>

    public init(paths: Set<String> = []) {
        self.paths = paths
    }

    /// Where something new goes when it is made from `folder` (the folder of the open note or page; nil for none):
    /// that folder, unless it is the root or one of these folders, in which case the inbox. One rule for every
    /// "New …" of the app.
    public func newItemFolder(from folder: String?) -> String {
        guard let folder, !folder.isEmpty, !contains(folder) else { return VaultPath.inbox }
        return folder
    }

    /// True when `folder` is one of `paths` or inside one.
    public func contains(_ folder: String) -> Bool {
        paths.contains { !$0.isEmpty && (folder == $0 || folder.hasPrefix($0 + "/")) }
    }
}

/// Sent when a plugin's answer to `ManagedFolders` changed (its folder setting), so a browser asks again.
public struct ManagedFoldersChanged: PluginEvent, Sendable, Equatable {
    public init() {}
}
