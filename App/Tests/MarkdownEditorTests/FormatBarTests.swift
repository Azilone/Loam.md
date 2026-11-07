import AppKit
import XCTest
@testable import MarkdownEditor

@MainActor
final class FormatBarTests: XCTestCase {
    private var window: NSWindow!
    private var scrollView: NSScrollView!
    private var textView: EditorTextView!
    private var controller: EditorController!

    override func setUp() async throws {
        window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 800, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        scrollView = NSScrollView(frame: window.contentView!.bounds)
        scrollView.hasVerticalScroller = true
        textView = EditorTextView(usingTextLayoutManager: true)
        textView.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        textView.autoresizingMask = [.width]
        textView.isVerticallyResizable = true
        textView.isRichText = false
        scrollView.documentView = textView
        window.contentView!.addSubview(scrollView)
        controller = EditorController()
        controller.attach(textView)
        window.orderFront(nil)
        window.makeFirstResponder(textView)
    }

    override func tearDown() async throws { window.close() }

    private func wait(_ s: Double) async { try? await Task.sleep(for: .seconds(s)) }
    private var bar: NSWindow? { window.childWindows?.first { $0 is FormatBarPanel } }

    private func load() -> NSString {
        let text = (1...80).map { "Line \($0) lorem ipsum dolor sit amet consectetur" }.joined(separator: "\n\n")
        controller.show(EditorContent(id: 1, text: text))
        return text as NSString
    }

    private var scrollY: CGFloat { scrollView.contentView.bounds.origin.y }

    /// Selects `length` characters from `marker`, waits for the bar to show (longer when the whole suite is busy).
    private func select(_ marker: String, length: Int, in text: NSString) async -> FormatBarPanel? {
        textView.setSelectedRange(NSRange(location: text.range(of: marker).location, length: length))
        await wait(0.5)
        for _ in 0..<45 where bar == nil { await wait(0.1) }
        return bar as? FormatBarPanel
    }

    func testTheBarKeepsItsHeightThroughTheColoursAndEveryAction() async {
        let text = load()
        await wait(0.3)
        guard let panel = await select("Line 3 ", length: 20, in: text) else { return XCTFail("the bar shows over the selection") }
        let height = FormatBar.panelHeight
        XCTAssertEqual(panel.frame.height, height)

        panel.model.showsColors = true
        panel.model.onResize?()
        await wait(0.5)
        XCTAssertEqual(panel.frame.height, height, "the colours replace the buttons, the bar keeps its height")
        XCTAssertGreaterThan(panel.frame.width, 0)

        controller.perform(.highlight(.yellow))
        await wait(0.6)
        XCTAssertEqual((bar as? FormatBarPanel)?.frame.height ?? height, height)
        controller.perform(.toggle(.bold))
        await wait(0.6)
        XCTAssertEqual((bar as? FormatBarPanel)?.frame.height ?? height, height)
    }

    func testFormattingAPageLongSelectionNeverScrollsThePage() async {
        let text = load()
        await wait(0.3)
        // From the first lines to far below the page: revealing the whole range would scroll.
        textView.setSelectedRange(NSRange(location: text.range(of: "Line 2 ").location, length: 6000))
        await wait(0.5)
        let before = scrollY
        controller.perform(.toggle(.bold))
        await wait(0.6)
        XCTAssertEqual(scrollY, before, "formatting does not scroll")
        controller.perform(.toggle(.italic))
        await wait(0.6)
        XCTAssertEqual(scrollY, before, "formatting does not scroll")
    }

    func testTheBarNeverTakesTheFocusOrTheSelection() async {
        let text = load()
        await wait(0.3)
        guard let panel = await select("Line 3 ", length: 20, in: text) else { return XCTFail("the bar shows over the selection") }
        XCTAssertFalse(panel.canBecomeKey)
        XCTAssertTrue(window.firstResponder === textView)
        panel.model.showsColors = true
        panel.model.onResize?()
        await wait(0.5)
        XCTAssertTrue(window.firstResponder === textView)
        XCTAssertTrue(window.isKeyWindow || !window.canBecomeKey || window.firstResponder === textView)
        XCTAssertEqual(textView.selectedRange().length, 20)
    }
}
