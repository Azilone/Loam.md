import Foundation

/// Where the sync stands, as `sync.status` reports it and the status bar shows it.
public struct SyncStatus: Codable, Sendable, Equatable {
    public enum State: String, Codable, Sendable {
        /// Automatic sync is off, or the vault is not a git repository.
        case off
        /// Everything is committed and the remote has the same commits.
        case synced
        case syncing
        /// The remote cannot be reached; changes are committed here and wait.
        case offline
        /// Something needs the user (see `message`); nothing more is written until it is fixed.
        case attention
    }

    public var state: State
    /// Why the state is `attention` or `offline`, in one sentence.
    public var message: String?
    /// Conflict copies in the vault, to look at and merge by hand.
    public var conflicts: [String]
    public var branch: String?
    public var remote: String?
    /// Commits here the remote does not have, and the reverse.
    public var ahead: Int?
    public var behind: Int?
    /// The last time a sync reached the remote.
    public var lastSync: Date?
    public var device: String?
    /// The remote's address, without credentials.
    public var remoteURL: String?
    /// Files changed here and not committed yet.
    public var uncommitted: Int?
    /// Advice that does not stop the sync (a `.git` folder inside iCloud Drive).
    public var warnings: [String]
    /// The id of the key the remote is encrypted with; nil when the vault is not encrypted.
    public var encryptionKey: String?
    /// What the last sync brought in from other devices and agents, one entry per device; empty when nothing came.
    public var incoming: [DeviceChanges] = []

    /// The files one device (or agent) changed, as its commits name it.
    public struct DeviceChanges: Codable, Sendable, Equatable {
        public var device: String
        public var files: [String]

        public init(device: String, files: [String]) {
            self.device = device
            self.files = files
        }

        /// "agent-research changed 4 notes", or "… changed Plan.md".
        public var summary: String {
            let notes = files.filter { $0.hasSuffix(".md") }
            let what: String
            if notes.count == 1 {
                what = String(notes[0].split(separator: "/").last ?? "")
            } else if !notes.isEmpty {
                what = "\(notes.count) notes"
            } else {
                what = files.count == 1 ? "1 file" : "\(files.count) files"
            }
            return "\(device) changed \(what)"
        }
    }

    public init(state: State, message: String? = nil, conflicts: [String] = [], branch: String? = nil,
                remote: String? = nil, ahead: Int? = nil, behind: Int? = nil, lastSync: Date? = nil,
                device: String? = nil, warnings: [String] = []) {
        self.state = state
        self.message = message
        self.conflicts = conflicts
        self.branch = branch
        self.remote = remote
        self.ahead = ahead
        self.behind = behind
        self.lastSync = lastSync
        self.device = device
        self.warnings = warnings
    }

    public static let off = SyncStatus(state: .off)

    /// A few words for the status bar.
    public var label: String {
        switch state {
        case .off: return "Sync off"
        case .syncing: return "Syncing…"
        case .offline: return "Offline"
        case .attention: return "Sync needs attention"
        case .synced:
            switch conflicts.count {
            case 0: return "Synced"
            case 1: return "1 conflict"
            default: return "\(conflicts.count) conflicts"
            }
        }
    }

    /// One sentence for a toast after `sync.now`.
    public var sentence: String {
        switch state {
        case .off: return message ?? "Sync is off."
        case .syncing: return "Syncing…"
        case .offline: return "Offline: changes are saved here and will sync later."
        case .attention: return message ?? "Sync needs attention."
        case .synced:
            if !incoming.isEmpty, conflicts.isEmpty {
                return "Synced: " + incoming.map(\.summary).joined(separator: ", ") + "."
            }
            if conflicts.isEmpty { return "Synced." }
            return "Synced, with \(label): the other version is saved next to the note."
        }
    }
}
