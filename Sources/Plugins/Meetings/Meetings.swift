import Foundation
import PluginKit

/// A recording moved on: `step` is what it is doing now, empty once it stopped.
public struct MeetingProgress: PluginEvent, Equatable, Sendable {
    public let folder: String
    public let title: String
    public let step: String

    public init(folder: String, title: String, step: String) {
        self.folder = folder
        self.title = title
        self.step = step
    }
}

/// A recording became notes. `background`: nobody was waiting (an inbox file, a memo, a retry).
public struct MeetingFinished: PluginEvent, Equatable, Sendable {
    public let folder: String
    public let title: String
    /// The note to open: the summary, or the day's note for a voice note.
    public let note: String
    public let cost: Double
    public let background: Bool

    public init(folder: String, title: String, note: String, cost: Double, background: Bool) {
        self.folder = folder
        self.title = title
        self.note = note
        self.cost = cost
        self.background = background
    }
}

public struct MeetingFailed: PluginEvent, Equatable, Sendable {
    public let folder: String
    public let title: String
    public let message: String

    public init(folder: String, title: String, message: String) {
        self.folder = folder
        self.title = title
        self.message = message
    }
}

/// The meeting recorder without its interface: starts recordings the app feeds with sound, imports audio files,
/// processes and re-processes recordings, retries the ones that failed, and watches the inbox and Voice Memos. Every
/// recording is a folder of plain Markdown; what is needed to process it again lives in its `.raw/`.
public final class Meetings: @unchecked Sendable {
    let vault: VaultAccess
    let settingsSource: () -> MeetingsSettings
    let ai: MeetingAI
    let dailyNotes: () -> DailyNotesService?
    let emit: (PluginEvent) -> Void
    let now: () -> Date
    /// Lets the user confirm or fix the speakers' names, when someone is waiting (the app sets it).
    public var askNames: (([Person], [Utterance]) async -> [Person])?
    private let busy = Locked<Set<String>>([])
    private let memoCheck = Locked<Bool>(false)

    public init(vault: VaultAccess, settings: @escaping () -> MeetingsSettings, ai: MeetingAI,
                dailyNotes: @escaping () -> DailyNotesService? = { nil },
                emit: @escaping (PluginEvent) -> Void = { _ in }, now: @escaping () -> Date = Date.init) {
        self.vault = vault
        settingsSource = settings
        self.ai = ai
        self.dailyNotes = dailyNotes
        self.emit = emit
        self.now = now
    }

    public var settings: MeetingsSettings { settingsSource() }

    // MARK: Recording

    /// Starts a recording: its folder (with `Notes.md` for a meeting) and the session the app pushes sound into.
    /// `mode` nil uses the default; a voice note is always the microphone alone.
    public func start(kind: MeetingKind, mode: MeetingMode? = nil, title: String? = nil, template: String? = nil) throws -> RecordingSession {
        let s = settings
        let p = s.prompts
        let when = now()
        let mode = kind == .voice ? .room : (mode ?? s.mode)
        let given = title?.trimmed ?? ""
        let title = given.isEmpty ? (kind == .voice ? p.journal : p.meeting) : given
        let folder = try newFolder(title: title, date: when, kind: kind)
        var state = MeetingState(
            title: title, folder: folder, startedAt: when, language: s.language, mode: mode,
            template: kind == .voice ? "" : resolvedTemplate(template ?? s.defaultTemplate),
            status: .recording, kind: kind, autoTitle: kind == .meeting && given.isEmpty
        )
        state.origin = kind == .voice ? .voiceNote : mode == .call ? .call : .room
        if kind == .meeting { try writeNotes(&state, prompts: p) }
        let box = StateBox(state, vault: vault)
        let session = try RecordingSession(box: box, ai: ai, settings: s, tracks: mode == .call ? [.mic, .system] : [.mic])
        try RawFolder.save(vault, state)
        return session
    }

    /// Stops a recording and turns it into notes.
    @discardableResult
    public func finish(_ session: RecordingSession) async throws -> PipelineResult {
        let state = session.state
        emit(MeetingProgress(folder: state.folder, title: state.title, step: "Audio…"))
        await session.stop()
        return try await process(box: session.box, queue: session.queue, background: false)
    }

    /// Writes the empty notes of a meeting, named after it.
    private func writeNotes(_ state: inout MeetingState, prompts p: Prompts) throws {
        let name = MeetingWriter.notesTitle(state.title, date: state.startDate, prompts: p)
        state.notesFile = "\(name).md"
        try vault.write(state.notesPath, MeetingWriter.notes(name, prompts: p))
    }

    /// Throws a recording in progress away: the folder (notes included) goes to `.trash/`, so it can be got back.
    /// The folders it was made in go too when nothing else is in them: a first voice note cancelled leaves no empty
    /// "Voice notes" in the sidebar.
    public func discard(_ session: RecordingSession) async {
        await session.discard()
        let folder = session.state.folder
        guard vault.exists(folder) else { return }
        let name = (folder as NSString).lastPathComponent
        let stamp = Int(now().timeIntervalSince1970)
        guard (try? vault.move(folder, to: ".trash/\(name) \(stamp)")) != nil else { return }
        var parent = VaultPath.directory(of: folder)
        while !parent.isEmpty, Self.removeIfEmptyFolder(vault.rootURL.appendingPathComponent(parent)) {
            parent = VaultPath.directory(of: parent)
        }
    }

    /// Deletes a folder holding nothing (Finder's `.DS_Store` aside); false when anything is in it.
    static func removeIfEmptyFolder(_ url: URL) -> Bool {
        let manager = FileManager.default
        guard let names = try? manager.contentsOfDirectory(atPath: url.path),
              names.allSatisfy({ $0 == ".DS_Store" }) else { return false }
        return (try? manager.removeItem(at: url)) != nil
    }

    // MARK: Import

    public struct ImportOptions: Sendable {
        public var kind: MeetingKind
        public var title: String
        public var startedAt: Date?
        public var template: String?
        public var mode: MeetingMode = .room
        /// Nil: the inbox when the file is in it, else a file picked by hand.
        public var origin: MeetingOrigin?

        public init(kind: MeetingKind = .auto, title: String = "", startedAt: Date? = nil, template: String? = nil,
                    origin: MeetingOrigin? = nil) {
            self.kind = kind
            self.title = title
            self.startedAt = startedAt
            self.template = template
            self.origin = origin
        }
    }

    /// Builds a meeting or a voice note from an audio file, in the vault (vault path) or anywhere on disk (absolute
    /// path). A file from the inbox folder is moved into the new folder, so it is handled once; another file is copied
    /// when the audio is kept, and left where it is.
    @discardableResult
    public func importAudio(_ source: String, options: ImportOptions, background: Bool = false) async throws -> PipelineResult {
        let s = settings
        let p = s.prompts
        let url = source.hasPrefix("/") ? URL(fileURLWithPath: source) : vault.rootURL.appendingPathComponent(source)
        guard FileManager.default.fileExists(atPath: url.path) else { throw AIError("No file at \(source).", status: 0) }
        let modified = (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date) ?? now()
        let kind = options.kind
        let given = options.title.trimmed
        let title = given.isEmpty ? (kind == .voice ? p.journal : kind == .auto ? p.memo : p.meeting) : given
        let folder = try newFolder(title: title, date: options.startedAt ?? modified, kind: kind)
        var state = MeetingState(
            title: title, folder: folder, startedAt: options.startedAt ?? modified, language: s.language, mode: .room,
            template: kind == .voice ? "" : resolvedTemplate(options.template ?? s.defaultTemplate),
            status: .processing, kind: kind, autoTitle: kind != .voice && given.isEmpty
        )
        let inbox = !source.hasPrefix("/") && VaultPath.directory(of: source) == (try? VaultPath.normalize(s.inboxFolder))
        state.source = "import"
        state.sourceFile = source
        state.origin = options.origin ?? (inbox ? .inbox : .file)
        let box = StateBox(state, vault: vault)
        try RawFolder.save(vault, state)
        emit(MeetingProgress(folder: folder, title: title, step: "Audio…"))

        do {
            // Keep the audio: the inbox file moves in, a playable one is copied, the rest is kept as decoded.
            let ext = url.pathExtension.lowercased()
            var decodeURL = url
            var archiveDecoded = false
            if inbox {
                try vault.move(source, to: "\(folder)/audio.\(ext)")
                decodeURL = vault.rootURL.appendingPathComponent("\(folder)/audio.\(ext)")
            } else if s.keepAudio {
                if ["m4a", "mp3", "wav", "aac", "flac", "aif", "aiff", "caf"].contains(ext) {
                    try FileManager.default.copyItem(at: url, to: vault.rootURL.appendingPathComponent("\(folder)/audio.\(ext)"))
                } else {
                    archiveDecoded = true
                }
            }

            let queue = TranscriptionQueue(box: box, ai: ai, settings: s)
            let writer = ChunkWriter(box: box, queue: queue, codec: s.codec)
            let track = Track(.mic, options: Track.Options(chunkMinutes: max(1, s.chunkMinutes))) { writer.add($0) }
            let raw = RawFolder.url(vault, folder, "audio.pcm")
            let archive = archiveDecoded ? try AudioArchive(url: raw, tracks: [.mic]) : nil
            var lastShown = -1
            try await s.codec.decode(decodeURL, onSamples: { samples in
                track.push(samples)
                archive?.push(.mic, samples)
                archive?.pump()
            }, progress: { [emit] ratio in
                let percent = Int(ratio * 100)
                guard percent / 5 != lastShown / 5 else { return }
                lastShown = percent
                emit(MeetingProgress(folder: folder, title: title, step: "Audio \(percent)%"))
            })
            track.flush()
            await writer.flush()
            if let archive {
                archive.close()
                _ = try? await s.codec.archive(rawSamples: raw, to: vault.rootURL.appendingPathComponent(folder))
                try? FileManager.default.removeItem(at: raw)
            }
            box.update { $0.duration = track.seconds }
            return try await process(box: box, queue: queue, background: background)
        } catch {
            fail(box, error)
            throw error
        }
    }

    // MARK: Processing

    /// Processes a recording again from what its `.raw/` holds: transcribes what is missing, then everything after.
    @discardableResult
    public func reprocess(_ folder: String, background: Bool = false) async throws -> PipelineResult {
        guard var state = RawFolder.load(vault, folder: folder) else {
            throw AIError("\(folder) has no recording data (.raw/meeting.json).", status: 0)
        }
        if state.status == .recording { state.status = .processing }
        let box = StateBox(state, vault: vault)
        box.update { $0.status = .processing }
        let queue = TranscriptionQueue(box: box, ai: ai, settings: settings)
        return try await process(box: box, queue: queue, background: background)
    }

    private func process(box: StateBox, queue: TranscriptionQueue, background: Bool) async throws -> PipelineResult {
        let start = box.value
        guard busy.update({ $0.insert(start.folder).inserted }) else {
            throw AIError("\(start.title) is already being processed.", status: 0)
        }
        defer { busy.update { _ = $0.remove(start.folder) } }
        let s = settings
        let hooks = PipelineHooks(
            progress: { [emit] step in emit(MeetingProgress(folder: box.value.folder, title: box.value.title, step: step)) },
            relocate: { [self] kind in try relocate(box, kind: kind) },
            askNames: background || !s.askSpeakerNames ? nil : askNames,
            dailyNotePath: { [dailyNotes] day in try? dailyNotes()?.path(for: day) }
        )
        let pipeline = Pipeline(vault: vault, ai: ai, settings: s, box: box, queue: queue, hooks: hooks)
        do {
            let result = try await pipeline.run()
            let state = box.value
            emit(MeetingProgress(folder: state.folder, title: state.title, step: ""))
            emit(MeetingFinished(folder: state.folder, title: state.title, note: result.note, cost: result.cost, background: background))
            return result
        } catch {
            fail(box, error)
            throw error
        }
    }

    private func fail(_ box: StateBox, _ error: Error) {
        box.update { state in
            state.status = .error
            state.error = error.localizedDescription
            state.failedAt = now().timeIntervalSince1970
        }
        let state = box.value
        emit(MeetingProgress(folder: state.folder, title: state.title, step: ""))
        emit(MeetingFailed(folder: state.folder, title: state.title, message: error.localizedDescription))
    }

    /// An `auto` recording once it is known: a journal goes with the voice notes, a meeting to the meetings folder.
    private func relocate(_ box: StateBox, kind: MeetingKind) throws {
        let s = settings
        let p = s.prompts
        let state = box.value
        let name = (state.folder as NSString).lastPathComponent
        let stamp = name.range(of: #"^\d{4}-\d{2}-\d{2} \d{4}"#, options: .regularExpression).map { String(name[$0]) }
            ?? Self.folderStamp(state.startDate)
        let title = kind == .voice ? p.journal : p.meeting
        let root = kind == .voice ? s.voiceFolder : s.meetingsFolder
        try vault.createFolder(root)
        let target = MeetingWriter.freePath(vault, "\(root)/\(stamp) \(title)")
        try vault.move(state.folder, to: target)
        box.update { state in
            state.folder = target
            state.title = title
            state.kind = kind
            if kind == .meeting {
                state.autoTitle = true
                if state.template.isEmpty { state.template = resolvedTemplate(s.defaultTemplate) }
            }
        }
    }

    // MARK: Failures and interruptions

    /// Every recording folder with a state, in the meetings and voice notes folders.
    public func recordings() -> [MeetingState] {
        let s = settings
        var out: [MeetingState] = []
        for root in [s.meetingsFolder, s.voiceFolder] where !root.trimmed.isEmpty {
            for entry in (try? vault.list(root)) ?? [] where entry.isFolder {
                if let state = RawFolder.load(vault, folder: entry.path) { out.append(state) }
            }
        }
        return out.sorted { $0.startedAt > $1.startedAt }
    }

    /// The note to open for a recording: the day's note for a voice note once written there, else its summary, its
    /// notes or its transcript.
    public func note(of state: MeetingState) -> String? {
        if state.kind == .voice, state.status == .done {
            let day = Pipeline.day(state.startDate)
            let daily = (try? dailyNotes()?.path(for: day)) ?? "\(day).md"
            if vault.exists(daily) { return daily }
        }
        // "Résumé.md": the summary of a recording made before the names were English.
        return (["Summary.md", "Résumé.md"].map { "\(state.folder)/\($0)" }
            + [state.notesPath, "\(state.folder)/Transcript.md"])
            .first { vault.exists($0) }
    }

    static let retryDelays: [Double] = [2, 10, 30]

    /// A failure worth showing or retrying: something was recorded, someone spoke, in the last 7 days.
    func isFailure(_ state: MeetingState) -> Bool {
        state.status == .error && !state.chunks.isEmpty && state.error != Pipeline.NoSpeech().errorDescription
            && now().timeIntervalSince(state.startDate) <= 7 * 86_400
    }

    func shouldRetry(_ state: MeetingState) -> Bool {
        guard isFailure(state) else { return false }
        let tries = state.retries ?? 0
        return tries < Self.retryDelays.count && now().timeIntervalSince1970 - (state.failedAt ?? 0) >= Self.retryDelays[tries] * 60
    }

    public func failures() -> [MeetingState] { recordings().filter(isFailure) }

    /// Recordings a quit or a crash cut short (still recording or processing, and not being processed now).
    public func interrupted() -> [MeetingState] {
        let working = busy.get()
        return recordings().filter { ($0.status == .recording || $0.status == .processing) && !working.contains($0.folder) }
    }

    /// Tries failed recordings again: by themselves 3 times (2, 10 then 30 min apart), or all of them now when
    /// `manual`. Returns how many were tried.
    @discardableResult
    public func retryFailed(manual: Bool = false, skipping: Set<String> = []) async -> Int {
        var count = 0
        for state in recordings() where !skipping.contains(state.folder) && !busy.get().contains(state.folder) {
            guard manual ? isFailure(state) : shouldRetry(state) else { continue }
            count += 1
            let box = StateBox(state, vault: vault)
            box.update { $0.retries = manual ? 1 : ($0.retries ?? 0) + 1 }
            _ = try? await reprocess(state.folder, background: true)
        }
        return count
    }

    // MARK: Inbox and Voice Memos

    /// Audio files waiting in the inbox folder.
    public func inboxFiles() -> [String] {
        let folder = settings.inboxFolder.trimmed
        guard !folder.isEmpty else { return [] }
        return ((try? vault.list(folder)) ?? []).filter { !$0.isFolder && Self.isAudio($0.path) }.map(\.path)
    }

    /// Processes every audio file of the inbox, one after the other, as `auto` recordings.
    public func processInbox() async {
        for path in inboxFiles() where !busy.get().contains(path) {
            busy.update { _ = $0.insert(path) }
            _ = try? await importAudio(path, options: ImportOptions(kind: .auto), background: true)
            busy.update { _ = $0.remove(path) }
        }
    }

    public static func isAudio(_ path: String) -> Bool {
        MeetingWriter.audioExtensions.contains((path as NSString).pathExtension.lowercased())
    }

    /// New Voice Memos (synced from the iPhone) become meetings or journal entries. Throws `VoiceMemos.NoAccess`
    /// without Full Disk Access.
    public func checkVoiceMemos() async throws {
        let s = settings
        guard s.voiceMemos, memoCheck.update({ running in
            if running { return false }
            running = true
            return true
        }) else { return }
        defer { memoCheck.set(false) }
        let ledger = VoiceMemos.Ledger(vault: vault)
        var seen = ledger.load()
        if seen.since == nil {
            // Turning it on counts today's memos: you often record first, then switch this on.
            seen.since = Calendar.current.startOfDay(for: now())
            ledger.save(seen)
        }
        let memos = try VoiceMemos.newMemos(in: s.voiceMemosFolder, since: seen.since ?? now(), seen: Set(seen.names), now: now())
        for memo in memos where settings.voiceMemos {
            // Marked first: a memo that fails stays in its folder for a retry, never imported again in a loop.
            seen.names.append(memo.name)
            ledger.save(seen)
            let kind: MeetingKind = memo.looksLikeMeeting ? .meeting : .auto
            _ = try? await importAudio(memo.path, options: ImportOptions(
                kind: kind, title: kind == .meeting ? memo.title : "", startedAt: memo.recordedAt, origin: .voiceMemos
            ), background: true)
        }
    }

    // MARK: Templates and folders

    /// The template names: the notes of the templates folder, written there from the built-in ones the first time.
    public func templateNames() -> [String] {
        let s = settings
        let folder = s.templatesFolder.trimmed
        if !folder.isEmpty, !vault.exists(folder) {
            for template in s.prompts.defaultTemplates {
                try? vault.write("\(folder)/\(template.name).md", template.body + "\n")
            }
        }
        let names = ((try? vault.list(folder)) ?? []).filter { !$0.isFolder && $0.path.hasSuffix(".md") }
            .map { (($0.path as NSString).lastPathComponent as NSString).deletingPathExtension }
        return names.isEmpty ? s.prompts.defaultTemplates.map(\.name) : names
    }

    /// `name` when the folder has it, else the general template of the summary's language, else the first one.
    func resolvedTemplate(_ name: String) -> String {
        let names = templateNames()
        if names.contains(name) { return name }
        let general = settings.prompts.defaultTemplates[0].name
        return names.contains(general) ? general : names.first ?? name
    }

    /// `<root>/YYYY-MM-DD HHmm Title`, made free with a suffix, and created.
    private func newFolder(title: String, date: Date, kind: MeetingKind) throws -> String {
        let s = settings
        let root = kind == .voice || kind == .auto ? s.voiceFolder : s.meetingsFolder
        let folder = MeetingWriter.freePath(vault, "\(root)/\(Self.folderStamp(date)) \(MeetingWriter.safeName(title))")
        try vault.createFolder(folder)
        return folder
    }

    static func folderStamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HHmm"
        return formatter.string(from: date)
    }
}
