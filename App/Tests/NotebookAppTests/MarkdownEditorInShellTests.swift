import AppKit
import BuiltinPlugins
import BuiltinUIPlugins
import MarkdownEditorUI
import SwiftUI
import XCTest
@testable import NotebookApp

/// The Markdown editor plugin inside the real shell: a `.md` tab shows the note in the editor.
@MainActor
final class MarkdownEditorInShellTests: ShellTestCase {
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

    private func textViews(in view: NSView) -> [NSTextView] {
        (view as? NSTextView).map { [$0] } ?? view.subviews.flatMap(textViews(in:))
    }

    func testAMarkdownTabShowsTheNoteInTheEditor() throws {
        try write("Note.md", "# Note\n\nText.")
        let session = try openSession(logic: builtinPlugins, ui: builtinUIPlugins)
        XCTAssertEqual(session.views.viewTypes(for: .file("Note.md")).map(\.id), [MarkdownEditorPlugin.viewTypeID])
        session.workspace.open(.file("Note.md"), placement: .replace)
        // The page shows the note's text; its `# Note` is the page's title.
        let editors = textViews(in: render(session)).filter { $0.isEditable && $0.string == "Text.\n" }
        XCTAssertEqual(editors.count, 1)
    }

    func testANewNoteOpensInTheEditor() async throws {
        let session = try openSession(logic: builtinPlugins, ui: builtinUIPlugins)
        let path = try await session.run("explorer.new-note")
        XCTAssertEqual(session.workspace.activeResource, .file(path))
        let view = render(session)
        XCTAssertTrue(textViews(in: view).contains { $0.isEditable && $0.string.isEmpty })
    }
}
