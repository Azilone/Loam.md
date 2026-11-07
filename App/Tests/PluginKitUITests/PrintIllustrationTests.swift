import AppKit
import SwiftUI
import XCTest
@testable import PluginKitUI

/// Any SF Symbol has a picture: Loam's own, a plugin's, or the symbol inked on a stippled tile.
@MainActor
final class PrintIllustrationTests: XCTestCase {
    func testASymbolWithNoDrawingOfItsOwnStillDrawsAPicture() throws {
        let pixels = try inked(PrintIllustration(symbol: "star"))
        XCTAssertGreaterThan(pixels, 400, "the tile and the symbol are drawn")
    }

    func testAPluginsDrawingIsUsedForItsSymbol() throws {
        PrintIllustration.register("loam.test.square") { context, ink in
            context.fill(Path(CGRect(x: 0, y: 0, width: 100, height: 100)), with: .color(ink.accent))
        }
        let registered = try inked(PrintIllustration(symbol: "loam.test.square"))
        let tile = try inked(PrintIllustration(symbol: "star"))
        XCTAssertGreaterThan(registered, tile, "the plugin's full square covers more than the tile")
    }

    /// The number of pixels that are not transparent in `view` drawn at 100 x 100.
    private func inked(_ view: some View) throws -> Int {
        let renderer = ImageRenderer(content: view.frame(width: 100, height: 100).environment(\.themeTokens, .standard))
        renderer.scale = 1
        let image = try XCTUnwrap(renderer.cgImage)
        let bitmap = NSBitmapImageRep(cgImage: image)
        var count = 0
        for x in 0..<bitmap.pixelsWide {
            for y in 0..<bitmap.pixelsHigh where (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.1 {
                count += 1
            }
        }
        return count
    }
}
