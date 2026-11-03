import Foundation
import SwiftUI
import XCTest
@testable import PluginKitUI

final class ThemeTests: XCTestCase {
    private func parse(_ json: String, name: String = "File") throws -> Theme {
        try Theme.parse(Data(json.utf8), fallbackName: name)
    }

    private func XCTAssertInvalid(_ json: String, mentions key: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try parse(json), file: file, line: line) { error in
            guard case ThemeError.invalid(let reason) = error else { return XCTFail("\(error)", file: file, line: line) }
            XCTAssertTrue(reason.contains(key), "\(reason) should name \(key)", file: file, line: line)
        }
    }

    // MARK: Colours

    func testColoursParseSixAndEightDigitHex() throws {
        let opaque = try XCTUnwrap(ThemeColor(hex: "#C2410C"))
        XCTAssertEqual(opaque.red, 0xC2 / 255, accuracy: 0.0001)
        XCTAssertEqual(opaque.green, 0x41 / 255, accuracy: 0.0001)
        XCTAssertEqual(opaque.blue, 0x0C / 255, accuracy: 0.0001)
        XCTAssertEqual(opaque.alpha, 1)
        XCTAssertEqual(opaque.hex, "#C2410C")

        let translucent = try XCTUnwrap(ThemeColor(hex: "#ffffff80"))
        XCTAssertEqual(translucent.alpha, 0x80 / 255, accuracy: 0.0001)
        XCTAssertEqual(translucent.hex, "#FFFFFF80")
    }

    func testBadColoursAreRejected() {
        for text in ["C2410C", "#C2410", "#C2410C0", "#GGGGGG", "red", "", "#", "#+12345"] {
            XCTAssertNil(ThemeColor(hex: text), text)
        }
    }

    // MARK: Parsing

    func testEveryKeyIsRead() throws {
        let theme = try parse("""
        { "name": "Paper", "appearance": "light",
          "colors": { "accent": "#C2410C", "text": "#1F2937", "secondaryText": "#6B7280", "background": "#FBF7F0",
                      "separator": "#E5E0D8", "codeBackground": "#F2EDE4", "link": "#0000FF", "marker": "#B8B0A3" },
          "dark": { "colors": { "background": "#111111" } },
          "fonts": { "body": "New York", "mono": "Menlo", "size": 17 },
          "editor": { "lineHeight": 1.3, "columnWidth": 680 } }
        """)
        XCTAssertEqual(theme.name, "Paper")
        XCTAssertEqual(theme.appearance, .light)
        XCTAssertEqual(theme.colors.accent?.hex, "#C2410C")
        XCTAssertEqual(theme.colors.text?.hex, "#1F2937")
        XCTAssertEqual(theme.colors.secondaryText?.hex, "#6B7280")
        XCTAssertEqual(theme.colors.background?.hex, "#FBF7F0")
        XCTAssertEqual(theme.colors.separator?.hex, "#E5E0D8")
        XCTAssertEqual(theme.colors.codeBackground?.hex, "#F2EDE4")
        XCTAssertEqual(theme.colors.link?.hex, "#0000FF")
        XCTAssertEqual(theme.colors.marker?.hex, "#B8B0A3")
        XCTAssertEqual(theme.darkColors, ThemePalette(background: ThemeColor(hex: "#111111")))
        XCTAssertEqual(theme.bodyFont, .system(.serif))
        XCTAssertEqual(theme.monoFont, .named("Menlo"))
        XCTAssertEqual(theme.fontSize, 17)
        XCTAssertEqual(theme.lineHeight, 1.3)
        XCTAssertEqual(theme.columnWidth, 680)
    }

    func testTheStyleKeysAreRead() throws {
        let theme = try parse("""
        { "colors": { "heading": "#111111", "highlight": "#FCEBAF", "tagText": "#1E7D58", "tagBackground": "#C3E1D3",
                      "checkbox": "#2F7DF6", "checkboxBorder": "#8080804D", "quoteBar": "#F83366", "sidebar": "#F5F6F8" },
          "headings": { "font": "Georgia", "weight": "Semibold", "sizes": [2, 1.5, 9, 1, 1, 1, 1], "rules": [2, 4, 9] },
          "tasks": { "checkbox": "square", "strikethrough": false },
          "tags": { "shape": "capsule" } }
        """)
        XCTAssertEqual(theme.colors.heading?.hex, "#111111")
        XCTAssertEqual(theme.colors.highlight?.hex, "#FCEBAF")
        XCTAssertEqual(theme.colors.tagText?.hex, "#1E7D58")
        XCTAssertEqual(theme.colors.tagBackground?.hex, "#C3E1D3")
        XCTAssertEqual(theme.colors.checkbox?.hex, "#2F7DF6")
        XCTAssertEqual(theme.colors.checkboxBorder?.hex, "#8080804D")
        XCTAssertEqual(theme.colors.quoteBar?.hex, "#F83366")
        XCTAssertEqual(theme.colors.sidebar?.hex, "#F5F6F8")
        XCTAssertEqual(theme.style.headingFont, .named("Georgia"))
        XCTAssertEqual(theme.style.headingWeight, .semibold)
        XCTAssertEqual(theme.style.headingSizes, [2, 1.5, 4, 1, 1, 1], "six levels at most, each 0.8...4")
        XCTAssertEqual(theme.style.headingRules, [2, 4, 6])
        XCTAssertEqual(theme.style.checkbox, .square)
        XCTAssertEqual(theme.style.strikeDoneTasks, false)
        XCTAssertEqual(theme.style.tagShape, .capsule)
        XCTAssertEqual(theme.tokens(dark: false).style, theme.style)
    }

    func testSpacingIsReadAndClamped() throws {
        let theme = try parse(##"{ "fonts": { "letterSpacing": 9 }, "editor": { "paragraphSpacing": 0.5 }, "headings": { "letterSpacing": -0.5 } }"##)
        XCTAssertEqual(theme.style.letterSpacing, 3)
        XCTAssertEqual(theme.style.paragraphSpacing, 0.5)
        XCTAssertEqual(theme.style.headingLetterSpacing, -0.5)
    }

    func testTheDitherFallsBackToTheAccentAndTheBackground() throws {
        let theme = try parse(##"""
        { "colors": { "accent": "#155EEF", "background": "#F7F5EF" },
          "dark": { "colors": { "ditherInk": "#DDEBFF", "ditherPaper": "#111827" } } }
        """##)
        let light = theme.tokens(dark: false).dither
        XCTAssertEqual(light.ink.hex, "#155EEF")
        XCTAssertEqual(light.paper.hex, "#F7F5EF")
        let dark = theme.tokens(dark: true).dither
        XCTAssertEqual(dark.ink.hex, "#DDEBFF")
        XCTAssertEqual(dark.paper.hex, "#111827")
    }

    func testTheLookKeysAreRead() throws {
        let theme = try parse(##"""
        { "colors": { "quoteBackground": "#EAF1FF" }, "fonts": { "interface": "Georgia" } }
        """##)
        XCTAssertEqual(theme.colors.quoteBackground?.hex, "#EAF1FF")
        XCTAssertEqual(theme.style.interfaceFont, .named("Georgia"))
    }

    /// Cards, labels, icons, the sidebar's selection and the dither are Loam's own look: a theme written when they
    /// were keys still opens, and the keys change nothing.
    func testTheRetiredLookKeysAreIgnored() throws {
        let theme = try parse(##"""
        { "sidebar": { "selection": 1 }, "icons": { "tint": "neon" }, "cards": { "style": "glass" },
          "labels": { "style": "plain" }, "decor": { "halftone": false }, "home": { "banner": false },
          "images": { "dither": "yes" } }
        """##)
        XCTAssertTrue(theme.style.isEmpty)
    }


    func testABadStyleNamesTheKey() {
        XCTAssertInvalid(##"{ "headings": { "weight": "fat" } }"##, mentions: "headings.weight")
        XCTAssertInvalid(##"{ "headings": { "sizes": 2 } }"##, mentions: "headings.sizes")
        XCTAssertInvalid(##"{ "headings": { "rules": ["h2"] } }"##, mentions: "headings.rules")
        XCTAssertInvalid(##"{ "tasks": { "checkbox": "star" } }"##, mentions: "tasks.checkbox")
        XCTAssertInvalid(##"{ "tasks": { "strikethrough": "no" } }"##, mentions: "tasks.strikethrough")
        XCTAssertInvalid(##"{ "tags": { "shape": 1 } }"##, mentions: "tags.shape")
    }

    func testMissingKeysKeepTheSystemLook() throws {
        let theme = try parse("{}", name: "Empty")
        XCTAssertEqual(theme, Theme(name: "Empty"))
        XCTAssertEqual(theme.appearance, .auto)
        XCTAssertTrue(theme.colors.isEmpty)
        XCTAssertEqual(theme.tokens(dark: false), .standard)
        XCTAssertEqual(theme.tokens(dark: true), .standard)
    }

    func testUnknownKeysAreIgnored() throws {
        let theme = try parse("""
        { "name": "Future", "gradient": [1, 2], "colors": { "accent": "#112233", "glow": 3 },
          "fonts": { "heading": "Futura" }, "editor": { "cursor": "block" }, "dark": { "shadow": true } }
        """)
        XCTAssertEqual(theme.name, "Future")
        XCTAssertEqual(theme.colors, ThemePalette(accent: ThemeColor(hex: "#112233")))
    }

    func testABadColourNamesTheKey() {
        XCTAssertInvalid(##"{ "colors": { "accent": "orange" } }"##, mentions: "colors.accent")
        XCTAssertInvalid(##"{ "dark": { "colors": { "text": "#12" } } }"##, mentions: "dark.colors.text")
        XCTAssertInvalid(##"{ "colors": { "link": 12 } }"##, mentions: "colors.link")
    }

    func testWrongKindsAreRejected() {
        XCTAssertInvalid("not json", mentions: "JSON")
        XCTAssertInvalid("[1]", mentions: "object")
        XCTAssertInvalid(##"{ "appearance": "sepia" }"##, mentions: "appearance")
        XCTAssertInvalid(##"{ "colors": "#FFFFFF" }"##, mentions: "colors")
        XCTAssertInvalid(##"{ "fonts": { "size": "big" } }"##, mentions: "fonts.size")
        XCTAssertInvalid(##"{ "fonts": { "size": true } }"##, mentions: "fonts.size")
        XCTAssertInvalid(##"{ "fonts": { "body": 3 } }"##, mentions: "fonts.body")
        XCTAssertInvalid(##"{ "editor": { "columnWidth": [] } }"##, mentions: "editor.columnWidth")
    }

    func testNullsAndAnEmptyNameAreMissingKeys() throws {
        let theme = try parse(##"{ "name": "", "colors": null, "fonts": { "size": null } }"##, name: "File")
        XCTAssertEqual(theme, Theme(name: "File"))
    }

    func testNumbersAreClampedToUsableValues() throws {
        let theme = try parse(##"{ "fonts": { "size": 2 }, "editor": { "lineHeight": 10, "columnWidth": 50 } }"##)
        XCTAssertEqual(theme.fontSize, 9)
        XCTAssertEqual(theme.lineHeight, 3)
        XCTAssertEqual(theme.columnWidth, 320)
    }

    func testFontNames() {
        XCTAssertEqual(ThemeFontFamily("SF Pro"), .system(.default))
        XCTAssertEqual(ThemeFontFamily("system"), .system(.default))
        XCTAssertEqual(ThemeFontFamily("New York"), .system(.serif))
        XCTAssertEqual(ThemeFontFamily("SF Mono"), .system(.monospaced))
        XCTAssertEqual(ThemeFontFamily("SF Pro Rounded"), .system(.rounded))
        XCTAssertEqual(ThemeFontFamily(" Georgia "), .named("Georgia"))
    }

    // MARK: Resolution

    private let twoAppearances = """
    { "appearance": "auto",
      "colors": { "accent": "#C2410C", "text": "#1F2937", "background": "#FBF7F0" },
      "dark": { "colors": { "text": "#EEEEEE", "background": "#111111" } } }
    """

    func testDarkOverridesApplyOnlyWhenDark() throws {
        let theme = try parse(twoAppearances)
        XCTAssertEqual(theme.palette(dark: false).text?.hex, "#1F2937")
        XCTAssertEqual(theme.palette(dark: false).background?.hex, "#FBF7F0")
        XCTAssertEqual(theme.palette(dark: true).text?.hex, "#EEEEEE")
        XCTAssertEqual(theme.palette(dark: true).background?.hex, "#111111")
        // Not overridden: the light colour serves both.
        XCTAssertEqual(theme.palette(dark: true).accent?.hex, "#C2410C")
    }

    func testAppearanceDecidesWhetherTheWindowIsDark() throws {
        let auto = try parse(##"{ "appearance": "auto" }"##)
        XCTAssertTrue(auto.isDark(systemIsDark: true))
        XCTAssertFalse(auto.isDark(systemIsDark: false))
        XCTAssertNil(auto.colorScheme)

        let light = try parse(##"{ "appearance": "light" }"##)
        XCTAssertFalse(light.isDark(systemIsDark: true))
        XCTAssertEqual(light.colorScheme, .light)

        let dark = try parse(##"{ "appearance": "DARK" }"##)
        XCTAssertTrue(dark.isDark(systemIsDark: false))
        XCTAssertEqual(dark.colorScheme, .dark)
    }

    func testTokensUseTheThemeAndTheSystemElsewhere() throws {
        let theme = try parse(twoAppearances.replacingOccurrences(
            of: ##""appearance": "auto","##,
            with: ##""appearance": "auto", "fonts": { "body": "New York", "size": 18 }, "editor": { "lineHeight": 1.4, "columnWidth": 800 },"##
        ))
        let light = theme.tokens(dark: false)
        XCTAssertEqual(light.text, Color(ThemeColor(hex: "#1F2937")!))
        XCTAssertEqual(light.background, Color(ThemeColor(hex: "#FBF7F0")!))
        XCTAssertEqual(light.accent, Color(ThemeColor(hex: "#C2410C")!))
        XCTAssertEqual(light.link, light.accent, "links follow the accent when not set")
        XCTAssertEqual(light.secondaryText, ThemeTokens.standard.secondaryText)
        XCTAssertEqual(light.separator, ThemeTokens.standard.separator)
        XCTAssertEqual(light.marker, ThemeTokens.standard.marker)
        XCTAssertEqual(light.codeBackground, ThemeTokens.standard.codeBackground)
        XCTAssertEqual(light.bodySize, 18)
        XCTAssertEqual(light.bodyFamily, .system(.serif))
        XCTAssertEqual(light.bodyFont, .system(size: 18, design: .serif))
        XCTAssertEqual(light.monoFont, .system(size: 17, design: .monospaced))
        XCTAssertEqual(light.lineHeight, 1.4)
        XCTAssertEqual(light.columnWidth, 800)
        XCTAssertEqual(light.spacing, ThemeTokens.standard.spacing)

        let dark = theme.tokens(dark: true)
        XCTAssertEqual(dark.text, Color(ThemeColor(hex: "#EEEEEE")!))
        XCTAssertEqual(dark.palette.background?.hex, "#111111")
    }

    func testStandardTokensAreTheCalmPage() {
        let standard = ThemeTokens.standard
        XCTAssertEqual(standard.bodySize, 16)
        XCTAssertEqual(standard.lineHeight, 1.42)
        XCTAssertEqual(standard.columnWidth, 720)
        XCTAssertEqual(standard.bodyFamily, .system(.default))
        XCTAssertEqual(standard.monoFamily, .system(.monospaced))
        XCTAssertTrue(standard.palette.isEmpty)
    }
}
