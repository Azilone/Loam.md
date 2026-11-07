import Foundation
import PluginKitUI

/// One note in the graph.
public struct GraphNode: Equatable, Sendable, Identifiable {
    public let path: String
    public let title: String
    public let tags: [String]
    /// Links to and from the note among the nodes shown.
    public var degree: Int

    public var id: String { path }
}

/// An undirected link between two nodes, as indices into `GraphData.nodes`, `a < b`.
public struct GraphEdge: Hashable, Sendable {
    public let a: Int
    public let b: Int

    public init(_ a: Int, _ b: Int) {
        self.a = min(a, b)
        self.b = max(a, b)
    }
}

/// What the graph shows, filtered: notes as nodes (sorted by path) and the links between them. A pure value built
/// from the note graph, so the filters are tested without a view.
public struct GraphData: Equatable, Sendable {
    public var nodes: [GraphNode] = []
    public var edges: [GraphEdge] = []
    /// The index of the note a local graph is centred on.
    public var center: Int?

    public init(nodes: [GraphNode] = [], edges: [GraphEdge] = [], center: Int? = nil) {
        self.nodes = nodes
        self.edges = edges
        self.center = center
    }

    /// The filters a graph tab applies.
    public struct Filter: Codable, Equatable, Sendable {
        /// Local graph only: 1 (the note, its links and backlinks) or 2 (their links and backlinks too).
        public var depth: Int = 1
        /// Keeps the notes with a tag containing this text (case-insensitive, `#` optional). Empty keeps all.
        public var tag: String = ""
        /// Whether notes without any link shown stay in the graph.
        public var showOrphans: Bool = true
        /// Top-level folders whose notes are left out ("" for the notes at the vault's root).
        public var hiddenFolders: [String] = []

        public init(depth: Int = 1, tag: String = "", showOrphans: Bool = true, hiddenFolders: [String] = []) {
            self.depth = depth
            self.tag = tag
            self.showOrphans = showOrphans
            self.hiddenFolders = hiddenFolders
        }

        /// Reads a filter saved before a field existed, that field at its default.
        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            depth = try container.decodeIfPresent(Int.self, forKey: .depth) ?? 1
            tag = try container.decodeIfPresent(String.self, forKey: .tag) ?? ""
            showOrphans = try container.decodeIfPresent(Bool.self, forKey: .showOrphans) ?? true
            hiddenFolders = try container.decodeIfPresent([String].self, forKey: .hiddenFolders) ?? []
        }
    }

    /// The top-level folder of `path`, "" for a note at the vault's root.
    public static func topFolder(of path: String) -> String {
        guard let slash = path.firstIndex(of: "/") else { return "" }
        return String(path[..<slash])
    }

    /// The graph of `notes`: the whole vault when `center` is nil, else the notes within `filter.depth` links of
    /// `center` (in either direction). Links to files that are not notes are left out. The centre note is never
    /// filtered out; an unknown centre gives an empty graph.
    public static func build(notes: [NoteInfo], center: String? = nil, filter: Filter = Filter()) -> GraphData {
        let sorted = notes.sorted { $0.path < $1.path }
        var index: [String: Int] = [:]
        for (i, note) in sorted.enumerated() { index[note.path] = i }

        var adjacency = Array(repeating: Set<Int>(), count: sorted.count)
        for (i, note) in sorted.enumerated() {
            for link in note.links {
                guard let j = index[link.target], j != i else { continue }
                adjacency[i].insert(j)
                adjacency[j].insert(i)
            }
        }

        var keep: Set<Int>
        var centerIndex: Int?
        if let center {
            guard let c = index[center] else { return GraphData() }
            centerIndex = c
            keep = [c]
            var frontier: Set<Int> = [c]
            for _ in 0 ..< max(1, min(filter.depth, 2)) {
                var next = Set<Int>()
                for i in frontier { next.formUnion(adjacency[i]) }
                next.subtract(keep)
                keep.formUnion(next)
                frontier = next
            }
        } else {
            keep = Set(sorted.indices)
        }

        let tag = normalizedTag(filter.tag)
        if !tag.isEmpty {
            keep = keep.filter { i in
                i == centerIndex || sorted[i].tags.contains { $0.lowercased().contains(tag) }
            }
        }

        if !filter.hiddenFolders.isEmpty {
            let hidden = Set(filter.hiddenFolders)
            keep = keep.filter { i in i == centerIndex || !hidden.contains(topFolder(of: sorted[i].path)) }
        }

        var degree = Array(repeating: 0, count: sorted.count)
        for i in keep {
            degree[i] = adjacency[i].intersection(keep).count
        }
        if !filter.showOrphans {
            keep = keep.filter { degree[$0] > 0 || $0 == centerIndex }
        }

        // Re-index the nodes kept, in path order.
        let kept = keep.sorted()
        var newIndex: [Int: Int] = [:]
        for (n, i) in kept.enumerated() { newIndex[i] = n }
        let nodes = kept.map { i in
            GraphNode(path: sorted[i].path, title: sorted[i].title, tags: sorted[i].tags, degree: degree[i])
        }
        var edges = Set<GraphEdge>()
        for i in kept {
            for j in adjacency[i] where i < j {
                if let a = newIndex[i], let b = newIndex[j] { edges.insert(GraphEdge(a, b)) }
            }
        }
        let edgeList = edges.sorted { ($0.a, $0.b) < ($1.a, $1.b) }
        return GraphData(nodes: nodes, edges: edgeList, center: centerIndex.flatMap { newIndex[$0] })
    }

    /// The indices linked to each node.
    public var neighbours: [Set<Int>] {
        var result = Array(repeating: Set<Int>(), count: nodes.count)
        for edge in edges {
            result[edge.a].insert(edge.b)
            result[edge.b].insert(edge.a)
        }
        return result
    }

    static func normalizedTag(_ text: String) -> String {
        var tag = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        while tag.hasPrefix("#") { tag.removeFirst() }
        return tag
    }
}
