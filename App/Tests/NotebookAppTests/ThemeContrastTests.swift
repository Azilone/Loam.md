import PluginKitUI
import XCTest
@testable import NotebookApp

/// Every theme that ships with Loam stays readable in each appearance it has: body text and headings at least 4.5:1
/// on the page (WCAG AA), secondary text, links, tags and the text over a highlight at least 3:1.
@MainActor
final class ThemeContrastTests: XCTestCase {
    private var themes: [Theme] {
        BuiltInThemes.all.compactMap(\.theme) + ThemeStore.examples.compactMap { try? Theme.parse(Data($0.json.utf8), fallbackName: $0.name) }
    }

    func testShippedThemesAreReadable() {
        var problems: [String] = []
        for theme in themes {
            for dark in appearances(of: theme) {
                let palette = theme.palette(dark: dark)
                guard let background = palette.background, let text = palette.text else { continue }
                let label = "\(theme.name) \(dark ? "dark" : "light")"
                func check(_ name: String, _ color: ThemeColor?, on surface: ThemeColor? = nil, _ minimum: Double) {
                    guard let color else { return }
                    // A translucent surface shows as its mix over the page: contrast ignores opacity.
                    let shown = surface.map { layer in
                        let a = layer.alpha
                        return ThemeColor(
                            red: layer.red * a + background.red * (1 - a),
                            green: layer.green * a + background.green * (1 - a),
                            blue: layer.blue * a + background.blue * (1 - a)
                        )
                    }
                    let ratio = color.contrast(with: shown ?? background)
                    if ratio < minimum { problems.append("\(label): \(name) \(String(format: "%.2f", ratio)):1, needs \(minimum)") }
                }
                check("text", text, 4.5)
                check("heading", palette.heading, 4.5)
                check("secondaryText", palette.secondaryText, 3)
                check("link", palette.link, 3)
                check("accent", palette.accent, 3)
                check("tagText", palette.tagText, on: palette.tagBackground, 3)
                check("text on highlight", palette.highlightText ?? text, on: palette.highlight, 3)
                check("text on sidebar", palette.hasDarkCanvas ? ThemePalette.canvasText : text, on: palette.sidebar, 4.5)
            }
        }
        XCTAssert(problems.isEmpty, "\n" + problems.joined(separator: "\n"))
    }

    private func appearances(of theme: Theme) -> [Bool] {
        switch theme.appearance {
        case .light: [false]
        case .dark: [true]
        case .auto: [false, true]
        }
    }
}
