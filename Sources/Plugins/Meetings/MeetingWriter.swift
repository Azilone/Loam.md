import Foundation
import PluginKit

/// Writes what a recording became: a meeting folder (`Summary.md`, `Transcript.md`, `Mindmap.md`, next to `Notes.md`
/// and the audio), or a voice note's transcript and its entry in the day's note. Plain Markdown, standard links.
struct MeetingWriter {
    let vault: VaultAccess
    let prompts: Prompts

    static let audioExtensions = ["m4a", "mp3", "wav", "aac", "ogg", "oga", "opus", "webm", "mp4", "flac", "aiff", "aif", "caf", "qta", "mov"]

    /// The recording's audio in its folder, if it was kept.
    func audio(in folder: String) -> String? {
        let entries = (try? vault.list(folder)) ?? []
        return entries.first { entry in
            let name = (entry.path as NSString).lastPathComponent
            return (name as NSString).deletingPathExtension == "audio" && Self.audioExtensions.contains((name as NSString).pathExtension.lowercased())
        }?.path
    }

    func writeMeeting(state: MeetingState, transcript: String, summary: String, participants: [String], mindmap: String) throws -> String {
        let p = prompts
        let type = state.noteType ?? .meeting
        let folder = state.folder
        let meta: [(String, String)] = [
            ("date", Self.stamp(state.startDate)),
            ("duration", "\(max(1, Int((state.duration / 60).rounded()))) min"),
            ("participants", Self.yamlList(participants)),
            ("language", state.language.isEmpty ? "auto" : state.language),
            ("tags", Self.yamlList([type.rawValue])),
        ]
        let summaryPath = "\(folder)/\(p.summaryFile).md"
        let transcriptPath = "\(folder)/Transcript.md"
        try vault.write(transcriptPath, Self.frontmatter(meta + [("type", "transcript")])
            + "# \(Self.heading(p.transcript, state.title))\n\n\(transcript)\n")
        var links = [Self.link(p.transcript, from: summaryPath, to: transcriptPath)]
        if vault.exists(state.notesPath) { links.append(Self.link(p.rawNotes, from: summaryPath, to: state.notesPath)) }
        if !mindmap.isEmpty {
            try vault.write("\(folder)/Mindmap.md", Self.titled(mindmap, Self.heading(p.mindmapLink, state.title)))
            links.append(Self.link(p.mindmapLink, from: summaryPath, to: "\(folder)/Mindmap.md"))
        }
        var embed = ""
        if let audio = audio(in: folder) {
            links.append(Self.link(p.audio, from: summaryPath, to: audio))
            embed = "\n\n![](\(VaultPath.relativeDestination(fromDirectory: folder, to: audio)))"
        }
        try vault.write(summaryPath, Self.frontmatter(meta + [("type", type.rawValue)])
            + "# \(Self.heading(p.summaryFile, state.title))\n\n\(links.joined(separator: " · "))\(embed)\n\n\(summary)\n")
        return summaryPath
    }

    /// The transcript next to the audio, and a bullet-journal block in the day's note. Running it again replaces the
    /// block (found by its link to this transcript) instead of adding a second one.
    func writeVoiceNote(state: MeetingState, transcript: String, entry: ModelReplies.JournalEntry, dailyPath: String?) throws -> String {
        let p = prompts
        let transcriptPath = "\(state.folder)/Transcript.md"
        try vault.write(transcriptPath, Self.frontmatter([
            ("date", Self.stamp(state.startDate)),
            ("duration", "\(max(1, Int((state.duration / 60).rounded()))) min"),
            ("type", "voice note"),
        ]) + "# \(Self.heading(p.transcript, state.title))\n\n\(transcript)\n")

        let daily = dailyPath ?? "\(Pipeline.day(state.startDate)).md"
        var links = [Self.link(p.transcript, from: daily, to: transcriptPath)]
        if let audio = audio(in: state.folder) { links.append(Self.link(p.audio, from: daily, to: audio)) }
        let time = DateFormatter()
        time.locale = Locale(identifier: "en_US_POSIX")
        time.dateFormat = "HH:mm"
        let block = ModelReplies.journalBlock(time: time.string(from: state.startDate), fallbackTitle: state.title, entry: entry,
                                              links: links.joined(separator: " · "))
        let text = vault.exists(daily) ? try vault.read(daily) : "# \((daily as NSString).lastPathComponent.replacingOccurrences(of: ".md", with: ""))\n\n"
        try vault.write(daily, Self.replacingBlock(in: text, block: block, marker: links[0]))
        return daily
    }

    /// `text` with the block holding `marker` replaced by `block`, or `block` appended.
    static func replacingBlock(in text: String, block: String, marker: String) -> String {
        var lines = text.components(separatedBy: "\n")
        if let at = lines.firstIndex(where: { $0.contains(marker) }),
           let start = lines[...at].lastIndex(where: { $0.hasPrefix(ModelReplies.journalHeadingPrefix) }) {
            var end = start + 1
            while end < lines.count, lines[end].range(of: #"^#{1,3} "#, options: .regularExpression) == nil { end += 1 }
            lines.replaceSubrange(start..<end, with: block.components(separatedBy: "\n") + [""])
            return lines.joined(separator: "\n").replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
        }
        let trimmed = text.replacingOccurrences(of: #"\s+$"#, with: "", options: .regularExpression)
        return trimmed + (trimmed.isEmpty ? "" : "\n\n") + block + "\n"
    }

    /// A meeting written by hand or by an agent, without a recording: `<meetings folder>/<date> <title>/<Summary>.md`
    /// with the properties a recorded meeting has, so it lists and filters with them.
    static func writeManualMeeting(vault: VaultAccess, root: String, prompts: Prompts, title: String, date: Date,
                                   participants: [String], text: String) throws -> String {
        let folder = freePath(vault, "\(root)/\(Meetings.folderStamp(date)) \(safeName(title))")
        try vault.createFolder(folder)
        let path = "\(folder)/\(prompts.summaryFile).md"
        let body = text.trimmed.isEmpty ? "" : "\n\n" + text.trimmed
        try vault.write(path, frontmatter([
            ("date", stamp(date)),
            ("participants", yamlList(participants)),
            ("tags", yamlList([NoteType.meeting.rawValue])),
            ("type", NoteType.meeting.rawValue),
        ]) + "# \(heading(prompts.summaryFile, title))\(body)\n")
        return path
    }

    // MARK: Markdown helpers

    static func link(_ title: String, from note: String, to target: String) -> String {
        "[\(title)](\(VaultPath.relativeDestination(fromDirectory: VaultPath.directory(of: note), to: target)))"
    }

    static func frontmatter(_ pairs: [(String, String)]) -> String {
        "---\n" + pairs.map { "\($0.0): \($0.1)" }.joined(separator: "\n") + "\n---\n\n"
    }

    /// A file's title in a meeting folder: its role first, so the folder reads at a glance, then the meeting, so
    /// it stays unique in search and All Notes ("Transcription · Weekly sync").
    static func heading(_ role: String, _ title: String) -> String { "\(role) · \(title)" }

    /// The name of the notes the user types during a meeting: the meeting's title, or its date while it has none
    /// ("Meeting on October 29"), so it says which meeting it belongs to.
    static func notesTitle(_ title: String, date: Date, prompts: Prompts) -> String {
        let name = safeName(title == prompts.meeting ? prompts.meeting(on: date) : title)
        let taken = [prompts.summaryFile, "Summary", "Transcript", "Mindmap", "Notes"]
        return taken.contains { $0.caseInsensitiveCompare(name) == .orderedSame } ? "Notes · \(name)" : name
    }

    /// The notes' text: their name as heading (the page title, so the editor hides it) and a line saying what they
    /// are for. Left empty, they are thrown away when the meeting is written.
    static func notes(_ name: String, prompts: Prompts) -> String { "# \(name)\n\n> *\(prompts.notesHint)*\n\n" }

    /// What the user wrote in their notes: without the frontmatter, the heading and the hint. The hint of notes made
    /// before the names were English is skipped too, so they are still thrown away when left empty.
    static func userNotes(_ text: String) -> String {
        var lines = body(text).components(separatedBy: "\n")
        if lines.first?.hasPrefix("# ") == true { lines.removeFirst() }
        let legacyHint = "> *Ce que tu écris ici guide le résumé de la réunion. Laissée vide, cette note est supprimée.*"
        let hints = Set(["> *\(Prompts().notesHint)*", legacyHint])
        return lines.filter { !hints.contains($0.trimmed) }.joined(separator: "\n").trimmed
    }

    /// `text` with `title` first in its frontmatter: a mind map's heading is its central topic, so the sidebar
    /// names it by this instead.
    static func titled(_ text: String, _ title: String) -> String {
        guard text.hasPrefix("---\n") else { return frontmatter([("title", title)]) + text }
        return "---\ntitle: \(yamlString(title))\n" + text.dropFirst(4)
    }

    static func yamlList(_ items: [String]) -> String {
        "[" + items.map(yamlString).joined(separator: ", ") + "]"
    }

    static func yamlString(_ text: String) -> String {
        let plain = text.range(of: #"^[\p{L}\p{N}][\p{L}\p{N} .'_-]*$"#, options: .regularExpression) != nil
        return plain ? text : "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    static func stamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm"
        return formatter.string(from: date)
    }

    /// A note's text without its frontmatter.
    static func body(_ text: String) -> String {
        text.replacingOccurrences(of: #"^---\n[\s\S]*?\n---\n?"#, with: "", options: .regularExpression).trimmed
    }

    /// A title made safe for a folder name.
    static func safeName(_ title: String) -> String {
        title.replacingOccurrences(of: #"[\\/:*?"<>|#^\[\]]"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmed
    }

    /// `path`, or `path (2)`, `path (3)`… the first that does not exist yet.
    static func freePath(_ vault: VaultAccess, _ path: String) -> String {
        var candidate = path
        var n = 2
        while vault.exists(candidate) {
            candidate = "\(path) (\(n))"
            n += 1
        }
        return candidate
    }
}
