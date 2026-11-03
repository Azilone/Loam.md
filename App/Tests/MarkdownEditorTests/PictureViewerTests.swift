import AppKit
import XCTest
@testable import MarkdownEditor

/// The diagram viewer: it fits the picture, zooms by steps within its limits, and closes on Escape.
@MainActor
final class PictureViewerTests: XCTestCase {
    private func viewer(picture: NSSize, room: NSSize = NSSize(width: 800, height: 600)) -> (PictureViewer, NSView) {
        let host = NSView(frame: NSRect(origin: .zero, size: room))
        let viewer = PictureViewer(image: NSImage(size: picture))
        viewer.show(over: host)
        return (viewer, host)
    }

    func testASmallDiagramGrowsToFitAndALargeOneShrinks() {
        let (small, _) = viewer(picture: NSSize(width: 200, height: 100))
        XCTAssertEqual(small.fittedMagnification, PictureViewer.maxFit, accuracy: 0.001)
        let (large, _) = viewer(picture: NSSize(width: 2000, height: 1000))
        XCTAssertLessThan(large.fittedMagnification, 1)
        XCTAssertEqual(large.magnification, large.fittedMagnification, accuracy: 0.001, "it opens fitted")
    }

    func testZoomStaysWithinItsLimits() {
        let (viewer, _) = viewer(picture: NSSize(width: 400, height: 300))
        for _ in 0..<40 { viewer.zoomIn() }
        XCTAssertLessThanOrEqual(viewer.magnification, PictureViewer.maxMagnification + 0.001)
        for _ in 0..<40 { viewer.zoomOut() }
        XCTAssertGreaterThanOrEqual(viewer.magnification, PictureViewer.minMagnification - 0.001)
    }

    func testEscapeCloses() {
        let (viewer, host) = viewer(picture: NSSize(width: 400, height: 300))
        var closed = false
        viewer.onClose = { closed = true }
        viewer.cancelOperation(nil)
        XCTAssertTrue(closed)
        XCTAssertNotNil(host.subviews.first, "it fades before leaving")
    }

    func testTheCodePageWritesTheCodeBackWhenItCloses() {
        let (viewer, _) = viewer(picture: NSSize(width: 400, height: 300))
        var written: [String] = []
        viewer.codeEditing = .init(code: "flowchart LR\n  A --> B", render: { _ in nil }, commit: { written.append($0) })
        viewer.editCode()
        XCTAssertTrue(viewer.isEditingCode)
        let code = viewer.subviews.compactMap { ($0 as? NSScrollView)?.documentView as? NSTextView }.first
        XCTAssertEqual(code?.string, "flowchart LR\n  A --> B")
        code?.string = "flowchart LR\n  A --> C"
        viewer.close()
        XCTAssertEqual(written, ["flowchart LR\n  A --> C"])
    }
}
