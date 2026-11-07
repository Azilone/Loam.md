import Foundation

/// Every piece of audio in the plugin: 16 kHz, mono, signed 16-bit samples.
public let meetingSampleRate = 16_000

public enum TrackID: String, Codable, Sendable, CaseIterable {
    /// The microphone.
    case mic
    /// What the Mac plays: the other people in a call.
    case system
}

public struct TimeMapEntry: Codable, Sendable, Equatable {
    /// Sample offset inside the compacted chunk.
    public var out: Int
    /// Sample offset on the meeting clock.
    public var src: Int
}

/// A finished chunk: the samples to send and where they were on the meeting clock.
public struct Chunk: Sendable {
    public var track: TrackID
    public var index: Int
    public var samples: [Int16]
    public var speech: Double
    public var map: [TimeMapEntry]
    public var duration: Double { Double(samples.count) / Double(meetingSampleRate) }
}

/// Maps a time (seconds) in a compacted chunk back to the meeting clock.
public func remapTime(_ map: [TimeMapEntry], _ time: Double) -> Double {
    let sample = Int((time * Double(meetingSampleRate)).rounded())
    guard var entry = map.first else { return time }
    for item in map {
        if item.out <= sample { entry = item } else { break }
    }
    return Double(entry.src + (sample - entry.out)) / Double(meetingSampleRate)
}

/// One audio source cut into transcription chunks.
///
/// Silence is removed before anything is sent (transcription is billed by the second): an energy detector keeps
/// speech with a short pad before and after, and drops longer silences. Chunks are cut inside a silence, so no word
/// is split, and carry a time map so timestamps in the compacted audio point back to the real meeting clock.
public final class Track {
    public struct Options: Sendable {
        /// Target seconds of compacted audio per chunk; cut at the next silence after this.
        public var chunkSeconds = 8.0 * 60
        /// Cut here even without a silence (diarization breaks above ~15 min).
        public var maxChunkSeconds = 10.0 * 60
        /// Lowest threshold in dBFS; raised above the noise floor as it is learnt.
        public var thresholdDb = -50.0
        public var preRollMs = 300
        public var hangMs = 500
        /// Chunks with less speech than this are dropped.
        public var minSpeechSeconds = 1.0

        public init(chunkMinutes: Double = 8) {
            chunkSeconds = chunkMinutes * 60
            maxChunkSeconds = chunkMinutes * 60 + 120
        }
    }

    static let frameLength = 320 // 20 ms
    static let attackFrames = 4 // 80 ms

    public let id: TrackID
    public let options: Options
    /// Level of the last frame in dBFS, for meters.
    public private(set) var level = -120.0
    /// Meeting-clock time (seconds) of the last frame heard as speech; -1 before any.
    public private(set) var lastSpeechAt = -1.0
    /// Seconds of compacted audio handed over so far (sent or about to be).
    public private(set) var sentSeconds = 0.0

    private let onChunk: (Chunk) -> Void
    private var pending: [Int16] = []
    private var position = 0 // meeting-clock sample of the next frame
    private var noiseFloor = -70.0
    private var hang = 0
    private var loudRun = 0
    private var ring: [(frame: ArraySlice<Int16>, at: Int)] = []

    private var index: Int
    private var isOpen = false
    private var samples: [Int16] = []
    private var speechFrames = 0
    private var map: [TimeMapEntry] = []
    private var lastEmittedEnd = -1

    public init(_ id: TrackID, options: Options = Options(), startIndex: Int = 0, onChunk: @escaping (Chunk) -> Void) {
        self.id = id
        self.options = options
        self.index = startIndex
        self.onChunk = onChunk
    }

    /// Seconds of meeting clock consumed so far.
    public var seconds: Double { Double(position + pending.count) / Double(meetingSampleRate) }

    public func push(_ pcm: [Int16]) {
        pending.append(contentsOf: pcm)
        var start = 0
        while pending.count - start >= Self.frameLength {
            frame(pending[start..<start + Self.frameLength])
            start += Self.frameLength
        }
        if start > 0 { pending.removeFirst(start) }
    }

    /// Moves the clock on without audio (a source that started late, or was suspended).
    public func skip(_ samples: Int) {
        position += samples
    }

    /// Closes the current chunk; the track can go on receiving audio.
    public func flush() {
        if !pending.isEmpty {
            frame(pending[...])
            pending = []
        }
        closeChunk()
    }

    private func frame(_ frame: ArraySlice<Int16>) {
        let at = position
        position += frame.count
        let db = Self.decibels(frame)
        level = db
        // The noise floor follows quiet frames quickly and loud frames slowly.
        noiseFloor += (db < noiseFloor ? 0.2 : 0.002) * (db - noiseFloor)
        let loud = db > max(options.thresholdDb, noiseFloor + 12)
        // Speech needs a few loud frames in a row: an isolated click (typing) is not speech.
        loudRun = loud ? loudRun + 1 : 0
        let speech = loud && (hang > 0 || loudRun >= Self.attackFrames)

        if speech {
            lastSpeechAt = Double(at) / Double(meetingSampleRate)
            hang = options.hangMs / 20
            for item in ring { emit(item.frame, at: item.at, speech: false) }
            ring = []
            emit(frame, at: at, speech: true)
        } else if hang > 0 {
            hang -= 1
            emit(frame, at: at, speech: false)
        } else {
            ring.append((frame, at))
            if ring.count > options.preRollMs / 20 { ring.removeFirst() }
            if Double(samples.count) >= options.chunkSeconds * Double(meetingSampleRate) { closeChunk() }
        }
        if Double(samples.count) >= options.maxChunkSeconds * Double(meetingSampleRate) { closeChunk() }
    }

    private func emit(_ frame: ArraySlice<Int16>, at: Int, speech: Bool) {
        if !isOpen {
            isOpen = true
            samples = []
            speechFrames = 0
            map = []
            lastEmittedEnd = -1
        }
        if at != lastEmittedEnd { map.append(TimeMapEntry(out: samples.count, src: at)) }
        lastEmittedEnd = at + frame.count
        samples.append(contentsOf: frame)
        sentSeconds += Double(frame.count) / Double(meetingSampleRate)
        if speech { speechFrames += 1 }
    }

    private func closeChunk() {
        guard isOpen else { return }
        isOpen = false
        let speech = Double(speechFrames * Self.frameLength) / Double(meetingSampleRate)
        let chunk = Chunk(track: id, index: index, samples: samples, speech: speech, map: map)
        samples = []
        if speech >= options.minSpeechSeconds {
            index += 1
            onChunk(chunk)
        } else {
            sentSeconds -= chunk.duration
        }
    }

    static func decibels(_ frame: ArraySlice<Int16>) -> Double {
        var sum = 0.0
        for sample in frame { sum += Double(sample) * Double(sample) }
        let rms = (sum / Double(max(1, frame.count))).squareRoot() / 32768
        return rms > 0 ? 20 * log10(rms) : -120
    }
}
