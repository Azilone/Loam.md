import PluginKitUI
import SwiftUI
import AppKit

/// The shell's look (docs/DESIGN.md, "Look"), taken from Craft: one flat light grey window behind the sidebars and
/// the tabs, each pane an opaque white rounded page detached from the window's edges, and the floating controls
/// (palette, toasts) in Liquid Glass.
enum Glass {
    /// The accent when no theme sets one: the blue of the design.
    static let defaultAccentColor = ThemeStore.accents[0].color
    static let defaultAccent = Color(defaultAccentColor)

    static let lightPage = ThemeColor(hex: "#FFFFFF")!
    static let darkPage = ThemeColor(hex: "#232325")!

    /// The radius of a page's corners.
    static var pageRadius: CGFloat { Corners.pill ? 24 : 14 }
    /// The room between two pages, and between a page and a side column.
    static let gap: CGFloat = 8
    /// The text of the window: Craft's ink, a touch softer than black.
    static let ink = Color(hex: 0x1A1C1E)
    /// The window behind the sidebars and around the pages: Craft's flat greys.
    static let lightCanvas = Color(hex: 0xF2F2F1)
    static let darkCanvas = Color(hex: 0x1B1B1D)
}

/// The window's background, behind the sidebars and around the pages: Craft's flat grey, so the white pages stand
/// out; a shade of the theme's background when the theme sets one.
struct WindowCanvas: View {
    /// Lets the desktop show through, blurred, under a veil of the grey: the main window's sidebars and tab bar in
    /// the manner of macOS 26, a theme's canvas as much as the grey. Opaque with Reduce Transparency.
    var translucent = false

    /// How much of the desktop shows through, 0 (opaque) to `maxTransparency`; set in Settings → Appearance.
    static let transparencyKey = "windowTransparency"
    static let defaultTransparency = maxTransparency / 2
    static let maxTransparency = 0.9

    @AppStorage(WindowCanvas.transparencyKey) private var transparency = WindowCanvas.defaultTransparency

    @Environment(\.windowCanvas) private var canvas
    @Environment(\.themeTokens) private var theme
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        if translucent && Self.isTranslucent(transparency, reduceTransparency) {
            ZStack {
                // A dark canvas under light pages blurs the desktop dark, or its veil would turn grey.
                BehindWindowBlur(dark: theme.hasDarkCanvas)
                Self.color(canvas, colorScheme).opacity(1 - min(transparency, Self.maxTransparency))
            }
        } else {
            Self.color(canvas, colorScheme)
        }
    }

    /// Whether the translucent canvas shows the desktop; the sidebars' scroll views then fade their ends out with a
    /// mask, since a fade painted in the canvas's colour would show as a solid band over the desktop.
    static func isTranslucent(_ transparency: Double, _ reduceTransparency: Bool) -> Bool {
        transparency > 0 && !reduceTransparency
    }

    static func color(_ canvas: Color?, _ colorScheme: ColorScheme) -> Color {
        canvas ?? (colorScheme == .dark ? Glass.darkCanvas : Glass.lightCanvas)
    }
}

/// The desktop behind the window, blurred by the window server.
private struct BehindWindowBlur: NSViewRepresentable {
    var dark = false

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = SeeThroughEffectView()
        view.appearance = dark ? NSAppearance(named: .darkAqua) : nil
        view.blendingMode = .behindWindow
        view.material = .underWindowBackground
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.appearance = dark ? NSAppearance(named: .darkAqua) : nil
    }
}

/// Clears its window's own fill, which would otherwise hide the desktop the blur samples.
private final class SeeThroughEffectView: NSVisualEffectView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        window.isOpaque = false
        window.backgroundColor = .clear
    }
}

extension View {
    /// Draws the view as a page, for a window of its own (Settings): the theme's background, rounded, a hairline ring
    /// and a soft layered shadow. The workspace's pages are drawn by AppKit the same way (`PageChromeView`).
    func page() -> some View {
        modifier(PageChrome())
    }
}

private struct PageChrome: ViewModifier {
    @Environment(\.themeTokens) private var theme
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: Corners.r(Glass.pageRadius), style: .continuous)
        let dark = colorScheme == .dark
        content
            .environment(\.scrollEdgeBackdrop, theme.background)
            .background(theme.background)
            .clipShape(shape)
            // The shadow is cast by a shape of the page's colour, not by the page: a shadow on the page rendered all
            // its text off screen to find its outline, on the CPU, on every frame it moved.
            .background {
                shape.fill(theme.background)
                    .shadow(color: .black.opacity(dark ? 0.3 : 0.05), radius: 1, y: 1)
                    .shadow(color: .black.opacity(dark ? 0.3 : 0.05), radius: 6, y: 3)
            }
            .overlay { shape.stroke(Color.primary.opacity(dark ? 0.1 : 0.06), lineWidth: 1) }
    }
}

extension Color {
    /// An opaque sRGB colour from `0xRRGGBB`.
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }
}
