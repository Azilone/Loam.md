import Foundation
import PluginKitUI

/// Mermaid diagrams in notes: a fenced ` ```mermaid ` block shows as its diagram, and as its code again (the diagram
/// under it, following the typing) while the caret is in it. A click on a diagram opens it large, to zoom
/// (`PictureViewer`), and "Edit Code" there shows Craft's code page: the diagram drawn live over its code. The note stays plain Markdown, as GitHub and Obsidian
/// read it. Every Mermaid diagram type is drawn, by Pele (`MermaidRenderer`). "Diagram" in the `/` menu inserts one.
/// Without an editor the plugin does nothing.
public final class DiagramsPlugin: UIPlugin {
    public static let manifest = PluginManifest(
        id: "diagrams",
        name: "Diagrams",
        version: "0.1.0",
        description: "Draws Mermaid code blocks as diagrams.",
        icon: "flowchart",
        optionalRequires: ["editor"],
        permissions: ["ui", "vault.read"]
    )

    static let rendererID = "diagrams.mermaid"

    public init() {}

    @MainActor public func activateUI(context: PluginContext) throws {
        guard context.editor != nil else { return }
        let renderer = MermaidRenderer()
        context.addCodeBlockRenderer(CodeBlockRenderer(id: Self.rendererID, languages: ["mermaid"]) { [weak renderer] request in
            await renderer?.render(request)
        })
        context.addSlashItem(SlashItem(
            id: "diagrams.mermaid",
            title: "Diagram",
            symbol: "flowchart",
            keywords: ["mermaid", "flowchart", "chart", "graph", "sequence", "gantt", "mindmap"]
        ) { text, trigger in
            Self.insertion(in: text, replacing: trigger)
        })
        context.effect { MainActor.assumeIsolated { renderer.close() } }
        renderer.warm()
    }

    /// The example a new diagram starts from; its first edge is selected, ready to be typed over.
    static let example = "flowchart LR\n    A[Idea] --> B[Diagram]"
    static let selected = "A[Idea] --> B[Diagram]"

    /// Replaces the `/` and its filter with a ` ```mermaid ` block on its own lines, the example's edge selected.
    static func insertion(in text: String, replacing trigger: NSRange) -> TextChange {
        let ns = text as NSString
        let line = ns.lineRange(for: NSRange(location: trigger.location, length: 0))
        let before = ns.substring(with: NSRange(location: line.location, length: trigger.location - line.location))
        var lead = ""
        if !before.trimmingCharacters(in: .whitespaces).isEmpty {
            lead = "\n\n"
        } else if line.location > 0 {
            let previous = ns.lineRange(for: NSRange(location: line.location - 1, length: 0))
            if !ns.substring(with: previous).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { lead = "\n" }
        }
        let head = lead + "```mermaid\n"
        let replacement = head + example + "\n```"
        let start = trigger.location + head.utf16.count + (example as NSString).range(of: selected).location
        return TextChange(
            range: trigger,
            replacement: replacement,
            selection: NSRange(location: start, length: selected.utf16.count)
        )
    }
}
