import CanvasPlugin
import PluginKitUI
import SwiftUI

/// The small bar at the bottom of a presentation: where it is, the slides before and after, stop. It shows when the
/// pointer moves or the slide changes, and goes after a moment of stillness. The board hides everything but the
/// slide and pushes slides in and out (`BoardCanvasView.updatePresentation`).
struct BoardPresentationBar: View {
    let model: BoardModel
    @Environment(\.themeTokens) private var theme
    @State private var barShown = true
    @State private var hideTask: Task<Void, Never>?

    var body: some View {
        if let presentation = model.presentation {
            HStack(spacing: 4) {
                button("chevron.left", "Previous slide (←)") { model.previousSlide() }
                    .disabled(presentation.index == 0)
                Text("\(presentation.index + 1) / \(presentation.slides.count)")
                    .font(.ui(size: 13, weight: .semibold).monospacedDigit())
                    .foregroundStyle(theme.secondaryText)
                    .frame(minWidth: 44)
                button("chevron.right", "Next slide (→ or Space)") { model.nextSlide() }
                    .disabled(presentation.index == presentation.slides.count - 1)
                Divider().frame(height: 16).padding(.horizontal, 3)
                button("xmark", "Stop presenting (Esc)") { model.stopPresenting() }
            }
            .foregroundStyle(theme.text)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .glassEffect(.regular, in: ThemeCapsule())
            .fixedSize()
            .opacity(barShown ? 1 : 0)
            .animation(BoardMotion.chrome, value: barShown)
            .onAppear { showBar() }
            .onChange(of: presentation.index) { showBar() }
            .onChange(of: model.pointerMoves) { showBar() }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Presenting slide \(presentation.index + 1) of \(presentation.slides.count)")
        }
    }

    private func button(_ image: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(symbol: image).font(.ui(size: 13, weight: .semibold)).frame(width: 30, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private func showBar() {
        if !barShown { barShown = true }
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(for: .seconds(2.5))
            if !Task.isCancelled { barShown = false }
        }
    }
}
