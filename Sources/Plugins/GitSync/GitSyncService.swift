import Foundation
import PluginKit

/// The vault's git sync, for the app's status bar and focus handling (`GitSyncUI`). Other plugins reach the same
/// behaviour through the `sync.*` commands.
public protocol GitSyncService: AnyObject, Sendable {
    var status: SyncStatus { get }
    /// Calls `handler` on the main thread whenever the status changes. Returns the function that stops it.
    func observe(_ handler: @escaping @Sendable (SyncStatus) -> Void) -> () -> Void
    /// Runs one sync now, after the one running, and returns where it left things.
    func syncNow() async -> SyncStatus
    /// Starts a sync now without waiting for it (a click); the status follows through `observe`.
    func requestSync()
    /// The app came to the front or went to the back. The first call arms automatic sync: only the app makes it,
    /// so the command line and tests never sync on their own.
    func setForeground(_ isForeground: Bool)
    /// How the sync asks the editor about notes being typed in. `nil` puts back the default (events only).
    func setEditorBridge(_ bridge: SyncEditorBridge?)
    /// Where things stand on disk, without the network (`sync.status`).
    func report() async -> SyncStatus
    /// `sync.setup` from Settings: makes the vault sync with the repository at `url`, then syncs once. A vault in
    /// iCloud Drive keeps git's data outside it. Throws a sentence for the user.
    func setUp(url: String, device: String?, encrypt: Bool) async throws -> SyncStatus
    /// Turns automatic sync on or off (`sync.enable`, `sync.disable`).
    func setAutomatic(_ on: Bool) async throws
    /// Stops syncing with the repository and forgets it, to set up another (`sync.disconnect`). Nothing is deleted.
    func disconnect() async throws -> SyncStatus

    /// The GitHub account this device is signed in to; nil when it is not.
    func gitHubAccount() async -> String?
    /// Starts signing in to GitHub: the user opens the code's address and types its code.
    func startGitHubSignIn() async throws -> GitHubDeviceCode
    /// Waits until the user approved the code, then keeps the sign-in (the Keychain).
    func finishGitHubSignIn(_ code: GitHubDeviceCode) async throws
    func signOutOfGitHub() throws
    /// One click once signed in: the vault syncs with its private repository on GitHub, made if new; `encrypt`
    /// encrypts a new one (agents then need Loam to read it).
    func setUpWithGitHub(encrypt: Bool) async throws -> SyncStatus
    /// What another Mac (`agent: false`) or an agent needs to join this vault: a connect code (`loam-connect:…`) for a
    /// Mac or an encrypted vault's agent; for a plain vault's agent, a shell snippet that clones it with git alone.
    func connectCode(for device: String, agent: Bool) async throws -> String
    /// Joins the vault a code names (`connectCode` on a device that syncs it).
    func join(_ code: String, maxChanges: Int?) async throws -> SyncStatus
    /// An agent's deploy key and what it runs (`AgentAccess`); the key is added on GitHub when signed in.
    func agentAccess(for name: String) async throws -> AgentAccess
    /// The agents connected to the vault's repository.
    func connectedAgents() async throws -> [String]
    /// Takes an agent's access away: its deploy key on GitHub.
    func removeAgent(_ name: String) async throws -> SyncStatus
}

public extension GitSyncService {
    func report() async -> SyncStatus { status }
    func setUp(url: String, device: String?, encrypt: Bool) async throws -> SyncStatus {
        throw GitSyncServiceError.unsupported
    }
    func setAutomatic(_ on: Bool) async throws { throw GitSyncServiceError.unsupported }
    func disconnect() async throws -> SyncStatus { throw GitSyncServiceError.unsupported }
    func gitHubAccount() async -> String? { nil }
    func startGitHubSignIn() async throws -> GitHubDeviceCode { throw GitSyncServiceError.unsupported }
    func finishGitHubSignIn(_ code: GitHubDeviceCode) async throws { throw GitSyncServiceError.unsupported }
    func signOutOfGitHub() throws { throw GitSyncServiceError.unsupported }
    func setUpWithGitHub(encrypt: Bool) async throws -> SyncStatus { throw GitSyncServiceError.unsupported }
    func connectCode(for device: String, agent: Bool) async throws -> String { throw GitSyncServiceError.unsupported }
    func join(_ code: String, maxChanges: Int?) async throws -> SyncStatus { throw GitSyncServiceError.unsupported }
    func connectedAgents() async throws -> [String] { [] }
    func agentAccess(for name: String) async throws -> AgentAccess { throw GitSyncServiceError.unsupported }
    func removeAgent(_ name: String) async throws -> SyncStatus { throw GitSyncServiceError.unsupported }
}

/// A `GitSyncService` that cannot do what was asked.
public enum GitSyncServiceError: Error, LocalizedError, Equatable {
    case unsupported

    public var errorDescription: String? { "This sync cannot be set up from here." }
}

public extension ServiceKey where Service == GitSyncService {
    static var gitSync: ServiceKey<GitSyncService> { ServiceKey<GitSyncService>("git-sync") }
}

/// What the sync needs from the editor so a pull never fights unsaved typing. Always called on the main thread.
public protocol SyncEditorBridge: AnyObject {
    /// Of `paths`, the notes open and typed in within the last `quiet` seconds, or holding unsaved typing.
    func busyPaths(_ paths: [String], quiet: TimeInterval) -> [String]
    /// Saves the unsaved typing of these notes now.
    func flush(_ paths: [String])
    /// Shows the new content of these notes. Returns the ones whose editor kept different unsaved text.
    func reload(_ paths: [String]) -> [String]
}
