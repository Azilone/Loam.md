@testable import PluginKitUI
import XCTest

@MainActor
final class SidebarGlyphTests: XCTestCase {
    static let symbols = ["magnifyingglass", "doc.on.doc", "checkmark.circle", "square.stack.3d.up", "calendar", "flame",
                          "waveform", "point.3.connected.trianglepath.dotted", "rectangle.3.group", "scribble.variable",
                          LoamSymbol.mindmap, "paperclip", "star", "clock", "doc.text", "ellipsis", "gearshape", "trash",
                          "arrow.triangle.2.circlepath", "sidebar.leading", "plus", "tray", "loam.vault"]

    func testEveryGlyphMovesAsFarAsItsGainSays() throws {
        for symbol in Self.symbols {
            let glyph = try XCTUnwrap(SidebarGlyph.named(for: symbol), symbol)
            let travel = glyph.measuredTravel
            // The waveform, the check and the scribble light or draw instead of moving.
            if travel < 0.01 { continue }
            XCTAssertEqual(travel, SidebarGlyph.travel * glyph.gain, accuracy: 0.08, symbol)
        }
    }

    func testASymbolWithoutAGlyphKeepsItsSFSymbol() {
        XCTAssertNil(SidebarGlyph.named(for: "bolt"))
        XCTAssertNotNil(SidebarGlyph.named(for: "star.fill"))
    }
}
