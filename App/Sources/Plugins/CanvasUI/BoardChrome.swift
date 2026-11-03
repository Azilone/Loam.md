import CanvasPlugin
import PluginKitUI
import SwiftUI

/// The skin of a card: Liquid Glass over a faint paper, a hairline edge, a tint when the card has a colour, a
/// shadow that deepens as the card is lifted. Zoomed far out the glass is dropped for a flat fill, which is cheap.
struct BoardCardSurface: ViewModifier {
    let tint: Color?
    let shape: BoardShape
    var border: CanvasBorder? = nil
    let glass: Bool
    /// Text cards sit on a more opaque paper than notes, so their writing reads at once.
    let paper: Double
    let lifted: Bool
    /// A sticky note: solid colour, flat, a small shadow.
    var sticky = false
    @Environment(\.themeTokens) private var theme
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        let dark = colorScheme == .dark
        let invisible = border == .invisible
        let width: CGFloat = tint == nil ? (border == nil ? 1 : 1.5) : 1.75
        let line = tint?.opacity(0.8) ?? Color.primary.opacity(dark ? 0.2 : border == nil ? 0.14 : 0.35)
        content
            // The glass is the card's floor: the content stays above it, the paper in between keeps text readable.
            .background {
                if sticky {
                    ZStack {
                        shape.fill(theme.background)
                        shape.fill((tint ?? BoardStyle.color("3")!).opacity(dark ? 0.5 : 0.78))
                    }
                } else if !invisible {
                    ZStack {
                        if glass {
                            Color.clear.glassEffect(.regular.tint(tint?.opacity(dark ? 0.28 : 0.22)), in: shape)
                            shape.fill(theme.background.opacity(paper))
                        } else {
                            shape.fill(theme.background)
                        }
                        if let tint { shape.fill(tint.opacity(dark ? (glass ? 0.14 : 0.2) : (glass ? 0.08 : 0.12))) }
                    }
                }
            }
        .overlay {
            if !invisible, !sticky {
                let style = StrokeStyle(lineWidth: width, lineCap: .round, dash: border?.dash(width) ?? [])
                ZStack {
                    shape.strokeBorder(line, style: style)
                    if shape.hasDetails { BoardShapeDetails(shape: shape.inset(by: width / 2)).stroke(line, style: style) }
                }
                .allowsHitTesting(false)
            }
        }
        // Flat cards (many on screen) go without the blur of a shadow, the dearest thing a card draws.
        .shadow(color: .black.opacity(invisible ? 0 : sticky ? (lifted ? 0.3 : 0.16) : lifted ? (dark ? 0.5 : 0.22) : glass ? (dark ? 0.32 : 0.11) : 0),
                radius: lifted ? 26 : 10, y: lifted ? 14 : 4)
    }
}

/// The light on a card's glass: a bright rim on the side the pointer is nearest, and a soft glow under it, both
/// following the pointer while it is over the card. Reads the pointer itself, so moving it redraws only this.
struct BoardSpecular: View {
    let model: BoardModel
    let id: String
    let size: CGSize
    let shape: BoardShape
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        if model.hovered == id, let point = model.hoverPoint, size.width > 0, size.height > 0 {
            let dark = colorScheme == .dark
            let angle = atan2(point.y - size.height / 2, point.x - size.width / 2) * 180 / .pi
            ZStack {
                shape.fill(RadialGradient(
                    colors: [.white.opacity(dark ? 0.12 : 0.55), .clear],
                    center: UnitPoint(x: point.x / size.width, y: point.y / size.height),
                    startRadius: 0, endRadius: max(size.width, size.height) * 0.65
                ))
                shape.strokeBorder(AngularGradient(
                    stops: [
                        .init(color: .white.opacity(dark ? 0.55 : 0.95), location: 0),
                        .init(color: .white.opacity(0), location: 0.16),
                        .init(color: .white.opacity(0), location: 0.84),
                        .init(color: .white.opacity(dark ? 0.55 : 0.95), location: 1),
                    ],
                    center: .center, angle: .degrees(angle)
                ), lineWidth: 1.5)
            }
            .allowsHitTesting(false)
            .transition(.opacity)
        }
    }
}

/// A colour's name in the picker, and the swatches themselves.
struct BoardSwatches: View {
    let current: String?
    let pick: (String?) -> Void
    @Environment(\.themeTokens) private var theme

    var body: some View {
        HStack(spacing: 8) {
            swatch(nil, Color.clear)
            ForEach(BoardStyle.presets, id: \.value) { preset in
                swatch(preset.value, BoardStyle.color(preset.value) ?? .gray)
            }
        }
        .padding(12)
    }

    private func swatch(_ value: String?, _ color: Color) -> some View {
        Button { pick(value) } label: {
            ZStack {
                Circle().fill(color)
                if value == nil {
                    Circle().strokeBorder(theme.secondaryText.opacity(0.5), lineWidth: 1.5)
                    Rectangle().fill(Color.red.opacity(0.7)).frame(width: 1.5, height: 22).rotationEffect(.degrees(45)) // ui-rules: illustration
                        .clipShape(Circle())
                }
                if value == current {
                    Circle().strokeBorder(theme.text, lineWidth: 2).padding(-3)
                }
            }
            .frame(width: 22, height: 22)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(value == nil ? "No colour" : BoardStyle.presets.first { $0.value == value }?.name ?? "")
    }
}
