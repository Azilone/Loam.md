import AppKit
import XCTest
@testable import MarkdownEditor

/// The clip view keeps the text view as wide as the column and centres it, so that a page widening around the
/// column (a sidebar sliding) only moves the text.
@MainActor
final class EditorClipViewTests: XCTestCase {
    private func makeScrollView(width: CGFloat) -> (NSScrollView, EditorTextView) {
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: width, height: 400))
        scrollView.contentView = EditorClipView()
        let textView = EditorTextView(usingTextLayoutManager: true)
        textView.autoresizingMask = []
        textView.isVerticallyResizable = true
        textView.frame = NSRect(x: 0, y: 0, width: width, height: 400)
        scrollView.documentView = textView
        scrollView.layoutSubtreeIfNeeded()
        (scrollView.contentView as? EditorClipView)?.fitDocument()
        return (scrollView, textView)
    }

    func testTextViewKeepsItsWidthWhilePageWidens() {
        let (scrollView, textView) = makeScrollView(width: 1400)
        let wide = textView.frame.width
        scrollView.setFrameSize(NSSize(width: 1700, height: 400))
        XCTAssertEqual(textView.frame.width, wide, "a page wider than the column leaves the text view alone")
        XCTAssertLessThan(wide, 1400)
    }

    func testTextViewIsCentred() {
        let (scrollView, textView) = makeScrollView(width: 1400)
        let clip = scrollView.contentView
        let left = textView.frame.minX - clip.bounds.minX
        let right = clip.bounds.maxX - textView.frame.maxX
        XCTAssertEqual(left, right, accuracy: 1)
    }

    func testNarrowPageFitsTheWholeWidth() {
        let (_, textView) = makeScrollView(width: 300)
        XCTAssertEqual(textView.frame.width, 300, accuracy: 0.5)
    }
}
