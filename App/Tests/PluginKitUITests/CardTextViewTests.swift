import AppKit
@testable import PluginKitUI
import XCTest

/// A card's text drawn into its layer: at once the first time, off the main thread when only its width changes, the
/// last drawing shown meanwhile.
@MainActor
final class CardTextViewTests: XCTestCase {
    private var window: NSWindow?

    override func tearDown() async throws {
        window?.close()
        window = nil
        try await super.tearDown()
    }

    private func textView() -> CardTextView {
        let window = NSWindow(contentRect: CGRect(x: -10_000, y: -10_000, width: 400, height: 300),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.orderFrontRegardless()
        self.window = window
        let view = CardTextView(frame: CGRect(x: 0, y: 0, width: 200, height: 40))
        view.attributed = NSAttributedString(string: "A title long enough to wrap on two lines", attributes: [
            .font: NSFont.systemFont(ofSize: 15), .foregroundColor: NSColor.black,
        ])
        window.contentView?.addSubview(view)
        return view
    }

    private func display(_ view: CardTextView) {
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        view.updateLayer()
    }

    /// The number of pixels with ink in the layer's image, and its width in pixels.
    private func ink(_ view: CardTextView) throws -> (pixels: Int, width: Int) {
        let contents = try XCTUnwrap(view.layer?.contents, "the layer shows a drawing")
        let image = contents as! CGImage
        let data = try XCTUnwrap(image.dataProvider?.data) as Data
        return (data.reduce(0) { $0 + ($1 > 0 ? 1 : 0) }, image.width)
    }

    func testTheFirstDrawingIsMadeAtOnce() throws {
        let view = textView()
        display(view)
        let drawn = try ink(view)
        XCTAssertGreaterThan(drawn.pixels, 100, "the text is drawn")
        XCTAssertEqual(drawn.width, 400)
        XCTAssertFalse(view.isDrawingInBackground)
    }

    func testAWidthChangeIsDrawnOffTheMainThreadThenShown() throws {
        let view = textView()
        display(view)
        view.frame.size.width = 150
        display(view)
        XCTAssertTrue(view.isDrawingInBackground, "the new width is drawn in the background")
        XCTAssertEqual(try ink(view).width, 400, "the last drawing stays meanwhile")
        let deadline = Date(timeIntervalSinceNow: 5)
        while view.isDrawingInBackground, Date() < deadline {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
        }
        display(view)
        let drawn = try ink(view)
        XCTAssertEqual(drawn.width, 300, "the drawing at the new width is shown")
        XCTAssertGreaterThan(drawn.pixels, 100, "with its text")
        XCTAssertEqual(view.layer?.contentsGravity, view.layer?.contentsAreFlipped() == true ? .bottomLeft : .topLeft)
    }
}
