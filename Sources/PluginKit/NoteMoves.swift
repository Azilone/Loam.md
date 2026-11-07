import Foundation

/// What moving notes, attachments or folders did.
public struct MoveResult: Codable, Sendable, Equatable {
    /// Old path to new path for every file that moved: a moved folder is expanded to the files under it.
    public let moves: [String: String]
    /// Paths (after the move) of every note whose links changed, sorted.
    public let updated: [String]

    public init(moves: [String: String], updated: [String]) {
        self.moves = moves
        self.updated = updated
    }
}

/// Sent before files move on disk, with every file move (folders expanded), so an editor can save
/// pending edits first. The links are rewritten from the files as they are after this event.
public struct NotesWillMove: PluginEvent {
    public let moves: [String: String]

    public init(moves: [String: String]) {
        self.moves = moves
    }
}

/// Sent after files moved and the note graph was updated, so open views can follow the new paths.
public struct NotesMoved: PluginEvent {
    public let moves: [String: String]

    public init(moves: [String: String]) {
        self.moves = moves
    }
}
