import Foundation
import PluginKitUI

/// The themes that ship with Loam, the same set as Codex's Appearance settings. They are data only: each is a
/// `Theme` made from a background, a text colour and an accent per appearance, every other colour mixed from those.
/// A file of `.loam/themes/` with the same name wins over a built-in one.
public enum BuiltInThemes {
    /// One appearance of a theme: its background, text and accent, `#RRGGBB`.
    struct Colors {
        let background: String
        let text: String
        let accent: String
    }

    /// Sorted by name, as in Codex's menu.
    public static let all: [ThemeStore.Entry] = [
        make("absolutely", "Absolutely", light: .init(background: "#F9F9F7", text: "#2D2D2B", accent: "#CC7D5E"),
             dark: .init(background: "#2D2D2B", text: "#F9F9F7", accent: "#D98E6F"),
             look: #"{ "fonts": { "body": "Georgia", "size": 16, "letterSpacing": -0.1 }, "editor": { "lineHeight": 1.5, "paragraphSpacing": 0.15, "columnWidth": 700 }, "headings": { "font": "Georgia", "weight": "medium", "sizes": [1.6, 1.35, 1.15, 1.05], "letterSpacing": -0.3 } }"#),
        make("ayu", "Ayu", light: .init(background: "#FCFCFC", text: "#5C6166", accent: "#F29718"),
             dark: .init(background: "#0B0E14", text: "#BFBDB6", accent: "#E6B450"),
             look: #"{ "fonts": { "mono": "Menlo" }, "headings": { "weight": "semibold" }, "tasks": { "checkbox": "square" } }"#),
        make("catppuccin", "Catppuccin", light: .init(background: "#EFF1F5", text: "#4C4F69", accent: "#8839EF"),
             dark: .init(background: "#1E1E2E", text: "#CDD6F4", accent: "#CBA6F7"),
             look: #"{ "fonts": { "body": "SF Pro Rounded" }, "headings": { "font": "SF Pro Rounded", "weight": "bold" }, "tags": { "shape": "capsule" } }"#),
        dither,
        ditherGreen,
        make("dracula", "Dracula", light: nil,
             dark: .init(background: "#282A36", text: "#F8F8F2", accent: "#BD93F9"),
             look: #"{ "headings": { "weight": "bold" }, "tags": { "shape": "capsule" }, "tasks": { "strikethrough": false } }"#),
        make("everforest", "Everforest", light: .init(background: "#FDF6E3", text: "#5C6A72", accent: "#8DA101"),
             dark: .init(background: "#2D353B", text: "#D3C6AA", accent: "#A7C080"),
             look: #"{ "fonts": { "body": "Avenir Next" }, "editor": { "lineHeight": 1.45 }, "headings": { "font": "Avenir Next", "weight": "semibold" }, "tags": { "shape": "capsule" } }"#),
        make("github", "GitHub", light: .init(background: "#FFFFFF", text: "#1F2328", accent: "#0969DA"),
             dark: .init(background: "#0D1117", text: "#E6EDF3", accent: "#4493F8"),
             look: #"{ "fonts": { "size": 15 }, "editor": { "paragraphSpacing": 0.1 }, "headings": { "weight": "semibold", "sizes": [2, 1.5, 1.25, 1], "rules": [1, 2] }, "tasks": { "checkbox": "square", "strikethrough": false } }"#),
        make("gruvbox", "Gruvbox", light: .init(background: "#FBF1C7", text: "#3C3836", accent: "#AF3A03"),
             dark: .init(background: "#282828", text: "#EBDBB2", accent: "#FE8019"),
             look: #"{ "fonts": { "body": "Charter", "mono": "Menlo", "size": 16 }, "editor": { "lineHeight": 1.4 }, "headings": { "weight": "bold" }, "tasks": { "checkbox": "square" } }"#),
        make("linear", "Linear", light: .init(background: "#FCFCFD", text: "#1B1B1F", accent: "#5E6AD2"),
             dark: .init(background: "#08090A", text: "#F7F8F8", accent: "#7170FF"),
             look: #"{ "fonts": { "size": 14.5, "letterSpacing": -0.15 }, "headings": { "weight": "medium", "letterSpacing": -0.6 }, "tasks": { "checkbox": "circle", "strikethrough": false }, "tags": { "shape": "capsule" } }"#),
        ink,
        make("lobster", "Lobster", light: .init(background: "#FFF8F5", text: "#2B1B17", accent: "#D93A2E"),
             dark: .init(background: "#1A1210", text: "#F3E6E1", accent: "#FF5A4E"),
             look: #"{ "fonts": { "body": "Avenir Next" }, "headings": { "font": "Avenir Next", "weight": "heavy", "letterSpacing": -0.4 }, "tags": { "shape": "capsule" } }"#),
        make("material", "Material", light: .init(background: "#FAFAFA", text: "#546E7A", accent: "#39ADB5"),
             dark: .init(background: "#263238", text: "#EEFFFF", accent: "#80CBC4"),
             look: #"{ "headings": { "weight": "medium" }, "tasks": { "checkbox": "square" }, "editor": { "paragraphSpacing": 0.1 } }"#),
        make("monokai", "Monokai", light: nil,
             dark: .init(background: "#272822", text: "#F8F8F2", accent: "#A6E22E"),
             look: #"{ "fonts": { "mono": "Menlo" }, "headings": { "weight": "bold" }, "tasks": { "checkbox": "square" } }"#),
        make("nord", "Nord", light: .init(background: "#ECEFF4", text: "#2E3440", accent: "#5E81AC"),
             dark: .init(background: "#2E3440", text: "#D8DEE9", accent: "#88C0D0"),
             look: #"{ "fonts": { "body": "Avenir Next" }, "editor": { "lineHeight": 1.5 }, "headings": { "font": "Avenir Next", "weight": "medium" } }"#),
        make("raycast", "Raycast", light: .init(background: "#FFFFFF", text: "#0F0F10", accent: "#FF6363"),
             dark: .init(background: "#0F0F10", text: "#EDEDED", accent: "#FF6363"),
             look: #"{ "fonts": { "letterSpacing": -0.1 }, "headings": { "weight": "semibold", "letterSpacing": -0.4 }, "tasks": { "checkbox": "square" }, "tags": { "shape": "capsule" } }"#),
        make("rose-pine", "Rose Pine", light: .init(background: "#FAF4ED", text: "#575279", accent: "#907AA9"),
             dark: .init(background: "#191724", text: "#E0DEF4", accent: "#C4A7E7"),
             look: #"{ "fonts": { "body": "New York", "size": 16 }, "editor": { "lineHeight": 1.5 }, "headings": { "weight": "medium" }, "tags": { "shape": "capsule" } }"#),
        make("sentry", "Sentry", light: .init(background: "#FFFFFF", text: "#2B2233", accent: "#6C5FC7"),
             dark: .init(background: "#181225", text: "#E9E4F0", accent: "#A796F2"),
             look: #"{ "fonts": { "body": "SF Pro Rounded" }, "headings": { "font": "SF Pro Rounded", "weight": "semibold" }, "tags": { "shape": "capsule" } }"#),
        make("solarized", "Solarized", light: .init(background: "#FDF6E3", text: "#657B83", accent: "#268BD2"),
             dark: .init(background: "#002B36", text: "#839496", accent: "#268BD2"),
             look: #"{ "fonts": { "body": "Charter", "mono": "Menlo", "size": 16 }, "editor": { "lineHeight": 1.45 }, "headings": { "weight": "semibold" } }"#),
        make("temple", "Temple", light: .init(background: "#F7F3EA", text: "#2E2A24", accent: "#B8862B"),
             dark: .init(background: "#1B1915", text: "#EAE3D2", accent: "#D4A53C"),
             look: #"{ "fonts": { "body": "Baskerville", "size": 17 }, "editor": { "lineHeight": 1.45, "paragraphSpacing": 0.15 }, "headings": { "font": "Baskerville", "weight": "bold", "rules": [1] } }"#),
        things,
        make("tokyo-night", "Tokyo Night", light: .init(background: "#E1E2E7", text: "#3760BF", accent: "#2E7DE9"),
             dark: .init(background: "#1A1B26", text: "#C0CAF5", accent: "#7AA2F7"),
             look: #"{ "fonts": { "mono": "Menlo" }, "headings": { "weight": "semibold" }, "tags": { "shape": "capsule" } }"#),
        make("vercel", "Vercel", light: .init(background: "#FFFFFF", text: "#000000", accent: "#0070F3"),
             dark: .init(background: "#000000", text: "#EDEDED", accent: "#3291FF"),
             look: #"{ "fonts": { "size": 15, "letterSpacing": -0.15 }, "headings": { "weight": "semibold", "letterSpacing": -0.8, "rules": [] }, "tasks": { "checkbox": "square" } }"#),
        make("vs-code-plus", "VS Code Plus", light: .init(background: "#FFFFFF", text: "#1F1F1F", accent: "#005FB8"),
             dark: .init(background: "#1F1F1F", text: "#CCCCCC", accent: "#0078D4"),
             look: #"{ "fonts": { "mono": "Menlo" }, "headings": { "weight": "semibold", "rules": [1, 2] }, "tasks": { "checkbox": "square" } }"#),
        make("xcode", "Xcode", light: .init(background: "#FFFFFF", text: "#000000", accent: "#AD3DA4"),
             dark: .init(background: "#1F1F24", text: "#FFFFFF", accent: "#FC5FA3"),
             look: #"{ "headings": { "weight": "bold" }, "tasks": { "checkbox": "square" } }"#),
    ]

    /// Loam's own look, as its brand: dithered corners, mono labels, blue.
    static let dither: ThemeStore.Entry = file("dither", "Dither", #"""
        {
          "name": "Dither",
          "appearance": "auto",
          "colors": {
            "accent": "#155EEF",
            "text": "#0B0F19",
            "secondaryText": "#5F6779",
            "background": "#FFFFFF",
            "sidebar": "#F3F4F7",
            "separator": "#E4E7EE",
            "codeBackground": "#F5F8FF",
            "link": "#155EEF",
            "marker": "#A3AAB8",
            "heading": "#0B0F19",
            "highlight": "#155EEF",
            "highlightText": "#FFFFFF",
            "tagText": "#155EEF",
            "tagBackground": "#E9F0FF",
            "checkbox": "#155EEF",
            "checkboxBorder": "#9AA2B3",
            "quoteBar": "#155EEF",
            "quoteBackground": "#E9F0FF",
            "ditherInk": "#155EEF",
            "ditherPaper": "#FFFFFF"
          },
          "dark": {
            "colors": {
              "accent": "#4C80FF",
              "text": "#ECECEE",
              "secondaryText": "#8E8E93",
              "background": "#161618",
              "sidebar": "#0F0F10",
              "separator": "#2A2A2D",
              "codeBackground": "#1C1C1F",
              "link": "#6E9BFF",
              "marker": "#55555A",
              "heading": "#F4F4F5",
              "highlight": "#3A64D8",
              "highlightText": "#FFFFFF",
              "tagText": "#8FB2FF",
              "tagBackground": "#1C2538",
              "checkbox": "#4C80FF",
              "checkboxBorder": "#5A5A60",
              "quoteBar": "#4C80FF",
              "quoteBackground": "#1A2131",
              "ditherInk": "#7FA6FF",
              "ditherPaper": "#161618"
            }
          },
          "fonts": {
            "body": "Gerstner Programm",
            "mono": "FT System Mono",
            "interface": "Gerstner Programm",
            "size": 15
          },
          "headings": {
            "font": "Gerstner Programm",
            "weight": "medium",
            "letterSpacing": -0.6,
            "sizes": [
              1.87,
              1.33,
              1.07,
              1,
              1,
              1
            ],
            "rules": []
          },
          "tasks": {
            "checkbox": "square"
          },
          "tags": {
            "shape": "rounded"
          },
          "editor": {
            "lineHeight": 1.55,
            "paragraphSpacing": 0.45
          },
          "shape": {
            "corners": "soft"
          }
        }
        """#)

    /// Loam's own look in its green, the brand's: the theme a new vault starts with.
    static let ditherGreen: ThemeStore.Entry = file("dither-green", "Dither Green", #"""
        {
          "name": "Dither Green",
          "appearance": "auto",
          "colors": {
            "accent": "#2F5D46",
            "text": "#2E322F",
            "secondaryText": "#6B6F66",
            "background": "#FCFBF8",
            "sidebar": "#F3F1EA",
            "separator": "#E6E2D8",
            "codeBackground": "#F4F1EA",
            "link": "#2F5D46",
            "marker": "#AEAA9E",
            "heading": "#1C1F1D",
            "highlight": "#2F5D46",
            "highlightText": "#FFFFFF",
            "tagText": "#2F5D46",
            "tagBackground": "#2F5D4622",
            "checkbox": "#2F5D46",
            "checkboxBorder": "#A6A296",
            "quoteBar": "#2F5D46",
            "quoteBackground": "#2F5D461A",
            "ditherInk": "#2F5D46",
            "ditherPaper": "#FCFBF8"
          },
          "dark": {
            "colors": {
              "accent": "#8CC79B",
              "text": "#ECECEE",
              "secondaryText": "#8E8E93",
              "background": "#161618",
              "sidebar": "#0F0F10",
              "separator": "#2A2A2D",
              "codeBackground": "#1C1C1F",
              "link": "#8CC79B",
              "marker": "#55555A",
              "heading": "#F4F4F5",
              "highlight": "#3E6A4C",
              "highlightText": "#FFFFFF",
              "tagText": "#B5D8BC",
              "tagBackground": "#8CC79B26",
              "checkbox": "#8CC79B",
              "checkboxBorder": "#5A5A60",
              "quoteBar": "#8CC79B",
              "quoteBackground": "#8CC79B1A",
              "ditherInk": "#B5D8BC",
              "ditherPaper": "#161618"
            }
          },
          "fonts": {
            "body": "SF Pro",
            "mono": "FT System Mono",
            "interface": "Gerstner Programm",
            "size": 16
          },
          "headings": {
            "font": "SF Pro",
            "weight": "semibold",
            "letterSpacing": -0.2,
            "sizes": [
              1.35,
              1.2,
              1.07,
              1,
              1,
              1
            ],
            "rules": []
          },
          "tasks": {
            "checkbox": "square"
          },
          "tags": {
            "shape": "rounded"
          },
          "editor": {
            "lineHeight": 1.42,
            "paragraphSpacing": 0.8,
            "columnWidth": 640
          },
          "shape": {
            "corners": "soft"
          }
        }
        """#)

    /// Warm white pages on a near-black frame, coral accent, square task boxes, capsule tags (the Loam Ink design).
    static let ink: ThemeStore.Entry = file("ink", "Ink", #"""
        {
          "name": "Ink",
          "appearance": "light",
          "colors": {
            "accent": "#D8695A",
            "text": "#1C1C1A",
            "secondaryText": "#8E8D8A",
            "background": "#FEFCFB",
            "sidebar": "#0D0C0F",
            "separator": "#EDEBE9",
            "codeBackground": "#F7F5F4",
            "link": "#C25A4C",
            "marker": "#B2B0AD",
            "heading": "#0D0D0B",
            "highlight": "#F6E7B0",
            "tagText": "#3B4B88",
            "tagBackground": "#E5EAF8",
            "checkbox": "#0D0D0B",
            "checkboxBorder": "#C8C5C1",
            "quoteBar": "#D8695A"
          },
          "fonts": { "body": "SF Pro", "interface": "SF Pro", "size": 16 },
          "headings": { "weight": "bold", "letterSpacing": -0.6, "sizes": [2.4, 1.6, 1.25, 1], "rules": [] },
          "editor": { "lineHeight": 1.4, "paragraphSpacing": 0.5 },
          "tasks": { "checkbox": "square" },
          "tags": { "shape": "capsule" },
          "shape": { "corners": "pill" }
        }
        """#)
    /// A built-in theme written as a theme file (docs/THEMES.md).
    static func file(_ id: String, _ name: String, _ json: String) -> ThemeStore.Entry {
        do {
            return ThemeStore.Entry(id: id, theme: try Theme.parse(Data(json.utf8), fallbackName: name), error: nil)
        } catch {
            return ThemeStore.Entry(id: id, theme: nil, error: error.localizedDescription)
        }
    }

    /// Things 3, after the Obsidian theme that copies it (github.com/MrParalloid/obsidian-things): white pages on a
    /// grey sidebar, square task boxes, green capsule tags, a red bar along quotes, semibold headings with
    /// hairlines under `##` and `####`. Written as a theme file, so it also shows what one can set.
    static let things: ThemeStore.Entry = {
        let json = """
        {
          "name": "Things",
          "appearance": "auto",
          "colors": {
            "accent": "#0062C1", "text": "#373A3E", "secondaryText": "#82868A", "background": "#FFFFFF",
            "separator": "#D2D2D2B3", "codeBackground": "#F5F6F8", "link": "#1F67CF", "marker": "#B0B4B9",
            "heading": "#1D1F22", "highlight": "#FCEBAF", "tagText": "#1E7D58", "tagBackground": "#C3E1D3",
            "checkbox": "#2F7DF6", "checkboxBorder": "#8080804D", "quoteBar": "#F83366", "sidebar": "#F5F6F8"
          },
          "dark": {
            "colors": {
              "accent": "#4D94F7", "text": "#DADBDD", "secondaryText": "#8A919B", "background": "#262626",
              "separator": "#464646E6", "codeBackground": "#212121", "link": "#72A8FF", "marker": "#807F7F",
              "heading": "#FFFFFF", "highlight": "#6B5A1E", "tagText": "#F1F1F1", "tagBackground": "#2F7155",
              "checkbox": "#4D94F7", "checkboxBorder": "#5A5A5A", "quoteBar": "#F83366", "sidebar": "#1A1A1A"
            }
          },
          "fonts": { "body": "SF Pro", "mono": "SF Mono", "size": 15 },
          "editor": { "lineHeight": 1.35, "columnWidth": 760 },
          "headings": { "weight": "semibold", "sizes": [1.75, 1.5, 1.25, 1, 1, 1], "rules": [2, 4] },
          "tasks": { "checkbox": "square", "strikethrough": false },
          "tags": { "shape": "capsule" }
        }
        """
        do {
            let theme = try Theme.parse(Data(json.utf8), fallbackName: "Things")
            return ThemeStore.Entry(id: "things", theme: theme, error: nil)
        } catch {
            return ThemeStore.Entry(id: "things", theme: nil, error: error.localizedDescription)
        }
    }()

    /// A theme with `light` colours and `dark` overrides; dark only when it has no light variant.
    /// `look` is the rest of a theme file (fonts, spacing, headings, tasks, tags), JSON as in docs/THEMES.md.
    static func make(_ id: String, _ name: String, light: Colors?, dark: Colors, look: String = "{}") -> ThemeStore.Entry {
        var theme: Theme
        do {
            theme = try Theme.parse(Data(look.utf8), fallbackName: name)
        } catch {
            return ThemeStore.Entry(id: id, theme: nil, error: error.localizedDescription)
        }
        if let light {
            theme.appearance = .auto
            theme.colors = palette(light)
            theme.darkColors = palette(dark)
        } else {
            theme.appearance = .dark
            theme.colors = palette(dark)
        }
        return ThemeStore.Entry(id: id, theme: theme, error: nil)
    }

    /// Every colour of a palette, the secondary ones mixed from the text into the background. Text, links and tags
    /// are nudged darker (or lighter on a dark page) where the original colours fall short of WCAG AA: 4.5:1 for
    /// text, 3:1 for secondary text, the accent and tags.
    static func palette(_ colors: Colors) -> ThemePalette {
        let background = ThemeColor(hex: colors.background)!
        var text = ThemeColor(hex: colors.text)!
        let sidebar = background.mixed(with: text, by: 0.04)
        text = text.readable(on: sidebar, minimum: 4.5)
        let accent = ThemeColor(hex: colors.accent)!.readable(on: background, minimum: 3)
        func mix(_ amount: Double, of color: ThemeColor? = nil) -> ThemeColor {
            background.mixed(with: color ?? text, by: amount)
        }
        var palette = ThemePalette(
            accent: accent, text: text, secondaryText: mix(0.65).readable(on: background, minimum: 3),
            background: background, separator: mix(0.12), codeBackground: mix(0.06), link: accent, marker: mix(0.4)
        )
        // The rest of the look, from the same three colours: accent tags, boxes and quote bars, a soft accent
        // highlight, and a sidebar a shade off the page.
        palette.heading = text
        palette.highlight = mix(0.25, of: accent)
        palette.tagBackground = mix(0.14, of: accent)
        palette.tagText = accent.readable(on: mix(0.14, of: accent), minimum: 3)
        palette.checkbox = accent
        palette.checkboxBorder = mix(0.35)
        palette.quoteBar = accent
        palette.sidebar = sidebar
        return palette
    }
}
