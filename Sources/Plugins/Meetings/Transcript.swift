import Foundation

/// What the transcription model returns for one chunk (`verbose_json`).
public struct SttResult: Codable, Sendable, Equatable {
    public struct Segment: Codable, Sendable, Equatable {
        public var start: Double
        public var end: Double
        public var text: String
        public var speaker: Int?

        public init(start: Double, end: Double, text: String, speaker: Int? = nil) {
            self.start = start
            self.end = end
            self.text = text
            self.speaker = speaker
        }

        enum CodingKeys: String, CodingKey { case start, end, text, speaker }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            start = try c.decodeIfPresent(Double.self, forKey: .start) ?? 0
            end = try c.decodeIfPresent(Double.self, forKey: .end) ?? start
            text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
            // Some providers send the speaker as a number, others as "1" or "Speaker 1".
            if let number = try? c.decodeIfPresent(Int.self, forKey: .speaker) {
                speaker = number
            } else if let label = try? c.decodeIfPresent(String.self, forKey: .speaker) {
                speaker = Int(label.filter(\.isNumber))
            }
        }
    }

    public struct Usage: Codable, Sendable, Equatable {
        public var seconds: Double?
        public var cost: Double?
    }

    public var text: String
    public var language: String?
    public var segments: [Segment]?
    public var usage: Usage?

    public init(text: String, segments: [Segment]? = nil) {
        self.text = text
        self.segments = segments
    }

    enum CodingKeys: String, CodingKey { case text, language, segments, usage }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
        language = try? c.decodeIfPresent(String.self, forKey: .language)
        segments = try? c.decodeIfPresent([Segment].self, forKey: .segments)
        usage = try? c.decodeIfPresent(Usage.self, forKey: .usage)
    }
}

/// One stretch of speech on the meeting clock.
public struct Utterance: Sendable, Equatable {
    public var start: Double
    public var end: Double
    /// `me`, or `<track><chunk>:<speaker>` (`system2:1`): a speaker number is only valid inside its chunk.
    public var label: String
    public var text: String
}

enum Transcript {
    /// Every chunk's segments on one timeline, in order. With `micIsMe`, the microphone is the user and the echoes of
    /// the others it picked up (no headphones) are dropped.
    static func merge(_ chunks: [(ChunkState, SttResult)], micIsMe: Bool) -> [Utterance] {
        var out: [Utterance] = []
        for (meta, result) in chunks {
            var segments = result.segments ?? []
            if segments.isEmpty, !result.text.trimmed.isEmpty {
                segments = [.init(start: 0, end: meta.duration, text: result.text)]
            }
            for segment in segments {
                let text = segment.text.trimmed
                guard !text.isEmpty else { continue }
                out.append(Utterance(
                    start: remapTime(meta.map, segment.start),
                    end: remapTime(meta.map, segment.end),
                    label: meta.track == .mic && micIsMe ? "me" : "\(meta.track.rawValue)\(meta.index):\(segment.speaker ?? 0)",
                    text: text
                ))
            }
        }
        out.sort { $0.start < $1.start }
        return micIsMe ? dropEchoes(out) : out
    }

    /// Without headphones the microphone also hears the others. A microphone line that overlaps a system line and
    /// mostly repeats its words is an echo, not the user speaking.
    static func dropEchoes(_ utterances: [Utterance]) -> [Utterance] {
        let system = utterances.filter { $0.label != "me" }
        return utterances.filter { utterance in
            guard utterance.label == "me" else { return true }
            let mine = words(utterance.text)
            guard !mine.isEmpty else { return true }
            let theirs = Set(system.filter { $0.start < utterance.end + 1.5 && $0.end > utterance.start - 1.5 }
                .flatMap { words($0.text) })
            guard !theirs.isEmpty else { return true }
            let shared = mine.filter { theirs.contains($0) }.count
            return Double(shared) / Double(mine.count) < 0.6
        }
    }

    static func words(_ text: String) -> [String] {
        text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
            .split { !($0.isLetter || $0.isNumber) }
            .map(String.init)
            .filter { $0.count > 2 }
    }

    /// The compact form given to the language model, `[mm:ss] label: text`, with a speaker's consecutive lines merged.
    static func rawLines(_ utterances: [Utterance], names: [String: String] = [:]) -> [String] {
        var lines: [String] = []
        var last: String?
        for utterance in utterances {
            let who = names[utterance.label] ?? utterance.label
            if who == last, let tail = lines.last, tail.count < 1200 {
                lines[lines.count - 1] = tail + " " + utterance.text
            } else {
                lines.append("[\(clock(utterance.start))] \(who): \(utterance.text)")
                last = who
            }
        }
        return lines
    }
}

/// `mm:ss`, or `h:mm:ss` past an hour.
public func clock(_ seconds: Double) -> String {
    let total = max(0, Int(seconds.rounded()))
    let h = total / 3600, m = total % 3600 / 60, s = total % 60
    return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", m, s)
}

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
