import Foundation

/// The vault plugins this user approved, per vault, kept outside every vault.
///
/// A vault's `.loam/config.json` travels with the vault (a zip, a clone, a shared folder), so its `"enabled": true` is
/// not enough to run native code: a vault's own plugin loads only once someone turned it on here, on this machine,
/// for this vault (`plugins.enable`). A copy of the vault at another path asks again.
public struct PluginTrust: Sendable {
    /// Where the approvals are written; nil approves every plugin (tests).
    let fileURL: URL?

    public init(fileURL: URL?) {
        self.fileURL = fileURL
    }

    /// Approves every plugin, for tests that load plugins without enabling them through a command.
    public static let everything = PluginTrust(fileURL: nil)

    /// This user's file: `LOAM_TRUST_FILE` when set, else `Application Support/Loam/trusted-plugins.json`
    /// (`~/.local/share/loam/` on Linux).
    public static var onThisMachine: PluginTrust {
        if let path = ProcessInfo.processInfo.environment["LOAM_TRUST_FILE"], !path.isEmpty {
            return PluginTrust(fileURL: URL(fileURLWithPath: path))
        }
        #if os(macOS)
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return PluginTrust(fileURL: base.appendingPathComponent("Loam/trusted-plugins.json"))
        #else
        let home = FileManager.default.homeDirectoryForCurrentUser
        return PluginTrust(fileURL: home.appendingPathComponent(".local/share/loam/trusted-plugins.json"))
        #endif
    }

    public func isTrusted(_ id: String, in rootURL: URL) -> Bool {
        guard fileURL != nil else { return true }
        return read()[Self.key(rootURL)]?.contains(id) == true
    }

    public func trust(_ id: String, in rootURL: URL) throws {
        guard let fileURL else { return }
        var all = read()
        var ids = Set(all[Self.key(rootURL)] ?? [])
        guard ids.insert(id).inserted else { return }
        all[Self.key(rootURL)] = ids.sorted()
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(all).write(to: fileURL, options: .atomic)
    }

    /// Vault path → approved plugin ids. An unreadable file approves nothing.
    private func read() -> [String: [String]] {
        guard let fileURL, let data = try? Data(contentsOf: fileURL),
              let all = try? JSONDecoder().decode([String: [String]].self, from: data) else { return [:] }
        return all
    }

    private static func key(_ rootURL: URL) -> String {
        rootURL.standardizedFileURL.resolvingSymlinksInPath().path
    }
}
