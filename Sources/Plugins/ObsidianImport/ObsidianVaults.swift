import Foundation
import PluginKit

/// An Obsidian vault found on this Mac.
public struct ObsidianVault: Codable, Equatable, Sendable, Identifiable {
    public var id: String { path }
    /// The folder's name, as Obsidian shows it.
    public let name: String
    public let path: String
    /// Markdown notes in it, its `.obsidian`, `.trash` and `.git` excepted.
    public let notes: Int
    /// When Obsidian last opened it.
    public let opened: Date?

    public init(name: String, path: String, notes: Int, opened: Date?) {
        self.name = name
        self.path = path
        self.notes = notes
        self.opened = opened
    }
}

/// Finds the vaults Obsidian knows, from its own list (`obsidian.json` in its Application Support folder). Reads
/// only; a vault whose folder is gone is left out.
public enum ObsidianVaults {
    public static var defaultList: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/obsidian/obsidian.json")
    }

    /// The vaults in `list`, most recently opened first.
    public static func find(list: URL = defaultList) -> [ObsidianVault] {
        guard let data = try? Data(contentsOf: list),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let vaults = json["vaults"] as? [String: [String: Any]]
        else { return [] }
        return vaults.values.compactMap { entry -> ObsidianVault? in
            guard let path = entry["path"] as? String else { return nil }
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue
            else { return nil }
            // Obsidian stores milliseconds.
            let opened = (entry["ts"] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) }
            return ObsidianVault(
                name: (path as NSString).lastPathComponent, path: path, notes: countNotes(in: path), opened: opened
            )
        }
        .sorted { ($0.opened ?? .distantPast) > ($1.opened ?? .distantPast) }
    }

    /// The vault at `url`, for one Obsidian does not list.
    public static func vault(at url: URL) -> ObsidianVault {
        ObsidianVault(name: url.lastPathComponent, path: url.path, notes: countNotes(in: url.path), opened: nil)
    }

    static func countNotes(in path: String) -> Int {
        let root = URL(fileURLWithPath: path)
        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else { return 0 }
        var count = 0
        for case let url as URL in enumerator where url.pathExtension.lowercased() == "md" { count += 1 }
        return count
    }
}

/// What the `obsidian-import` service offers: the vaults to import and the import itself.
public protocol ObsidianImporting: AnyObject {
    func vaults() -> [ObsidianVault]
    func run(_ options: ImportOptions) throws -> ImportReport
    /// The import, telling `progress` where it stands and leaving the caller's thread free while it runs. Throws an
    /// `ImportFailure` when a file cannot be copied.
    /// It runs on `isolation`, the caller's actor, giving it back every few milliseconds.
    func run(
        _ options: ImportOptions, progress: @escaping (ImportProgress) -> Void, isolation: isolated (any Actor)?
    ) async throws -> ImportReport
}

public extension ServiceKey where Service == any ObsidianImporting {
    static var obsidianImport: ServiceKey<any ObsidianImporting> { ServiceKey<any ObsidianImporting>("obsidian-import") }
}

/// Asks for `path`, an Obsidian vault, to be imported: the import page opens on it and starts at once, with the
/// agent finishing it when `useAgent` (and an agent is ready). The intro's welcome card sends it when the user brings
/// their notes.
public struct ObsidianImportRequested: PluginEvent, Sendable {
    public let path: String
    public let useAgent: Bool

    public init(path: String, useAgent: Bool = true) {
        self.path = path
        self.useAgent = useAgent
    }
}

/// Where an import started by `ObsidianImportRequested` stands, for whoever shows it (the intro's card).
public enum ObsidianImportProgress: PluginEvent, Sendable, Equatable {
    /// Copying the notes.
    case copying(ImportProgress)
    /// The agent at work; `status` is what it is doing now.
    case finishing(agent: String, status: String)
    /// Over: the report note is at `reportPath`.
    case done(converted: Int, reportPath: String)
    /// Stopped: `message` says why, `progress` how far it went (`file` is the one that failed).
    case failed(message: String, progress: ImportProgress)
}
