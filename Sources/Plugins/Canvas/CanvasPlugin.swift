import Foundation
import PluginKit

/// Boards: JSON Canvas files (`.canvas`) of cards, each a note of the vault, a piece of text, a web page or a group,
/// joined by edges. Provides the `canvas` service (for `CanvasUI`) and the `canvas.*` commands, so an agent builds
/// a board the way the board view does. Cards follow their notes when they move.
public final class CanvasPlugin: Plugin {
    public static var manifest: PluginManifest {
        PluginManifest(id: "canvas", name: "Canvas", version: "0.1.0", description: "Boards of cards, notes and links, saved as JSON Canvas files.", icon: "square.on.square.dashed", provides: ["canvas", "note-boards"],
                       permissions: ["vault.read", "vault.write"])
    }

    public required init() {}

    public func activate(context: PluginContext) throws {
        let vault = context.vault
        let boards = CanvasBoards(vault: vault)
        try context.provide(.canvas, boards)
        try context.provide(.noteBoards, boards)
        context.on(NotesMoved.self) { event in boards.follow(moves: event.moves) }
        context.on(VaultChanged.self) { event in boards.vaultChanged(event.changes) }

        try context.registerCommand(Command(
            id: "canvas.new",
            title: "Create board file",
            summary: "Creates an empty board (a JSON Canvas `.canvas` file) and returns its path. Writes to the "
                + "vault. Optional: folder (default Inbox), title (default Board).",
            isInPalette: false
        ) { args in
            let path = try boards.create(in: args["folder"] ?? "", title: args["title"])
            return try JSON.string(["path": path])
        })

        try context.registerCommand(Command(
            id: "canvas.list",
            title: "List boards",
            summary: "Lists every board (`.canvas` file) in the vault, or with path set, the boards with a card "
                + "showing that note.",
            isInPalette: false
        ) { args in
            if let path = args["path"], !path.isEmpty { return try JSON.string(try boards.boards(showing: path)) }
            return try JSON.string(try boards.boards())
        })

        try context.registerCommand(Command(
            id: "canvas.read",
            title: "Read board",
            summary: "Returns a board as JSON Canvas: nodes (id, type text|file|link|group, x, y, width, height, "
                + "color, text, file, url, label) and edges (id, fromNode, toNode, sides, label). Argument: path.",
            isInPalette: false
        ) { args in
            try boards.read(try args.require("path")).text
        })

        try context.registerCommand(Command(
            id: "canvas.add-node",
            title: "Add card to board",
            summary: "Adds a card to a board and returns its id. Writes to the vault. Arguments: path; one of "
                + "text (Markdown), file (a vault path, a note shows as its card), url, or type=group with label. "
                + "Optional: color (1-6 or #RRGGBB), x, y, width, height; near (a node id: placed beside it); for a "
                + "text card shape (rectangle|pill|diamond|parallelogram|circle|predefined-process|document|database, "
                + "then text may be empty), border (solid|dashed|dotted|invisible), textAlign (left|center|right). "
                + "Without x and y the card goes to a free spot.",
            isInPalette: false
        ) { args in
            let path = try args.require("path")
            let node = try boards.update(path) { document -> CanvasNode in
                let node = try Self.node(from: args, in: document, vault: vault)
                document.add(node)
                return node
            }
            return try JSON.string(["id": node.id])
        })

        try context.registerCommand(Command(
            id: "canvas.update-node",
            title: "Update card on board",
            summary: "Changes a card of a board. Writes to the vault. Arguments: path, id; any of text, file, url, "
                + "label, color, fontSize (of a text card), shape, border, textAlign, x, y, width, height (an empty "
                + "value removes text, label, color, fontSize, shape, border or textAlign).",
            isInPalette: false
        ) { args in
            let path = try args.require("path"), id = try args.require("id")
            try boards.update(path) { document in
                guard let index = document.nodes.firstIndex(where: { $0.id == id }) else {
                    throw CanvasError.unknownNode(id)
                }
                try Self.apply(args, to: &document.nodes[index], vault: vault)
            }
            return try JSON.string(["id": id])
        })

        try context.registerCommand(Command(
            id: "canvas.connect",
            title: "Connect cards on board",
            summary: "Draws an arrow between two cards of a board and returns its id. Writes to the vault. "
                + "Arguments: path, from, to (node ids). Optional: label, color (1-6 or #RRGGBB), fromSide, toSide "
                + "(top|right|bottom|left), shape (curve|straight), dashed (true|false).",
            isInPalette: false
        ) { args in
            let path = try args.require("path")
            let from = try args.require("from"), to = try args.require("to")
            let shape = try Self.shape(args["shape"])
            let id = try boards.update(path) { document in
                let id = try document.connect(from, to: to,
                                              fromSide: try Self.side(args["fromSide"]),
                                              toSide: try Self.side(args["toSide"]), label: args["label"])
                if let index = document.edges.firstIndex(where: { $0.id == id }) {
                    document.edges[index].color = args["color"].flatMap { $0.isEmpty ? nil : $0 }
                    document.edges[index].shape = shape
                    document.edges[index].dashed = args["dashed"] == "true" ? true : nil
                }
                return id
            }
            return try JSON.string(["id": id])
        })

        try context.registerCommand(Command(
            id: "canvas.align",
            title: "Align cards on board",
            summary: "Lines cards of a board up, or spaces them evenly. Writes to the vault. Arguments: path, ids "
                + "(comma separated), and align (left|centerX|right|top|centerY|bottom) or distribute "
                + "(horizontal|vertical, three cards or more).",
            isInPalette: false
        ) { args in
            let path = try args.require("path")
            let ids = Set(try args.require("ids").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
            let alignment = try args["align"].flatMap { $0.isEmpty ? nil : $0 }.map { value -> CanvasAlignment in
                guard let alignment = CanvasAlignment(rawValue: value) else {
                    throw CanvasError.invalid("Unknown alignment: \(value)")
                }
                return alignment
            }
            let axis = try args["distribute"].flatMap { $0.isEmpty ? nil : $0 }.map { value -> CanvasAxis in
                switch value {
                case "horizontal": return .horizontal
                case "vertical": return .vertical
                default: throw CanvasError.invalid("Unknown direction: \(value)")
                }
            }
            guard alignment != nil || axis != nil else { throw CanvasError.invalid("Give align or distribute.") }
            try boards.update(path) { document in
                for id in ids where document.node(id) == nil { throw CanvasError.unknownNode(id) }
                if let alignment { document.align(ids, to: alignment) }
                if let axis { document.distribute(ids, along: axis) }
            }
            return try JSON.string(["ids": Array(ids).sorted()])
        })

        try context.registerCommand(Command(
            id: "canvas.add-frame",
            title: "Add frame to board",
            summary: "Adds a frame (a 16:9 slide, Advanced Canvas's: a group with a ratio) and returns its id. Writes "
                + "to the vault. Arguments: path; ids (comma separated: the frame goes around these cards) or x, y "
                + "(its top-left corner; 1280x720 unless width is given). Optional: label (default Slide N). The "
                + "board's first frame starts its presentation.",
            isInPalette: false
        ) { args in
            let path = try args.require("path")
            let id = try boards.update(path) { document -> String in
                let rect: CanvasRect
                if let ids = args["ids"], !ids.isEmpty {
                    let wanted = Set(ids.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
                    for id in wanted where document.node(id) == nil { throw CanvasError.unknownNode(id) }
                    let bounds = CanvasRect.bounds(document.nodes.filter { wanted.contains($0.id) }.map(\.frame))!
                    rect = CanvasDocument.frame(around: bounds)
                } else {
                    let width = try Self.number(args, "width") ?? CanvasDocument.frameSize.width
                    let height = width / CanvasDocument.frameRatio
                    var origin = CanvasPoint(x: 0, y: 0)
                    if let x = try Self.number(args, "x"), let y = try Self.number(args, "y") {
                        origin = CanvasPoint(x: x, y: y)
                    } else if let bounds = CanvasRect.bounds(document.nodes.map(\.frame)) {
                        origin = CanvasPoint(x: bounds.minX, y: bounds.maxY + 120)
                    }
                    rect = CanvasRect(x: origin.x, y: origin.y, width: width, height: height.rounded())
                }
                return document.addFrame(rect, label: args["label"].flatMap { $0.isEmpty ? nil : $0 })
            }
            return try JSON.string(["id": id])
        })

        try context.registerCommand(Command(
            id: "canvas.slides",
            title: "List slides of board",
            summary: "Returns the ids and labels of a board's slides in the order they are presented: from the start "
                + "frame along the arrows between frames, then the others in reading order. Argument: path.",
            isInPalette: false
        ) { args in
            let document = try boards.read(try args.require("path"))
            return try JSON.string(document.slides().map { id in
                ["id": id, "label": document.node(id)?.label ?? ""]
            })
        })

        try context.registerCommand(Command(
            id: "canvas.remove",
            title: "Remove from board",
            summary: "Removes cards or edges from a board by id, and the edges of removed cards. Writes to the "
                + "vault (the notes behind the cards stay). Arguments: path, ids (comma separated).",
            isInPalette: false
        ) { args in
            let path = try args.require("path")
            let ids = Set(try args.require("ids").split(separator: ",").map {
                $0.trimmingCharacters(in: .whitespaces)
            })
            let removed = try boards.update(path) { document -> Int in
                let before = document.nodes.count + document.edges.count
                document.remove(ids)
                return before - document.nodes.count - document.edges.count
            }
            return try JSON.string(["removed": removed])
        })
    }

    static func side(_ value: String?) throws -> CanvasSide? {
        guard let value, !value.isEmpty else { return nil }
        guard let side = CanvasSide(rawValue: value) else { throw CanvasError.invalid("Unknown side: \(value)") }
        return side
    }

    static func shape(_ value: String?) throws -> CanvasEdgeShape? {
        guard let value, !value.isEmpty else { return nil }
        guard let shape = CanvasEdgeShape(rawValue: value) else { throw CanvasError.invalid("Unknown shape: \(value)") }
        return shape
    }

    /// A style value (a shape, a border, an alignment); nil for an empty or absent one.
    static func style<T: RawRepresentable>(_ value: String?, _ type: T.Type, _ key: String) throws -> T?
        where T.RawValue == String {
        guard let value, !value.isEmpty else { return nil }
        guard let style = T(rawValue: value) else { throw CanvasError.invalid("Unknown \(key): \(value)") }
        return style
    }

    static func number(_ args: [String: String], _ key: String) throws -> Double? {
        guard let value = args[key], !value.isEmpty else { return nil }
        guard let number = Double(value), number.isFinite else { throw CanvasError.invalid("\(key) is not a number.") }
        return number
    }

    /// A card from command arguments, placed where they say or at a free spot.
    static func node(from args: [String: String], in document: CanvasDocument, vault: VaultAccess) throws -> CanvasNode {
        let kind: CanvasNodeKind
        if let type = args["type"], !type.isEmpty {
            kind = CanvasNodeKind(type)
        } else if args["file"] != nil {
            kind = .file
        } else if args["url"] != nil {
            kind = .link
        } else {
            kind = .text
        }
        let shape = try style(args["shape"], CanvasNodeShape.self, "shape")
        let size: (width: Double, height: Double)
        switch kind {
        case .text where shape != nil: size = shape!.defaultSize
        case .file: size = CanvasDocument.fileSize
        case .link: size = args["url"].flatMap(URL.init(string:)).map { CanvasLinkKind($0).cardSize } ?? CanvasDocument.linkSize
        case .group: size = (600, 400)
        default: size = CanvasDocument.textSize
        }
        let width = try number(args, "width") ?? size.width, height = try number(args, "height") ?? size.height
        var origin = CanvasPoint(x: 0, y: 0)
        if let x = try number(args, "x"), let y = try number(args, "y") {
            origin = CanvasPoint(x: x, y: y)
        } else {
            var preferred = CanvasPoint(x: 0, y: 0)
            if let near = args["near"], !near.isEmpty {
                guard let anchor = document.node(near) else { throw CanvasError.unknownNode(near) }
                preferred = CanvasPoint(x: anchor.frame.maxX + 80, y: anchor.y)
            } else if let bounds = CanvasRect.bounds(document.nodes.map(\.frame)) {
                preferred = CanvasPoint(x: bounds.minX, y: bounds.maxY + 80)
            }
            origin = kind == .group ? preferred
                : CanvasGeometry.freeSpot(for: (width, height), near: preferred, in: document)
        }
        var node = CanvasNode(id: document.newID(), kind: kind, x: origin.x, y: origin.y, width: width, height: height)
        try apply(args.filter { !["x", "y", "width", "height"].contains($0.key) }, to: &node, vault: vault)
        if kind == .text, shape != nil, node.text == nil { node.text = "" }
        switch kind {
        case .text where node.text == nil: throw CanvasError.invalid("A text card needs text.")
        case .file where node.file == nil: throw CanvasError.invalid("A file card needs file.")
        case .link where node.url == nil: throw CanvasError.invalid("A link card needs url.")
        default: return node
        }
    }

    static func apply(_ args: [String: String], to node: inout CanvasNode, vault: VaultAccess) throws {
        func optional(_ key: String) -> String?? {
            guard let value = args[key] else { return nil }
            return .some(value.isEmpty ? nil : value)
        }
        if let text = optional("text") { node.text = text }
        if let label = optional("label") { node.label = label }
        if let color = optional("color") { node.color = color }
        if let url = optional("url"), let url { node.url = url }
        if let file = args["file"], !file.isEmpty {
            let path = try VaultPath.normalize(file)
            guard vault.exists(path) else { throw VaultError.notFound(path: path) }
            node.file = path
        }
        if let size = args["fontSize"] {
            if size.isEmpty { node.fontSize = nil } else if let number = Double(size), number.isFinite, number > 0 {
                node.fontSize = number
            } else {
                throw CanvasError.invalid("fontSize is not a number.")
            }
        }
        if args["shape"] != nil { node.shape = try style(args["shape"], CanvasNodeShape.self, "shape") }
        if args["border"] != nil { node.border = try style(args["border"], CanvasBorder.self, "border") }
        if args["textAlign"] != nil { node.textAlign = try style(args["textAlign"], CanvasTextAlign.self, "textAlign") }
        if let x = try number(args, "x") { node.x = x }
        if let y = try number(args, "y") { node.y = y }
        if let width = try number(args, "width") { node.width = max(width, 1) }
        if let height = try number(args, "height") { node.height = max(height, 1) }
    }
}
