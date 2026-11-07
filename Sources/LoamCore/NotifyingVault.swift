import Foundation
import PluginKit

/// The vault as one plugin sees it (`context.vault`): the kernel's vault, plus `NoteWillRead` before a read and
/// `NoteWillChange` / `NoteDidChange` around a write or a move, carrying the plugin's id. This is how an editor with
/// unsaved typing keeps a plugin's write from being lost to it, or from overwriting it. Listings, stamps and
/// `createFolder` pass through silently; so does the kernel's own `vault`.
struct NotifyingVault: VaultAccess {
    let base: VaultAccess
    let pluginID: String
    let events: EventBus

    var rootURL: URL { base.rootURL }
    func markdownPaths() throws -> [String] { try base.markdownPaths() }
    func stamps() throws -> [String: FileStamp] { try base.stamps() }
    func exists(_ path: String) -> Bool { base.exists(path) }
    func list(_ folder: String) throws -> [VaultEntry] { try base.list(folder) }
    func createFolder(_ path: String) throws { try base.createFolder(path) }

    func read(_ path: String) throws -> String {
        events.emit(NoteWillRead(path: Self.normalized(path), pluginID: pluginID))
        return try base.read(path)
    }

    func write(_ path: String, _ contents: String) throws {
        try changing([path]) { try base.write(path, contents) }
    }

    func writeData(_ path: String, _ data: Data) throws {
        try changing([path]) { try base.writeData(path, data) }
    }

    func move(_ from: String, to: String) throws {
        try changing([from, to]) { try base.move(from, to: to) }
    }

    func removeIfEmpty(_ path: String) throws -> Bool {
        var removed = false
        try changing([path]) { removed = try base.removeIfEmpty(path) }
        return removed
    }

    private func changing(_ paths: [String], _ body: () throws -> Void) throws {
        let paths = paths.map(Self.normalized)
        for path in paths { events.emit(NoteWillChange(path: path, pluginID: pluginID)) }
        try body()
        for path in paths { events.emit(NoteDidChange(path: path, pluginID: pluginID)) }
    }

    /// The path as listeners key notes; an invalid one is passed as is (the vault refuses it anyway).
    private static func normalized(_ path: String) -> String {
        (try? VaultPath.normalize(path)) ?? path
    }
}
