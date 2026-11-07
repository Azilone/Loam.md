import AppKit
import PluginKitUI
import XCTest

final class SymbolsTests: XCTestCase {
    /// SF Symbols and Loam's own names both count as symbols; anything else does not.
    func testExists() {
        XCTAssertTrue(LoamSymbol.exists("doc.text"))
        XCTAssertTrue(LoamSymbol.exists(LoamSymbol.mindmap))
        XCTAssertFalse(LoamSymbol.exists("loam.nothing"))
        XCTAssertFalse(LoamSymbol.exists("no.such.symbol"))
    }

    /// Without the app's catalog (the test runner) a Loam symbol still shows, as its SF Symbol stand-in.
    func testFallsBackWithoutTheCatalog() {
        XCTAssertNotNil(NSImage.symbol(LoamSymbol.mindmap, accessibilityDescription: nil))
        XCTAssertNotNil(NSImage.symbol("doc.text", accessibilityDescription: nil))
        XCTAssertNil(NSImage.symbol("loam.nothing", accessibilityDescription: nil))
    }

    /// The symbol set the build compiles is in place and holds the three weights SF Symbols interpolates between.
    func testMindmapTemplate() throws {
        let svg = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/Symbols.xcassets/loam.mindmap.symbolset/loam.mindmap.svg")
        let text = try String(contentsOf: svg, encoding: .utf8)
        for weight in ["Ultralight-M", "Regular-M", "Black-M"] { XCTAssertTrue(text.contains("id=\"\(weight)\"")) }
    }
}
