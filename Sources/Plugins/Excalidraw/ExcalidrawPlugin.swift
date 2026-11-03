import Foundation
import PluginKit

/// Drawings: Excalidraw scenes kept in the vault as notes the Obsidian Excalidraw plugin also opens
/// (`Plan.excalidraw.md`), or as plain `.excalidraw` files. Provides the `excalidraw` service (for `ExcalidrawUI`,
/// which draws them) and the `excalidraw.*` commands, so an agent creates a drawing and reads its text. Images follow
/// their files when they move.
public final class ExcalidrawPlugin: Plugin {
    public static var manifest: PluginManifest {
        PluginManifest(id: "excalidraw", name: "Excalidraw", version: "0.1.0",
                       description: "Hand-drawn whiteboards, saved as Excalidraw drawings in the vault.",
                       icon: "scribble.variable", provides: ["excalidraw"], optionalRequires: ["attachments"],
                       permissions: ["vault.read", "vault.write"])
    }

    public required init() {}

    public func activate(context: PluginContext) throws {
        let attachments = context.service(.attachments)
        let drawings = ExcalidrawDrawings(vault: context.vault, attachments: { attachments })
        try context.provide(.excalidraw, drawings)
        context.on(VaultChanged.self) { event in drawings.vaultChanged(event.changes) }
        context.on(NotesMoved.self) { event in drawings.follow(moves: event.moves) }

        try context.registerCommand(Command(
            id: "excalidraw.new",
            title: "Create drawing file",
            summary: "Creates an empty Excalidraw drawing (a note named `<title>.excalidraw.md`, flagged "
                + "`excalidraw-plugin: parsed`) and returns its path. Writes to the vault. Optional: folder "
                + "(default Inbox), title (default Drawing).",
            isInPalette: false
        ) { args in
            let path = try drawings.create(in: args["folder"] ?? "", title: args["title"])
            return try JSON.string(["path": path])
        })

        try context.registerCommand(Command(
            id: "excalidraw.list",
            title: "List drawings",
            summary: "Lists every Excalidraw drawing in the vault: `.excalidraw` files and notes flagged "
                + "`excalidraw-plugin`.",
            isInPalette: false
        ) { _ in
            try JSON.string(try drawings.drawings())
        })

        try context.registerCommand(Command(
            id: "excalidraw.read",
            title: "Read drawing",
            summary: "Returns what a drawing says: its shapes (id, type, text: what excalidraw.connect joins), its "
                + "texts (id, text), the links of its shapes (id, link), its images (id, path) and how many elements "
                + "it has. Argument: path.",
            isInPalette: false
        ) { args in
            let document = try drawings.read(try args.require("path"))
            let used = document.imageFileIDs
            return try JSON.string(DrawingSummary(
                shapes: document.shapes.map { .init(id: $0.id, type: $0.type, text: $0.text) },
                texts: document.texts.map { .init(id: $0.id, text: $0.text) },
                links: document.links.map { .init(id: $0.id, link: $0.link) },
                images: document.embeddedFiles.filter { used.contains($0.id) }
                    .map { .init(id: $0.id, path: $0.link ?? $0.value) },
                elements: document.elements.filter { ($0["isDeleted"] as? Bool) != true }.count
            ))
        })

        try context.registerCommand(Command(
            id: "excalidraw.add-shape",
            title: "Add a shape to a drawing",
            summary: "Adds a hand-drawn shape with its text centred in it, and returns its id. Writes to the vault. "
                + "Arguments: path, text; optional: type (rectangle, ellipse, diamond or text; default rectangle), "
                + "color (blue, green, yellow, red, purple, orange, gray or #RRGGBB fill), x, y (default: right of "
                + "the last shape), width, height (default: fits the text). Join shapes with excalidraw.connect.",
            isInPalette: false
        ) { args in
            let path = try args.require("path")
            var document = try drawings.read(path)
            let id = try document.addShape(
                type: args["type"].flatMap { $0.isEmpty ? nil : $0 } ?? "rectangle", text: args["text"] ?? "",
                x: args["x"].flatMap(Double.init), y: args["y"].flatMap(Double.init),
                width: args["width"].flatMap(Double.init), height: args["height"].flatMap(Double.init), color: args["color"]
            )
            try drawings.write(path, document)
            return try JSON.string(["id": id])
        })

        try context.registerCommand(Command(
            id: "excalidraw.connect",
            title: "Connect two shapes of a drawing",
            summary: "Draws an arrow from one shape to another, attached to both so it follows them, and returns its "
                + "id. Writes to the vault. Arguments: path, from, to (shape ids from excalidraw.add-shape or "
                + "excalidraw.read); optional: label.",
            isInPalette: false
        ) { args in
            let path = try args.require("path")
            var document = try drawings.read(path)
            let id = try document.connect(from: try args.require("from"), to: try args.require("to"), label: args["label"])
            try drawings.write(path, document)
            return try JSON.string(["id": id])
        })
    }
}

private struct DrawingSummary: Encodable {
    struct Shape: Encodable { let id: String, type: String, text: String }
    struct Text: Encodable { let id: String, text: String }
    struct Link: Encodable { let id: String, link: String }
    struct Image: Encodable { let id: String, path: String }
    let shapes: [Shape]
    let texts: [Text]
    let links: [Link]
    let images: [Image]
    let elements: Int
}
