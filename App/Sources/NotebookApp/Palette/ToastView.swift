import PluginKitUI
import SwiftUI

/// The `CommandRunner`'s message: a small glass capsule on a card of the page's colour along the bottom of the window.
/// A click or a swipe down dismisses it; the pointer over it holds the timer, so a long message can be read.
struct ToastView: View {
    let toast: CommandRunner.Toast
    let dismiss: @MainActor () -> Void
    /// The pointer came over the toast (true) or left it (false): the timer pauses and resumes.
    var hover: @MainActor (Bool) -> Void = { _ in }
    @Environment(\.themeTokens) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// How far down (or, damped, up) the hand has taken the toast.
    @State private var drag: CGFloat = 0
    @State private var dragging = false

    /// The colour of the toast's kind: green when work is done, orange when it failed, the accent otherwise.
    private var tint: Color {
        switch toast.kind {
        case .success: .green
        case .error: .orange
        case .info: theme.accent
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            ToastDot(color: tint)
            // A new message replaces the old one inside the same capsule: the words cross-fade, the capsule resizes.
            Text(toast.text)
                .foregroundStyle(theme.text)
                .lineLimit(3)
                .multilineTextAlignment(.leading)
                .id(toast.id)
                .transition(.opacity)
        }
        .font(.ui(.label))
        .padding(.leading, 12)
        .padding(.trailing, 14)
        .padding(.vertical, 8)
        // The glass alone is clear over a white page and the text looks bare: a card of the page's colour sits under it,
        // lit from the dot's side by a wash of its colour that fades before the words.
        .background {
            ThemeCapsule().fill(theme.background.opacity(0.88))
                .overlay(ThemeCapsule().fill(LinearGradient(
                    colors: [tint.opacity(0.22), tint.opacity(0)], startPoint: .leading, endPoint: UnitPoint(x: 0.6, y: 0.5)
                )))
        }
        .overlay(ThemeCapsule().strokeBorder(theme.separator, lineWidth: 0.5))
        .glassEffect(.regular, in: ThemeCapsule())
        .shadow(color: .black.opacity(0.12), radius: 10, y: 4)
        .frame(maxWidth: 520)
        .offset(y: drag)
        .opacity(ToastSwipe.opacity(for: drag))
        .padding(.bottom, 36)
        .onHover { hover($0) }
        .onTapGesture { dismiss() }
        // The toast follows the hand 1:1; let go past the threshold and it leaves, short of it and it settles back.
        .gesture(
            DragGesture(minimumDistance: 6)
                .onChanged { value in
                    if !dragging {
                        dragging = true
                        hover(true)
                    }
                    drag = ToastSwipe.offset(for: value.translation.height)
                }
                .onEnded { value in
                    dragging = false
                    if ToastSwipe.shouldDismiss(translation: value.translation.height, predicted: value.predictedEndTranslation.height) {
                        dismiss()
                    } else {
                        hover(false)
                        withAnimation(Motion.resolved(Motion.Spring.settle.animation, reduceMotion: reduceMotion)) { drag = 0 }
                    }
                }
        )
    }

    /// Rises from the bottom edge with a little life while it fades in; sinks and fades out, faster. Only a fade when
    /// motion is reduced.
    static func transition(reduceMotion: Bool) -> AnyTransition {
        if reduceMotion { return .opacity.animation(Motion.fade) }
        return .asymmetric(
            insertion: .opacity
                .combined(with: .offset(y: Motion.Metrics.toastRise))
                .animation(Motion.Spring.pop.animation),
            removal: .opacity
                .combined(with: .offset(y: Motion.Metrics.toastSink))
                .animation(Motion.exit)
        )
    }
}

/// The toast's kind at a glance: a small lit dot, its colour glowing around it.
private struct ToastDot: View {
    let color: Color

    var body: some View {
        Circle()
            .fill(RadialGradient(colors: [color.mix(with: .white, by: 0.35), color], center: UnitPoint(x: 0.35, y: 0.3),
                                 startRadius: 0, endRadius: 5))
            .frame(width: 8, height: 8)
            .shadow(color: color.opacity(0.7), radius: 4)
            .shadow(color: color.opacity(0.35), radius: 8)
            .animation(Motion.crossfade, value: color)
            .accessibilityHidden(true)
    }
}

/// How a swipe on a toast reads: down follows the hand and dismisses past a threshold; up barely moves (there is
/// nowhere to go), so it feels held by the edge.
enum ToastSwipe {
    /// The distance down, in points, that dismisses on release.
    static let dismissDistance: CGFloat = 24
    /// A flick: where the gesture would end at its speed, in points down.
    static let flickDistance: CGFloat = 60

    /// The toast's offset for a hand `translation` points down (negative: up).
    static func offset(for translation: CGFloat) -> CGFloat {
        translation >= 0 ? translation : -sqrt(-translation) * 1.5
    }

    /// Dragged far enough down, or flicked down.
    static func shouldDismiss(translation: CGFloat, predicted: CGFloat) -> Bool {
        translation >= dismissDistance || (translation > 4 && predicted >= flickDistance)
    }

    /// It fades as it is taken down, so the swipe reads as leaving.
    static func opacity(for offset: CGFloat) -> Double {
        guard offset > 0 else { return 1 }
        return max(0.35, 1 - Double(offset) / 120)
    }
}
