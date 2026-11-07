import Observation
import PluginKitUI
import SwiftUI

/// The theme of the page, as the views a note hosts read it: the embeds (`![](Tasks/Tasks.base)`) and the live blocks.
/// Their hosting views are made once and kept, and a hosting view inherits nothing from the SwiftUI view around the
/// editor, so each reads the page's tokens from here and redraws when a new theme or appearance replaces them.
@MainActor
@Observable
final class EmbedTheme {
    var tokens: ThemeTokens

    init(_ tokens: ThemeTokens = .standard) {
        self.tokens = tokens
    }
}

/// A hosted view with the page's theme in its environment, following `theme`.
struct ThemedEmbedRoot: View {
    let content: AnyView
    let theme: EmbedTheme

    var body: some View {
        content
            .environment(\.themeTokens, theme.tokens)
            .tint(theme.tokens.accent)
    }
}
