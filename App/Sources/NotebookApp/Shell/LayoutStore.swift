import Foundation
import PluginKit
import WorkspaceModel

/// The window around the workspace: which sidebars show and which panel each one shows. Saved with the layout,
/// so the window comes back as it was left.
public struct WorkspaceChrome: Codable, Equatable, Sendable {
    public var showsLeading = true
    public var showsTrailing = true
    /// The selected panel of a slot with several; nil shows the first one.
    public var leadingPanel: String?
    public var trailingPanel: String?

    public init() {}
}

/// What is saved per machine: the workspace tree and the chrome.
public struct WorkspaceSnapshot: Codable, Equatable, Sendable {
    public var layout: WorkspaceLayout
    public var chrome: WorkspaceChrome

    public init(layout: WorkspaceLayout = WorkspaceLayout(), chrome: WorkspaceChrome = WorkspaceChrome()) {
        self.layout = layout
        self.chrome = chrome
    }
}

/// Reads and writes the layout at `.loam/cache/workspace/<machine-id>.json`. Per machine, so two Macs syncing one
/// vault do not fight over it; in the cache, so deleting it only loses the open tabs.
struct LayoutStore {
    let vault: VaultAccess
    let machineID: String

    var path: String { ".loam/cache/workspace/\(machineID).json" }

    /// The saved snapshot without the tabs of files that no longer exist, or nil when there is none or it cannot
    /// be read (an older format, a hand edit gone wrong): starting with an empty workspace beats failing.
    func load() -> WorkspaceSnapshot? {
        guard vault.exists(path), let text = try? vault.read(path),
              var snapshot = try? JSONDecoder().decode(WorkspaceSnapshot.self, from: Data(text.utf8)),
              (try? snapshot.layout.validate()) != nil
        else { return nil }
        snapshot.layout.closeAll { $0.kind == .file && !vault.exists($0.path) }
        return snapshot
    }

    func save(_ snapshot: WorkspaceSnapshot) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try vault.writeData(path, try encoder.encode(snapshot))
    }
}

/// A random id for this Mac, kept in the user defaults. It names the layout file; it is not tied to the hardware,
/// so nothing about the machine leaks into a synced vault.
public enum MachineID {
    static let key = "machineID"

    public static func current(defaults: UserDefaults = .standard) -> String {
        if let id = defaults.string(forKey: key), !id.isEmpty { return id }
        let id = UUID().uuidString
        defaults.set(id, forKey: key)
        return id
    }
}
