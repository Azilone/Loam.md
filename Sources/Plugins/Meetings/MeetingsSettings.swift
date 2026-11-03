import Foundation
import PluginKit

/// The meeting recorder's settings, in `.loam/config.json` under `plugins.meetings.settings`. The keys are not here:
/// they stay in this Mac's Keychain (`DeviceKeys`).
public struct MeetingsSettings: Codable, Equatable, Sendable {
    /// Your name, for your microphone in transcripts.
    public var myName = "Me"
    /// `call` (microphone and the Mac's sound) or `room` (microphone only, every voice told apart).
    public var defaultMode = MeetingMode.call.rawValue
    public var defaultTemplate = "General"
    /// Spoken language code (`fr`, `en`…), empty to detect it.
    public var language = ""
    /// The language summaries are written in, whatever was spoken.
    public var summaryLanguage = "English"
    public var keepAudio = true
    public var askSpeakerNames = true
    /// Writes `Mindmap.md` next to the summary.
    public var mindmap = true
    /// Minutes of audio per transcription chunk.
    public var chunkMinutes = 8.0

    public var overlay = true
    /// Keeps the floating recorder out of screen sharing and screenshots.
    public var overlayHiddenFromCapture = true
    /// Minutes without speech before asking whether the meeting is still on (0: never).
    public var idleMinutes = 10.0
    /// Minutes to wait for an answer before stopping by itself.
    public var idleGraceMinutes = 5.0
    /// Longest recording, in minutes (0: no limit).
    public var maxMinutes = 180.0
    /// US dollars per minute of audio sent, for the live estimate.
    public var sttPricePerMinute = 0.0017

    public var sttModel = "microsoft/mai-transcribe-2"
    public var llmModel = "anthropic/claude-haiku-5.5"
    /// Model that decides what a memo is; empty: `llmModel`.
    public var classifyModel = ""

    public var meetingsFolder = "Meetings"
    public var templatesFolder = "Meetings/Templates"
    /// Audio files put here are processed by themselves.
    public var inboxFolder = "Meetings/Inbox"
    /// Inside the meetings folder by default, so recordings live under one folder.
    public var voiceFolder = "Meetings/Voice notes"

    /// macOS: new iPhone Voice Memos synced by iCloud are processed by themselves (needs Full Disk Access).
    public var voiceMemos = false
    public var voiceMemosFolder = "~/Library/Group Containers/group.com.apple.VoiceMemos.shared/Recordings"

    /// Path to ffmpeg; found in the usual places when empty.
    public var ffmpegPath = ""

    public init() {}

    var mode: MeetingMode { MeetingMode(rawValue: defaultMode) ?? .call }
    var prompts: Prompts { Prompts() }
    var classifier: String { classifyModel.trimmed.isEmpty ? llmModel : classifyModel.trimmed }
    var codec: AudioCodec { AudioCodec(ffmpeg: ffmpegPath.trimmed) }

    static var descriptions: [SettingDescription] {
        let d = MeetingsSettings()
        return [
            SettingDescription("myName", title: "Your name", help: "Used for your microphone in transcripts.", default: .string(d.myName)),
            SettingDescription("defaultMode", title: "Default meeting type", choices: [
                SettingChoice(.string("call"), title: "Call: microphone and the Mac's sound"),
                SettingChoice(.string("room"), title: "In person: microphone only"),
            ]),
            SettingDescription("defaultTemplate", title: "Default summary template", help: "A note of the templates folder.", default: .string(d.defaultTemplate)),
            SettingDescription("language", title: "Spoken language", help: "A code such as fr or en; empty to detect it.", default: .string(d.language)),
            SettingDescription("summaryLanguage", title: "Summary language", help: "Summaries are written in it, whatever was spoken.", default: .string(d.summaryLanguage)),
            SettingDescription("keepAudio", title: "Keep the audio", help: "An audio file next to the summary.", default: .bool(d.keepAudio)),
            SettingDescription("askSpeakerNames", title: "Ask for speaker names", help: "Confirm or fix the names found before the summary is written.", default: .bool(d.askSpeakerNames)),
            SettingDescription("mindmap", title: "Mind map", help: "A Mindmap.md next to each summary.", default: .bool(d.mindmap)),
            SettingDescription("chunkMinutes", title: "Segment length", help: "Minutes of speech sent at a time while recording.", default: .number(d.chunkMinutes)),
            SettingDescription("overlay", title: "Floating recorder", help: "A small pill above every window while recording.", default: .bool(d.overlay)),
            SettingDescription("overlayHiddenFromCapture", title: "Hide it from screen sharing", help: "Keeps the pill out of shared screens and screenshots.", default: .bool(d.overlayHiddenFromCapture)),
            SettingDescription("idleMinutes", title: "Ask after minutes without speech", help: "0 never asks.", default: .number(d.idleMinutes)),
            SettingDescription("idleGraceMinutes", title: "Stop after minutes without an answer", help: "", default: .number(d.idleGraceMinutes)),
            SettingDescription("maxMinutes", title: "Maximum duration", help: "In minutes; 0 for no limit.", default: .number(d.maxMinutes)),
            SettingDescription("sttPricePerMinute", title: "Transcription price per minute", help: "In US dollars, for the live estimate.", default: .number(d.sttPricePerMinute)),
            SettingDescription("sttModel", title: "Transcription model", help: "An OpenRouter model.", default: .string(d.sttModel)),
            SettingDescription("llmModel", title: "Language model", help: "An OpenRouter model (vendor/model), or a Claude model id for the Claude API.", default: .string(d.llmModel)),
            SettingDescription("classifyModel", title: "Model that sorts memos", help: "Empty: the language model.", default: .string(d.classifyModel)),
            SettingDescription("meetingsFolder", title: "Meetings folder", default: .string(d.meetingsFolder)),
            SettingDescription("templatesFolder", title: "Templates folder", default: .string(d.templatesFolder)),
            SettingDescription("inboxFolder", title: "Inbox folder", help: "Audio files put here (AirDrop, iCloud Drive) are processed by themselves.", default: .string(d.inboxFolder)),
            SettingDescription("voiceFolder", title: "Voice notes folder", help: "Audio and transcript of each voice note.", default: .string(d.voiceFolder)),
            SettingDescription("voiceMemos", title: "Process new Voice Memos", help: "New iPhone Voice Memos synced to this Mac become meetings or journal entries. Needs Full Disk Access for Loam.", default: .bool(d.voiceMemos)),
            SettingDescription("voiceMemosFolder", title: "Voice Memos folder", default: .string(d.voiceMemosFolder)),
            SettingDescription("ffmpegPath", title: "Path to ffmpeg", help: "Optional: makes uploads smaller. Found in the usual places when empty."),
        ]
    }
}
