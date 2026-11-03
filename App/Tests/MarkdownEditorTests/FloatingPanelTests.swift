import AppKit
import XCTest
@testable import MarkdownEditor

/// The `/` menu and the format bar fade out before they leave, and must always leave: whatever happens to the
/// animation, the panel ends off the screen, and showing again cancels a pending exit.
@MainActor
final class FloatingPanelTests: XCTestCase {
    private func makeWindow() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 600, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.orderFront(nil)
        return window
    }

    private func wait(_ seconds: Double) async {
        try? await Task.sleep(for: .seconds(seconds))
    }

    func testTheMenuIsOffTheScreenAfterItsFade() async {
        let window = makeWindow()
        defer { window.close() }
        let panel = SlashMenuPanel()
        let item = SlashMenu.standardItems.first!
        panel.show([item], grouped: true, below: NSRect(x: 200, y: 300, width: 8, height: 16), in: window)
        XCTAssertTrue(window.childWindows?.contains(panel) == true)
        panel.hide()
        XCTAssertFalse(window.childWindows?.contains(panel) == true, "no longer attached at once")
        await wait(0.6)
        XCTAssertFalse(panel.isVisible)
        XCTAssertEqual(panel.alphaValue, 1, "ready for the next time")
    }

    func testShowingAgainDuringTheFadeKeepsTheMenu() async {
        let window = makeWindow()
        defer { window.close() }
        let panel = SlashMenuPanel()
        let items = [SlashMenu.standardItems.first!]
        let anchor = NSRect(x: 200, y: 300, width: 8, height: 16)
        panel.show(items, grouped: true, below: anchor, in: window)
        panel.hide()
        panel.show(items, grouped: true, below: anchor, in: window)
        await wait(0.6)
        XCTAssertTrue(panel.isVisible)
        XCTAssertTrue(window.childWindows?.contains(panel) == true)
        panel.hide()
        await wait(0.6)
        XCTAssertFalse(panel.isVisible)
    }

    func testHidingAPanelThatWasNeverShownIsHarmless() {
        let panel = SlashMenuPanel()
        panel.hide()
        XCTAssertFalse(panel.isVisible)
    }
}
