import Foundation
import PluginKit

public extension ServiceKey where Service == Meetings {
    /// The meeting recorder's engine, for its app module.
    static var meetings: ServiceKey<Meetings> { ServiceKey<Meetings>("meetings") }
}

/// The meeting recorder, Muesli's features in Loam: no bot joins the call, the microphone and the Mac's sound are
/// transcribed with speakers told apart, and each meeting becomes a folder of Markdown (a summary built around your
/// notes, a clean transcript, a mind map, the audio). A voice note becomes an entry in the day's note. Audio files
/// can be imported, dropped in an inbox, or come from the iPhone's Voice Memos. Recording itself is `MeetingsUI`.
public final class MeetingsPlugin: Plugin {
    public static var manifest: PluginManifest {
        PluginManifest(
            id: "meetings",
            name: "Meeting recorder",
            version: "0.1.0",
            description: "Records meetings without a bot: transcript, summary, actions and a mind map in your notes.",
            icon: "waveform.badge.mic",
            provides: ["meetings"],
            optionalRequires: ["daily-notes"],
            permissions: ["vault.read", "vault.write", "disk.read", "network", "shell"],
            settings: MeetingsSettings.descriptions
        )
    }

    public static var optionalTools: [String] { ["ffmpeg"] }

    public required init() {}

    /// The first run stores the folder names. Folders the vault already has are kept, under their old French names too.
    static func freezeFolders(settings: PluginSettingsAccess, vault: VaultAccess) {
        var probe = MeetingsSettings()
        probe.meetingsFolder = ""
        var current = settings.value(default: probe)
        guard current.meetingsFolder.isEmpty else { return }
        let defaults = MeetingsSettings()
        func existing(_ candidates: [String], else fallback: String) -> String {
            candidates.first(where: vault.exists) ?? fallback
        }
        current.meetingsFolder = existing(["Meetings", "Réunions"], else: defaults.meetingsFolder)
        let root = current.meetingsFolder
        current.templatesFolder = existing([root + "/Templates", root + "/Modèles"], else: root + "/Templates")
        current.inboxFolder = existing([root + "/Inbox", root + "/À importer"], else: root + "/Inbox")
        current.voiceFolder = existing(["Voice notes", "Notes vocales", root + "/Voice notes", root + "/Notes vocales"],
                                       else: root + "/Voice notes")
        try? settings.update(current)
    }

    /// Keeps the ffmpeg path in the settings on a working ffmpeg: the one found on this Mac when the setting is empty
    /// or points at nothing. ffmpeg is optional here (AVFoundation does without it), but importing some formats needs it.
    static func refreshFFmpeg(_ settings: PluginSettingsAccess, located: String?) {
        var current = settings.value(default: MeetingsSettings())
        let path = current.ffmpegPath.trimmed
        if !path.isEmpty, FileManager.default.isExecutableFile(atPath: path) { return }
        guard let located, located != current.ffmpegPath else { return }
        current.ffmpegPath = located
        try? settings.update(current)
    }

    public func activate(context: PluginContext) throws {
        let settings = context.settings
        _ = settings.value(default: MeetingsSettings())
        Self.freezeFolders(settings: settings, vault: context.vault)
        Self.refreshFFmpeg(settings, located: context.service(ServiceKey<ToolLocating>.tools)?.locate("ffmpeg")?.path)
        let meetings = Meetings(
            vault: context.vault,
            settings: { settings.value(default: MeetingsSettings()) },
            ai: OpenRouterClient(keys: DeviceKeys()),
            dailyNotes: { [weak context] in context?.service(.dailyNotes) },
            emit: { [weak context] event in context?.emit(event) }
        )
        try context.provide(.meetings, meetings)
        context.intercept(ManagedFolders.self) { event, next in
            var event = event
            let current = settings.value(default: MeetingsSettings())
            for folder in [current.meetingsFolder, current.voiceFolder] where !folder.isEmpty { event.paths.insert(folder) }
            return next(event)
        }
        let id = context.pluginID
        context.on(PluginSettingsChanged.self) { [weak context] event in
            if event.pluginID == id { context?.emit(ManagedFoldersChanged()) }
        }

        try context.registerCommand(Command(
            id: "meetings.import",
            title: "Create a meeting from an audio file (by path)",
            summary: "Transcribes an audio file (m4a, mp3, wav, Voice Memos qta…) and writes its notes: a meeting folder "
                + "with Summary, Transcript and Mindmap, or for a voice note a journal entry in the day's note. Calls "
                + "OpenRouter (paid). Arguments: path (vault path, or absolute path anywhere on disk); optional: kind "
                + "(auto, meeting or voice; default auto, decided from what is said), title, template. Returns the note "
                + "written and the cost.",
            isInPalette: false
        ) { arguments in
            let kind = MeetingKind(rawValue: arguments["kind"] ?? "auto") ?? .auto
            let result = try await meetings.importAudio(try arguments.require("path"), options: Meetings.ImportOptions(
                kind: kind, title: arguments["title"] ?? "", template: arguments["template"]
            ), background: true)
            return try JSON.string(Outcome(note: result.note, cost: result.cost))
        })

        try context.registerCommand(Command(
            id: "meetings.reprocess",
            title: "Re-process a meeting (by folder)",
            summary: "Processes a recording again from its .raw/ folder: transcribes the segments still missing, then "
                + "rewrites the transcript, summary and mind map (or the journal entry). Calls OpenRouter. Argument: "
                + "folder (vault path of the recording's folder). Returns the note written and the cost.",
            isInPalette: false
        ) { arguments in
            let result = try await meetings.reprocess(try arguments.require("folder"), background: true)
            return try JSON.string(Outcome(note: result.note, cost: result.cost))
        })

        try context.registerCommand(Command(
            id: "meetings.retry-failed",
            title: "Re-process failed meetings",
            summary: "Tries again every recording of the last 7 days whose processing failed. Returns how many were tried."
        ) { _ in
            "\(await meetings.retryFailed(manual: true)) recording(s) tried again."
        })

        try context.registerCommand(Command(
            id: "meetings.list",
            title: "List recorded meetings",
            summary: "Lists the recordings in the meetings and voice notes folders, newest first, with their folder, "
                + "title, origin (call, room, voiceNote, voiceMemos, inbox, file), status (recording, processing, done, error), "
                + "duration in minutes and error. No arguments.",
            isInPalette: false
        ) { _ in
            let settings = meetings.settings
            return try JSON.string(meetings.recordings().map {
                Listing(folder: $0.folder, title: $0.title, startedAt: $0.startedAt,
                        origin: Meetings.origin(of: $0, settings: settings).rawValue, status: $0.status.rawValue,
                        minutes: Int(($0.duration / 60).rounded()), error: $0.error)
            })
        })

        try context.registerCommand(Command(
            id: "meetings.new",
            title: "New meeting note",
            summary: "Writes a meeting without a recording, as a recorded one is: <meetings folder>/<date time> <title>/"
                + "Summary.md with date, participants, tags [meeting] and type meeting. Writes to the vault. Arguments: "
                + "title; optional: participants (comma separated), date (YYYY-MM-DD or YYYY-MM-DDTHH:mm, default now), "
                + "text (the Markdown body: decisions, actions as - [ ] tasks). Returns the path.",
            isInPalette: false
        ) { arguments in
            let date = try arguments["date"].map { value in
                guard let date = Self.parseDate(value) else { throw AIError("date must be YYYY-MM-DD or YYYY-MM-DDTHH:mm", status: 0) }
                return date
            } ?? Date()
            let participants = (arguments["participants"] ?? "").split(separator: ",").map { String($0).trimmed }.filter { !$0.isEmpty }
            let settings = meetings.settings
            return try JSON.string(["path": try MeetingWriter.writeManualMeeting(
                vault: context.vault, root: settings.meetingsFolder, prompts: settings.prompts,
                title: try arguments.require("title"), date: date, participants: participants, text: arguments["text"] ?? ""
            )])
        })

        try context.registerCommand(Command(
            id: "meetings.process-inbox",
            title: "Process the meetings inbox",
            summary: "Turns every audio file waiting in the inbox folder (setting inboxFolder) into a meeting or a "
                + "journal entry, decided from what is said; the file moves into the new folder. Calls OpenRouter."
        ) { _ in
            let files = meetings.inboxFiles()
            await meetings.processInbox()
            return "\(files.count) file(s) processed."
        })

        try context.registerCommand(Command(
            id: "meetings.set-key",
            title: "Set the meeting recorder's API key",
            summary: "Saves an API key in this Mac's Keychain, never in the vault, and checks it. Arguments: key; "
                + "optional: provider (openrouter, the default, used for transcription; or anthropic, for Claude "
                + "model ids without a vendor prefix). An empty key removes it. Returns whether it works.",
            isInPalette: false
        ) { arguments in
            let provider = DeviceKeys.Provider(rawValue: arguments["provider"] ?? "openrouter") ?? .openRouter
            let key = (arguments["key"] ?? "").trimmed
            try DeviceKeys().set(provider, key)
            guard !key.isEmpty else { return "Key removed." }
            guard provider == .openRouter else { return "Key saved." }
            return await OpenRouterClient.check(openRouterKey: key).message
        })

        try context.registerCommand(Command(
            id: "meetings.check-key",
            title: "Check the meeting recorder's API key",
            summary: "Says whether the OpenRouter key of this Mac works and how much credit it has left. No arguments."
        ) { _ in
            guard let key = DeviceKeys().openRouterKey() else { return "No OpenRouter key yet: run meetings.set-key key=…" }
            return await OpenRouterClient.check(openRouterKey: key).message
        })
    }

    /// `YYYY-MM-DD` (at the current time) or `YYYY-MM-DDTHH:mm`, local time.
    static func parseDate(_ text: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm"
        if let date = formatter.date(from: text) { return date }
        formatter.dateFormat = "yyyy-MM-dd"
        guard let day = formatter.date(from: text) else { return nil }
        let now = Calendar.current.dateComponents([.hour, .minute], from: Date())
        return Calendar.current.date(bySettingHour: now.hour ?? 9, minute: now.minute ?? 0, second: 0, of: day)
    }

    private struct Outcome: Encodable {
        let note: String
        let cost: Double
    }

    private struct Listing: Encodable {
        let folder: String
        let title: String
        let startedAt: String
        let origin: String
        let status: String
        let minutes: Int
        let error: String?
    }
}
