import AppKit
import BuiltinPlugins
import BuiltinUIPlugins
import SwiftUI
import XCTest
@testable import NotebookApp

/// Lays the main window out offscreen: a smoke test that the views build for each shape of workspace.
@MainActor
final class ShellWindowTests: ShellTestCase {
    private var windows: [NSWindow] = []

    override func tearDown() async throws {
        for window in windows { window.close() }
        windows = []
        try await super.tearDown()
    }

    private func render(_ session: ShellSession) -> NSView {
        let size = CGSize(width: 1000, height: 700)
        let hosting = NSHostingView(rootView: ShellWindow(session: session))
        hosting.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(
            contentRect: CGRect(origin: CGPoint(x: -10_000, y: -10_000), size: size),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        windows.append(window)
        return hosting
    }

    func testTheWindowRendersSplitsTabsAndPlaceholders() throws {
        try write("Note.md", "# Note\n\nText.")
        let session = try openSession(logic: builtinPlugins, ui: [ShellTestPlugin.self] + builtinUIPlugins)
        XCTAssertEqual(render(session).frame.width, 1000, "empty workspace")

        session.workspace.open(.file("Note.md"), placement: .replace)
        session.workspace.open(.virtual("test:a"), placement: .beside)
        session.workspace.open(.virtual("unknown:x"), placement: .newTab)
        session.workspace.splitActive(.bottom)
        let view = render(session)
        XCTAssertEqual(view.frame.size, CGSize(width: 1000, height: 700))
    }

    func testTheWindowRendersWithoutAnyPanel() throws {
        let session = try openSession(ui: [])
        session.workspace.open(.virtual("test:a"), placement: .replace)
        _ = render(session)
    }
}
