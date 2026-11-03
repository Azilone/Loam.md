import PluginKitUI
import SwiftUI

/// The board's measures, in board units (points at 100 %), and its colours.
enum BoardStyle {
    static let cornerRadius: CGFloat = 16
    static let textPadding: CGFloat = 16
    /// Around free text (text with no card): just enough to grab it.
    static let freeTextPadding: CGFloat = 4
    /// The smallest and largest free text, in board units: resizing stops there.
    static let freeTextSizes: ClosedRange<Double> = 6...600
    static let titleSize: CGFloat = 20
    static let groupLabelSize: CGFloat = 17
    static let edgeWidth: CGFloat = 2.5
    static let arrowSize: CGFloat = 13
    static let handleSize: CGFloat = 11
    static let minimumCard = (width: 72.0, height: 44.0)
    static let minimumGroup = (width: 140.0, height: 90.0)

    /// The six presets of JSON Canvas, "1" to "6", as Obsidian draws them; or `#RRGGBB`.
    static func color(_ value: String?) -> Color? {
        guard let value else { return nil }
        switch value {
        case "1": return Color(red: 0.91, green: 0.29, blue: 0.29)
        case "2": return Color(red: 0.94, green: 0.55, blue: 0.2)
        case "3": return Color(red: 0.92, green: 0.75, blue: 0.13)
        case "4": return Color(red: 0.27, green: 0.69, blue: 0.4)
        case "5": return Color(red: 0.2, green: 0.67, blue: 0.79)
        case "6": return Color(red: 0.6, green: 0.4, blue: 0.85)
        default:
            let hex = value.hasPrefix("#") ? String(value.dropFirst()) : value
            guard hex.count == 6, let number = UInt32(hex, radix: 16) else { return nil }
            return Color(red: Double((number >> 16) & 0xFF) / 255, green: Double((number >> 8) & 0xFF) / 255,
                         blue: Double(number & 0xFF) / 255)
        }
    }

    static let presets: [(value: String, name: String)] = [
        ("1", "Red"), ("2", "Orange"), ("3", "Yellow"), ("4", "Green"), ("5", "Cyan"), ("6", "Purple"),
    ]
}

/// The board's motion: the shared tokens of `Motion` (docs/design/MOTION.md), by what they are used for here.
enum BoardMotion {
    /// A new card pops in.
    static var appear: Animation { Motion.resolved(Motion.Spring.pop.animation) }
    /// A card lifts under the pointer, and comes back down.
    static var lift: Animation { Motion.resolved(Motion.Spring.lift.animation) }
    /// The chrome around a selection (handles, bar) coming and going.
    static var chrome: Animation { Motion.resolved(Motion.Spring.overlay.animation) }
    /// The camera moving to a place (fit, minimap click).
    static var camera: Animation { Motion.resolved(Motion.Spring.smooth.animation) }
    /// How long a new arrow takes to draw itself, in seconds.
    static let linkDraw: Double = 0.38
}
