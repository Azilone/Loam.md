import Foundation
import PluginKit

/// A recording's state shared by the session, the transcription queue and the pipeline: every change is saved to
/// `.raw/meeting.json` at once.
public final class StateBox: @unchecked Sendable {
    private let lock = NSLock()
    private var state: MeetingState
    private var cancelled = false
    let vault: VaultAccess

    init(_ state: MeetingState, vault: VaultAccess) {
        self.state = state
        self.vault = vault
    }

    public var value: MeetingState {
        lock.lock()
        defer { lock.unlock() }
        return state
    }

    /// True once the recording was thrown away: nothing is written to its folder any more.
    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    @discardableResult
    func update<T>(_ change: (inout MeetingState) -> T) -> T {
        lock.lock()
        let result = change(&state)
        let copy = state
        let skip = cancelled
        lock.unlock()
        if !skip { try? RawFolder.save(vault, copy) }
        return result
    }
}

/// Sends a recording's pending chunks for transcription, one at a time, while it goes on and after; safe to call
/// again at any time.
final class TranscriptionQueue: @unchecked Sendable {
    private let box: StateBox
    private let ai: MeetingAI
    private let settings: MeetingsSettings
    private let running = Locked<Task<Void, Never>?>(nil)
    var onProgress: (@Sendable () -> Void)?

    init(box: StateBox, ai: MeetingAI, settings: MeetingsSettings) {
        self.box = box
        self.ai = ai
        self.settings = settings
    }

    /// Starts the loop if it is not running; `retryErrors` puts failed chunks back in line first.
    @discardableResult
    func kick(retryErrors: Bool = false) -> Task<Void, Never> {
        if retryErrors {
            box.update { state in
                for i in state.chunks.indices where state.chunks[i].status == .error { state.chunks[i].status = .pending }
            }
        }
        return running.update { task in
            if let task { return task }
            let new = Task { [self] in
                await loop()
                running.set(nil)
            }
            task = new
            return new
        }
    }

    /// Waits until nothing is pending, starting the loop again if a chunk arrived as it ended.
    func drain(retryErrors: Bool) async {
        await kick(retryErrors: retryErrors).value
        while !box.isCancelled, box.value.chunks.contains(where: { $0.status == .pending }) {
            await kick().value
        }
    }

    private func loop() async {
        while !box.isCancelled, let chunk = box.value.chunks.first(where: { $0.status == .pending }) {
            let state = box.value
            do {
                let audio = try RawFolder.readData(box.vault, state.folder, "\(chunk.name).\(chunk.format)")
                let result = try await ai.transcribe(
                    audio, format: chunk.format, model: settings.sttModel, language: state.language,
                    // In a call or a voice note the microphone is only the user: diarizing would split their voice.
                    diarize: !(chunk.track == .mic && state.micIsMe)
                )
                guard !box.isCancelled else { return }
                try RawFolder.writeData(box.vault, state.folder, "\(chunk.name).json", JSONEncoder().encode(result))
                box.update { state in
                    guard let i = state.chunks.firstIndex(where: { $0.name == chunk.name }) else { return }
                    state.chunks[i].status = .done
                    state.chunks[i].cost = result.usage?.cost
                    state.chunks[i].error = nil
                }
            } catch {
                box.update { state in
                    guard let i = state.chunks.firstIndex(where: { $0.name == chunk.name }) else { return }
                    state.chunks[i].status = .error
                    state.chunks[i].error = error.localizedDescription
                }
            }
            onProgress?()
        }
    }
}

/// Writes finished chunks to `.raw/` and puts them in the transcription queue; shared by live recordings and imports.
final class ChunkWriter: @unchecked Sendable {
    private let box: StateBox
    private let queue: TranscriptionQueue
    private let codec: AudioCodec
    private let writes = Locked<[Task<Void, Never>]>([])

    init(box: StateBox, queue: TranscriptionQueue, codec: AudioCodec) {
        self.box = box
        self.queue = queue
        self.codec = codec
    }

    func add(_ chunk: Chunk) {
        let task = Task { [box, queue, codec] in
            guard let (data, format) = try? await codec.encodeChunk(chunk.samples) else { return }
            let folder = box.value.folder
            guard !box.isCancelled else { return }
            guard (try? RawFolder.writeData(box.vault, folder, "\(chunk.track.rawValue)-\(chunk.index).\(format)", data)) != nil else { return }
            box.update { state in
                state.chunks.append(ChunkState(track: chunk.track, index: chunk.index, duration: chunk.duration,
                                               speech: chunk.speech, map: chunk.map, format: format))
            }
            queue.kick()
        }
        writes.update { $0.append(task) }
    }

    /// Returns once every chunk handed over so far is on disk (not yet transcribed).
    func flush() async {
        for task in writes.get() { await task.value }
    }
}

/// The sound of a recording as one mono stream: both tracks mixed into `.raw/audio.pcm`, turned into the kept audio
/// file when the recording stops.
final class AudioArchive {
    private let handle: FileHandle
    private let tracks: [TrackID]
    private var queues: [TrackID: [Int16]] = [:]

    init(url: URL, tracks: [TrackID]) throws {
        if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
        handle = try FileHandle(forWritingTo: url)
        handle.seekToEndOfFile()
        self.tracks = tracks
        for track in tracks { queues[track] = [] }
    }

    func push(_ track: TrackID, _ samples: [Int16]) {
        queues[track, default: []].append(contentsOf: samples)
    }

    /// Mixes what every track has in common; a track lagging more than 3 s is padded with silence.
    func pump(final: Bool = false) {
        let lengths = tracks.map { queues[$0]?.count ?? 0 }
        guard let longest = lengths.max(), var n = lengths.min() else { return }
        if final || longest - n > 3 * meetingSampleRate { n = longest }
        guard n > 0 else { return }
        var mix = [Int32](repeating: 0, count: n)
        for track in tracks {
            let queue = queues[track] ?? []
            let take = min(n, queue.count)
            for i in 0..<take { mix[i] += Int32(queue[i]) }
            queues[track] = Array(queue.dropFirst(take))
        }
        let out = mix.map { Int16(clamping: $0) }
        out.withUnsafeBytes { handle.write(Data($0)) }
    }

    func close() {
        pump(final: true)
        try? handle.close()
    }
}

/// A recording in progress. The app's audio capture pushes samples into it from any thread; it cuts them into chunks
/// (sent for transcription as it goes), keeps the mixed audio, and knows the time, the levels and the silence.
public final class RecordingSession: @unchecked Sendable {
    public let box: StateBox
    let queue: TranscriptionQueue
    let writer: ChunkWriter
    private let settings: MeetingsSettings
    private let work = DispatchQueue(label: "loam.meetings.recording")
    private var tracks: [TrackID: Track] = [:]
    private var archive: AudioArchive?
    private var startedTracks: Set<TrackID> = []
    private let clock: () -> TimeInterval
    private var started: TimeInterval
    private var pausedAt: TimeInterval?
    private var pausedTotal: TimeInterval = 0
    private var stopped = false
    /// Why the system audio could not be recorded, when it could not.
    public var systemAudioProblem: String?

    init(box: StateBox, ai: MeetingAI, settings: MeetingsSettings, tracks ids: [TrackID],
         clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) throws {
        self.box = box
        self.settings = settings
        self.clock = clock
        started = clock()
        queue = TranscriptionQueue(box: box, ai: ai, settings: settings)
        writer = ChunkWriter(box: box, queue: queue, codec: settings.codec)
        try FileManager.default.createDirectory(at: RawFolder.url(box.vault, box.value.folder), withIntermediateDirectories: true)
        if settings.keepAudio {
            archive = try AudioArchive(url: RawFolder.url(box.vault, box.value.folder, "audio.pcm"), tracks: ids)
        }
        for id in ids {
            tracks[id] = Track(id, options: Track.Options(chunkMinutes: max(1, settings.chunkMinutes))) { [writer] in writer.add($0) }
        }
    }

    public var state: MeetingState { box.value }
    public var trackIDs: [TrackID] { work.sync { TrackID.allCases.filter { tracks[$0] != nil } } }

    /// Seconds of recorded time, pauses left out.
    public var elapsed: Double {
        work.sync { elapsedLocked }
    }

    private var elapsedLocked: Double {
        (pausedAt ?? clock()) - started - pausedTotal
    }

    public var isPaused: Bool { work.sync { pausedAt != nil } }

    public func setPaused(_ paused: Bool) {
        work.sync {
            guard !stopped, paused != (pausedAt != nil) else { return }
            if paused {
                pausedAt = clock()
            } else if let at = pausedAt {
                pausedTotal += clock() - at
                pausedAt = nil
            }
        }
    }

    /// Level of a track's last sound in dBFS, nil when the track is not recorded.
    public func level(_ id: TrackID) -> Double? { work.sync { tracks[id]?.level } }

    /// Seconds since anyone last spoke.
    public var idleSeconds: Double {
        work.sync { max(0, elapsedLocked - (tracks.values.map(\.lastSpeechAt).max() ?? 0)) }
    }

    /// Seconds of speech sent (or about to be) for transcription.
    public var sentSeconds: Double { work.sync { tracks.values.reduce(0) { $0 + $1.sentSeconds } } }
    public var estimatedCost: Double { sentSeconds / 60 * settings.sttPricePerMinute }
    /// Chunks transcribed and chunks made so far.
    public var progress: (done: Int, total: Int) {
        let chunks = box.value.chunks
        return (chunks.filter { $0.status == .done }.count, chunks.count)
    }

    /// The system audio failed: the recording goes on with the microphone only.
    public func dropTrack(_ id: TrackID, reason: String) {
        work.sync {
            tracks[id] = nil
            if id == .system { systemAudioProblem = reason }
        }
    }

    /// New samples from a track, 16 kHz mono. Ignored while paused.
    public func push(_ id: TrackID, _ samples: [Int16]) {
        work.async { [self] in
            guard !stopped, pausedAt == nil, let track = tracks[id] else { return }
            // A source that starts late, or was suspended, is aligned on the meeting clock with silence.
            let late = Int(elapsedLocked * Double(meetingSampleRate)) - Int(track.seconds * Double(meetingSampleRate))
            let first = !startedTracks.contains(id)
            if late > (first ? meetingSampleRate / 4 : 2 * meetingSampleRate) {
                track.skip(late)
                archive?.push(id, [Int16](repeating: 0, count: late))
            }
            startedTracks.insert(id)
            track.push(samples)
            archive?.push(id, samples)
            archive?.pump()
        }
    }

    /// Remembers when a line of the notes was first typed, for the summary to line notes and talk up.
    public func noteTyped(_ text: String, at seconds: Double) {
        let line = text.trimmed
        guard !line.isEmpty else { return }
        box.update { state in
            if state.noteTimes[line] == nil { state.noteTimes[line] = seconds }
        }
    }

    /// When each line of the notes was started, keyed by its current text (replaces what was known).
    public func setNoteTimes(_ times: [String: Double]) {
        box.update { $0.noteTimes = times }
    }

    /// Stops listening and throws the recording away: nothing more is written to its folder.
    func discard() async {
        box.cancel()
        work.sync {
            stopped = true
            for track in tracks.values { track.flush() }
            archive?.close()
        }
        await writer.flush()
    }

    /// Stops listening and writes everything out: every chunk on disk (not yet transcribed) and the kept audio.
    func stop() async {
        let duration: Double = work.sync {
            stopped = true
            for track in tracks.values { track.flush() }
            archive?.close()
            return elapsedLocked
        }
        await writer.flush()
        let folder = box.value.folder
        let raw = RawFolder.url(box.vault, folder, "audio.pcm")
        if archive != nil, FileManager.default.fileExists(atPath: raw.path) {
            _ = try? await settings.codec.archive(rawSamples: raw, to: box.vault.rootURL.appendingPathComponent(folder))
            try? FileManager.default.removeItem(at: raw)
        }
        box.update { state in
            state.duration = duration
            state.status = .processing
        }
    }
}
