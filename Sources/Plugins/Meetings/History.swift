import Foundation
import PluginKit

/// Where a recording came from: recorded in the app (a call, a meeting in person, a voice note), or an audio file
/// brought in (by Voice Memos syncing from the iPhone, by the inbox folder a dictaphone or an automation fills, or
/// picked by hand).
public enum MeetingOrigin: String, Codable, Sendable, CaseIterable {
    case call, room, voiceNote, voiceMemos, inbox, file
}

/// One line of the history: what came in, from where, when, and how its processing went. Built from the recordings'
/// own `.raw/meeting.json`, so it needs no file of its own and lists what the vault holds.
public struct HistoryEntry: Sendable, Equatable {
    public enum Outcome: Sendable, Equatable {
        case working
        case done
        /// The reason on one line.
        case failed(String)
    }

    public var folder: String
    public var title: String
    public var origin: MeetingOrigin
    public var date: Date
    /// Seconds of audio.
    public var duration: Double
    public var outcome: Outcome
    /// The full error, for a tooltip.
    public var error: String?
}

public extension Meetings {
    /// Every recording, newest first, as the history shows it.
    func history() -> [HistoryEntry] {
        let s = settings
        return recordings().map { Self.entry($0, settings: s) }
    }

    static func entry(_ state: MeetingState, settings: MeetingsSettings) -> HistoryEntry {
        let outcome: HistoryEntry.Outcome
        switch state.status {
        case .recording, .processing: outcome = .working
        case .done: outcome = .done
        case .error: outcome = .failed(oneLine(state.error ?? ""))
        }
        return HistoryEntry(folder: state.folder, title: state.title, origin: origin(of: state, settings: settings),
                            date: state.startDate, duration: state.duration, outcome: outcome, error: state.error)
    }

    /// The origin recorded when it started; for older recordings, guessed from where the audio was.
    static func origin(of state: MeetingState, settings: MeetingsSettings) -> MeetingOrigin {
        if let origin = state.origin { return origin }
        guard state.source == "import", let file = state.sourceFile else {
            return state.kind == .voice ? .voiceNote : state.mode == .call ? .call : .room
        }
        if file.hasPrefix("/") {
            let memos = (settings.voiceMemosFolder as NSString).expandingTildeInPath
            return !memos.isEmpty && file.hasPrefix(memos + "/") ? .voiceMemos : .file
        }
        let inbox = (try? VaultPath.normalize(settings.inboxFolder)) ?? ""
        return !inbox.isEmpty && VaultPath.directory(of: file) == inbox ? .inbox : .file
    }

    /// The cause of an error in a few words: its first line and sentence, `N segment(s) could not be transcribed:`
    /// said `Transcription:`, spaces collapsed, cut at 120 characters.
    static func oneLine(_ error: String) -> String {
        var line = error.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        line = line.replacingOccurrences(of: #"^\d+ segment\(s\) could not be transcribed:"#, with: "Transcription:",
                                         options: .regularExpression)
        if let end = line.range(of: ". ") { line = String(line[..<end.lowerBound]) }
        if line.hasSuffix(".") { line.removeLast() }
        let collapsed = line.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return collapsed.count > 120 ? collapsed.prefix(119).trimmingCharacters(in: .whitespaces) + "…" : collapsed
    }
}
