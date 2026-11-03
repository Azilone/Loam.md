import PluginKitUI
import SwiftUI

/// Craft's Assistant, measured on docs.craft.do (October 2026, docs/AI.md): sizes, colours in both appearances, and
/// its motion. One place, so the panel stays one to one with Craft.
enum CraftStyle {
    // MARK: Geometry

    static let inset: CGFloat = 16
    static let bubbleSize = CGSize(width: 112, height: 40)
    static let panelSize = CGSize(width: 464, height: 704)
    static let cornerRadius: CGFloat = 18
    /// Room kept above the panel in a short window: the tab bar and a gap.
    static let topClearance: CGFloat = 64

    // MARK: Motion

    /// The container grows from the bubble into the panel and back: Framer's `spring(duration 0.5, bounce 0.2)` on its
    /// width and height, anchored at the bottom right.
    static let morph = Animation.spring(duration: 0.5, bounce: 0.2)
    /// The content cross-fades (Framer's `AnimatePresence mode="wait"`): out in 0.1 s, in over 0.2 s after 0.05 s.
    static let contentIn = Animation.easeOut(duration: 0.2).delay(0.05)
    static let contentOut = Animation.easeIn(duration: 0.1)
    /// Buttons' hover: Craft's `0.15s cubic-bezier(0.4, 0, 0.2, 1)`.
    static let hover = Animation.timingCurve(0.4, 0, 0.2, 1, duration: 0.15)

    // MARK: Type

    static func font(_ size: CGFloat, _ weight: Font.Weight = .medium) -> Font {
        .ui(size: size, weight: weight)
    }

    static let tracking: CGFloat = -0.04
}

/// The colours, light and dark, as Craft draws them.
struct CraftColors {
    let dark: Bool

    init(_ scheme: ColorScheme) {
        dark = scheme == .dark
    }

    /// Text and icons: Craft's `rgb(31, 34, 37)` on light, white on dark.
    var ink: Color { dark ? .white : Color(red: 31 / 255, green: 34 / 255, blue: 37 / 255) }
    /// The bubble's glass.
    var bubble: LinearGradient {
        dark
            ? LinearGradient(colors: [Color(white: 37 / 255), Color(white: 30 / 255)],
                             startPoint: UnitPoint(x: 0.06, y: 0.27), endPoint: UnitPoint(x: 0.94, y: 0.73))
            : LinearGradient(colors: [Color(red: 252 / 255, green: 253 / 255, blue: 254 / 255)],
                             startPoint: .leading, endPoint: .trailing)
    }
    /// The open panel's page.
    var panel: Color { dark ? Color(red: 28 / 255, green: 28 / 255, blue: 30 / 255) : .white }
    /// The title capsule.
    var capsuleFill: Color { ink.opacity(dark ? 0.06 : 0.04) }
    var capsuleStroke: Color { ink.opacity(dark ? 0.06 : 0.05) }
    /// The ring drawn inside the composer's round buttons and pills.
    var controlRing: Color { ink.opacity(0.1) }
    var hoverFill: Color { ink.opacity(dark ? 0.08 : 0.05) }
    /// The context chip, the user's message bubble.
    var chip: Color { dark ? Color(red: 39 / 255, green: 39 / 255, blue: 41 / 255) : Color(white: 244 / 255) }
    var chipTile: Color { dark ? Color(red: 28 / 255, green: 28 / 255, blue: 30 / 255) : .white }
    var chipRemove: Color { dark ? Color(white: 62 / 255) : Color(white: 233 / 255) }
    var userBubble: Color { dark ? Color(white: 46 / 255) : Color(white: 233 / 255) }
    /// The send button: Craft's brand blue.
    var send: Color { dark ? Color(red: 113 / 255, green: 178 / 255, blue: 1) : Color(red: 46 / 255, green: 109 / 255, blue: 233 / 255) }
    var sendInk: Color { dark ? Color(white: 30 / 255) : .white }
    var menu: Color { dark ? Color(red: 37 / 255, green: 37 / 255, blue: 39 / 255) : .white }
    var danger: Color { Color(red: 0.86, green: 0.25, blue: 0.22) }
}

extension View {
    /// Craft's layered shadow for floating glass: `0 12 24 -6 / 6 %`, `0 16 40 -6 / 24 %`, and a hairline ring.
    func craftFloatingShadow(_ colors: CraftColors, radius: CGFloat) -> some View {
        self
            .overlay(RoundedRectangle(cornerRadius: Corners.r(radius), style: .continuous)
                .strokeBorder(Color.black.opacity(0.1), lineWidth: 0.5))
            .overlay(RoundedRectangle(cornerRadius: Corners.r(radius), style: .continuous)
                .strokeBorder(Color.white.opacity(colors.dark ? 0.06 : 0), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.06), radius: 12, x: 0, y: 9)
            .shadow(color: .black.opacity(colors.dark ? 0.4 : 0.2), radius: 20, x: 0, y: 12)
    }

    /// The ring Craft draws inside its buttons and pills (`inset 0 0 0 1px`).
    func craftInsetRing<S: Shape>(_ shape: S, _ color: Color) -> some View {
        overlay(shape.stroke(color, lineWidth: 1).padding(0.5))
    }
}
