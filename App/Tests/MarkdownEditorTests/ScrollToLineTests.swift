import AppKit
import PluginKitUI
import XCTest
@testable import MarkdownEditor

/// `scroll(toLine:)`, which the outline and a `[[Note#Heading]]` link use: the line of the note comes to the top.
@MainActor
final class ScrollToLineTests: XCTestCase {
    func testALineOfTheNoteComesToTheTopOfTheBlockPage() async throws {
        Motion.reduceMotionOverride = true
        defer { Motion.reduceMotionOverride = nil }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 800, height: 400))
        let textView = EditorTextView(usingTextLayoutManager: true)
        textView.isVerticallyResizable = true
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        scrollView.documentView = textView
        window.contentView!.addSubview(scrollView)
        let controller = EditorController()
        controller.attach(textView)
        // A frontmatter takes the first lines of the file, not of the page.
        let text = "---\nstatus: x\n---\n" + (1...60).map { "Paragraph \($0)" }.joined(separator: "\n\n") + "\n\n## Target\n\nLast\n"
        controller.show(EditorContent(id: 1, text: text, initialState: EditorViewState(caret: 0, scrollY: 0)))
        for _ in 0..<20 { await Task.yield() }
        controller.scroll(toLine: 124)
        XCTAssertGreaterThan(scrollView.contentView.bounds.minY, 500, "the heading's line is near the top")
    }
}
