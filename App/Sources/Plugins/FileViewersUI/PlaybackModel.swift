import AVFoundation
import Observation

/// What a sound or a video plays and shows: the player, its position and length, its speed.
@MainActor
@Observable
final class PlaybackModel {
    static let speeds: [Float] = [0.5, 0.75, 1, 1.25, 1.5, 2]

    @ObservationIgnored let player: AVPlayer
    private(set) var isPlaying = false
    private(set) var time: Double = 0
    private(set) var duration: Double = 0
    private(set) var speed: Float = 1
    @ObservationIgnored private var observer: Any?

    init(url: URL) {
        player = AVPlayer(url: url)
        observer = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 20), queue: .main) { [weak self] now in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.time = now.seconds.isFinite ? now.seconds : 0
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

    var remaining: Double { max(duration - time, 0) }
    var progress: Double { duration > 0 ? min(max(time / duration, 0), 1) : 0 }

    func toggle() {
        if player.rate != 0 {
            pause()
        } else {
            // From the start again once it has played to the end.
            if duration > 0, time >= duration - 0.1 { seek(to: 0) }
            player.defaultRate = speed
            player.play()
            isPlaying = true
        }
    }

    func pause() {
        player.pause()
        isPlaying = false
    }

    func seek(to seconds: Double) {
        let clamped = min(max(seconds, 0), duration > 0 ? duration : seconds)
        time = clamped
        player.seek(to: CMTime(seconds: clamped, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func skip(_ seconds: Double) { seek(to: time + seconds) }

    func setSpeed(_ value: Float) {
        speed = value
        player.defaultRate = value
        if isPlaying { player.rate = value }
    }

    /// `m:ss`, or `h:mm:ss`, as the system's players write a time.
    static func clock(_ seconds: Double) -> String {
        let whole = Int(seconds.isFinite ? max(0, seconds.rounded(.down)) : 0)
        if whole >= 3600 { return String(format: "%d:%02d:%02d", whole / 3600, whole % 3600 / 60, whole % 60) }
        return String(format: "%d:%02d", whole / 60, whole % 60)
    }

    static func label(for speed: Float) -> String {
        speed == speed.rounded() ? "\(Int(speed))×" : String(format: "%g×", speed)
    }
}
