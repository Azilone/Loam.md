import AppKit
import CoreText
import PluginKitUI
import SwiftUI

// The onboarding's own identity: the welcome card's night on every card (the Onb4 boards' grid, the welcome's
// colours). It never follows the theme: no `.ui` fonts, no `Corners`, no theme tokens, so the first launch looks the
// same whatever look the vault will wear.

/// The palette, on night. Ink and Soft carry text (17:1, 8:1), Muted small print (6:1); Leaf marks what is chosen and
/// done; the main button is the welcome's light grey; Clay only says that something failed.
enum Onb {
    static let paper = Color.black
    static let raised = Color(hex: 0x141414)
    static let sand = Color(hex: 0x242424)
    static let ink = Color(hex: 0xF2F2F2)
    static let soft = Color(hex: 0xA6A6A6)
    static let muted = Color(hex: 0x8C8C8C)
    static let line = Color(hex: 0x2E2E2E)
    static let hoverLine = Color(hex: 0x4A4A4A)
    static let sage = Color(hex: 0x5E7B58)
    /// What is chosen: rings, radios, switches, the steps done.
    static let forest = Color(hex: 0x9CB88E)
    static let leaf = Color(hex: 0x9CB88E)
    static let clay = Color(hex: 0xE07A5F)
    static let radioOff = Color(hex: 0x5A5A5A)
    static let stepOff = Color(hex: 0x333333)
    static let night = Color.black
    static let nightButton = Color(hex: 0xE0E0E0)
    static let nightButtonText = Color(hex: 0x1F1F1F)

    /// The four radii: buttons and fields, cards and tiles, the card itself.
    static let radiusButton: CGFloat = 7
    static let radiusCard: CGFloat = 12
    static let radiusWindow: CGFloat = 16
}

/// Where everything sits on the 928 × 544 card, the same on every screen: a screen change moves only what changes.
enum OnbGrid {
    static let edge: CGFloat = 44
    static let markerY: CGFloat = 52
    static let titleY: CGFloat = 86
    static let choiceY: CGFloat = 196
    static let choiceWidth: CGFloat = 340
    static let actionY: CGFloat = 402
    static let footnoteY: CGFloat = 458
    static let backBottom: CGFloat = 34
    /// The text column: titles and the sentence under them.
    static let columnWidth: CGFloat = 352
    /// The art: from 40 % of the card to its right edge, fading in from its left third.
    static let artX: CGFloat = 371
    /// The app window resting on the art, cut by the card's edges.
    static let window = CGRect(x: 538, y: 110, width: 600, height: 440)
}

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(
            .sRGB, red: Double(hex >> 16 & 0xFF) / 255, green: Double(hex >> 8 & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255, opacity: opacity
        )
    }
}

extension EnvironmentValues {
    /// Draws what plays by itself (the terminal's lines, the crossing's arrow) as it ends: for still pictures.
    @Entry var introStill = false
}

extension View {
    /// Puts the view's top-left corner at `x`, `y` of a top-leading stack.
    func place(_ x: CGFloat, _ y: CGFloat) -> some View { offset(x: x, y: y) }
}

// MARK: Type

/// The serif of the titles: Fraunces (SIL Open Font Licence, `Resources/Brand/Fonts`) when the app ships it, the
/// system's serif otherwise. Nothing else is serif.
@MainActor
enum OnbType {
    private static let names: (upright: String?, italic: String?) = {
        var upright: String?
        var italic: String?
        let urls = IntroAssets.bundle?.urls(forResourcesWithExtension: "ttf", subdirectory: "Brand/Fonts") ?? []
        for url in urls {
            guard let descriptors = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor] else { continue }
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
            for descriptor in descriptors {
                guard let name = CTFontDescriptorCopyAttribute(descriptor, kCTFontNameAttribute) as? String else { continue }
                let traits = CTFontDescriptorCopyAttribute(descriptor, kCTFontTraitsAttribute) as? [CFString: Any]
                let symbolic = (traits?[kCTFontSymbolicTrait] as? UInt32) ?? 0
                if symbolic & CTFontSymbolicTraits.traitItalic.rawValue != 0 { italic = italic ?? name } else { upright = upright ?? name }
            }
        }
        return (upright, italic)
    }()

    /// Titles: 30/36 on the cards, 24/30 under the crossing's icons; weight 500, cut for display sizes.
    static func title(_ size: CGFloat) -> Font {
        serif(names.upright, size: size, weight: 500) ?? .system(size: size, weight: .medium, design: .serif)
    }

    /// The welcome card's line in italics.
    static func italic(_ size: CGFloat) -> Font {
        serif(names.italic, size: size, weight: 400) ?? .system(size: size, design: .serif).italic()
    }

    private static func serif(_ name: String?, size: CGFloat, weight: Double) -> Font? {
        guard let name else { return nil }
        // Fraunces's axes: weight and optical size.
        let variation: [UInt32: Double] = [0x7767_6874: weight, 0x6F70_737A: min(size * 2.4, 72)]
        let descriptor = CTFontDescriptorCreateWithAttributes([
            kCTFontNameAttribute: name, kCTFontVariationAttribute: variation,
        ] as CFDictionary)
        return Font(CTFontCreateWithFontDescriptor(descriptor, size, nil) as NSFont)
    }

    /// Body text, the system's: 14/21 sentences, 13 buttons, 12 small print.
    static func text(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font { .system(size: size, weight: weight) }
    static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font { .system(size: size, weight: weight, design: .monospaced) }
}

// MARK: Glyphs

/// The board's ↩ (24-unit grid, drawn at 12 points): a hook and its head.
struct ReturnGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        let s = rect.width / 24
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: rect.minX + x * s, y: rect.minY + y * s) }
        var path = Path()
        path.move(to: p(19, 6))
        path.addLine(to: p(19, 12))
        path.addArc(tangent1End: p(19, 15), tangent2End: p(16, 15), radius: 3 * s)
        path.addLine(to: p(6, 15))
        path.move(to: p(9.5, 11.5))
        path.addLine(to: p(6, 15))
        path.addLine(to: p(9.5, 18.5))
        return path
    }
}

/// ‹, for Back.
struct ChevronGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        let s = rect.width / 24
        var path = Path()
        path.move(to: CGPoint(x: rect.minX + 14.5 * s, y: rect.minY + 6 * s))
        path.addLine(to: CGPoint(x: rect.minX + 8.5 * s, y: rect.minY + 12 * s))
        path.addLine(to: CGPoint(x: rect.minX + 14.5 * s, y: rect.minY + 18 * s))
        return path
    }
}

/// A tick, in a 16-unit box.
struct TickGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        let s = rect.width / 16
        var path = Path()
        path.move(to: CGPoint(x: rect.minX + 4.6 * s, y: rect.minY + 8.2 * s))
        path.addLine(to: CGPoint(x: rect.minX + 6.8 * s, y: rect.minY + 10.4 * s))
        path.addLine(to: CGPoint(x: rect.minX + 11.4 * s, y: rect.minY + 5.5 * s))
        return path
    }
}

private let glyphStroke = StrokeStyle(lineWidth: 2.2, lineCap: .round, lineJoin: .round)

// MARK: Controls

/// The one filled button of a screen, 38 tall, light, with its ↩: Return does it.
struct OnbMainButton: View {
    let title: String
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(title).contentTransition(.opacity)
                ReturnGlyph().stroke(style: glyphStroke).frame(width: 12, height: 12)
            }
            .font(OnbType.text(13, .medium))
            .foregroundStyle(Onb.nightButtonText)
            .padding(.horizontal, 18)
            .frame(height: 38)
            .background(Onb.nightButton, in: RoundedRectangle(cornerRadius: Onb.radiusButton, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Onb.radiusButton, style: .continuous)
                    .fill(Color.white.opacity(hovered ? 0.5 : 0))
                    .allowsHitTesting(false)
            )
            .contentShape(RoundedRectangle(cornerRadius: Onb.radiusButton, style: .continuous))
        }
        .buttonStyle(.press)
        .onHover { hovered = $0 }
        .animation(Motion.hover, value: hovered)
    }
}

/// Skip, Read the report, Try again: plain words beside the main button, darker under the pointer.
struct OnbTextButton: View {
    let title: String
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(OnbType.text(13, .medium))
                .foregroundStyle(hovered ? Onb.ink : Onb.muted)
                .contentTransition(.opacity)
                .padding(.vertical, 8)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .animation(Motion.hover, value: hovered)
    }
}

/// A key as the boards write it: `esc`.
struct OnbKey: View {
    let label: String

    var body: some View {
        Text(label)
            .font(OnbType.text(10.5, .semibold))
            .foregroundStyle(Onb.soft)
            .padding(.horizontal, 5)
            .frame(height: 18)
            .background(Onb.sand, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
    }
}

/// Back, at the bottom left: Escape does it.
struct OnbBackButton: View {
    var enabled = true
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                HStack(spacing: 2) {
                    ChevronGlyph().stroke(style: StrokeStyle(lineWidth: 1.7, lineCap: .round, lineJoin: .round))
                        .frame(width: 14, height: 14)
                    Text("Back")
                }
                OnbKey(label: "esc")
            }
            .font(OnbType.text(12, .medium))
            .foregroundStyle(hovered && enabled ? Onb.ink : Onb.muted)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.4)
        .onHover { hovered = $0 }
        .animation(Motion.hover, value: hovered)
        .animation(Motion.fade, value: enabled)
    }
}

/// How far the setup is: one capsule a step, the current one long. It sits where the welcome card has its green bar.
struct OnbSteps: View {
    let count: Int
    let current: Int

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<count, id: \.self) { index in
                Capsule()
                    .fill(index <= current ? Onb.forest : Onb.stepOff)
                    .frame(width: index == current ? 26 : 12, height: 6)
            }
        }
        .frame(height: 8)
        .motion(.standard, value: current)
        .motion(.standard, value: count)
        .accessibilityElement()
        .accessibilityLabel(Text("Step \(current + 1) of \(count)"))
    }
}

/// A switch, 34 × 20, Leaf when on.
struct OnbSwitch: View {
    @Binding var isOn: Bool
    let label: String

    var body: some View {
        Button { isOn.toggle() } label: {
            Capsule()
                .fill(isOn ? Onb.forest : Onb.stepOff)
                .frame(width: 34, height: 20)
                .overlay(alignment: isOn ? .trailing : .leading) {
                    Circle().fill(.white)
                        .shadow(color: .black.opacity(0.18), radius: 1, y: 0.5)
                        .frame(width: 16, height: 16)
                        .padding(2)
                }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .motion(.tap, value: isOn)
        .accessibilityLabel(Text(label))
        .accessibilityValue(Text(isOn ? "On" : "Off"))
    }
}

/// A choice in a list: a radio, a name and a line. The chosen one gets a Leaf ring and a filled radio, never colour
/// alone.
struct OnbOption: View {
    let title: String
    let detail: String
    let selected: Bool
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Circle()
                    .strokeBorder(selected ? Onb.forest : Onb.radioOff, lineWidth: selected ? 4.5 : 1.5)
                    .frame(width: 16, height: 16)
                VStack(alignment: .leading, spacing: 0) {
                    Text(title).font(OnbType.text(14, .semibold)).foregroundStyle(Onb.ink).frame(height: 20)
                    Text(detail).font(OnbType.text(12.5)).foregroundStyle(Onb.muted).frame(height: 18)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .frame(width: OnbGrid.choiceWidth, height: 56)
            .background(Onb.raised, in: RoundedRectangle(cornerRadius: Onb.radiusCard, style: .continuous))
            .overlay(ring)
            .contentShape(RoundedRectangle(cornerRadius: Onb.radiusCard, style: .continuous))
        }
        .buttonStyle(.press)
        .onHover { hovered = $0 }
        .animation(Motion.hover, value: hovered)
        .motion(.tap, value: selected)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var ring: some View {
        RoundedRectangle(cornerRadius: Onb.radiusCard, style: .continuous)
            .strokeBorder(selected ? Onb.forest : (hovered ? Onb.hoverLine : Onb.line), lineWidth: selected ? 1.5 : 1)
    }
}

/// Loam's mark: the app's own icon, its tile `size` points wide (the icon's art keeps a margin around the tile).
struct LoamMark: View {
    var size: CGFloat = 104

    var body: some View {
        Image(nsImage: IntroAssets.shared.appIcon ?? NSImage())
            .resizable()
            .frame(width: size * 1024 / 824, height: size * 1024 / 824)
            .frame(width: size, height: size)
    }
}

/// A row's state as a 14-point mark: a Leaf tick, a turning ring, an empty ring, or Clay's "!".
struct OnbStatusMark: View {
    enum State: Equatable { case done, running, waiting, failed }
    let state: State
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @SwiftUI.State private var turning = false

    var body: some View {
        ZStack {
            switch state {
            case .done:
                Circle().fill(Onb.forest)
                TickGlyph().stroke(Onb.paper, style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
                    .frame(width: 14 * 14 / 16, height: 14 * 14 / 16)
            case .failed:
                Circle().fill(Onb.clay)
                VStack(spacing: 1.6) {
                    Capsule().fill(.white).frame(width: 1.7, height: 5)
                    Circle().fill(.white).frame(width: 1.7, height: 1.7)
                }
            case .running:
                Circle().stroke(Onb.line, lineWidth: 1.6).padding(0.6)
                Circle().trim(from: 0, to: 0.25)
                    .stroke(Onb.leaf, style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
                    .padding(0.6)
                    .rotationEffect(.degrees((turning ? 360 : 0) - 90))
                    .onAppear {
                        guard !reduceMotion else { return }
                        withAnimation(.linear(duration: 0.9).repeatForever(autoreverses: false)) { turning = true }
                    }
            case .waiting:
                Circle().stroke(Onb.hoverLine, lineWidth: 1.4).padding(0.7)
            }
        }
        .frame(width: 14, height: 14)
        .transition(.scale(scale: 0.6).combined(with: .opacity))
    }
}

// MARK: Art

// MARK: The art

/// The art on the right of every card: the intro's painting when it has one, else Loam's night; its left
/// third fading into the card.
struct OnbNightArt: View {
    var body: some View {
        let width = IntroScene.cardSize.width - OnbGrid.artX
        Group {
            if let painting = IntroAssets.shared.landscapes.first {
                Image(nsImage: painting).resizable().aspectRatio(contentMode: .fill)
                    .frame(width: width, height: IntroScene.cardSize.height).clipped()
            } else {
                NightArt()
            }
        }
        .mask(ArtFade())
        .place(OnbGrid.artX, 0)
        .allowsHitTesting(false)
    }
}

/// Loam itself, as a window resting on the art and cut by the card's edges: a picture of the real app
/// (`Resources/Brand/Shots/<name>.jpg`, made by `scripts/onboarding-shots.sh`), in the look and with the plugins the
/// card shows. Changing the picture crossfades.
struct OnbAppShot: View {
    let name: String
    var size = OnbGrid.window.size

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color(hex: 0x1C1C1C)
            if let image = OnbShots.image(name) {
                Image(nsImage: image).resizable().interpolation(.high)
                    .aspectRatio(contentMode: .fill)
                    .frame(width: size.width, height: size.height, alignment: .topLeading)
                    .id(name)
                    .transition(.opacity.animation(Motion.crossfade))
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .clipShape(RoundedRectangle(cornerRadius: Onb.radiusCard, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Onb.radiusCard, style: .continuous).strokeBorder(.white.opacity(0.1)))
        .shadow(color: .black.opacity(0.5), radius: 30, y: 20)
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }
}

/// The pictures of the app, read once each.
@MainActor
enum OnbShots {
    private static var cache: [String: NSImage] = [:]

    static func image(_ name: String) -> NSImage? {
        if let image = cache[name] { return image }
        guard let url = IntroAssets.bundle?.url(forResource: name, withExtension: "jpg", subdirectory: "Brand/Shots"),
              let image = NSImage(contentsOf: url) else { return nil }
        cache[name] = image
        return image
    }
}

/// The welcome card's art: a night sky warming toward the horizon.
struct NightArt: View {
    var body: some View {
        let size = CGSize(width: IntroScene.cardSize.width - OnbGrid.artX, height: IntroScene.cardSize.height)
        ZStack(alignment: .topLeading) {
            LinearGradient(
                stops: [
                    .init(color: Color(hex: 0x07070A), location: 0),
                    .init(color: Color(hex: 0x15161B), location: 0.45),
                    .init(color: Color(hex: 0x24221F), location: 0.76),
                    .init(color: Color(hex: 0x0A0A0B), location: 1),
                ],
                startPoint: .top, endPoint: .bottom
            )
            glow(Color(red: 190 / 255, green: 160 / 255, blue: 125 / 255).opacity(0.5),
                 at: CGPoint(x: 0.38, y: 0.8), radii: CGSize(width: 0.7, height: 0.38), size: size)
            glow(Color(red: 120 / 255, green: 130 / 255, blue: 150 / 255).opacity(0.22),
                 at: CGPoint(x: 0.7, y: 0.62), radii: CGSize(width: 0.6, height: 0.3), size: size)
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .clipped()
    }

    /// An elliptical glow fading out at 70 % of its radii, as the board's `radial-gradient(ellipse …)`.
    private func glow(_ color: Color, at center: CGPoint, radii: CGSize, size: CGSize) -> some View {
        let rx = radii.width * size.width, ry = radii.height * size.height
        return RadialGradient(colors: [color, color.opacity(0)], center: .center, startRadius: 0, endRadius: rx * 0.7)
            .frame(width: rx * 2, height: rx * 2)
            .scaleEffect(x: 1, y: ry / rx)
            .position(x: center.x * size.width, y: center.y * size.height)
    }
}

/// The art's left third, fading in from the page.
struct ArtFade: View {
    var body: some View {
        LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.32)],
                       startPoint: .leading, endPoint: .trailing)
    }
}

/// A coding agent using `loam` in a terminal, its lines arriving one after the other as the agent would type them.
struct OnbTerminal: View {
    private let lines = OnbTerminal.agent
    @State private var shown = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.introStill) private var still

    /// A question about the notes, answered through `loam`.
    static let agent: [(String, Color, CGFloat)] = [
        ("> what did I decide about the cabin?", Color(hex: 0xE8E8E8), 0),
        ("  loam search cabin", Onb.leaf, 6),
        ("  The one by the lake, the second week of July.", Color(hex: 0xBDBDBD), 6),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                ForEach(0..<3, id: \.self) { _ in Circle().fill(Color(hex: 0x333333)).frame(width: 9, height: 9) }
            }
            .padding(.horizontal, 12)
            .frame(height: 30)
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                    Text(line.0)
                        .font(OnbType.mono(12))
                        .foregroundStyle(line.1)
                        .frame(height: 20, alignment: .leading)
                        .padding(.top, line.2)
                        .opacity(index < shown || still ? 1 : 0)
                }
            }
            .padding(.horizontal, 22)
            .padding(.top, 6)
            Spacer(minLength: 0)
        }
        .frame(width: 600, height: 150, alignment: .topLeading)
        .background(Color(hex: 0x131313), in: RoundedRectangle(cornerRadius: Onb.radiusCard, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Onb.radiusCard, style: .continuous).strokeBorder(.white.opacity(0.06)))
        .shadow(color: Color(hex: 0x14281C, opacity: 0.4), radius: 30, y: 26)
        .accessibilityHidden(true)
        .task {
            guard !reduceMotion else { return shown = lines.count }
            try? await Task.sleep(for: .milliseconds(350))
            for index in lines.indices {
                withAnimation(Motion.fade) { shown = index + 1 }
                try? await Task.sleep(for: .milliseconds(700))
            }
        }
    }
}

// MARK: Transitions

/// The cards spreading over the welcome from the right: a soft edge travelling across the card.
struct PaperWipe: ViewModifier, Animatable {
    /// 0: none of the view shows; 1: all of it.
    var progress: Double

    nonisolated var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        content.mask {
            // The edge, 30 % of the card wide, from beyond the right edge to beyond the left one.
            let edge = 1.3 - progress * 1.6
            LinearGradient(
                stops: [.init(color: .clear, location: edge), .init(color: .black, location: edge + 0.3)],
                startPoint: .leading, endPoint: .trailing
            )
        }
    }
}

extension AnyTransition {
    static var paperWipe: AnyTransition {
        .modifier(active: PaperWipe(progress: 0), identity: PaperWipe(progress: 1))
    }
}
