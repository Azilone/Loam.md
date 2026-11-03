import PluginKitUI
import AppKit
import AVKit
import Observation
import SwiftUI

/// An animated picture (a GIF), playing in place.
struct AnimatedPicture: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> NSImageView {
        let view = NSImageView()
        view.image = NSImage(contentsOf: url)
        view.animates = true
        view.imageScaling = .scaleProportionallyUpOrDown
        view.isEditable = false
        // The editor sizes the embed; the picture never asks for its own size.
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        return view
    }

    func updateNSView(_ view: NSImageView, context: Context) {}
}

/// The system's player, with its controls in the picture (play, scrub, volume, full screen). Before it plays, a still
/// of the video's first moments covers the black the player draws at rest.
struct PlayerView: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = AVPlayer(url: url)
        view.controlsStyle = .inline
        view.videoGravity = .resizeAspect
        view.showsFullScreenToggleButton = true
        context.coordinator.showPoster(in: view, url: url)
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {}

    func makeCoordinator() -> Poster { Poster() }

    /// The line went away (deleted, another note): the sound stops with it.
    static func dismantleNSView(_ view: AVPlayerView, coordinator: Poster) {
        view.player?.pause()
        view.player = nil
        coordinator.stop()
    }

    /// The still over the player until the first play.
    @MainActor
    final class Poster {
        private var observation: NSKeyValueObservation?
        private var overlay: NSImageView?

        func showPoster(in view: AVPlayerView, url: URL) {
            guard let overlay = view.contentOverlayView else { return }
            let image = NSImageView(frame: overlay.bounds)
            image.autoresizingMask = [.width, .height]
            image.imageScaling = .scaleProportionallyUpOrDown
            overlay.addSubview(image)
            self.overlay = image
            observation = view.player?.observe(\.rate) { [weak self] player, _ in
                guard player.rate != 0 else { return }
                MainActor.assumeIsolated { self?.stop() }
            }
            Task { [weak image] in
                let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
                generator.appliesPreferredTrackTransform = true
                generator.maximumSize = CGSize(width: 1600, height: 1600)
                guard let frame = try? await generator.image(at: CMTime(value: 1, timescale: 10)).image else { return }
                image?.image = NSImage(cgImage: frame, size: .zero)
            }
        }

        func stop() {
            observation = nil
            overlay?.removeFromSuperview()
            overlay = nil
        }
    }
}

/// A sound in a note: a card with a play button, the file's name, kind and size, and a scrubber, playing with the
/// system's player (`AVPlayer`).
struct AudioCard: View {
    let url: URL
    let name: String
    let size: String
    @State private var playback: AudioPlayback

    init(url: URL, name: String, size: String) {
        self.url = url
        self.name = name
        self.size = size
        _playback = State(initialValue: AudioPlayback(url: url))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Button { playback.toggle() } label: {
                    Image(symbol: playback.isPlaying ? "pause.fill" : "play.fill")
                        .font(.ui(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 34, height: 34)
                        .background(Color.accentColor, in: .circle)
                }
                .buttonStyle(.plain)
                .help(playback.isPlaying ? "Pause" : "Play")
                VStack(alignment: .leading, spacing: 1) {
                    Text(name)
                        .font(.ui(size: 13, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(size.isEmpty ? "Audio File" : "Audio File · \(size)")
                        .font(.ui(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: 8) {
                Text(Self.clock(playback.time))
                Slider(
                    value: Binding(get: { playback.time }, set: { time in playback.seek(to: time) }),
                    in: 0...max(playback.duration, 0.1)
                )
                .controlSize(.small)
                Text(Self.clock(playback.duration))
            }
            .font(.ui(size: 11).monospacedDigit())
            .foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.primary.opacity(0.045))
        .onDisappear { playback.pause() }
    }

    /// `m:ss`, as the system's players write a short time.
    static func clock(_ seconds: Double) -> String {
        let whole = Int(seconds.isFinite ? max(0, seconds.rounded(.down)) : 0)
        return String(format: "%d:%02d", whole / 60, whole % 60)
    }

    static let height: CGFloat = 88
}

/// What the audio card plays and shows: the player, its position and length.
@MainActor
@Observable
final class AudioPlayback {
    @ObservationIgnored let player: AVPlayer
    private(set) var isPlaying = false
    private(set) var time: Double = 0
    private(set) var duration: Double = 0
    @ObservationIgnored private var observer: Any?

    init(url: URL) {
        player = AVPlayer(url: url)
        observer = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 4), queue: .main) { [weak self] now in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.time = now.seconds
                self.isPlaying = self.player.rate != 0
            }
        }
        Task { [weak self] in
            guard let asset = self?.player.currentItem?.asset, let length = try? await asset.load(.duration) else { return }
            self?.duration = length.seconds.isFinite ? length.seconds : 0
        }
    }

    isolated deinit {
        if let observer { player.removeTimeObserver(observer) }
        player.pause()
    }

    func toggle() {
        if player.rate != 0 {
            player.pause()
        } else {
            // From the start again once it has played to the end.
            if duration > 0, time >= duration - 0.1 { seek(to: 0) }
            player.play()
        }
        isPlaying = player.rate != 0
    }

    func pause() {
        player.pause()
        isPlaying = false
    }

    func seek(to seconds: Double) {
        time = seconds
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }
}

/// Craft's PDF card: the first page on a grey card, the file's name, kind and size under it.
struct PDFCard: View {
    let thumbnail: CGImage?
    let name: String
    let size: String

    var body: some View {
        VStack(spacing: 0) {
            Group {
                if let thumbnail {
                    Image(decorative: thumbnail, scale: 2)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .background(Color.white)
                        .clipShape(.rect(cornerRadius: Corners.r(4)))
                        .shadow(color: .black.opacity(0.14), radius: 3, y: 1)
                } else {
                    Image(symbol: "doc.richtext")
                        .font(.ui(size: 40, weight: .light))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: 128, maxHeight: 108)
            .frame(maxHeight: .infinity)
            VStack(spacing: 2) {
                Text(name)
                    .font(.ui(size: 13))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("PDF Document")
                    .font(.ui(size: 11))
                    .foregroundStyle(.secondary)
                if !size.isEmpty {
                    Text(size)
                        .font(.ui(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 12)
        }
        .padding(.top, 14)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.primary.opacity(0.045))
    }

    static let size = CGSize(width: 220, height: 190)
}
