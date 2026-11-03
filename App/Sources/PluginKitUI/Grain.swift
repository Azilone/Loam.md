import AppKit
import SwiftUI

/// A fine paper grain, made once and tiled: laid over a flat colour it reads as printed ink rather than a smooth
/// gradient. One small image for the whole app, so drawing it costs a tiled fill.
public enum Grain {
    /// A 96-point square of grey specks, white and black about evenly, on clear.
    @MainActor public static let tile: Image = {
        let side = 96
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        var state: UInt64 = 0x9E37_79B9_7F4A_7C15
        for index in 0..<(side * side) {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            let value = UInt8(truncatingIfNeeded: state >> 56)
            let alpha = UInt8(truncatingIfNeeded: (state >> 40) & 0x7F)
            let ink: UInt8 = value > 127 ? 255 : 0
            // Premultiplied.
            let channel = UInt8((Int(ink) * Int(alpha)) / 255)
            pixels[index * 4] = channel
            pixels[index * 4 + 1] = channel
            pixels[index * 4 + 2] = channel
            pixels[index * 4 + 3] = alpha
        }
        let provider = CGDataProvider(data: Data(pixels) as CFData)!
        let image = CGImage(
            width: side, height: side, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: side * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        )!
        return Image(decorative: image, scale: 2)
    }()
}

/// A colour as Loam prints it: flat ink, a soft light from the top, a fine grain and a hairline edge. For the
/// command icons' squares and the switch's track, so the small coloured surfaces share one look.
public struct InkFill<S: InsettableShape>: View {
    let shape: S
    let color: Color
    var grain: Double

    public init(_ shape: S, color: Color, grain: Double = 0.14) {
        self.shape = shape
        self.color = color
        self.grain = grain
    }

    public var body: some View {
        shape
            .fill(color)
            .overlay(shape.fill(LinearGradient(colors: [.white.opacity(0.16), .clear, .black.opacity(0.06)],
                                               startPoint: .top, endPoint: .bottom)))
            .overlay(shape.fill(ImagePaint(image: Grain.tile, scale: 1)).opacity(grain).blendMode(.overlay))
            .overlay(shape.strokeBorder(.black.opacity(0.08), lineWidth: 0.5))
            .compositingGroup()
    }
}

/// Loam's switch: an inked accent track with a white knob, the same in every window and on every theme, in place of
/// the system's.
public struct LoamSwitchStyle: ToggleStyle {
    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        HStack {
            configuration.label
            Spacer(minLength: 8)
            LoamSwitch(isOn: configuration.$isOn)
        }
    }
}

public extension ToggleStyle where Self == LoamSwitchStyle {
    static var loam: LoamSwitchStyle { LoamSwitchStyle() }
}

struct LoamSwitch: View {
    @Binding var isOn: Bool
    @Environment(\.themeTokens) private var theme
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button {
            withAnimation(Motion.resolved(Motion.Spring.tap.animation, reduceMotion: reduceMotion)) { isOn.toggle() }
        } label: {
            ZStack(alignment: isOn ? .trailing : .leading) {
                InkFill(Capsule(), color: isOn ? theme.accent : theme.text.opacity(0.18), grain: isOn ? 0.16 : 0.06)
                Circle()
                    .fill(.white)
                    .shadow(color: .black.opacity(0.22), radius: 1.5, y: 0.5)
                    .padding(2)
            }
            .frame(width: 36, height: 21)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .opacity(isEnabled ? 1 : 0.5)
        .accessibilityValue(Text(isOn ? "On" : "Off"))
    }
}
