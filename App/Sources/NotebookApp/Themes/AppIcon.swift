import AppKit
import Observation
import PluginKitUI

/// The app's icon follows the theme: the dark green one by default, the blue one in the Dither theme. Views read
/// `image` and `isBlue` (so they are drawn again when the theme changes); the Dock gets the same icon.
@MainActor
@Observable
final class AppIcon {
    static let shared = AppIcon()
    /// The theme whose look is blue.
    static let blueTheme = "Dither"

    private(set) var isBlue = false

    /// The icon in use.
    var image: NSImage { isBlue ? Self.blue : Self.green }

    private static let green = load("Loam")
    private static let blue = load("LoamBlue")
    private static func load(_ name: String) -> NSImage {
        Bundle.main.url(forResource: name, withExtension: "icns").flatMap(NSImage.init(contentsOf:)) ?? NSImage()
    }

    func apply(for theme: Theme?) {
        let blue = theme?.name == Self.blueTheme
        guard blue != isBlue else { return }
        isBlue = blue
        // nil brings back the icon of the bundle, the green one.
        NSApp?.applicationIconImage = blue ? Self.blue : nil
    }
}
