import Foundation
import XCTest

/// docs/UI-RULES.md, checked in the sources: the app's text follows the theme's interface font and the type scale,
/// and status colours come from the theme. A failure names the file and the line to move onto the design system.
final class UIRulesTests: XCTestCase {
    /// `App/Sources`, from this file's place.
    private var sources: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources")
    }

    /// Files that draw outside the interface on purpose: the scales themselves, the editor's text (the theme's body
    /// and heading fonts), and illustrations.
    private let exempt = [
        "PluginKitUI/ThemeTokens.swift",
        "PluginKitUI/DesignSystem.swift",
        "PluginKitUI/PrintIllustration.swift",
        "MarkdownEditor/",
        "Plugins/MarkdownEditorUI/",
        "Plugins/IntroUI/",
    ]

    private let rules: [(name: String, pattern: String)] = [
        ("a system font ignores the theme's interface font: use .ui(.body)", #"\.font\(\.system\(size:"#),
        ("a semantic font ignores the theme's interface font: use .ui(.body)",
         #"\.font\(\.(headline|subheadline|callout|caption|caption2|footnote|title|title2|title3|body|largeTitle)\)"#),
        ("a bare red is not a theme colour: use theme.danger", #"(Color\.red\b|\(\.red\)|: \.red\b)"#),
    ]

    func testViewsFollowTheUIRules() throws {
        let files = try XCTUnwrap(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        var failures: [String] = []
        for case let url as URL in files where url.pathExtension == "swift" {
            let relative = url.path.replacingOccurrences(of: sources.path + "/", with: "")
            guard !exempt.contains(where: { relative.contains($0) }) else { continue }
            let lines = try String(contentsOf: url, encoding: .utf8).components(separatedBy: "\n")
            for (index, line) in lines.enumerated() {
                let code = line.trimmingCharacters(in: .whitespaces)
                // Code is set in a mono face, and an illustration may say why it draws outside the theme.
                guard !code.hasPrefix("//"), !code.contains("design: .monospaced"),
                      !code.contains("// ui-rules:") else { continue }
                for rule in rules where code.range(of: rule.pattern, options: .regularExpression) != nil {
                    failures.append("\(relative):\(index + 1): \(rule.name)")
                }
            }
        }
        XCTAssertTrue(failures.isEmpty, "\(failures.count) views break docs/UI-RULES.md:\n" + failures.joined(separator: "\n"))
    }
}
