import CanvasPlugin
import PluginKitUI
import SwiftUI

/// The board presented: only the slide on screen shows, the rest of the board hidden behind the floor colour; a click
/// or the arrow keys go on, Escape stops. A small bar at the bottom says where the presentation is. Changing slide
/// pushes the old one out to the side as the new one comes in (`BoardModel.moveSlide`).
struct BoardPresentationOverlay: View {
    let model: BoardModel
    @Environment(\.themeTokens) private var theme
    @State private var barShown = true
    @State private var hideTask: Task<Void, Never>?

    var body: some View {
        if let presentation = model.presentation, let frame = model.presentedFrame {
            let slide = model.camera.screenRect(CGRect(frame)).offsetBy(dx: model.presentShift, dy: 0)
            ZStack(alignment: .bottom) {
                BoardSlideCutout(slide: slide, radius: 10 * model.camera.scale)
                    .fill(theme.background, style: FillStyle(eoFill: true))
                    .contentShape(Rectangle())
                    .onTapGesture { model.nextSlide() }
                    .onContinuousHover { _ in showBar() }
                if let change = model.slideChange {
                    leaving(change)
                }
                bar(presentation)
                    .padding(.bottom, 18)
                    .opacity(barShown ? 1 : 0)
                    .animation(BoardMotion.chrome, value: barShown)
            }
            .transition(.opacity)
            .onAppear { showBar() }
            .onChange(of: presentation.index) { showBar() }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Presenting slide \(presentation.index + 1) of \(presentation.slides.count)")
        }
    }

    /// The slide going away, drawn as it was on screen and pushed out (or faded) while the next one comes in.
    private func leaving(_ change: BoardSlideChange) -> some View {
        let scale = change.screen.width / max(CGFloat(change.rect.width), 1)
        return BoardExportPage(model: model, rect: change.rect, reusesLiveViews: true)
            .frame(width: change.rect.width, height: change.rect.height)
            .scaleEffect(scale, anchor: .topLeading)
            .frame(width: change.screen.width, height: change.screen.height, alignment: .topLeading)
            .clipShape(RoundedRectangle(cornerRadius: Corners.r(10 * scale)))
            .position(x: change.screen.midX + change.shift, y: change.screen.midY)
            .opacity(change.opacity)
            .allowsHitTesting(false)
            .id(change.id)
    }

    private func bar(_ presentation: BoardPresentation) -> some View {
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
    }

    private func button(_ image: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(symbol: image).font(.ui(size: 13, weight: .semibold)).frame(width: 30, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    /// The bar shows when the pointer moves or the slide changes, and goes after a moment of stillness.
    private func showBar() {
        if !barShown { barShown = true }
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(for: .seconds(2.5))
            if !Task.isCancelled { barShown = false }
        }
    }
}

/// Everything but the slide, in the floor colour. A shape, so it follows the slide as it is pushed in.
struct BoardSlideCutout: Shape {
    var slide: CGRect
    var radius: CGFloat

    var animatableData: CGRect.AnimatableData {
        get { slide.animatableData }
        set { slide.animatableData = newValue }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path(rect)
        path.addPath(Path(roundedRect: slide, cornerRadius: Corners.r(radius)))
        return path
    }
}
