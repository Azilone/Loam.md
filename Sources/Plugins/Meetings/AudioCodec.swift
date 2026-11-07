import Foundation
#if canImport(AVFoundation)
import AVFoundation
#endif

/// Turning samples into files and files into samples. On a Mac, AVFoundation does it all; ffmpeg, when installed, makes
/// the chunks sent for transcription MP3s (the smallest upload, as Muesli sent). Elsewhere ffmpeg is needed to read
/// audio files and to make anything smaller than WAV.
public struct AudioCodec: Sendable {
    /// Path to ffmpeg, empty when it is not installed.
    public var ffmpeg: String

    public init(ffmpeg: String = "") {
        self.ffmpeg = ffmpeg
    }

    var hasFFmpeg: Bool { !ffmpeg.isEmpty && FileManager.default.isExecutableFile(atPath: ffmpeg) }

    /// A chunk ready to upload: MP3 with ffmpeg, else FLAC on a Mac, else WAV.
    func encodeChunk(_ samples: [Int16]) async throws -> (data: Data, format: String) {
        let wav = Self.wav(samples)
        if hasFFmpeg {
            let temp = FileManager.default.temporaryDirectory.appendingPathComponent("loam-chunk-\(UUID().uuidString)")
            let input = temp.appendingPathExtension("wav"), output = temp.appendingPathExtension("mp3")
            defer {
                try? FileManager.default.removeItem(at: input)
                try? FileManager.default.removeItem(at: output)
            }
            try wav.write(to: input)
            if (try? await Self.run(ffmpeg, ["-v", "error", "-y", "-i", input.path, "-ac", "1", "-b:a", "48k", output.path])) != nil,
               let data = try? Data(contentsOf: output), !data.isEmpty {
                return (data, "mp3")
            }
        }
        #if canImport(AVFoundation)
        if let flac = try? Self.encodeWithAVFoundation(samples, format: kAudioFormatFLAC, fileType: "flac") {
            return (flac, "flac")
        }
        #endif
        return (wav, "wav")
    }

    /// The archive of a recording, from its raw samples file: `audio.m4a` on a Mac (AAC), `audio.mp3` with ffmpeg,
    /// else `audio.wav`. Returns the file's extension.
    func archive(rawSamples: URL, to folder: URL) async throws -> String {
        #if canImport(AVFoundation)
        let m4a = folder.appendingPathComponent("audio.m4a")
        if (try? Self.writeAAC(from: rawSamples, to: m4a)) != nil { return "m4a" }
        #endif
        let wav = folder.appendingPathComponent("audio.wav")
        try Self.wav(fromRaw: rawSamples, to: wav)
        if hasFFmpeg {
            let mp3 = folder.appendingPathComponent("audio.mp3")
            if (try? await Self.run(ffmpeg, ["-v", "error", "-y", "-i", wav.path, "-ac", "1", "-b:a", "64k", mp3.path])) != nil {
                try? FileManager.default.removeItem(at: wav)
                return "mp3"
            }
        }
        return "wav"
    }

    /// Reads any audio file as 16 kHz mono samples, in pieces, with the share read so far (0 to 1).
    func decode(_ file: URL, onSamples: ([Int16]) throws -> Void, progress: (Double) -> Void) async throws {
        #if canImport(AVFoundation)
        do {
            try Self.decodeWithAVFoundation(file, onSamples: onSamples, progress: progress)
            return
        } catch let error as DecodeStarted {
            throw error.underlying
        } catch where hasFFmpeg {
            // Not readable by AVFoundation and nothing passed on yet: ffmpeg may know the format.
        }
        #endif
        guard hasFFmpeg else {
            throw AIError("Cannot read \(file.lastPathComponent): install ffmpeg to import audio here.", status: 0)
        }
        let data = try await Self.run(ffmpeg, ["-v", "error", "-i", file.path, "-f", "s16le", "-ac", "1", "-ar", "\(meetingSampleRate)", "-"])
        let samples = data.withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
        let step = meetingSampleRate * 30
        for start in stride(from: 0, to: samples.count, by: step) {
            try onSamples(Array(samples[start..<min(samples.count, start + step)]))
            progress(Double(min(samples.count, start + step)) / Double(max(1, samples.count)))
        }
    }

    // MARK: WAV

    static func wav(_ samples: [Int16]) -> Data {
        var data = wavHeader(sampleBytes: samples.count * 2)
        samples.withUnsafeBytes { data.append(contentsOf: $0) }
        return data
    }

    static func wavHeader(sampleBytes: Int) -> Data {
        var data = Data()
        func put<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        data.append(contentsOf: Array("RIFF".utf8)); put(UInt32(36 + sampleBytes))
        data.append(contentsOf: Array("WAVEfmt ".utf8)); put(UInt32(16)); put(UInt16(1)); put(UInt16(1))
        put(UInt32(meetingSampleRate)); put(UInt32(meetingSampleRate * 2)); put(UInt16(2)); put(UInt16(16))
        data.append(contentsOf: Array("data".utf8)); put(UInt32(sampleBytes))
        return data
    }

    static func wav(fromRaw raw: URL, to wav: URL) throws {
        let size = (try FileManager.default.attributesOfItem(atPath: raw.path)[.size] as? NSNumber)?.intValue ?? 0
        FileManager.default.createFile(atPath: wav.path, contents: wavHeader(sampleBytes: size))
        let output = try FileHandle(forWritingTo: wav)
        defer { try? output.close() }
        output.seekToEndOfFile()
        let input = try FileHandle(forReadingFrom: raw)
        defer { try? input.close() }
        while true {
            let block = input.readData(ofLength: 1 << 20)
            if block.isEmpty { break }
            output.write(block)
        }
    }

    // MARK: Tools

    /// Runs `executable` to the end, off the calling thread, and returns its standard output. A tool still running
    /// after `timeout` seconds is stopped, and the call fails.
    static func run(_ executable: String, _ arguments: [String], timeout: TimeInterval = 30 * 60) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = arguments
                let output = Pipe(), errors = Pipe()
                process.standardOutput = output
                process.standardError = errors
                process.standardInput = FileHandle.nullDevice
                do { try process.run() } catch {
                    return continuation.resume(throwing: AIError("Cannot run \(executable).", status: 0))
                }
                let stopped = Locked(false)
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) {
                    guard process.isRunning else { return }
                    stopped.set(true)
                    process.terminate()
                }
                let errorData = Locked(Data())
                let group = DispatchGroup()
                group.enter()
                DispatchQueue.global(qos: .utility).async {
                    errorData.set(errors.fileHandleForReading.readDataToEndOfFile())
                    group.leave()
                }
                let data = output.fileHandleForReading.readDataToEndOfFile()
                group.wait()
                process.waitUntilExit()
                if stopped.get() {
                    continuation.resume(throwing: AIError("\((executable as NSString).lastPathComponent) stopped after \(Int(timeout / 60)) minutes.", status: 0))
                } else if process.terminationStatus == 0 {
                    continuation.resume(returning: data)
                } else {
                    let tail = String(decoding: errorData.get(), as: UTF8.self).split(separator: "\n").suffix(2).joined(separator: " ")
                    continuation.resume(throwing: AIError("\((executable as NSString).lastPathComponent) failed: \(tail)", status: 0))
                }
            }
        }
    }

    #if canImport(AVFoundation)
    /// A failure after samples were passed on: falling back to another decoder would repeat them.
    struct DecodeStarted: Error { let underlying: Error }

    static var pcmFormat: AVAudioFormat {
        AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: Double(meetingSampleRate), channels: 1, interleaved: true)!
    }

    static func buffer(_ samples: UnsafeBufferPointer<Int16>) -> AVAudioPCMBuffer? {
        guard let buffer = AVAudioPCMBuffer(pcmFormat: pcmFormat, frameCapacity: AVAudioFrameCount(max(1, samples.count))) else { return nil }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        if let base = samples.baseAddress { buffer.int16ChannelData![0].update(from: base, count: samples.count) }
        return buffer
    }

    static func encodeWithAVFoundation(_ samples: [Int16], format: AudioFormatID, fileType: String) throws -> Data {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("loam-\(UUID().uuidString).\(fileType)")
        defer { try? FileManager.default.removeItem(at: url) }
        do {
            let file = try AVAudioFile(forWriting: url, settings: [
                AVFormatIDKey: format, AVSampleRateKey: meetingSampleRate, AVNumberOfChannelsKey: 1,
            ], commonFormat: .pcmFormatInt16, interleaved: true)
            try samples.withUnsafeBufferPointer { pointer in
                if let buffer = buffer(pointer) { try file.write(from: buffer) }
            }
        }
        return try Data(contentsOf: url)
    }

    static func writeAAC(from raw: URL, to url: URL) throws {
        try? FileManager.default.removeItem(at: url)
        let file = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: meetingSampleRate, AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 48_000,
        ], commonFormat: .pcmFormatInt16, interleaved: true)
        let input = try FileHandle(forReadingFrom: raw)
        defer { try? input.close() }
        while true {
            let block = input.readData(ofLength: meetingSampleRate * 2 * 10)
            if block.isEmpty { break }
            try block.withUnsafeBytes { bytes in
                if let pointer = bytes.bindMemory(to: Int16.self).baseAddress, let buffer = buffer(UnsafeBufferPointer(start: pointer, count: block.count / 2)) {
                    try file.write(from: buffer)
                }
            }
        }
    }

    static func decodeWithAVFoundation(_ url: URL, onSamples: ([Int16]) throws -> Void, progress: (Double) -> Void) throws {
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: url)
        } catch {
            // QuickTime containers (Voice Memos `.qta`, `.mov`) are not audio files for AVAudioFile.
            return try decodeAsset(url, onSamples: onSamples, progress: progress)
        }
        guard let converter = AVAudioConverter(from: file.processingFormat, to: pcmFormat) else {
            throw AIError("Unsupported audio format.", status: 0)
        }
        converter.downmix = true
        let total = file.length
        let capacity: AVAudioFrameCount = 65_536
        guard let input = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: capacity) else { return }
        let outputCapacity = AVAudioFrameCount(Double(capacity) * Double(meetingSampleRate) / file.processingFormat.sampleRate) + 4096
        var finished = false
        var readError: Error?
        var passed = false
        while true {
            guard let output = AVAudioPCMBuffer(pcmFormat: pcmFormat, frameCapacity: outputCapacity) else { return }
            var error: NSError?
            let status = converter.convert(to: output, error: &error) { _, outStatus in
                // Never ask past the last frame: recent macOS throws instead of returning short.
                let remaining = total - file.framePosition
                if finished || remaining <= 0 {
                    finished = true
                    outStatus.pointee = .endOfStream
                    return nil
                }
                do {
                    input.frameLength = 0
                    try file.read(into: input, frameCount: AVAudioFrameCount(min(Int64(capacity), remaining)))
                } catch {
                    if (error as NSError).code != -39 { readError = error }
                    finished = true
                }
                if input.frameLength == 0 {
                    finished = true
                    outStatus.pointee = .endOfStream
                    return nil
                }
                outStatus.pointee = .haveData
                return input
            }
            if let readError { throw passed ? DecodeStarted(underlying: readError) : readError }
            if status == .error {
                let failure = error ?? NSError(domain: "Meetings", code: 1)
                throw passed ? DecodeStarted(underlying: failure) : failure
            }
            if output.frameLength > 0, let data = output.int16ChannelData {
                passed = true
                do {
                    try onSamples(Array(UnsafeBufferPointer(start: data[0], count: Int(output.frameLength))))
                } catch {
                    throw DecodeStarted(underlying: error)
                }
            }
            progress(total > 0 ? min(1, Double(file.framePosition) / Double(total)) : 1)
            if status == .endOfStream { break }
        }
    }

    /// For containers AVAudioFile cannot open: AVAssetReader mixes every audio track to 16 kHz mono.
    static func decodeAsset(_ url: URL, onSamples: ([Int16]) throws -> Void, progress: (Double) -> Void) throws {
        let asset = AVURLAsset(url: url)
        let loaded = Locked<([AVAssetTrack], Double)>(([], 0))
        let semaphore = DispatchSemaphore(value: 0)
        Task.detached {
            let tracks = (try? await asset.loadTracks(withMediaType: .audio)) ?? []
            let duration = (try? await asset.load(.duration).seconds) ?? 0
            loaded.set((tracks, duration))
            semaphore.signal()
        }
        semaphore.wait()
        let (tracks, duration) = loaded.get()
        guard !tracks.isEmpty else { throw AIError("No audio in \(url.lastPathComponent).", status: 0) }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: meetingSampleRate, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ])
        guard reader.canAdd(output) else { throw AIError("Unsupported audio format.", status: 0) }
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? AIError("Cannot read \(url.lastPathComponent).", status: 0) }
        var read = 0.0
        var passed = false
        while let sample = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }
            let length = CMBlockBufferGetDataLength(block)
            var samples = [Int16](repeating: 0, count: length / 2)
            samples.withUnsafeMutableBytes { _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: $0.baseAddress!) }
            passed = true
            do { try onSamples(samples) } catch { throw DecodeStarted(underlying: error) }
            read += Double(samples.count) / Double(meetingSampleRate)
            if duration > 0 { progress(min(1, read / duration)) }
        }
        if reader.status == .failed {
            let error = reader.error ?? AIError("Cannot read \(url.lastPathComponent).", status: 0)
            throw passed ? DecodeStarted(underlying: error) : error
        }
        progress(1)
    }
    #endif
}

/// A value shared across threads behind a lock.
final class Locked<Value>: @unchecked Sendable {
    private var value: Value
    private let lock = NSLock()

    init(_ value: Value) { self.value = value }

    func get() -> Value {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func set(_ newValue: Value) {
        lock.lock()
        value = newValue
        lock.unlock()
    }

    func update<T>(_ change: (inout Value) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return change(&value)
    }
}
