import AppKit
import AVFoundation
import PluginKitUI
import SwiftUI

/// What a sound file says about itself.
struct AudioMetadata: Sendable {
    var title: String?
    var artist: String?
    var album: String?
    var artwork: Data?

    nonisolated static func load(_ url: URL) async -> AudioMetadata {
        let asset = AVURLAsset(url: url)
        guard let items = try? await asset.load(.commonMetadata) else { return AudioMetadata() }
        func item(_ id: AVMetadataIdentifier) -> AVMetadataItem? {
            AVMetadataItem.metadataItems(from: items, filteredByIdentifier: id).first
        }
        var result = AudioMetadata()
        result.title = try? await item(.commonIdentifierTitle)?.load(.stringValue)
        result.artist = try? await item(.commonIdentifierArtist)?.load(.stringValue)
        result.album = try? await item(.commonIdentifierAlbumName)?.load(.stringValue)
        result.artwork = try? await item(.commonIdentifierArtwork)?.load(.dataValue)
        return result
    }
}

/// The loudness of a sound along its length, as `count` values from 0 to 1, for the waveform under the cover.
enum Waveform {
    nonisolated static func bars(of url: URL, count: Int) async -> [Float] {
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .audio).first,
              let length = try? await asset.load(.duration), length.seconds > 0,
              let reader = try? AVAssetReader(asset: asset) else { return [] }
        let rate = 8000.0
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 16, AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsFloatKey: false, AVLinearPCMIsNonInterleaved: false, AVNumberOfChannelsKey: 1,
            AVSampleRateKey: rate,
        ])
        reader.add(output)
        guard reader.startReading() else { return [] }
        let perBar = max(1, Int(length.seconds * rate) / count)
        var peaks = [Float](repeating: 0, count: count)
        var index = 0
        while let buffer = output.copyNextSampleBuffer(), let block = CMSampleBufferGetDataBuffer(buffer) {
            let bytes = CMBlockBufferGetDataLength(block)
            var samples = [Int16](repeating: 0, count: bytes / 2)
            guard CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: bytes - bytes % 2, destination: &samples) == kCMBlockBufferNoErr
            else { continue }
            for sample in samples {
                let bar = min(count - 1, index / perBar)
                peaks[bar] = max(peaks[bar], Float(abs(Int(sample))) / 32768)
                index += 1
            }
        }
        let loudest = peaks.max() ?? 0
        guard loudest > 0 else { return peaks }
        return peaks.map { ($0 / loudest).squareRoot() }
    }
}

/// A sound as a player screen, like Apple's Music or Podcasts: the cover (the file's artwork, else one drawn from its
/// name), title, artist and album, a waveform to scrub, and the transport: back 15 seconds, play, forward 15, speed.
struct AudioPlayer: View {
    let view: ViewContext
    let file: FileLocation?
    @State private var detail: String?

    var body: some View {
        ViewerFrame(view: view, file: file, detail: detail) { file in
            AudioScreen(file: file, detail: $detail)
        }
    }
}

private struct AudioScreen: View {
    @Environment(\.themeTokens) private var theme
    let file: FileLocation
    @Binding var detail: String?
    @State private var playback: PlaybackModel
    @State private var metadata = AudioMetadata()
    @State private var bars: [Float] = []
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(file: FileLocation, detail: Binding<String?>) {
        self.file = file
        _detail = detail
        _playback = State(initialValue: PlaybackModel(url: file.url))
    }

    private var title: String { metadata.title ?? file.url.deletingPathExtension().lastPathComponent }

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            Cover(artwork: metadata.artwork, title: title)
                .frame(width: 240, height: 240)
                .scaleEffect(playback.isPlaying ? 1 : 0.94)
                .shadow(color: .black.opacity(playback.isPlaying ? 0.28 : 0.14), radius: playback.isPlaying ? 26 : 12, y: 10)
                .animation(reduceMotion ? CollectionMotion.fade : .spring(duration: 0.5, bounce: 0.2), value: playback.isPlaying)
            VStack(spacing: 4) {
                Text(title.uiLocalized).font(.ui(.section)).lineLimit(2)
                if let line = [metadata.artist, metadata.album].compactMap({ $0 }).joined(separator: " — ").nonEmpty {
                    Text(line).font(.ui(.body)).foregroundStyle(theme.secondaryText).lineLimit(1)
                }
            }
            .multilineTextAlignment(.center)
            .padding(.top, 26)
            .padding(.horizontal, 32)
            WaveformScrubber(bars: bars, playback: playback)
                .frame(height: 52)
                .frame(maxWidth: 460)
                .padding(.top, 26)
                .padding(.horizontal, 32)
            HStack {
                Text(PlaybackModel.clock(playback.time))
                Spacer()
                Text("-" + PlaybackModel.clock(playback.remaining))
            }
            .font(.ui(size: 11, weight: .medium).monospacedDigit())
            .foregroundStyle(theme.secondaryText)
            .frame(maxWidth: 460)
            .padding(.top, 4)
            .padding(.horizontal, 32)
            Transport(playback: playback).padding(.top, 14)
            Spacer(minLength: 0)
            Spacer(minLength: 0).frame(height: 56)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: file.url) {
            metadata = await AudioMetadata.load(file.url)
            bars = await Task.detached(priority: .utility) { await Waveform.bars(of: file.url, count: 110) }.value
        }
        .onChange(of: playback.duration) { detail = playback.duration > 0 ? PlaybackModel.clock(playback.duration) : nil }
        .onDisappear { playback.pause() }
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}

/// The file's artwork, or a gradient drawn from its title with a note on it.
private struct Cover: View {
    let artwork: Data?
    let title: String

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Corners.r(22), style: .continuous)
        Group {
            if let artwork, let image = NSImage(data: artwork) {
                Image(nsImage: image).resizable().scaledToFill()
            } else {
                // A stable hue from the title: `hashValue` changes from one launch to the next.
                let seed = title.unicodeScalars.reduce(5381) { ($0 &* 33) &+ Int($1.value) } & 0xFFFF
                let hue = Double(seed % 360) / 360
                ZStack {
                    LinearGradient(
                        colors: [Color(hue: hue, saturation: 0.55, brightness: 0.95), Color(hue: (hue + 0.12).truncatingRemainder(dividingBy: 1), saturation: 0.7, brightness: 0.62)],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    )
                    Image(symbol: "music.note")
                        .font(.ui(size: 72, weight: .light))
                        .foregroundStyle(.white.opacity(0.9))
                }
            }
        }
        .clipShape(shape)
        .overlay(shape.strokeBorder(Color.white.opacity(0.12)))
    }
}

/// The waveform: bars to click or drag along, the played part in the accent, the bars at the playhead dancing while
/// it plays.
private struct WaveformScrubber: View {
    @Environment(\.themeTokens) private var theme
    let bars: [Float]
    let playback: PlaybackModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { proxy in
            TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !playback.isPlaying || reduceMotion)) { timeline in
                let phase = timeline.date.timeIntervalSinceReferenceDate
                Canvas { context, size in
                    let values = bars.isEmpty ? [Float](repeating: 0.15, count: 110) : bars
                    let step = size.width / CGFloat(values.count)
                    let played = playback.progress * Double(values.count)
                    for (i, value) in values.enumerated() {
                        var height = max(4, CGFloat(value) * size.height)
                        if playback.isPlaying, !reduceMotion {
                            let distance = abs(Double(i) - played)
                            if distance < 7 { height *= 1 + 0.22 * (1 - distance / 7) * CGFloat(sin(phase * 9 + Double(i))) }
                        }
                        let rect = CGRect(
                            x: CGFloat(i) * step + step * 0.18, y: (size.height - min(height, size.height)) / 2,
                            width: step * 0.64, height: min(height, size.height)
                        )
                        let color: Color = Double(i) < played ? theme.accent : theme.text.opacity(0.22)
                        context.fill(Path(roundedRect: rect, cornerRadius: Corners.r(rect.width / 2)), with: .color(color))
                    }
                }
            }
            .contentShape(.rect)
            .gesture(DragGesture(minimumDistance: 0).onChanged { drag in
                guard playback.duration > 0, proxy.size.width > 0 else { return }
                playback.seek(to: playback.duration * Double(min(max(drag.location.x / proxy.size.width, 0), 1)))
            })
        }
        .accessibilityElement()
        .accessibilityLabel("Position")
        .accessibilityValue(PlaybackModel.clock(playback.time))
    }
}

/// Back 15 seconds, play or pause, forward 15 seconds, and the speed.
private struct Transport: View {
    @Environment(\.themeTokens) private var theme
    let playback: PlaybackModel

    var body: some View {
        HStack(spacing: 22) {
            // As wide as the speed menu opposite, so the play button stays in the middle.
            Color.clear.frame(width: 40, height: 1)
            Button { playback.skip(-15) } label: { Image(symbol: "gobackward.15").font(.ui(size: 20)) }
                .help("Back 15 Seconds")
            Button { playback.toggle() } label: {
                Image(symbol: playback.isPlaying ? "pause.fill" : "play.fill")
                    .font(.ui(size: 22, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 56, height: 56)
                    .background(theme.accent, in: .circle)
                    .shadow(color: theme.accent.opacity(0.35), radius: 10, y: 4)
                    .contentTransition(.symbolEffect(.replace))
            }
            .keyboardShortcut(.space, modifiers: [])
            .help(playback.isPlaying ? "Pause" : "Play")
            Button { playback.skip(15) } label: { Image(symbol: "goforward.15").font(.ui(size: 20)) }
                .help("Forward 15 Seconds")
            Menu {
                ForEach(PlaybackModel.speeds, id: \.self) { value in
                    Button { playback.setSpeed(value) } label: {
                        if value == playback.speed { Label(PlaybackModel.label(for: value), symbol: "checkmark") } else { Text(PlaybackModel.label(for: value)) }
                    }
                }
            } label: {
                Text(PlaybackModel.label(for: playback.speed))
                    .font(.ui(size: 13, weight: .semibold).monospacedDigit())
                    .frame(width: 40, height: 28)
                    .background(Color.primary.opacity(0.07), in: .capsule)
            }
            .menuStyle(.button)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Playback Speed")
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
    }
}
