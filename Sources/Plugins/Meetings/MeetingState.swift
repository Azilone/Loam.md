import Foundation
import PluginKit

/// Where a recording is filed: a meeting gets its own folder of notes, a voice note becomes an entry in the day's
/// note. `auto` (a memo from the phone, a file from the inbox) is decided from what is said.
public enum MeetingKind: String, Codable, Sendable, CaseIterable {
    case meeting
    case voice
    case auto
}

/// Who is on the microphone. In a call it is only the user (the others come through the system audio); in a room
/// every voice goes through it and is told apart by diarization.
public enum MeetingMode: String, Codable, Sendable, CaseIterable {
    case call
    case room
}

/// What a recording turned out to be, decided by the language model for `auto` recordings.
public enum NoteType: String, Codable, Sendable, CaseIterable {
    case meeting, journal, idea, reading, dictation, lesson

    /// Only the journal goes to the daily note.
    var kind: MeetingKind { self == .journal ? .voice : .meeting }

    /// The user speaks alone, so every voice is them.
    var isSolo: Bool { [.journal, .idea, .reading, .dictation].contains(self) }

    /// Types with their own summary template; a meeting uses the one chosen when it started.
    var hasOwnTemplate: Bool { [.idea, .reading, .dictation, .lesson].contains(self) }
}

public enum MeetingStatus: String, Codable, Sendable {
    case recording, processing, done, error
}

/// One piece of a track sent for transcription: silences removed, with the map back to the meeting clock.
public struct ChunkState: Codable, Sendable, Equatable {
    public enum Status: String, Codable, Sendable { case pending, done, error }

    public var track: TrackID
    public var index: Int
    /// Seconds of audio actually sent.
    public var duration: Double
    /// Seconds of speech detected.
    public var speech: Double
    public var map: [TimeMapEntry]
    /// The encoded file's extension in `.raw/` (`mp3`, `flac`, `wav`).
    public var format: String
    public var status: Status = .pending
    public var error: String?
    public var cost: Double?

    var name: String { "\(track.rawValue)-\(index)" }
}

/// Everything known about one recording, kept in `<folder>/.raw/meeting.json` next to its audio chunks and their
/// transcriptions, so a crash or a failed call never loses a meeting: processing can always run again from there.
public struct MeetingState: Codable, Sendable {
    public var version = 1
    public var title: String
    /// Vault path of the recording's folder.
    public var folder: String
    /// ISO 8601.
    public var startedAt: String
    /// Spoken language code, empty to detect it.
    public var language: String
    public var mode: MeetingMode
    /// Name of the summary template.
    public var template: String
    /// Seconds of recorded time (pauses excluded).
    public var duration: Double = 0
    public var status: MeetingStatus
    public var chunks: [ChunkState] = []
    /// When each line of the notes was first typed (seconds into the meeting), keyed by its final text.
    public var noteTimes: [String: Double] = [:]
    public var error: String?
    /// Speaker label → name, once known.
    public var speakerNames: [String: String]?
    /// `import`: built from an existing audio file instead of a live recording.
    public var source: String?
    public var sourceFile: String?
    /// Where it came from, for the history (nil in recordings made before it was kept).
    public var origin: MeetingOrigin?
    public var kind: MeetingKind
    public var noteType: NoteType?
    /// When processing last failed (seconds since 1970), and how many automatic retries were made since.
    public var failedAt: Double?
    public var retries: Int?
    /// The title is a placeholder: the language model names the meeting (and its folder) after the summary.
    public var autoTitle: Bool?
    /// The file of the notes the user types during a meeting (nil: `Notes.md`, as before it was named after it).
    public var notesFile: String?

    public init(title: String, folder: String, startedAt: Date, language: String, mode: MeetingMode, template: String,
                status: MeetingStatus, kind: MeetingKind, autoTitle: Bool = false) {
        self.title = title
        self.folder = folder
        self.startedAt = Self.iso.string(from: startedAt)
        self.language = language
        self.mode = mode
        self.template = template
        self.status = status
        self.kind = kind
        self.autoTitle = autoTitle
    }

    /// In a call or a voice note the microphone only carries the user: it is not diarized and is attributed to them.
    var micIsMe: Bool { mode == .call || kind == .voice }

    /// Vault path of the notes the user types during a meeting.
    public var notesPath: String { "\(folder)/\(notesFile ?? "Notes.md")" }

    var startDate: Date { Self.iso.date(from: startedAt) ?? Date() }

    nonisolated(unsafe) static let iso: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
}

/// The hidden folder of a recording, with its state, audio chunks and raw transcriptions.
public enum RawFolder {
    public static let name = ".raw"

    static func path(_ folder: String, _ file: String) -> String { "\(folder)/\(name)/\(file)" }

    static func url(_ vault: VaultAccess, _ folder: String, _ file: String = "") -> URL {
        let base = vault.rootURL.appendingPathComponent(folder).appendingPathComponent(name)
        return file.isEmpty ? base : base.appendingPathComponent(file)
    }

    public static func load(_ vault: VaultAccess, folder: String) -> MeetingState? {
        guard let data = try? Data(contentsOf: url(vault, folder, "meeting.json")),
              var state = try? JSONDecoder().decode(MeetingState.self, from: data) else { return nil }
        state.folder = folder
        return state
    }

    static func save(_ vault: VaultAccess, _ state: MeetingState) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try writeData(vault, state.folder, "meeting.json", encoder.encode(state))
    }

    /// Hidden files bypass `VaultAccess.write` (which leaves dot folders to the app): written straight to disk.
    static func writeData(_ vault: VaultAccess, _ folder: String, _ file: String, _ data: Data) throws {
        let target = url(vault, folder, file)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: target, options: .atomic)
    }

    static func readData(_ vault: VaultAccess, _ folder: String, _ file: String) throws -> Data {
        try Data(contentsOf: url(vault, folder, file))
    }
}
