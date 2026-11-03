import PluginKitUI
import SwiftUI

extension View {
    /// Puts the theme of `themes` on the window: `themeTokens` for every view below, the accent as the tint (the
    /// design's blue when the theme has none), and the appearance it forces.
    func themed(by themes: ThemeStore) -> some View {
        modifier(ThemedWindow(themes: themes))
    }
}

/// What the views read from globals rather than from the environment: the interface font, the corners.
private struct Look: Hashable {
    var font: ThemeFontFamily
    var corners: CGFloat?
    var pill: Bool
}

private struct ThemedWindow: ViewModifier {
    let themes: ThemeStore
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        let tokens = tokens
        let look = Look(
            font: tokens.style.interfaceFont ?? .system(.default),
            corners: tokens.style.corners.flatMap(Corners.cap(for:)),
            pill: tokens.style.corners == "pill"
        )
        // Before the views below read them; a new look redraws them all, since an image or a font does not observe
        // them.
        InterfaceFont.family = look.font
        Corners.cap = look.corners
        Corners.pill = look.pill
        return content
            .id(look)
            .environment(\.themeTokens, tokens)
            .environment(\.windowCanvas, canvas)
            .tint(tokens.accent)
            .preferredColorScheme(themes.colorScheme)
    }

    /// The theme's tokens, with the design's blue as the accent unless the theme sets one; links follow it, as
    /// they follow a theme's accent.
    private var tokens: ThemeTokens {
        var tokens = themes.tokens(systemIsDark: colorScheme == .dark)
        if tokens.palette.accent == nil {
            // In the palette too, so the editor (which reads it) follows.
            tokens.palette.accent = Glass.defaultAccentColor
            tokens.accent = Glass.defaultAccent
            if tokens.palette.link == nil { tokens.link = Glass.defaultAccent }
        }
        // The page's colour unless the theme sets one, in the palette too so the editor (which reads it) draws
        // on the page.
        if tokens.palette.background == nil {
            let page = colorScheme == .dark ? Glass.darkPage : Glass.lightPage
            tokens.palette.background = page
            tokens.background = Color(page)
        }
        return tokens
    }

    /// The window's background around the pages: nil for the system's translucent material, the theme's `sidebar`
    /// colour, or a shade of its own background when it sets one.
    private var canvas: Color? {
        let dark = colorScheme == .dark
        let palette = themes.tokens(systemIsDark: dark).palette
        if let sidebar = palette.sidebar { return Color(sidebar) }
        guard let background = palette.background else { return nil }
        return Color(background).mix(with: dark ? .black : Color(hex: 0x1A1C1E), by: dark ? 0.25 : 0.04)
    }
}

extension EnvironmentValues {
    /// The window's background around the pages, set by `themed(by:)`; nil for the translucent material.
    @Entry var windowCanvas: Color? = nil
}
