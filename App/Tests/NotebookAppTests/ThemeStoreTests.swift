import AppKit
import BuiltinPlugins
import BuiltinUIPlugins
import PluginKit
import PluginKitUI
import SwiftUI
import XCTest
@testable import NotebookApp

/// Themes from `.loam/themes/`: the one the config names is used (Dither Green when it names none), a broken one falls back to the system look, and
/// choosing one writes the config.
@MainActor
final class ThemeStoreTests: ShellTestCase {
    private let paper = """
    { "name": "Paper", "appearance": "light",
      "colors": { "accent": "#C2410C", "text": "#1F2937", "background": "#FBF7F0" },
      "fonts": { "body": "New York" }, "editor": { "columnWidth": 600 } }
    """

    private func config() throws -> [String: Any] {
        let data = try Data(contentsOf: root.appendingPathComponent(".loam/config.json"))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testWithoutAThemeDitherGreenIsUsed() throws {
        let session = try openSession()
        XCTAssertEqual(session.themes.selectedName, "dither-green")
        XCTAssertEqual(session.themes.current?.name, "Dither Green")
        XCTAssertNil(session.themes.error)
        XCTAssertEqual(session.themes.tokens(systemIsDark: true).palette.background?.hex, "#FCFBF8", "light first")
        XCTAssertEqual(session.themes.colorScheme, .light, "the design is light first")
    }

    func testSystemInTheConfigIsTheDefaultTheme() throws {
        try write(".loam/config.json", ##"{ "theme": "system" }"##)
        let session = try openSession()
        XCTAssertEqual(session.themes.current?.name, "Dither Green")
        XCTAssertNil(session.themes.error)
        XCTAssertEqual(session.themes.colorScheme, .light, "the design is light first")
    }

    func testTheConfiguredThemeIsUsed() throws {
        try write(".loam/themes/Paper.json", paper)
        try write(".loam/themes/Other.json", "{}")
        try write(".loam/config.json", ##"{ "theme": "Paper", "future": { "kept": true } }"##)
        let session = try openSession()
        XCTAssertEqual(session.themes.entries.map(\.id), ["Other", "Paper"])
        XCTAssertEqual(session.themes.selectedName, "Paper")
        XCTAssertEqual(session.themes.current?.name, "Paper")
        XCTAssertNil(session.themes.error)
        XCTAssertEqual(session.themes.colorScheme, .light)
        let tokens = session.themes.tokens(systemIsDark: true)
        XCTAssertEqual(tokens.palette.background?.hex, "#FBF7F0", "light is forced, whatever the system")
        XCTAssertEqual(tokens.columnWidth, 600)
    }

    func testTheNameMatchesIgnoringCase() throws {
        try write(".loam/themes/Paper.json", paper)
        try write(".loam/config.json", ##"{ "theme": "paper" }"##)
        XCTAssertEqual(try openSession().themes.current?.name, "Paper")
    }

    func testAMissingThemeFallsBackWithAnError() throws {
        try write(".loam/config.json", ##"{ "theme": "Gone" }"##)
        let themes = try openSession().themes
        XCTAssertNil(themes.current)
        XCTAssertEqual(themes.tokens(systemIsDark: false), .standard)
        XCTAssertTrue(themes.error?.contains("Gone") == true, themes.error ?? "no error")
    }

    func testABrokenThemeFallsBackWithAnError() throws {
        try write(".loam/themes/Broken.json", ##"{ "colors": { "accent": "orange" } }"##)
        try write(".loam/themes/NotJSON.json", "{")
        try write(".loam/config.json", ##"{ "theme": "Broken" }"##)
        let themes = try openSession().themes
        XCTAssertNil(themes.current)
        XCTAssertEqual(themes.tokens(systemIsDark: false), .standard)
        XCTAssertTrue(themes.error?.contains("colors.accent") == true, themes.error ?? "no error")
        XCTAssertEqual(themes.entries.filter { $0.error != nil }.map(\.id), ["Broken", "NotJSON"])
    }

    func testAThemeKeyOfTheWrongKindFallsBack() throws {
        try write(".loam/config.json", ##"{ "theme": 3 }"##)
        let themes = try openSession().themes
        XCTAssertNil(themes.current)
        XCTAssertNotNil(themes.error)
    }

    func testSelectingWritesTheConfigAndKeepsOtherKeys() throws {
        try write(".loam/themes/Paper.json", paper)
        try write(".loam/config.json", ##"{ "future": { "kept": true }, "plugins": { "x": { "enabled": false } } }"##)
        let themes = try openSession().themes
        try themes.select("Paper")
        XCTAssertEqual(try config()["theme"] as? String, "Paper")
        XCTAssertEqual((try config()["future"] as? [String: Bool])?["kept"], true)
        XCTAssertNotNil(try config()["plugins"])
        XCTAssertEqual(themes.current?.name, "Paper")

        try themes.select(nil)
        XCTAssertEqual(try config()["theme"] as? String, ThemeStore.defaultName)
        XCTAssertEqual(themes.current?.name, "Dither Green")
    }

    func testAThemeEditedOnDiskAppliesOnTheNextVaultChange() throws {
        let session = try openSession()
        try write(".loam/themes/Paper.json", paper)
        try write(".loam/config.json", ##"{ "theme": "Paper" }"##)
        session.vaultDidChange()
        XCTAssertEqual(session.themes.current?.colors.accent?.hex, "#C2410C")

        try write(".loam/themes/Paper.json", paper.replacingOccurrences(of: "#C2410C", with: "#0000FF"))
        session.vaultDidChange()
        XCTAssertEqual(session.themes.current?.colors.accent?.hex, "#0000FF")
    }

    func testTheAppearanceAndAccentOfSettingsGoOverTheTheme() throws {
        try write(".loam/themes/Paper.json", paper)
        try write(".loam/config.json", ##"{ "theme": "Paper" }"##)
        let themes = try openSession().themes
        XCTAssertEqual(themes.colorScheme, .light)

        try themes.setAppearance(.dark)
        try themes.setAccent(ThemeColor(hex: "#3FB8A0"))
        XCTAssertEqual(try config()["appearance"] as? String, "dark")
        XCTAssertEqual(try config()["accent"] as? String, "#3FB8A0")
        XCTAssertEqual(try config()["theme"] as? String, "Paper", "the theme stays chosen")
        XCTAssertEqual(themes.colorScheme, .light, "a theme made for light keeps it: its colours are drawn for light")
        let tokens = themes.tokens(systemIsDark: false)
        XCTAssertEqual(tokens.palette.accent?.hex, "#3FB8A0")
        XCTAssertEqual(tokens.palette.background?.hex, "#FBF7F0", "the theme's other colours stay")

        try themes.setAppearance(nil)
        try themes.setAccent(nil)
        XCTAssertNil(try config()["appearance"])
        XCTAssertNil(try config()["accent"])
        XCTAssertEqual(themes.colorScheme, .light)
        XCTAssertEqual(themes.tokens(systemIsDark: false).palette.accent?.hex, "#C2410C")
    }

    func testTheAppearanceOfSettingsPicksTheSideOfAThemeMadeForBoth() throws {
        try write(".loam/config.json", ##"{ "theme": "catppuccin" }"##)
        let themes = try openSession().themes
        XCTAssertEqual(themes.colorScheme, .light)
        try themes.setAppearance(.dark)
        XCTAssertEqual(themes.colorScheme, .dark)
        XCTAssertEqual(themes.tokens(systemIsDark: false).palette.background?.hex, "#1E1E2E", "its dark colours")
    }

    func testWithTheDefaultThemeTheAppearanceOfSettingsStillApplies() throws {
        try write(".loam/config.json", ##"{ "theme": "system", "appearance": "light", "accent": "not a colour" }"##)
        let themes = try openSession().themes
        XCTAssertEqual(themes.colorScheme, .light)
        XCTAssertNil(themes.accent, "an unreadable accent is ignored")

        try themes.setAppearance(.auto)
        XCTAssertNil(themes.colorScheme, "Auto follows macOS")
    }

    func testTheExampleThemesAreWrittenAndParse() async throws {
        let session = try openSession()
        let answer = try await session.run("themes.install-examples")
        XCTAssertTrue(answer.contains(".loam/themes/Paper.json") && answer.contains(".loam/themes/Night.json"), answer)
        XCTAssertEqual(session.themes.entries.map(\.id), ["Night", "Paper"])
        XCTAssertTrue(session.themes.entries.allSatisfy { $0.error == nil })

        let paper = try XCTUnwrap(session.themes.entries.first { $0.id == "Paper" }?.theme)
        XCTAssertEqual(paper.appearance, .auto)
        XCTAssertEqual(Set(ThemePalette.keys.filter { paper.colors[$0] != nil }), Set(ThemePalette.keys), "every colour")
        XCTAssertEqual(Set(ThemePalette.keys.filter { paper.darkColors[$0] != nil }), Set(ThemePalette.keys))
        XCTAssertNotNil(paper.bodyFont)
        XCTAssertNotNil(paper.lineHeight)
        XCTAssertNotNil(paper.columnWidth)
        let night = try XCTUnwrap(session.themes.entries.first { $0.id == "Night" }?.theme)
        XCTAssertEqual(night.appearance, .dark)

        // Existing files are the user's: running it again writes nothing.
        try write(".loam/themes/Paper.json", "{ \"name\": \"Mine\" }")
        let again = try await session.run("themes.install-examples")
        XCTAssertFalse(again.contains("Wrote"), again)
        XCTAssertEqual(try read(".loam/themes/Paper.json"), "{ \"name\": \"Mine\" }")
    }

    func testEveryBuiltInThemeSetsEveryColour() {
        for entry in BuiltInThemes.all {
            guard let theme = entry.theme else { return XCTFail("\(entry.id): \(entry.error ?? "")") }
            let dark = theme.appearance == .dark ? theme.colors : theme.colors.merging(theme.darkColors)
            for palette in [theme.colors, dark] {
                XCTAssertEqual(Set(ThemePalette.keys.filter { palette[$0] != nil }), Set(ThemePalette.keys), entry.id)
            }
        }
    }

    func testBuiltInThemesHaveTheirOwnLook() throws {
        let claude = try XCTUnwrap(BuiltInThemes.all.first { $0.id == "absolutely" }?.theme)
        XCTAssertEqual(claude.bodyFont, .named("Georgia"))
        XCTAssertEqual(claude.style.letterSpacing, -0.1)
        XCTAssertEqual(claude.style.paragraphSpacing, 0.15)
        XCTAssertEqual(claude.style.headingLetterSpacing, -0.3)
        XCTAssertNotNil(claude.colors.sidebar, "the look keeps the colours")
    }

    func testThingsShipsWithItsWholeLook() throws {
        XCTAssertNil(BuiltInThemes.things.error)
        let things = try XCTUnwrap(BuiltInThemes.things.theme)
        XCTAssertEqual(things.name, "Things")
        XCTAssertEqual(Set(ThemePalette.keys.filter { things.colors[$0] != nil }), Set(ThemePalette.keys), "every colour")
        XCTAssertEqual(Set(ThemePalette.keys.filter { things.darkColors[$0] != nil }), Set(ThemePalette.keys))
        XCTAssertEqual(things.style.checkbox, .square)
        XCTAssertEqual(things.style.tagShape, .capsule)
        XCTAssertEqual(things.style.headingRules, [2, 4])
        XCTAssertTrue(BuiltInThemes.all.contains { $0.id == "things" })
    }

    func testThemesUseWritesTheConfig() async throws {
        try write(".loam/themes/Paper.json", paper)
        let session = try openSession()
        let answer = try await session.run("themes.use", ["name": "Paper"])
        XCTAssertEqual(answer, "Using Paper.")
        XCTAssertEqual(try config()["theme"] as? String, "Paper")
        _ = try await session.run("themes.use", ["name": "system"])
        XCTAssertEqual(try config()["theme"] as? String, ThemeStore.defaultName)
        XCTAssertEqual(session.themes.current?.name, "Dither Green")
    }

    // MARK: Rendering

    private var windows: [NSWindow] = []

    override func tearDown() async throws {
        for window in windows { window.close() }
        windows = []
        try await super.tearDown()
    }

    private func render(_ session: ShellSession) -> NSView {
        let size = CGSize(width: 1000, height: 700)
        let hosting = NSHostingView(rootView: ShellWindow(session: session))
        hosting.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(
            contentRect: CGRect(origin: CGPoint(x: -10_000, y: -10_000), size: size),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        windows.append(window)
        return hosting
    }

    private func editor(in view: NSView) -> NSTextView? {
        if let textView = view as? NSTextView, textView.isEditable { return textView }
        return view.subviews.lazy.compactMap { self.editor(in: $0) }.first
    }

    private func hex(_ color: Any?) -> String? {
        guard let rgb = (color as? NSColor)?.usingColorSpace(.sRGB) else { return nil }
        func byte(_ value: CGFloat) -> String { String(format: "%02X", Int((value * 255).rounded())) }
        return "#" + byte(rgb.redComponent) + byte(rgb.greenComponent) + byte(rgb.blueComponent)
    }

    func testTheEditorInTheWindowUsesTheTheme() throws {
        try write("Note.md", "# Note\n\nText.")
        try write(".loam/themes/Paper.json", paper)
        try write(".loam/config.json", ##"{ "theme": "Paper" }"##)
        let session = try openSession(logic: builtinPlugins, ui: builtinUIPlugins)
        session.workspace.open(.file("Note.md"), placement: .replace)

        let textView = try XCTUnwrap(editor(in: render(session)))
        XCTAssertEqual(textView.string, "Text.\n", "the page: its `# Note` is the title")
        let storage = try XCTUnwrap(textView.textStorage)
        XCTAssertEqual(hex(storage.attribute(.foregroundColor, at: 1, effectiveRange: nil)), "#1F2937")
        XCTAssertEqual(hex(textView.enclosingScrollView?.backgroundColor), "#FBF7F0")
        XCTAssertEqual(hex(textView.insertionPointColor), "#C2410C")
    }

    private func session_write_night() throws {
        let night = try XCTUnwrap(ThemeStore.examples.first { $0.name == "Night" })
        try write(".loam/themes/Night.json", night.json)
        try write(".loam/config.json", ##"{ "theme": "Night" }"##)
    }

    func testChoosingAThemeRestylesTheOpenEditor() throws {
        try write("Note.md", "Text.")
        try write(".loam/themes/Paper.json", paper)
        try session_write_night()
        let session = try openSession(logic: builtinPlugins, ui: builtinUIPlugins)
        session.workspace.open(.file("Note.md"), placement: .replace)
        let view = render(session)
        let textView = try XCTUnwrap(editor(in: view))
        let standardText = hex(textView.textStorage?.attribute(.foregroundColor, at: 0, effectiveRange: nil))
        XCTAssertEqual(standardText, "#D8DEE9", "Night's page text")

        try session.themes.select("Paper")
        // SwiftUI applies the change on a later turn of the run loop.
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline,
              hex(textView.textStorage?.attribute(.foregroundColor, at: 0, effectiveRange: nil)) != "#1F2937" {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            view.layoutSubtreeIfNeeded()
        }
        XCTAssertEqual(hex(textView.textStorage?.attribute(.foregroundColor, at: 0, effectiveRange: nil)), "#1F2937")
    }

    func testTheAppearanceTabRendersEveryTheme() throws {
        try write(".loam/themes/Paper.json", paper)
        try write(".loam/themes/Broken.json", "{")
        try write(".loam/config.json", ##"{ "theme": "Broken" }"##)
        let session = try openSession()
        let hosting = NSHostingView(rootView: AppearancePane(themes: session.themes))
        hosting.frame = CGRect(x: 0, y: 0, width: 640, height: 480)
        hosting.layoutSubtreeIfNeeded()
        XCTAssertEqual(session.themes.entries.count, 2)
        XCTAssertNotNil(session.themes.error)
    }
}
