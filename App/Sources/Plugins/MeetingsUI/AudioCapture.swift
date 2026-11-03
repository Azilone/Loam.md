import AVFoundation
import CoreAudio
import Foundation
import MeetingsPlugin

/// A source of 16 kHz mono samples for a recording.
protocol AudioSource: AnyObject, Sendable {
    func start() throws
    func stop()
}

struct CaptureError: Error, LocalizedError {
    let message: String
    /// The permission macOS refused, when that is why.
    var permission: PrivacyPane?
    var errorDescription: String? { message }
}

/// Converts whatever a device gives into 16 kHz mono signed 16-bit samples.
final class SampleConverter: @unchecked Sendable {
    private let converter: AVAudioConverter
    private let output: AVAudioFormat

    init?(from input: AVAudioFormat) {
        guard let output = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: Double(meetingSampleRate), channels: 1, interleaved: true),
              let converter = AVAudioConverter(from: input, to: output) else { return nil }
        converter.downmix = true
        self.converter = converter
        self.output = output
    }

    func convert(_ buffer: AVAudioPCMBuffer) -> [Int16] {
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * output.sampleRate / buffer.format.sampleRate) + 32
        guard let out = AVAudioPCMBuffer(pcmFormat: output, frameCapacity: capacity) else { return [] }
        var given = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if given {
                status.pointee = .noDataNow
                return nil
            }
            given = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, let data = out.int16ChannelData else { return [] }
        return Array(UnsafeBufferPointer(start: data[0], count: Int(out.frameLength)))
    }
}

/// The microphone, through AVAudioEngine.
final class MicrophoneSource: AudioSource, @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let onSamples: @Sendable ([Int16]) -> Void

    init(onSamples: @escaping @Sendable ([Int16]) -> Void) {
        self.onSamples = onSamples
    }

    /// Asks for the microphone once; false when the user said no.
    static func requestAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }

    func start() throws {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0, let converter = SampleConverter(from: format) else {
            throw CaptureError(message: "No microphone is available.")
        }
        let onSamples = onSamples
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in
            let samples = converter.convert(buffer)
            if !samples.isEmpty { onSamples(samples) }
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw CaptureError(message: "The microphone could not start: \(error.localizedDescription)")
        }
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }
}

/// What the Mac plays (the other people in a call), through a Core Audio process tap on every process and a private
/// aggregate device: no bot, no virtual audio driver. macOS asks once to let Loam record the computer's audio.
final class SystemAudioSource: AudioSource, @unchecked Sendable {
    private let onSamples: @Sendable ([Int16]) -> Void
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private let queue = DispatchQueue(label: "loam.meetings.system-audio", qos: .userInitiated)
    // Downmix and decimation state, kept across callbacks so no sample is lost or doubled.
    private var phase = 0.0
    private var sum: Float = 0
    private var count = 0

    init(onSamples: @escaping @Sendable ([Int16]) -> Void) {
        self.onSamples = onSamples
    }

    func start() throws {
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        description.uuid = UUID()
        description.name = "Loam meeting recorder"
        description.isPrivate = true
        description.muteBehavior = .unmuted
        var status = AudioHardwareCreateProcessTap(description, &tapID)
        guard status == noErr else {
            throw CaptureError(message: "The Mac's sound cannot be recorded (allow Loam in System Settings › Privacy & Security › Screen & System Audio Recording; error \(status)).", permission: .systemAudio)
        }
        let output = try Self.defaultOutputUID()
        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Loam capture",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: output,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: output]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true, kAudioSubTapUIDKey: description.uuid.uuidString]],
        ]
        status = AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID)
        guard status == noErr else {
            stop()
            throw CaptureError(message: "The Mac's sound cannot be recorded (aggregate device, error \(status)).", permission: .systemAudio)
        }
        var format = AudioStreamBasicDescription()
        guard Self.property(tapID, kAudioTapPropertyFormat, &format) == noErr, format.mFormatID == kAudioFormatLinearPCM,
              format.mFormatFlags & kAudioFormatFlagIsFloat != 0, format.mBitsPerChannel == 32 else {
            stop()
            throw CaptureError(message: "The Mac's sound comes in a format Loam does not read.")
        }
        // The tap's advertised rate can differ from the device's; the aggregate device's nominal rate is the truth.
        var deviceRate = Float64(0)
        let rate = Self.property(aggregateID, kAudioDevicePropertyNominalSampleRate, &deviceRate) == noErr && deviceRate > 0
            ? deviceRate : format.mSampleRate
        let channels = Int(max(1, format.mChannelsPerFrame))
        let planar = format.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0
        let ratio = rate / Double(meetingSampleRate)
        status = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, queue) { [weak self] _, input, _, _, _ in
            self?.receive(input, channels: channels, planar: planar, ratio: ratio)
        }
        guard status == noErr else {
            stop()
            throw CaptureError(message: "The Mac's sound cannot be recorded (error \(status)).", permission: .systemAudio)
        }
        status = AudioDeviceStart(aggregateID, procID)
        guard status == noErr else {
            stop()
            throw CaptureError(message: "The Mac's sound cannot be recorded (start, error \(status)).", permission: .systemAudio)
        }
    }

    private func receive(_ input: UnsafePointer<AudioBufferList>, channels: Int, planar: Bool, ratio: Double) {
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        guard let first = buffers.first, let base = first.mData else { return }
        let frames = planar ? Int(first.mDataByteSize) / 4 : Int(first.mDataByteSize) / (4 * channels)
        guard frames > 0 else { return }
        var planes: [UnsafePointer<Float>] = []
        if planar {
            for buffer in buffers.prefix(channels) {
                if let data = buffer.mData { planes.append(UnsafePointer(data.assumingMemoryBound(to: Float.self))) }
            }
        }
        let interleaved = UnsafePointer(base.assumingMemoryBound(to: Float.self))
        var out: [Int16] = []
        out.reserveCapacity(Int(Double(frames) / ratio) + 2)
        for frame in 0..<frames {
            var value: Float = 0
            if planar {
                for plane in planes { value += plane[frame] }
                value /= Float(max(1, planes.count))
            } else {
                for channel in 0..<channels { value += interleaved[frame * channels + channel] }
                value /= Float(channels)
            }
            sum += value
            count += 1
            phase += 1
            if phase >= ratio {
                phase -= ratio
                let mean = max(-1, min(1, sum / Float(count)))
                out.append(Int16(mean < 0 ? mean * 32768 : mean * 32767))
                sum = 0
                count = 0
            }
        }
        if !out.isEmpty { onSamples(out) }
    }

    func stop() {
        if aggregateID != kAudioObjectUnknown {
            if let procID {
                AudioDeviceStop(aggregateID, procID)
                AudioDeviceDestroyIOProcID(aggregateID, procID)
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        procID = nil
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
    }

    private static func property<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, _ value: inout T) -> OSStatus {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<T>.size)
        return AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value)
    }

    private static func defaultOutputUID() throws -> String {
        var device = AudioObjectID(0)
        guard property(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice, &device) == noErr else {
            throw CaptureError(message: "No sound output device.")
        }
        var uid: Unmanaged<CFString>?
        guard property(device, kAudioDevicePropertyDeviceUID, &uid) == noErr, let uid else {
            throw CaptureError(message: "The sound output device cannot be read.")
        }
        return uid.takeRetainedValue() as String
    }
}
