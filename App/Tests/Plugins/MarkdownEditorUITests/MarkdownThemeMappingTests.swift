import AppKit
import MarkdownEditor
import PluginKitUI
import XCTest
@testable import MarkdownEditorUI

/// The app's theme tokens become the editor's fonts, colours, line height and column.
final class MarkdownThemeMappingTests: XCTestCase {
    func testTheStandardTokensGiveTodaysEditor() {
        XCTAssertEqual(MarkdownTheme(tokens: .standard), MarkdownTheme())
    }

    func testAThemeSetsTheEditorsLook() throws {
        let theme = try Theme.parse(Data("""
        { "colors": { "accent": "#C2410C", "text": "#1F2937", "secondaryText": "#6B7280", "background": "#FBF7F0",
                      "codeBackground": "#F2EDE4", "marker": "#B8B0A3" },
          "fonts": { "body": "New York", "mono": "Menlo", "size": 18 },
          "editor": { "lineHeight": 1.4, "columnWidth": 640 } }
        """.utf8), fallbackName: "Paper")
        let editor = MarkdownTheme(tokens: theme.tokens(dark: false))
        XCTAssertEqual(editor.fontSize, 18)
        XCTAssertEqual(editor.lineHeightMultiple, 1.4)
        XCTAssertEqual(editor.columnWidth, 640)
        XCTAssertEqual(editor.bodyFamily, .system(.serif))
        XCTAssertEqual(editor.monoFamily, .named("Menlo"))
        XCTAssertEqual(editor.textColor, NSColor(srgbRed: 0x1F / 255, green: 0x29 / 255, blue: 0x37 / 255, alpha: 1))
        XCTAssertEqual(editor.backgroundColor, NSColor(srgbRed: 0xFB / 255, green: 0xF7 / 255, blue: 0xF0 / 255, alpha: 1))
        XCTAssertEqual(editor.accentColor, NSColor(srgbRed: 0xC2 / 255, green: 0x41 / 255, blue: 0x0C / 255, alpha: 1))
        XCTAssertEqual(editor.linkColor, editor.accentColor, "links follow the accent when not set")
        XCTAssertEqual(editor.secondaryTextColor.hexForTest, "#6B7280")
        XCTAssertEqual(editor.codeBackgroundColor.hexForTest, "#F2EDE4")
        XCTAssertEqual(editor.markerColor.hexForTest, "#B8B0A3")
    }

    func testAThemeSetsHeadingsTasksAndTags() throws {
        let theme = try Theme.parse(Data("""
        { "colors": { "heading": "#111111", "tagText": "#1E7D58", "tagBackground": "#C3E1D3", "checkbox": "#2F7DF6",
                      "checkboxBorder": "#808080", "quoteBar": "#F83366", "highlight": "#FCEBAF", "separator": "#D2D2D2" },
          "headings": { "font": "New York", "weight": "semibold", "sizes": [1.75, 1.5], "rules": [2, 4] },
          "tasks": { "checkbox": "square", "strikethrough": false },
          "tags": { "shape": "capsule" } }
        """.utf8), fallbackName: "Things")
        let editor = MarkdownTheme(tokens: theme.tokens(dark: false))
        XCTAssertEqual(editor.headingColor?.hexForTest, "#111111")
        XCTAssertEqual(editor.headingFamily, .system(.serif))
        XCTAssertEqual(editor.headingWeight, .semibold)
        XCTAssertEqual(editor.headingScales, [1.75, 1.5])
        XCTAssertEqual(editor.headingRules, [2, 4])
        XCTAssertEqual(editor.tagTextColor?.hexForTest, "#1E7D58")
        XCTAssertEqual(editor.tagBackgroundColor?.hexForTest, "#C3E1D3")
        XCTAssertEqual(editor.checkboxColor?.hexForTest, "#2F7DF6")
        XCTAssertEqual(editor.checkboxBorderColor?.hexForTest, "#808080")
        XCTAssertEqual(editor.quoteBarColor?.hexForTest, "#F83366")
        XCTAssertEqual(editor.highlightColor?.hexForTest, "#FCEBAF")
        XCTAssertEqual(editor.ruleColor?.hexForTest, "#D2D2D2")
        XCTAssertTrue(editor.squareCheckboxes)
        XCTAssertFalse(editor.strikesDoneTasks)
        XCTAssertTrue(editor.capsuleTags)
    }

    func testColoursTheThemeLeavesOutStaySystemColours() throws {
        let theme = try Theme.parse(Data(##"{ "colors": { "link": "#0000FF" } }"##.utf8), fallbackName: "Links")
        let editor = MarkdownTheme(tokens: theme.tokens(dark: true))
        XCTAssertEqual(editor.linkColor.hexForTest, "#0000FF")
        XCTAssertEqual(editor.textColor, MarkdownTheme.pageTextColor)
        XCTAssertEqual(editor.accentColor, .controlAccentColor)
        XCTAssertEqual(editor.backgroundColor, .textBackgroundColor)
    }
}

extension NSColor {
    var hexForTest: String {
        guard let rgb = usingColorSpace(.sRGB) else { return "?" }
        func byte(_ value: CGFloat) -> String { String(format: "%02X", Int((value * 255).rounded())) }
        return "#" + byte(rgb.redComponent) + byte(rgb.greenComponent) + byte(rgb.blueComponent)
    }
}
