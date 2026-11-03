import AppKit
import XCTest
@testable import PluginKitUI

final class ImageDitherTests: XCTestCase {
    private let style = DitherStyle(ink: ThemeColor(hex: "#155EEF")!, paper: ThemeColor(hex: "#F7F5EF")!, dotSize: 2)

    /// A left-to-right grey ramp, `width` x `height` pixels, opaque.
    private func ramp(width: Int, height: Int) -> CGImage {
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        for x in 0..<width {
            let grey = CGFloat(x) / CGFloat(width - 1)
            context.setFillColor(red: grey, green: grey, blue: grey, alpha: 1)
            context.fill(CGRect(x: x, y: 0, width: 1, height: height))
        }
        return context.makeImage()!
    }

    /// Each pixel of `image` as `#RRGGBB`, row by row, read from its own bytes (red, green, blue, alpha).
    private func pixels(of image: CGImage) -> [String] {
        let data = image.dataProvider!.data! as Data
        return (0..<(image.width * image.height)).map { index in
            let offset = (index / image.width) * image.bytesPerRow + (index % image.width) * 4
            return String(format: "#%02X%02X%02X", data[offset], data[offset + 1], data[offset + 2])
        }
    }

    func testAPictureBecomesInkAndPaperOnly() throws {
        let result = try XCTUnwrap(ImageDither.dither(ramp(width: 200, height: 100), pointSize: CGSize(width: 100, height: 50), style: style))
        // 50 dots across, 4 pixels per dot (2 points, 2 pixels per point).
        XCTAssertEqual(result.width, 200)
        XCTAssertEqual(result.height, 100)
        XCTAssertEqual(Set(pixels(of: result)), ["#155EEF", "#F7F5EF"])
    }

    func testDarkPartsGetMoreInk() throws {
        let result = try XCTUnwrap(ImageDither.dither(ramp(width: 200, height: 100), pointSize: CGSize(width: 100, height: 50), style: style))
        let all = pixels(of: result)
        func inkShare(_ columns: Range<Int>) -> Double {
            let picked = all.indices.filter { columns.contains($0 % result.width) }
            return Double(picked.filter { all[$0] == "#155EEF" }.count) / Double(picked.count)
        }
        XCTAssertGreaterThan(inkShare(0..<40), 0.6)
        XCTAssertLessThan(inkShare(160..<200), 0.1)
    }

    func testOnADarkPageTheLightPartsGetTheInk() throws {
        let dark = DitherStyle(ink: ThemeColor(hex: "#6E9BFF")!, paper: ThemeColor(hex: "#111827")!, dotSize: 2)
        let result = try XCTUnwrap(ImageDither.dither(ramp(width: 200, height: 100), pointSize: CGSize(width: 100, height: 50), style: dark))
        let all = pixels(of: result)
        let left = all.indices.filter { $0 % result.width < 40 }
        let right = all.indices.filter { $0 % result.width >= 160 }
        XCTAssertLessThan(Double(left.filter { all[$0] == "#6E9BFF" }.count) / Double(left.count), 0.1)
        XCTAssertGreaterThan(Double(right.filter { all[$0] == "#6E9BFF" }.count) / Double(right.count), 0.6)
    }

    @MainActor
    func testADitheredPictureKeepsItsSizeAndIsMadeOnce() {
        let image = NSImage(cgImage: ramp(width: 64, height: 32), size: NSSize(width: 64, height: 32))
        let first = ImageDither.dithered(image, style: style)
        XCTAssertEqual(first.size, image.size)
        XCTAssertTrue(first === ImageDither.dithered(image, style: style))
        var other = style
        other.dotSize = 4
        XCTAssertFalse(first === ImageDither.dithered(image, style: other))
    }

    func testAHalftoneCloudFadesOutInsideItsFrame() {
        let size = CGSize(width: 210, height: 130)
        let dots = HalftoneCloud.dots(in: size, corner: .bottomLeading, step: 3, seed: 0)
        XCTAssertFalse(dots.isEmpty)
        // Dense in its corner, nothing along the far sides: no straight edge.
        XCTAssertTrue(dots.contains { $0.minX < 12 && $0.maxY > size.height - 12 })
        XCTAssertFalse(dots.contains { $0.maxX > size.width - 6 || $0.minY < 6 })
    }
}
