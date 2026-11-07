import Foundation

/// The edits a board supports, shared by the board view, the `canvas.*` commands and agents: each keeps the
/// board valid (no edge to a missing node, unique ids).
extension CanvasDocument {
    /// Default card sizes, Obsidian's.
    public static let textSize = (width: 260.0, height: 80.0)
    public static let fileSize = (width: 400.0, height: 400.0)
    public static let linkSize = (width: 400.0, height: 300.0)

    /// A new id: 16 hexadecimal digits, as Obsidian makes them, unused on this board.
    public func newID() -> String {
        let used = Set(nodes.map(\.id) + edges.map(\.id))
        while true {
            let id = (0..<16).map { _ in String(Int.random(in: 0..<16), radix: 16) }.joined()
            if !used.contains(id) { return id }
        }
    }

    /// Adds a node on top of the others; a group goes under the nodes it holds.
    public mutating func add(_ node: CanvasNode) {
        if node.kind == .group,
           let first = nodes.firstIndex(where: { node.frame.contains($0.frame) }) {
            nodes.insert(node, at: first)
        } else {
            nodes.append(node)
        }
    }

    /// Moves nodes, and everything inside the groups among them.
    public mutating func move(_ ids: Set<String>, by dx: Double, _ dy: Double) {
        let moving = expandingGroups(ids)
        for index in nodes.indices where moving.contains(nodes[index].id) {
            nodes[index].x += dx
            nodes[index].y += dy
        }
    }

    /// `ids` with the members of the groups among them, nested groups included.
    public func expandingGroups(_ ids: Set<String>) -> Set<String> {
        var result = ids
        var pending = nodes.filter { ids.contains($0.id) && $0.kind == .group }
        while let group = pending.popLast() {
            for member in CanvasGeometry.members(of: group, in: self) where !result.contains(member.id) {
                result.insert(member.id)
                if member.kind == .group { pending.append(member) }
            }
        }
        return result
    }

    public mutating func setFrame(_ id: String, _ frame: CanvasRect) throws {
        guard let index = nodes.firstIndex(where: { $0.id == id }) else { throw CanvasError.unknownNode(id) }
        nodes[index].frame = frame
    }

    /// Removes nodes and edges by id, and the edges left without one of their nodes.
    public mutating func remove(_ ids: Set<String>) {
        nodes.removeAll { ids.contains($0.id) }
        let remaining = Set(nodes.map(\.id))
        edges.removeAll { ids.contains($0.id) || !remaining.contains($0.fromNode) || !remaining.contains($0.toNode) }
    }

    /// Adds an edge between two nodes and returns its id.
    @discardableResult
    public mutating func connect(_ from: String, to: String, fromSide: CanvasSide? = nil, toSide: CanvasSide? = nil,
                                 label: String? = nil) throws -> String {
        guard node(from) != nil else { throw CanvasError.unknownNode(from) }
        guard node(to) != nil else { throw CanvasError.unknownNode(to) }
        guard from != to else { throw CanvasError.invalid("An edge needs two different nodes.") }
        let id = newID()
        edges.append(CanvasEdge(id: id, fromNode: from, fromSide: fromSide, toNode: to, toSide: toSide,
                                label: label.flatMap { $0.isEmpty ? nil : $0 }))
        return id
    }

    /// Puts a labelled group around nodes and returns its id.
    @discardableResult
    public mutating func group(_ ids: Set<String>, label: String? = nil, padding: Double = 40) throws -> String {
        let frames = nodes.filter { ids.contains($0.id) }.map(\.frame)
        guard let bounds = CanvasRect.bounds(frames) else { throw CanvasError.invalid("Nothing to group.") }
        let id = newID()
        add(CanvasNode(id: id, kind: .group, x: bounds.x - padding, y: bounds.y - padding,
                       width: bounds.width + 2 * padding, height: bounds.height + 2 * padding,
                       label: label.flatMap { $0.isEmpty ? nil : $0 }))
        return id
    }

    /// The nodes with these ids (and what their groups hold) and the edges between them: what copy puts on the
    /// pasteboard, itself a valid board.
    public func fragment(_ ids: Set<String>) -> CanvasDocument {
        let kept = expandingGroups(ids)
        return CanvasDocument(
            nodes: nodes.filter { kept.contains($0.id) },
            edges: edges.filter { kept.contains($0.fromNode) && kept.contains($0.toNode) }
        )
    }

    /// Adds a copy of `fragment`, moved by `dx`, `dy`, with new ids, and returns the new nodes' ids.
    @discardableResult
    public mutating func paste(_ fragment: CanvasDocument, offsetBy dx: Double, _ dy: Double) -> [String] {
        var renamed: [String: String] = [:]
        var added: [String] = []
        for var node in fragment.nodes {
            let id = newID()
            renamed[node.id] = id
            node.id = id
            node.x += dx
            node.y += dy
            nodes.append(node)
            added.append(id)
        }
        for var edge in fragment.edges {
            guard let from = renamed[edge.fromNode], let to = renamed[edge.toNode] else { continue }
            edge.id = newID()
            edge.fromNode = from
            edge.toNode = to
            edges.append(edge)
        }
        return added
    }

    public mutating func bringToFront(_ ids: Set<String>) {
        let moving = nodes.filter { ids.contains($0.id) }
        nodes.removeAll { ids.contains($0.id) }
        nodes += moving
    }

    public mutating func sendToBack(_ ids: Set<String>) {
        let moving = nodes.filter { ids.contains($0.id) }
        nodes.removeAll { ids.contains($0.id) }
        nodes.insert(contentsOf: moving, at: 0)
    }

    /// Follows moved files (old path to new path): file nodes and group backgrounds. Returns whether anything
    /// changed.
    @discardableResult
    public mutating func follow(moves: [String: String]) -> Bool {
        var changed = false
        for index in nodes.indices {
            if let file = nodes[index].file, let moved = moves[file] {
                nodes[index].file = moved
                changed = true
            }
            if let background = nodes[index].background, let moved = moves[background] {
                nodes[index].background = moved
                changed = true
            }
        }
        return changed
    }

    /// The vault paths the board's file nodes show, in order, without repeats.
    public var files: [String] {
        var seen = Set<String>()
        return nodes.compactMap(\.file).filter { seen.insert($0).inserted }
    }
}
