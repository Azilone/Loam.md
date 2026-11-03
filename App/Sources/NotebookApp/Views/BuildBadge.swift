import SwiftUI
import PluginKitUI

/// Which development build this window belongs to, as a small coloured capsule: the worktree or branch it was built
/// from (`LoamBuildLabel` in Info.plist, written by scripts/build-app.sh for a debug build and scripts/agent-run.sh for
/// an instance). Several builds run side by side while developing; the label and its colour tell them apart. A
/// release build has no label and shows nothing.
struct BuildBadge: View {
    static let label = Bundle.main.object(forInfoDictionaryKey: "LoamBuildLabel") as? String

    var body: some View {
        if let label = Self.label, !label.isEmpty {
            Text(label)
                .font(.ui(size: 11, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(ThemeCapsule().fill(Self.color(for: label)))
                .allowsHitTesting(false)
        }
    }

    /// The same label gets the same colour on every build: a hue from a stable hash of its text.
    private static func color(for label: String) -> Color {
        let hash = label.unicodeScalars.reduce(UInt32(5381)) { ($0 &* 33) &+ $1.value }
        return Color(hue: Double(hash % 360) / 360, saturation: 0.65, brightness: 0.75)
    }
}
