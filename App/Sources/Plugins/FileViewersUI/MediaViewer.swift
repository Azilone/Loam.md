import AVFoundation
import PluginKitUI
import SwiftUI

/// A video or a sound: the player for either, or Quick Look when AVFoundation cannot play the file (an `.mkv`).
struct MediaViewer: View {
    let view: ViewContext
    let file: FileLocation?
    @State private var kind: MediaKind?

    private enum MediaKind { case video, audio, unplayable }

    var body: some View {
        Group {
            switch kind {
            case .video: VideoPlayer(view: view, file: file)
            case .audio: AudioPlayer(view: view, file: file)
            case .unplayable: QuickLookViewer(view: view, file: file)
            case nil: Color.clear
            }
        }
        .task(id: file?.url) {
            guard let url = file?.url else { return }
            kind = await Self.kind(of: url)
        }
    }

    private static func kind(of url: URL) async -> MediaKind {
        let asset = AVURLAsset(url: url)
        guard (try? await asset.load(.isPlayable)) == true else { return .unplayable }
        let hasVideo = (try? await asset.loadTracks(withMediaType: .video).isEmpty == false) ?? false
        return hasVideo ? .video : .audio
    }
}
