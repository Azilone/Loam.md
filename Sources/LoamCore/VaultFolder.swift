import Foundation

/// `.loam/` at the vault root: config, plugins, themes, cache. Vaults made before the app was called Loam have `.so/`
/// instead; `migrate` renames it when the vault opens.
public enum VaultFolder {
    public static let name = ".loam"
    static let legacyName = ".so"

    /// Renames `.so/` to `.loam/` when only `.so/` exists. Does nothing when both exist: the user decides then.
    public static func migrate(rootURL: URL) throws {
        let files = FileManager.default
        let legacy = rootURL.appendingPathComponent(legacyName, isDirectory: true)
        let current = rootURL.appendingPathComponent(name, isDirectory: true)
        var isFolder: ObjCBool = false
        guard files.fileExists(atPath: legacy.path, isDirectory: &isFolder), isFolder.boolValue,
              !files.fileExists(atPath: current.path) else { return }
        try files.moveItem(at: legacy, to: current)
    }
}
