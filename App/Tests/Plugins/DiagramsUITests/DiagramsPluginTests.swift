import PluginKitUI
import PluginKitUITesting
import XCTest
@testable import DiagramsUI

/// The plugin in the UI harness with a recording editor, and Pele drawing real diagrams in its web view.
@MainActor
final class DiagramsPluginTests: XCTestCase {
    func testWithAnEditorItDrawsMermaidAndOffersASlashItem() throws {
        let editor = RecordingEditor()
        let harness = try UIPluginHarness(uiPlugins: [DiagramsPlugin.self], editor: editor)
        XCTAssertTrue(harness.host.isActive("diagrams"), "\(harness.report)")
        XCTAssertEqual(editor.codeBlockRenderers.map(\.id), ["diagrams.mermaid"])
        XCTAssertEqual(editor.codeBlockRenderers.first?.languages, ["mermaid"])
        XCTAssertEqual(editor.slashItems.map(\.id), ["diagrams.mermaid"])

        harness.close()
        XCTAssertTrue(editor.codeBlockRenderers.isEmpty)
        XCTAssertTrue(editor.slashItems.isEmpty)
    }

    func testWithoutAnEditorItDoesNothing() throws {
        let harness = try UIPluginHarness(uiPlugins: [DiagramsPlugin.self])
        defer { harness.close() }
        XCTAssertTrue(harness.host.isActive("diagrams"), "\(harness.report)")
    }

    func testTheSlashItemInsertsAMermaidBlockWithTheEdgeSelected() {
        let change = DiagramsPlugin.insertion(in: "Intro\n/dia", replacing: NSRange(location: 6, length: 4))
        let text = change.applied(to: "Intro\n/dia")
        XCTAssertEqual(text, "Intro\n\n```mermaid\nflowchart LR\n    A[Idea] --> B[Diagram]\n```")
        XCTAssertEqual((text as NSString).substring(with: change.selection), "A[Idea] --> B[Diagram]")

        // At the start of an empty note: no blank line before it.
        let first = DiagramsPlugin.insertion(in: "/", replacing: NSRange(location: 0, length: 1))
        XCTAssertTrue(first.applied(to: "/").hasPrefix("```mermaid\n"))
        // After text on the same line: the block starts on its own paragraph.
        let inline = DiagramsPlugin.insertion(in: "See /", replacing: NSRange(location: 4, length: 1))
        XCTAssertTrue(inline.applied(to: "See /").hasPrefix("See \n\n```mermaid\n"))
    }

    func testStyleCarriesThePageLook() {
        let style = MermaidRenderer.style(for: CodeBlockRequest(language: "mermaid", code: "", isDark: true, text: "#f4f4f4", accent: "#ff0000"))
        XCTAssertTrue(style.contains("--pele-fg: #f4f4f4"))
        XCTAssertTrue(style.contains("--pele-accent: #ff0000"))
        XCTAssertTrue(style.contains("color-scheme: dark"))
    }

    func testPeleDrawsEveryKindOfDiagramAndRefusesInvalidCode() async throws {
        XCTAssertNotNil(MermaidRenderer.script, "Pele's bundle is a resource of the module")
        let renderer = MermaidRenderer()
        defer { renderer.close() }
        let diagrams = [
            "flowchart LR\n  A[Idée] --> B{Ça marche ?}\n  B -->|Oui| C[Ship]",
            "sequenceDiagram\n  Alice->>Bob: Salut\n  Bob-->>Alice: Ça va ?",
            "pie title Temps\n  \"Code\" : 60\n  \"Café\" : 40",
            "gantt\n  dateFormat YYYY-MM-DD\n  section Projet\n  Design :a1, 2026-01-01, 10d",
            "mindmap\n  root((Loam))\n    Notes\n    Diagrams",
        ]
        for code in diagrams {
            let rendered = await renderer.render(CodeBlockRequest(language: "mermaid", code: code))
            let picture = try XCTUnwrap(rendered, code)
            XCTAssertGreaterThan(picture.size.width, 20, code)
            XCTAssertGreaterThan(picture.size.height, 20, code)
            // A snapshot at the screen's scale: at least one pixel per point.
            XCTAssertGreaterThanOrEqual(CGFloat(picture.image.width), picture.size.width - 1, code)
        }
        let invalid = await renderer.render(CodeBlockRequest(language: "mermaid", code: "flowchart LR\n  A -->"))
        XCTAssertNil(invalid)
        let unknown = await renderer.render(CodeBlockRequest(language: "mermaid", code: "not a diagram"))
        XCTAssertNil(unknown)
        // Still drawing after a failure.
        let again = await renderer.render(CodeBlockRequest(language: "mermaid", code: "flowchart TD\n  A --> B"))
        XCTAssertNotNil(again)
    }

    func testConcurrentRequestsAreDrawnOneAtATime() async throws {
        let renderer = MermaidRenderer()
        defer { renderer.close() }
        async let wide = renderer.render(CodeBlockRequest(language: "mermaid", code: "flowchart LR\n  A --> B --> C --> D --> E"))
        async let tall = renderer.render(CodeBlockRequest(language: "mermaid", code: "flowchart TD\n  A --> B --> C --> D --> E"))
        let (w, t) = await (wide, tall)
        let wideSize = try XCTUnwrap(w).size
        let tallSize = try XCTUnwrap(t).size
        XCTAssertGreaterThan(wideSize.width, wideSize.height)
        XCTAssertGreaterThan(tallSize.height, tallSize.width)
    }
}
