import Foundation

/// The sync's settings, in `.loam/config.json` (`plugins.git-sync.settings`). They travel with the vault, so they
/// hold no secret, no remote address (git keeps that) and nothing that differs between devices.
public struct GitSyncSettings: Codable, Equatable, Sendable {
    /// Sync on its own while the app is open. Off until the user turns it on (`sync.setup`, `sync.enable`).
    public var auto = false
    /// The git remote to sync with.
    public var remote = "origin"
    /// The branch to sync; empty means the branch checked out.
    public var branch = ""
    /// How long after the last change a commit waits, so a burst of typing makes one commit.
    public var commitDelaySeconds = 30
    /// How often the remote is checked while the app is in front.
    public var pullIntervalMinutes = 5

    public init() {}
}
