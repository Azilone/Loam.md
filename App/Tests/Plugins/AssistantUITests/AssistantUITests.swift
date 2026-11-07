import AssistantPlugin
import PluginKit
import PluginKitUI
import PluginKitUITesting
import SwiftUI
import XCTest
@testable import AssistantUI

/// The bubble is on the window, ⌘J opens and closes the panel, the active note is offered as context, and unloading
/// leaves nothing behind.
@MainActor
final class AssistantUITests: XCTestCase {
    func testBubbleCommandsAndContext() async throws {
        let harness = try UIPluginHarness(logicPlugins: [AssistantPlugin.self], uiPlugins: [AssistantUIPlugin.self])
        defer { harness.close() }
        XCTAssertEqual(harness.windowOverlays.overlays(in: .bottomTrailing).map(\.id), ["assistant.bubble"])
        let model = try XCTUnwrap(harness.kernel.services.service(AssistantUIPlugin.modelKey))

        let opened = try await harness.run("assistant.toggle")
        XCTAssertEqual(opened, "open")
        XCTAssertTrue(model.chat.messages.isEmpty)
        let closed = try await harness.run("assistant.toggle")
        XCTAssertEqual(closed, "closed")

        harness.kernel.events.emit(ActiveResourceChanged(resource: .file("Projects/Plan.md")))
        XCTAssertEqual(model.context, ["Projects/Plan.md"])
        model.removeContext("Projects/Plan.md")
        XCTAssertEqual(model.context, [])
        model.addContext("Ideas/")
        XCTAssertEqual(model.context, ["Ideas/"])

        XCTAssertEqual(harness.settingsSections.sections(for: "assistant").map(\.id),
                       ["assistant.agents", "assistant.prompts", "assistant.instructions"])

        model.choose(mode: .readOnly)
        XCTAssertEqual(model.chat.mode, .readOnly)

        harness.host.deactivateAll()
        XCTAssertTrue(harness.windowOverlays.overlays(in: .bottomTrailing).isEmpty)
        XCTAssertTrue(harness.settingsSections.sections(for: "assistant").isEmpty)
    }

    func testTheOverlayRendersOpenAndClosed() throws {
        let harness = try UIPluginHarness(logicPlugins: [AssistantPlugin.self], uiPlugins: [AssistantUIPlugin.self])
        defer { harness.close() }
        let model = try XCTUnwrap(harness.kernel.services.service(AssistantUIPlugin.modelKey))
        for open in [false, true] {
            if open { model.open() }
            let view = harness.windowOverlays.overlays(in: .bottomTrailing)[0].makeView()
            let host = NSHostingView(rootView: view.frame(width: 1200, height: 900))
            host.frame = NSRect(x: 0, y: 0, width: 1200, height: 900)
            host.layoutSubtreeIfNeeded()
            XCTAssertGreaterThan(host.fittingSize.width, 0)
        }
    }
}

/// The answer's Markdown, and `/` and `@` in the field.
@MainActor
final class AssistantComposerTests: XCTestCase {
    func testMarkdownBlocks() {
        let blocks = MarkdownBlocks.parse("""
        ## Plan
        Read [[Ideas]] first.
        Then write.
        - one
          - nested
        - [x] done
        1. first
        > quote
        | A | B |
        | --- | --- |
        | 1 | 2 |
        ```
        code
        ```
        """)
        XCTAssertEqual(blocks, [
            .heading(2, "Plan"), .paragraph("Read [[Ideas]] first.\nThen write."),
            .item(depth: 0, marker: .bullet, "one"), .item(depth: 1, marker: .bullet, "nested"),
            .item(depth: 0, marker: .task(true), "done"), .item(depth: 0, marker: .number("1."), "first"),
            .quote("quote"), .table([["A", "B"], ["1", "2"]]), .code("code"),
        ])
    }

    func testNotesBecomeLinks() {
        let colors = CraftColors(.light)
        for text in ["See [[Projects/Plan]].", "See [Plan](Projects/Plan.md).", "See `Projects/Plan.md`."] {
            let links = MarkdownText.inline(text, colors: colors).runs.compactMap(\.link)
            XCTAssertEqual(links.map(\.scheme), ["loam-note"], text)
        }
        XCTAssertEqual(MarkdownText.inline("[web](https://a.b)", colors: colors).runs.compactMap(\.link).first?.scheme, "https")
    }

    func testSlashAndMention() throws {
        let harness = try UIPluginHarness(logicPlugins: [AssistantPlugin.self], uiPlugins: [AssistantUIPlugin.self],
                                          files: ["Projects/Plan.md": "# Plan", "Ideas.md": "x"])
        defer { harness.close() }
        let model = try XCTUnwrap(harness.kernel.services.service(AssistantUIPlugin.modelKey))
        _ = try model.engine.prompts.save(title: "Translate", prompt: "Translate this note into English.")

        model.draft = "/"
        model.draftChanged()
        XCTAssertEqual(model.menu, .slash)
        XCTAssertEqual(model.inlineItems.map(\.title), ["Translate", "Create Custom Prompt"])
        model.chooseHighlighted()
        XCTAssertEqual(model.draft, "Translate this note into English.")
        XCTAssertNil(model.menu)

        model.draft = "Compare @pla"
        model.draftChanged()
        XCTAssertEqual(model.menu, .mention)
        XCTAssertEqual(model.inlineItems.first?.title, "Plan")
        model.chooseHighlighted()
        XCTAssertEqual(model.draft, "Compare Plan ")
        XCTAssertTrue(model.context.contains("Projects/Plan.md"))

        model.draft = "mail me at a@b"
        model.draftChanged()
        XCTAssertNil(model.menu, "an @ inside a word is not a mention")
    }
}
