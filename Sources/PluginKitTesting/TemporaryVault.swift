import Foundation
import PluginKit
import LoamCore

/// A real `Vault` in a fresh folder under the system temporary directory, removed when the object goes
/// away. Tests use it instead of a hand-written fake so they exercise the same file code as the app,
/// and never touch a user's vault.
public final class TemporaryVault: VaultAccess {
    private let vault: Vault

    public init() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("loam-vault-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        vault = Vault(rootURL: root)
    }

    deinit {
        try? FileManager.default.removeItem(at: vault.rootURL)
    }

    /// The file URL of a vault-relative path, for checks that go around `VaultAccess`.
    public func url(_ path: String) -> URL {
        vault.rootURL.appendingPathComponent(path)
    }

    public var rootURL: URL { vault.rootURL }
    public func markdownPaths() throws -> [String] { try vault.markdownPaths() }
    public func stamps() throws -> [String: FileStamp] { try vault.stamps() }
    public func exists(_ path: String) -> Bool { vault.exists(path) }
    public func read(_ path: String) throws -> String { try vault.read(path) }
    public func write(_ path: String, _ text: String) throws { try vault.write(path, text) }
    public func writeData(_ path: String, _ data: Data) throws { try vault.writeData(path, data) }
    public func move(_ from: String, to: String) throws { try vault.move(from, to: to) }
    public func list(_ folder: String) throws -> [VaultEntry] { try vault.list(folder) }
    public func createFolder(_ path: String) throws { try vault.createFolder(path) }
    public func removeIfEmpty(_ path: String) throws -> Bool { try vault.removeIfEmpty(path) }
}
