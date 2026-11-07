import LoamCore
import Foundation
import PluginKit
import XCTest
@testable import MeetingsPlugin

/// A model that answers each prompt the way a real one would, and records what it was asked.
final class FakeAI: MeetingAI, @unchecked Sendable {
    let calls = Locked<[String]>([])
    var segments: [SttResult.Segment] = [
        .init(start: 0.2, end: 1.5, text: "Hello Paul, we are talking about the launch.", speaker: 0),
        .init(start: 1.6, end: 3.0, text: "Yes, I am preparing the demo for Friday.", speaker: 1),
    ]
    var kind = "meeting"
    var failTranscription = false

    func transcribe(_ audio: Data, format: String, model: String, language: String, diarize: Bool) async throws -> SttResult {
        calls.update { $0.append("stt:\(format):\(diarize)") }
        if failTranscription { throw AIError("OpenRouter 503: busy", status: 503) }
        XCTAssertFalse(audio.isEmpty)
        var result = SttResult(text: segments.map(\.text).joined(separator: " "), segments: segments)
        result.usage = .init(seconds: 3, cost: 0.01)
        return result
    }

    func chat(model: String, system: String, user: String, json: Bool, schema: [String: Any]?, maxTokens: Int?) async throws
        -> (text: String, cost: Double) {
        let reply: String
        if system.contains("\"people\"") {
            calls.update { $0.append("speakers") }
            reply = #"{"people":[{"name":"Paul","labels":["mic0:1"],"evidence":"Hello Paul"},{"name":"","labels":["mic0:0"]}]}"#
        } else if system.contains("clean up an excerpt") {
            calls.update { $0.append("clean") }
            reply = user.replacingOccurrences(of: "\n", with: "\n\n")
        } else if system.contains("classify an audio recording") {
            calls.update { $0.append("classify") }
            reply = #"{"type":"\#(kind)","confidence":0.9,"reason":"two voices"}"#
        } else if system.contains("bullet journal") || system.contains("bullet-journal") {
            calls.update { $0.append("journal") }
            reply = #"{"title":"Day review","tldr":"A busy day.","tasks":[{"text":"Call Paul","done":false}],"events":["14:00 — demo"],"notes":["==Launch on Friday=="]}"#
        } else if system.contains("give a title") {
            calls.update { $0.append("title") }
            reply = "« Demo launch »"
        } else if system.contains("mind map") {
            calls.update { $0.append("mindmap") }
            reply = "- Launch\n\t- Demo on Friday\n- Actions\n\t- Paul prepares the demo"
        } else {
            calls.update { $0.append("summary") }
            XCTAssertTrue(user.contains("=== TRANSCRIPT ==="))
            reply = "## TL;DR\nThe demo ships on Friday.\n\n## Actions\n- [ ] Paul — prepare the demo (Friday)"
        }
        return (reply, 0.002)
    }
}

final class MeetingsTests: XCTestCase {
    private var root: URL!
    private var vault: Vault!
    /// The settings as the plugin leaves them at activation: ffmpeg's path where this Mac has it.
    private var settings: MeetingsSettings = {
        var settings = MeetingsSettings()
        settings.ffmpegPath = ToolLocator().locate("ffmpeg")?.path ?? ""
        return settings
    }()

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("meetings-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        vault = Vault(rootURL: root)
        settings.summaryLanguage = "French"
        settings.defaultTemplate = "General"
        settings.myName = "Kevin"
        settings.askSpeakerNames = true
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func meetings(_ ai: FakeAI, events: Locked<[PluginEvent]>? = nil, daily: DailyNotesService? = nil) -> Meetings {
        let s = settings
        return Meetings(vault: vault, settings: { s }, ai: ai, dailyNotes: { daily },
                        emit: { event in events?.update { $0.append(event) } },
                        now: { ISO8601DateFormatter().date(from: "2026-10-22T14:30:00Z")! })
    }

    /// Speech-like audio: a tone switched on and off, with long silences between.
    static func speech(_ pattern: [(seconds: Double, loud: Bool)]) -> [Int16] {
        var out: [Int16] = []
        var phase = 0.0
        for (seconds, loud) in pattern {
            for _ in 0..<Int(seconds * Double(meetingSampleRate)) {
                phase += 2 * .pi * 220 / Double(meetingSampleRate)
                out.append(loud ? Int16(sin(phase) * 8000) : Int16.random(in: -20...20))
            }
        }
        return out
    }

    // MARK: Pure parts

    func testTrackDropsSilencesAndMapsTimesBack() {
        var chunks: [Chunk] = []
        let track = Track(.mic) { chunks.append($0) }
        track.push(Self.speech([(5, false), (2, true), (10, false), (2, true), (3, false)]))
        track.flush()
        XCTAssertEqual(chunks.count, 1)
        let chunk = chunks[0]
        // Two seconds of speech twice, with short pads, instead of 22 seconds.
        XCTAssertLessThan(chunk.duration, 6)
        XCTAssertGreaterThan(chunk.speech, 3.5)
        // The second burst starts at 17 s on the meeting clock.
        let secondStart = Double(chunk.map[1].out) / Double(meetingSampleRate)
        XCTAssertEqual(remapTime(chunk.map, secondStart + 0.5), Double(chunk.map[1].src) / Double(meetingSampleRate) + 0.5, accuracy: 0.01)
        XCTAssertEqual(remapTime(chunk.map, secondStart + 0.4), 17.1, accuracy: 0.2)
        XCTAssertEqual(track.seconds, 22, accuracy: 0.01)
    }

    func testTrackCutsLongSpeechInsideASilenceAndDropsSilentChunks() {
        var chunks: [Chunk] = []
        var options = Track.Options(chunkMinutes: 1)
        options.chunkSeconds = 3
        let track = Track(.system, options: options) { chunks.append($0) }
        track.push(Self.speech([(2, true), (1, false), (2, true), (1, false), (2, true), (2, false)]))
        track.flush()
        XCTAssertEqual(chunks.map(\.index), [0, 1])
        XCTAssertTrue(chunks.allSatisfy { $0.speech >= 1 })
        var silent: [Chunk] = []
        let quiet = Track(.mic) { silent.append($0) }
        quiet.push(Self.speech([(10, false)]))
        quiet.flush()
        XCTAssertTrue(silent.isEmpty)
    }

    func testMergeLabelsTheMicrophoneAsMeAndDropsItsEchoes() {
        let mic = ChunkState(track: .mic, index: 0, duration: 10, speech: 5, map: [TimeMapEntry(out: 0, src: 0)], format: "wav")
        let system = ChunkState(track: .system, index: 0, duration: 10, speech: 5, map: [TimeMapEntry(out: 0, src: 16_000)], format: "wav")
        let utterances = Transcript.merge([
            (mic, SttResult(text: "", segments: [.init(start: 0, end: 1, text: "Hello everyone"),
                                                 .init(start: 1.2, end: 3, text: "the budget will be approved tomorrow")])),
            (system, SttResult(text: "", segments: [.init(start: 0.5, end: 2, text: "the budget will be approved tomorrow", speaker: 2)])),
        ], micIsMe: true)
        XCTAssertEqual(utterances.map(\.label), ["me", "system0:2"])
        XCTAssertEqual(utterances[1].start, 1.5, accuracy: 0.001)
        XCTAssertEqual(Transcript.rawLines(utterances, names: ["me": "Kevin", "system0:2": "Paul"]),
                       ["[00:00] Kevin: Hello everyone", "[00:02] Paul: the budget will be approved tomorrow"])
    }

    func testSpeakersKeepEveryLabelOnceAndNameTheUnknown() {
        let utterances = [
            Utterance(start: 0, end: 1, label: "system0:0", text: "a"),
            Utterance(start: 2, end: 3, label: "system0:1", text: "b"),
            Utterance(start: 4, end: 5, label: "system1:0", text: "c"),
        ]
        let json = ModelReplies.json(#"```json {"people":[{"name":"Marie","labels":["system1:0","system0:1","nope"]},{"name":"X","labels":["system0:1"]}]} ```"#)
        let people = Speakers.people(from: json, utterances: utterances)
        XCTAssertEqual(people.map(\.labels), [["system0:0"], ["system1:0", "system0:1"]])
        XCTAssertEqual(Speakers.names(people, me: "Kevin") { "Speaker \($0)" },
                       ["me": "Kevin", "system0:0": "Speaker 1", "system1:0": "Marie", "system0:1": "Marie"])
    }

    func testModelRepliesAreReadDefensively() {
        XCTAssertEqual(ModelReplies.classification(#"{"type":"idea","confidence":3}"#)?.confidence, 1)
        XCTAssertNil(ModelReplies.classification(#"{"type":"podcast"}"#))
        XCTAssertEqual(ModelReplies.title("\"Plan Q4.\"\nother"), "Plan Q4")
        let entry = ModelReplies.journalEntry(#"{"title":"- Review","tasks":["[ ] Groceries",{"text":"Sport","done":true}],"notes":["• Idea"]}"#)
        XCTAssertEqual(ModelReplies.journalBlock(time: "09:05", fallbackTitle: "Journal", entry: entry, links: "[Transcript](t.md)"),
                       "### 🎙️ 09:05 · Review\n\n- [ ] Groceries\n- [x] Sport\n- Idea\n\n[Transcript](t.md)")
        XCTAssertEqual(ModelReplies.journalEntry("not json\n- an idea").notes, ["not json", "an idea"])
        let highlighted = ModelReplies.journalEntry(#"{"title":"Test","tldr":"I ==doubt== it","notes":["a == b, ==key=="]}"#)
        XCTAssertEqual(ModelReplies.journalBlock(time: "23:33", fallbackTitle: "Journal", entry: highlighted, links: ""),
                       "### 🎙️ 23:33 · Test\n*I <mark>doubt</mark> it*\n\n- a == b, <mark>key</mark>")
        XCTAssertEqual(ModelReplies.mindmap(title: "Demo", reply: "Here:\n- A\n        - B\n            - C\n- D\n  1. E"),
                       "---\nmindmap-plugin: basic\n---\n\n# Demo\n\n- A\n\t- B\n\t\t- C\n- D\n\t- E\n")
        XCTAssertEqual(ModelReplies.mindmap(title: "x", reply: "- alone"), "")
    }

    func testAJournalBlockIsReplacedNotRepeated() {
        let first = MeetingWriter.replacingBlock(in: "# 2026-10-22\n\nMorning.\n", block: "### 🎙️ 09:00 · A\n\n[Transcript](x.md)", marker: "[Transcript](x.md)")
        XCTAssertEqual(first, "# 2026-10-22\n\nMorning.\n\n### 🎙️ 09:00 · A\n\n[Transcript](x.md)\n")
        let again = MeetingWriter.replacingBlock(in: first + "\n## Evening\nOK\n", block: "### 🎙️ 09:00 · B\n\n[Transcript](x.md)", marker: "[Transcript](x.md)")
        XCTAssertEqual(again, "# 2026-10-22\n\nMorning.\n\n### 🎙️ 09:00 · B\n\n[Transcript](x.md)\n\n## Evening\nOK\n")
    }

    // MARK: Whole recordings

    private func writeWAV(_ path: String, _ samples: [Int16]) throws -> URL {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try AudioCodec.wav(samples).write(to: url)
        // Imports are dated by the file, like a recorder's file.
        try FileManager.default.setAttributes([.modificationDate: ISO8601DateFormatter().date(from: "2026-10-22T14:30:00Z")!],
                                              ofItemAtPath: url.path)
        return url
    }

    func testAnImportedMeetingBecomesAFolderOfNotes() async throws {
        let ai = FakeAI()
        let events = Locked<[PluginEvent]>([])
        let engine = meetings(ai, events: events)
        var asked: [Person] = []
        engine.askNames = { people, _ in
            asked = people
            return people.map { var p = $0; if p.name.isEmpty { p.name = "Kevin bis" }; return p }
        }
        let file = try writeWAV("Dictaphone/rec.wav", Self.speech([(1, false), (3, true), (1, false)]))
        let result = try await engine.importAudio(file.path, options: .init(kind: .meeting), background: false)

        let folder = "Meetings/2026-10-22 \(Self.hhmm) Demo launch"
        XCTAssertEqual(result.note, "\(folder)/Summary.md")
        let summary = try vault.read(result.note)
        XCTAssertTrue(summary.contains("\n# Summary · Demo launch\n"), summary)
        XCTAssertTrue(summary.contains("participants: [Kevin bis, Paul]"), summary)
        XCTAssertTrue(summary.contains("# Summary · Demo launch\n\n[Transcript](Transcript.md) · [Mind map](Mindmap.md) · [Audio](audio.wav)\n\n![](audio.wav)"), summary)
        XCTAssertTrue(summary.contains("- [ ] Paul — prepare the demo"))
        let transcript = try vault.read("\(folder)/Transcript.md")
        XCTAssertTrue(transcript.contains("\n# Transcript · Demo launch\n"), transcript)
        XCTAssertTrue(transcript.contains("[00:02] Paul: Yes, I am preparing the demo for Friday."), transcript)
        XCTAssertTrue(try vault.read("\(folder)/Mindmap.md").hasPrefix("---\ntitle: \"Mind map · Demo launch\"\nmindmap-plugin: basic"))
        // An import has no notes to type.
        XCTAssertFalse(vault.exists("\(folder)/Notes.md"))
        XCTAssertEqual(asked.map(\.name), ["", "Paul"])
        XCTAssertEqual(RawFolder.load(vault, folder: folder)?.status, .done)
        // The source file stays where it was; the templates folder was made.
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        XCTAssertTrue(vault.exists("Meetings/Templates/General.md"))
        XCTAssertEqual(RawFolder.load(vault, folder: folder)?.template, "General")
        // A template the folder lacks falls back to the general one.
        XCTAssertEqual(meetings(ai).resolvedTemplate("Missing"), "General")
        XCTAssertEqual(ai.calls.get(), ["stt:\(Self.chunkFormat):true", "speakers", "clean", "summary", "title", "mindmap"])
        XCTAssertTrue(events.get().contains { ($0 as? MeetingFinished)?.note == result.note })
    }

    func testAnInboxMemoThatIsAJournalGoesToTheDailyNote() async throws {
        let ai = FakeAI()
        ai.kind = "journal"
        let engine = meetings(ai)
        _ = try writeWAV("Meetings/Inbox/memo.wav", Self.speech([(3, true), (1, false)]))
        XCTAssertEqual(engine.inboxFiles(), ["Meetings/Inbox/memo.wav"])
        await engine.processInbox()

        XCTAssertEqual(engine.inboxFiles(), [])
        let folder = "Meetings/Voice notes/2026-10-22 \(Self.hhmm) Journal"
        XCTAssertTrue(vault.exists("\(folder)/Transcript.md"))
        XCTAssertTrue(vault.exists("\(folder)/audio.wav"))
        let daily = try vault.read("2026-10-22.md")
        XCTAssertTrue(daily.contains("### 🎙️ \(Self.hhmmColon) · Day review\n*A busy day.*\n\n- [ ] Call Paul\n- 14:00 — demo\n- <mark>Launch on Friday</mark>"), daily)
        XCTAssertTrue(daily.contains("[Transcript](Meetings/Voice%20notes/2026-10-22%20\(Self.hhmm)%20Journal/Transcript.md)"), daily)
        // Alone with the microphone: no speaker grouping, no summary.
        XCTAssertEqual(ai.calls.get(), ["stt:\(Self.chunkFormat):true", "classify", "clean", "journal"])

        // Processing it again replaces the entry.
        _ = try await engine.reprocess(folder)
        XCTAssertEqual(try vault.read("2026-10-22.md").components(separatedBy: "### 🎙️").count, 2)
    }

    func testALiveCallIsRecordedTranscribedAndSummarized() async throws {
        let ai = FakeAI()
        let engine = meetings(ai)
        let session = try engine.start(kind: .meeting, mode: .call)
        XCTAssertEqual(session.trackIDs, [.mic, .system])
        let notesPath = session.state.notesPath
        XCTAssertTrue(notesPath.hasSuffix("Meeting/Meeting on October 22.md"), notesPath)
        let hint = "> *What you write here guides the meeting summary. Left empty, this note is deleted.*"
        XCTAssertEqual(try vault.read(notesPath), "# Meeting on October 22\n\n\(hint)\n\n")
        XCTAssertEqual(MeetingWriter.userNotes(try vault.read(notesPath)), "")
        try vault.write(notesPath, try vault.read(notesPath) + "Demo on Friday\n")
        let samples = Self.speech([(3, true), (1, false)])
        for start in stride(from: 0, to: samples.count, by: 1600) {
            session.push(.mic, Array(samples[start..<min(samples.count, start + 1600)]))
            session.push(.system, Array(samples[start..<min(samples.count, start + 1600)]))
        }
        session.noteTyped("Demo on Friday", at: 12)
        let result = try await engine.finish(session)
        XCTAssertTrue(result.note.hasSuffix("Demo launch/Summary.md"), result.note)
        // Written-in notes stay, renamed after the meeting, and the summary links them.
        let folder = VaultPath.directory(of: result.note)
        XCTAssertEqual(try vault.read("\(folder)/Demo launch.md"), "# Demo launch\n\n\(hint)\n\nDemo on Friday\n")
        XCTAssertTrue(try vault.read(result.note).contains("[Raw notes](Demo%20launch.md)"))
        let calls = ai.calls.get()
        // The microphone is the user (not diarized), the system audio is.
        XCTAssertTrue(calls.contains("stt:\(Self.chunkFormat):false"))
        XCTAssertTrue(calls.contains("stt:\(Self.chunkFormat):true"))
        let state = try XCTUnwrap(RawFolder.load(vault, folder: VaultPath.directory(of: result.note)))
        XCTAssertEqual(state.noteTimes, ["Demo on Friday": 12])
        XCTAssertEqual(state.chunks.count, 2)
        XCTAssertTrue(vault.exists(VaultPath.directory(of: result.note) + "/audio.\(Self.archiveFormat)"))
    }

    func testACancelledFirstVoiceNoteLeavesNoEmptyFolder() async throws {
        let engine = meetings(FakeAI())
        try vault.write("Meetings/Kept.md", "# Kept\n")
        let session = try engine.start(kind: .voice)
        XCTAssertTrue(vault.exists("Meetings/Voice notes"))
        await engine.discard(session)
        XCTAssertFalse(vault.exists(session.state.folder))
        // The folder made for it goes; the one holding something else stays.
        XCTAssertFalse(vault.exists("Meetings/Voice notes"))
        XCTAssertTrue(vault.exists("Meetings/Kept.md"))
    }

    func testEmptyMeetingNotesGoToTheTrash() async throws {
        let engine = meetings(FakeAI())
        let session = try engine.start(kind: .meeting, mode: .call)
        let samples = Self.speech([(3, true), (1, false)])
        for start in stride(from: 0, to: samples.count, by: 1600) {
            session.push(.mic, Array(samples[start..<min(samples.count, start + 1600)]))
            session.push(.system, Array(samples[start..<min(samples.count, start + 1600)]))
        }
        let result = try await engine.finish(session)
        let folder = VaultPath.directory(of: result.note)
        XCTAssertEqual(try vault.list(folder).map { ($0.path as NSString).lastPathComponent }.filter { $0.hasSuffix(".md") }.sorted(),
                       ["Mindmap.md", "Summary.md", "Transcript.md"])
        XCTAssertFalse(try vault.read(result.note).contains("Raw notes"))
    }

    func testTheHistorySaysWhereEachRecordingCameFromAndHowItWent() async throws {
        let ai = FakeAI()
        ai.kind = "journal"
        let engine = meetings(ai)
        // A memo from the inbox (a dictaphone, an automation) becomes the day's journal.
        _ = try writeWAV("Meetings/Inbox/memo.wav", Self.speech([(3, true), (1, false)]))
        await engine.processInbox()
        // A Voice Memo whose transcription fails.
        ai.failTranscription = true
        let memo = try writeWAV("Recordings/20261022 143000-AB.wav", Self.speech([(3, true)]))
        _ = try? await engine.importAudio(memo.path, options: .init(kind: .meeting, title: "Point", origin: .voiceMemos))
        // A call and a voice note being recorded.
        let call = try engine.start(kind: .meeting, mode: .call, title: "Call")
        let voice = try engine.start(kind: .voice)

        let history = engine.history()
        let byOrigin = Dictionary(uniqueKeysWithValues: history.map { ($0.origin, $0) })
        XCTAssertEqual(Set(byOrigin.keys), [.inbox, .voiceMemos, .call, .voiceNote])
        XCTAssertEqual(byOrigin[.inbox]?.outcome, .done)
        XCTAssertEqual(byOrigin[.voiceMemos]?.outcome, .failed("Transcription: OpenRouter 503: busy"))
        XCTAssertEqual(byOrigin[.voiceMemos]?.title, "Point")
        XCTAssertEqual(byOrigin[.call]?.outcome, .working)
        XCTAssertEqual(byOrigin[.voiceNote]?.outcome, .working)
        // A voice note opens the day's note it was written in.
        let journal = try XCTUnwrap(engine.recordings().first { $0.folder == byOrigin[.inbox]?.folder })
        XCTAssertEqual(engine.note(of: journal), "2026-10-22.md")
        await call.stop()
        await voice.stop()
    }

    func testTheHistoryGuessesWhereOlderRecordingsCameFrom() {
        var state = MeetingState(title: "x", folder: "Meetings/x", startedAt: Date(), language: "", mode: .room, template: "",
                                 status: .done, kind: .meeting)
        XCTAssertEqual(Meetings.origin(of: state, settings: settings), .room)
        state.mode = .call
        XCTAssertEqual(Meetings.origin(of: state, settings: settings), .call)
        state.kind = .voice
        XCTAssertEqual(Meetings.origin(of: state, settings: settings), .voiceNote)
        state.source = "import"
        state.sourceFile = (settings.voiceMemosFolder as NSString).expandingTildeInPath + "/20261022 143000-AB.m4a"
        XCTAssertEqual(Meetings.origin(of: state, settings: settings), .voiceMemos)
        state.sourceFile = "Meetings/Inbox/memo.m4a"
        XCTAssertEqual(Meetings.origin(of: state, settings: settings), .inbox)
        state.sourceFile = "/Users/me/Downloads/rec.m4a"
        XCTAssertEqual(Meetings.origin(of: state, settings: settings), .file)
        state.origin = .voiceMemos
        XCTAssertEqual(Meetings.origin(of: state, settings: settings), .voiceMemos)

        XCTAssertEqual(Meetings.oneLine("OpenRouter 402:\n  {\"error\": \"credits\"}"), "OpenRouter 402:")
        XCTAssertEqual(Meetings.oneLine("a  b\tc"), "a b c")
        XCTAssertEqual(Meetings.oneLine("2 segment(s) could not be transcribed: OpenRouter 402: Insufficient credits. Add more."),
                       "Transcription: OpenRouter 402: Insufficient credits")
        XCTAssertEqual(Meetings.oneLine("No speech was heard in this recording."), "No speech was heard in this recording")
        let long = Meetings.oneLine(String(repeating: "word ", count: 60).trimmingCharacters(in: .whitespaces))
        XCTAssertEqual(long.count, 120)
        XCTAssertTrue(long.hasSuffix("…"))
    }

    func testAFailedTranscriptionIsKeptAndRetried() async throws {
        let ai = FakeAI()
        ai.failTranscription = true
        let engine = meetings(ai)
        let file = try writeWAV("rec.wav", Self.speech([(3, true)]))
        do {
            _ = try await engine.importAudio(file.path, options: .init(kind: .meeting, title: "Point"))
            XCTFail("should fail")
        } catch {}
        XCTAssertEqual(engine.failures().map(\.title), ["Point"])
        XCTAssertEqual(engine.recordings().first?.status, .error)
        ai.failTranscription = false
        let tried = await engine.retryFailed(manual: true)
        XCTAssertEqual(tried, 1)
        XCTAssertEqual(engine.failures().count, 0)
        XCTAssertTrue(vault.exists("Meetings/2026-10-22 \(Self.hhmm) Point/Summary.md"))
    }

    func testThePluginActivatesListsAndUnloads() async throws {
        let kernel = Kernel(vault: vault)
        let host = PluginHost(kernel: kernel)
        try host.register(MeetingsPlugin.self)
        try host.activateAll()
        XCTAssertNotNil(kernel.services.service(.meetings))
        let list = try XCTUnwrap(kernel.commands.command(id: "meetings.list"))
        let listing = try await list.handler([:])
        XCTAssertEqual(listing, "[\n\n]")
        host.deactivateAll()
        XCTAssertNil(kernel.services.service(.meetings))
        XCTAssertNil(kernel.commands.command(id: "meetings.import"))
    }

    // MARK: Folders

    /// The settings as the plugin reads and writes them, kept in memory.
    private final class MemorySettings: PluginSettingsAccess {
        var stored: MeetingsSettings?
        func value<S: Codable & Equatable>(default defaultValue: S) -> S { (stored as? S) ?? defaultValue }
        func update<S: Codable & Equatable>(_ value: S) throws { stored = value as? MeetingsSettings }
    }

    func testANewVaultGetsEnglishFolders() {
        let settings = MemorySettings()
        MeetingsPlugin.freezeFolders(settings: settings, vault: vault)
        XCTAssertEqual(settings.stored?.meetingsFolder, "Meetings")
        XCTAssertEqual(settings.stored?.templatesFolder, "Meetings/Templates")
        XCTAssertEqual(settings.stored?.inboxFolder, "Meetings/Inbox")
        XCTAssertEqual(settings.stored?.voiceFolder, "Meetings/Voice notes")
    }

    func testAVaultWithItsFrenchFoldersKeepsThem() throws {
        for folder in ["Réunions", "Réunions/Modèles", "Réunions/À importer", "Réunions/Notes vocales"] {
            try vault.createFolder(folder)
        }
        let settings = MemorySettings()
        MeetingsPlugin.freezeFolders(settings: settings, vault: vault)
        XCTAssertEqual(settings.stored?.meetingsFolder, "Réunions")
        XCTAssertEqual(settings.stored?.templatesFolder, "Réunions/Modèles")
        XCTAssertEqual(settings.stored?.inboxFolder, "Réunions/À importer")
        XCTAssertEqual(settings.stored?.voiceFolder, "Réunions/Notes vocales")
    }

    // MARK: Environment

    static var hhmm: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HHmm"
        return formatter.string(from: ISO8601DateFormatter().date(from: "2026-10-22T14:30:00Z")!)
    }

    static var hhmmColon: String { String(hhmm.prefix(2)) + ":" + String(hhmm.suffix(2)) }
    static var chunkFormat: String { AudioCodec(ffmpeg: ToolLocator().locate("ffmpeg")?.path ?? "").hasFFmpeg ? "mp3" : "flac" }
    static var archiveFormat: String { "m4a" }
}
