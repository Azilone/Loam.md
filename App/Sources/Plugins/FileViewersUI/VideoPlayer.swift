import AppKit
import AVFoundation
import AVKit
import PluginKitUI
import SwiftUI

/// A video in a rounded frame on the quiet stage, with Loam's own glass controls that fade away while it plays:
/// back 15 seconds, play, forward 15, a scrubber, the speed and picture in picture. A click plays or pauses.
struct VideoPlayer: View {
    let view: ViewContext
    let file: FileLocation?
    @State private var detail: String?

    var body: some View {
        if let file, file.exists {
            VideoScreen(view: view, file: file, detail: $detail)
        } else {
            ViewerFrame(view: view, file: file) { _ in EmptyView() }
        }
    }
}

private struct VideoScreen: View {
    let view: ViewContext
    let file: FileLocation
    @Binding var detail: String?
    @State private var playback: PlaybackModel
    @State private var controller = VideoController()
    @State private var size: CGSize?
    @State private var lastMove = Date()
    @State private var controlsShown = true

    init(view: ViewContext, file: FileLocation, detail: Binding<String?>) {
        self.view = view
        self.file = file
        _detail = detail
        _playback = State(initialValue: PlaybackModel(url: file.url))
    }

    var body: some View {
        ViewerFrame(view: view, file: file, detail: detail, barVisible: controlsShown) { _ in
            VideoSurface(player: playback.player, controller: controller)
                .aspectRatio(size ?? CGSize(width: 16, height: 9), contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: Corners.r(14), style: .continuous))
                .shadow(color: .black.opacity(0.2), radius: 22, y: 8)
                .padding(.horizontal, 28)
                .padding(.top, 8)
                .padding(.bottom, 76)
                .contentShape(.rect)
                .onTapGesture { playback.toggle(); wake() }
                .onContinuousHover { phase in if case .active = phase { wake() } }
        } bar: {
            Controls(playback: playback, controller: controller)
        }
        .task(id: file.url) {
            let asset = AVURLAsset(url: file.url)
            if let track = try? await asset.loadTracks(withMediaType: .video).first,
               let (natural, transform) = try? await track.load(.naturalSize, .preferredTransform) {
                let shown = natural.applying(transform)
                size = CGSize(width: abs(shown.width), height: abs(shown.height))
                detail = "\(Int(abs(shown.width))) × \(Int(abs(shown.height))) · \(PlaybackModel.clock(playback.duration))"
            }
        }
        .onChange(of: playback.duration) {
            if let size { detail = "\(Int(size.width)) × \(Int(size.height)) · \(PlaybackModel.clock(playback.duration))" }
        }
        // The controls go after a moment of stillness while the video plays, and come back with the pointer.
        .task(id: lastMove) {
            controlsShown = true
            guard playback.isPlaying else { return }
            try? await Task.sleep(for: .seconds(2.4))
            if playback.isPlaying { controlsShown = false }
        }
        .onChange(of: playback.isPlaying) { wake() }
        .onDisappear { playback.pause() }
    }

    private func wake() { lastMove = Date() }
}

private struct Controls: View {
    let playback: PlaybackModel
    let controller: VideoController

    var body: some View {
        BarButton(symbol: "gobackward.15", help: "Back 15 Seconds", size: 14) { playback.skip(-15) }
        BarButton(symbol: playback.isPlaying ? "pause.fill" : "play.fill", help: playback.isPlaying ? "Pause" : "Play", size: 15) { playback.toggle() }
            .keyboardShortcut(.space, modifiers: [])
        BarButton(symbol: "goforward.15", help: "Forward 15 Seconds", size: 14) { playback.skip(15) }
        Text(PlaybackModel.clock(playback.time))
            .font(.ui(size: 11, weight: .medium).monospacedDigit())
            .foregroundStyle(.secondary)
            .frame(minWidth: 34)
        Slider(
            value: Binding(get: { playback.time }, set: { playback.seek(to: $0) }),
            in: 0...max(playback.duration, 0.1)
        )
        .controlSize(.mini)
        .frame(width: 190)
        Text("-" + PlaybackModel.clock(playback.remaining))
            .font(.ui(size: 11, weight: .medium).monospacedDigit())
            .foregroundStyle(.secondary)
            .frame(minWidth: 38)
        Menu {
            ForEach(PlaybackModel.speeds, id: \.self) { value in
                Button { playback.setSpeed(value) } label: {
                    if value == playback.speed { Label(PlaybackModel.label(for: value), symbol: "checkmark") } else { Text(PlaybackModel.label(for: value)) }
                }
            }
        } label: {
            Text(PlaybackModel.label(for: playback.speed))
                .font(.ui(size: 12, weight: .semibold).monospacedDigit())
                .frame(width: 34, height: 28)
                .contentShape(.rect)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Playback Speed")
        if controller.supportsPictureInPicture {
            BarButton(symbol: "pip.enter", help: "Picture in Picture", size: 14) { controller.togglePictureInPicture() }
        }
        BarDivider()
    }
}

/// The video's layer and its picture in picture, which the controls call.
@MainActor
@Observable
final class VideoController {
    @ObservationIgnored fileprivate var pip: AVPictureInPictureController?

    var supportsPictureInPicture: Bool { AVPictureInPictureController.isPictureInPictureSupported() }

    fileprivate func attach(_ layer: AVPlayerLayer) {
        guard AVPictureInPictureController.isPictureInPictureSupported() else { return }
        pip = AVPictureInPictureController(playerLayer: layer)
    }

    func togglePictureInPicture() {
        guard let pip else { return }
        if pip.isPictureInPictureActive { pip.stopPictureInPicture() } else { pip.startPictureInPicture() }
    }
}

private final class PlayerLayerView: NSView {
    let playerLayer = AVPlayerLayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer = CALayer()
        layer?.backgroundColor = NSColor.black.cgColor
        playerLayer.videoGravity = .resizeAspect
        layer?.addSublayer(playerLayer)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerLayer.frame = bounds
        CATransaction.commit()
    }
}

private struct VideoSurface: NSViewRepresentable {
    let player: AVPlayer
    let controller: VideoController

    func makeNSView(context: Context) -> NSView {
        let view = PlayerLayerView()
        view.playerLayer.player = player
        controller.attach(view.playerLayer)
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {}

    static func dismantleNSView(_ view: NSView, coordinator: ()) {
        (view as? PlayerLayerView)?.playerLayer.player = nil
    }
}
