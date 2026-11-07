import CoreGraphics
import Foundation
import Observation
import PluginKitUI

/// The plugin's shared state: the note graph and the open graph tabs, which it refreshes when the vault changes.
@MainActor
final class GraphStore {
    let graph: NoteGraphService
    private let workspace: @MainActor () -> (any Workspace)?
    private var tabs: [WeakTab] = []

    init(graph: NoteGraphService, workspace: @escaping @MainActor () -> (any Workspace)?) {
        self.graph = graph
        self.workspace = workspace
    }

    /// The model of one graph tab, refreshed by the store while it lives.
    func makeTab(_ view: ViewContext) -> GraphTabModel {
        let tab = GraphTabModel(store: self, view: view)
        tabs.removeAll { $0.tab == nil }
        tabs.append(WeakTab(tab: tab))
        return tab
    }

    /// `VaultChanged` and `NotesMoved`: the note graph has already applied them.
    func vaultChanged() {
        tabs.removeAll { $0.tab == nil }
        for entry in tabs { entry.tab?.reload() }
    }

    func open(_ resource: Resource, placement: Placement) {
        workspace()?.open(resource, placement: placement)
    }

    var activeResource: Resource? { workspace()?.activeResource }

    private struct WeakTab {
        weak var tab: GraphTabModel?
    }
}

/// What a graph tab saves: its filters.
struct GraphTabState: Codable, Equatable {
    var filter = GraphData.Filter()
}

/// A tag offered while typing in the filter, with the notes carrying it.
struct GraphTag: Equatable, Identifiable {
    let name: String
    let count: Int
    var id: String { name }
}

/// How far each node is into its animations, in 0...1: it appears, is lit by the pointer, and grows under it.
/// Stepped once per frame by `GraphTabModel.frame`, so the canvas only reads it.
struct NodeMotion {
    var appear: [Double] = []
    /// Seconds before a new node starts to appear, so a new graph unfolds instead of popping in at once.
    var delay: [Double] = []
    /// 1 for the focused node and its neighbours.
    var lit: [Double] = []
    /// 1 for the node under the pointer.
    var grow: [Double] = []
    /// How much the rest of the graph steps back: 1 while a node is focused, 0 otherwise.
    var focus: Double = 0

    static let appearDuration = 0.45
    static let stagger = 0.012
    static let maxDelay = 0.6

    init() {}

    init(nodeCount: Int, appeared: Set<Int>) {
        appear = (0 ..< nodeCount).map { appeared.contains($0) ? 1 : 0 }
        var rank = 0.0
        delay = (0 ..< nodeCount).map { i in
            guard !appeared.contains(i) else { return 0 }
            defer { rank += 1 }
            return min(rank * Self.stagger, Self.maxDelay)
        }
        lit = Array(repeating: 0, count: nodeCount)
        grow = Array(repeating: 0, count: nodeCount)
    }

    /// The eased size of a node that is appearing: 0 hidden, 1 in place.
    func presence(_ i: Int) -> Double {
        guard appear.indices.contains(i) else { return 1 }
        let t = 1 - appear[i]
        return 1 - t * t * t
    }
}

/// One graph tab: the filtered graph, its live layout, and the zoom, pan, hover and drag of the canvas.
///
/// The layout moves every frame while it settles, so the simulation and the camera are not observed: the canvas
/// redraws them from a `TimelineView` while `isAnimating`, and `cameraRevision` redraws it after a pan or zoom.
@MainActor
@Observable
final class GraphTabModel {
    /// The note a local graph is centred on; nil for the vault graph.
    let center: String?
    private(set) var data = GraphData()
    /// True while the layout moves: the canvas then redraws every frame.
    private(set) var isAnimating = false
    /// Bumped when the camera moves outside a frame, so the canvas redraws.
    private(set) var cameraRevision = 0
    var filter: GraphData.Filter {
        didSet { if filter != oldValue { save(); reload() } }
    }
    /// The node under the pointer; changing it starts the frames that ease the highlight.
    var hovered: Int? {
        didSet { if hovered != oldValue { animate() } }
    }

    @ObservationIgnored private(set) var simulation = ForceSimulation(nodeCount: 0, edges: [])
    @ObservationIgnored private(set) var scale: CGFloat = 1
    @ObservationIgnored private(set) var offset: CGSize = .zero
    /// The node being dragged.
    @ObservationIgnored private(set) var dragged: Int?
    /// The camera eases towards the whole graph while the layout moves, until the user pans or zooms.
    @ObservationIgnored private var followsLayout = true
    /// True once the user pans or zooms: a changed filter then leaves the camera where it is.
    @ObservationIgnored private var cameraMovedByUser = false
    /// The next frame puts the camera on the graph at once instead of easing to it (the first one).
    @ObservationIgnored private var snapsCamera = true
    @ObservationIgnored private(set) var motion = NodeMotion()
    /// The last node focused, kept while its highlight fades out.
    @ObservationIgnored private var lastFocus: Int?
    @ObservationIgnored private var lastFrame: Date?
    @ObservationIgnored private var pendingTicks: Double = 0
    @ObservationIgnored private unowned let store: GraphStore
    @ObservationIgnored private let view: ViewContext
    @ObservationIgnored private var neighbourCache: [Set<Int>] = []

    init(store: GraphStore, view: ViewContext) {
        self.store = store
        self.view = view
        center = GraphPlugin.center(of: view.resource)
        let saved = view.state(GraphTabState.self) ?? GraphTabState()
        filter = saved.filter
        reload()
    }

    var isLocal: Bool { center != nil }

    /// The title of the note a local graph is centred on.
    var centerTitle: String? { data.center.map { data.nodes[$0].title } }

    var positions: [CGPoint] { simulation.positions }

    /// Rebuilds the graph from the note graph and restarts the layout, keeping known nodes where they were.
    func reload() {
        let new = GraphData.build(notes: store.graph.notes, center: center, filter: filter)
        guard new != data || simulation.nodeCount != new.nodes.count else { return }
        var previous: [Int: CGPoint] = [:]
        let oldIndex = Dictionary(uniqueKeysWithValues: data.nodes.enumerated().map { ($1.path, $0) })
        for (i, node) in new.nodes.enumerated() {
            if let old = oldIndex[node.path], old < simulation.nodeCount { previous[i] = simulation.position(old) }
        }
        data = new
        neighbourCache = new.neighbours
        hovered = nil
        dragged = nil
        lastFocus = nil
        let count = new.nodes.count
        motion = NodeMotion(nodeCount: count, appeared: Set(previous.keys))
        if !cameraMovedByUser { followsLayout = true }
        if oldIndex.isEmpty { snapsCamera = true }
        simulation = ForceSimulation(
            nodeCount: count,
            edges: new.edges.map { ($0.a, $0.b) },
            initial: previous,
            alpha: previous.isEmpty ? 1 : previous.count == count ? 0.3 : 0.6
        )
        animate()
    }

    func neighbours(of index: Int) -> Set<Int> {
        index < neighbourCache.count ? neighbourCache[index] : []
    }

    /// A click on a node: opens its note beside the graph, so the graph stays visible.
    func open(_ index: Int) {
        guard data.nodes.indices.contains(index) else { return }
        store.open(.file(data.nodes[index].path), placement: .beside)
    }

    // MARK: Animation

    /// Moves the layout, the camera and the nodes' animations on to `date`, once per frame of the canvas: about 60
    /// ticks a second whatever the screen's refresh rate. Once everything is at rest, stops the frames (after this
    /// one: the canvas is drawing).
    func frame(at date: Date, in size: CGSize) {
        let elapsed = lastFrame.map { date.timeIntervalSince($0) } ?? 1.0 / 60
        lastFrame = date
        let dt = min(max(elapsed, 0), 0.1)
        pendingTicks = min(pendingTicks + dt * 60, 3)
        while pendingTicks >= 1 {
            simulation.tick()
            pendingTicks -= 1
        }
        var cameraSettled = true
        if followsLayout { cameraSettled = easeCamera(in: size, dt: dt) }
        let motionSettled = stepMotion(dt: dt)
        if simulation.isSettled, motionSettled, cameraSettled {
            Task { @MainActor [weak self] in self?.stopIfSettled() }
        }
    }

    private func animate() {
        lastFrame = nil
        if !isAnimating { isAnimating = true }
    }

    private func stopIfSettled() {
        guard simulation.isSettled, isAnimating else { return }
        isAnimating = false
        followsLayout = false
    }

    /// The node the pointer holds: the one being dragged, else the one under it.
    var focused: Int? { dragged ?? hovered }

    /// The node whose highlight is drawn, which stays for a moment after the pointer leaves it.
    var highlightedNode: Int? { focused ?? lastFocus }

    /// Eases the highlight and the appearance of the nodes. Returns true when nothing is left to move.
    private func stepMotion(dt: Double) -> Bool {
        let count = data.nodes.count
        guard motion.appear.count == count else { return true }
        let follow = 1 - exp(-dt * 16)
        let focus = focused
        if let focus { lastFocus = focus }
        let ring = lastFocus.map { neighbours(of: $0).union([$0]) } ?? []
        var settled = true

        for i in 0 ..< count {
            if motion.appear[i] < 1 {
                settled = false
                if motion.delay[i] > 0 {
                    motion.delay[i] -= dt
                } else {
                    motion.appear[i] = min(1, motion.appear[i] + dt / NodeMotion.appearDuration)
                }
            }
            if focus != nil {
                let target: Double = ring.contains(i) ? 1 : 0
                motion.lit[i] += (target - motion.lit[i]) * follow
                if abs(target - motion.lit[i]) < 0.005 { motion.lit[i] = target } else { settled = false }
            }
            let grow: Double = i == focus ? 1 : 0
            motion.grow[i] += (grow - motion.grow[i]) * follow
            if abs(grow - motion.grow[i]) < 0.005 { motion.grow[i] = grow } else { settled = false }
        }
        let focusTarget: Double = focus == nil ? 0 : 1
        motion.focus += (focusTarget - motion.focus) * follow
        if abs(focusTarget - motion.focus) < 0.005 {
            motion.focus = focusTarget
            if focus == nil { lastFocus = nil }
        } else {
            settled = false
        }
        return settled
    }

    // MARK: Dragging a node

    /// Starts dragging node `index`: it follows the pointer and pulls its neighbours along.
    func beginDrag(_ index: Int) {
        guard data.nodes.indices.contains(index) else { return }
        dragged = index
        followsLayout = false
        simulation.pin(index, at: simulation.position(index))
        simulation.alphaTarget = 0.3
        simulation.reheat(0.3)
        animate()
    }

    func drag(to location: CGPoint, in size: CGSize) {
        guard let dragged else { return }
        simulation.pin(dragged, at: layoutPoint(location, in: size))
    }

    func endDrag() {
        if let dragged { simulation.unpin(dragged) }
        dragged = nil
        simulation.alphaTarget = 0
    }

    // MARK: Canvas geometry

    /// Where a layout position is drawn in a canvas of `size`, after zoom and pan.
    func screenPoint(_ point: CGPoint, in size: CGSize) -> CGPoint {
        CGPoint(
            x: size.width / 2 + offset.width + point.x * scale,
            y: size.height / 2 + offset.height + point.y * scale
        )
    }

    /// The layout position drawn at `location`.
    func layoutPoint(_ location: CGPoint, in size: CGSize) -> CGPoint {
        CGPoint(
            x: (location.x - size.width / 2 - offset.width) / scale,
            y: (location.y - size.height / 2 - offset.height) / scale
        )
    }

    /// A note's dot at zoom 1: bigger with more links, as in Obsidian.
    static func radius(degree: Int) -> CGFloat {
        min(3 + CGFloat(Double(degree).squareRoot()) * 1.5, 12)
    }

    /// A note's dot on screen: it grows slower than the zoom, so a zoomed-out graph stays a cloud of dots.
    func screenRadius(degree: Int) -> CGFloat {
        max(Self.radius(degree: degree) * scale.squareRoot(), 1.5)
    }

    /// The node under `location` in a canvas of `size`, if any (the nearest one within its radius plus a margin).
    func node(at location: CGPoint, in size: CGSize) -> Int? {
        var best: (index: Int, distance: CGFloat)?
        for i in 0 ..< min(simulation.nodeCount, data.nodes.count) {
            let p = screenPoint(simulation.position(i), in: size)
            let distance = hypot(p.x - location.x, p.y - location.y)
            let reach = screenRadius(degree: data.nodes[i].degree) + 4
            if distance <= reach, distance < (best?.distance ?? .infinity) { best = (i, distance) }
        }
        return best?.index
    }

    /// Pans the canvas by `delta` points.
    func pan(by delta: CGSize) {
        offset.width += delta.width
        offset.height += delta.height
        userMovedCamera()
    }

    func setOffset(_ offset: CGSize) {
        self.offset = offset
        userMovedCamera()
    }

    private func userMovedCamera() {
        followsLayout = false
        cameraMovedByUser = true
        cameraRevision += 1
    }

    /// Zooms by `factor` around `anchor` (a point of the canvas), between 0.05 and 8.
    func zoom(by factor: CGFloat, around anchor: CGPoint, in size: CGSize) {
        let newScale = min(max(scale * factor, 0.05), 8)
        let applied = newScale / scale
        let center = CGPoint(x: size.width / 2 + offset.width, y: size.height / 2 + offset.height)
        offset.width += (anchor.x - center.x) * (1 - applied)
        offset.height += (anchor.y - center.y) * (1 - applied)
        scale = newScale
        userMovedCamera()
    }

    /// Fits the whole graph in a canvas of `size`, at once.
    func fit(in size: CGSize) {
        let target = fitTarget(in: size)
        scale = target.scale
        offset = target.offset
        cameraRevision += 1
    }

    /// Brings the whole graph back into view, easing the camera there.
    func recenter() {
        cameraMovedByUser = false
        followsLayout = true
        animate()
    }

    /// Room the camera leaves around the graph: more on top, under the page's tools.
    private static let fitInsets = (side: CGFloat(48), top: CGFloat(88), bottom: CGFloat(56))

    private func fitTarget(in size: CGSize) -> (scale: CGFloat, offset: CGSize) {
        let bounds = GraphLayout.bounds(of: positions)
        guard bounds.width > 0 || bounds.height > 0 else { return (1, .zero) }
        let inset = Self.fitInsets
        let sx = (size.width - inset.side * 2) / max(bounds.width, 1)
        let sy = (size.height - inset.top - inset.bottom) / max(bounds.height, 1)
        let scale = min(max(min(sx, sy), 0.05), 2)
        // The graph is centred in the room left, which sits a little below the middle of the canvas.
        return (scale, CGSize(width: -bounds.midX * scale, height: -bounds.midY * scale + (inset.top - inset.bottom) / 2))
    }

    /// Moves the camera a step towards the whole graph (or onto it, for the first frame). Returns true once there.
    private func easeCamera(in size: CGSize, dt: Double) -> Bool {
        let target = fitTarget(in: size)
        let k = snapsCamera ? 1 : CGFloat(1 - exp(-dt * 6))
        snapsCamera = false
        scale += (target.scale - scale) * k
        offset.width += (target.offset.width - offset.width) * k
        offset.height += (target.offset.height - offset.height) * k
        let near = abs(target.scale - scale) < 0.001 * target.scale
            && abs(target.offset.width - offset.width) < 0.5 && abs(target.offset.height - offset.height) < 0.5
        if near {
            scale = target.scale
            offset = target.offset
        }
        return near
    }

    /// How visible the labels of nodes that are not hovered are: they fade in as you zoom in, as in Obsidian.
    var labelOpacity: Double {
        if data.nodes.count <= 12 { return 1 }
        return min(max((Double(scale) - 0.7) / 0.5, 0), 1)
    }

    /// The tags to offer under what is typed in the filter, the most used first.
    func tagSuggestions(limit: Int = 6) -> [GraphTag] {
        var counts: [String: Int] = [:]
        for note in store.graph.notes {
            for tag in Set(note.tags.map { GraphData.normalizedTag($0) }) where !tag.isEmpty { counts[tag, default: 0] += 1 }
        }
        let typed = GraphData.normalizedTag(filter.tag)
        let matches = counts.filter { typed.isEmpty || $0.key.contains(typed) }
            .sorted { ($1.value, $0.key) < ($0.value, $1.key) }
        if matches.count == 1, matches[0].key == typed { return [] }
        return matches.prefix(limit).map { GraphTag(name: $0.key, count: $0.value) }
    }

    /// The size of the graph shown, in the corner of the canvas.
    var stats: String {
        let notes = data.nodes.count == 1 ? "1 note" : "\(data.nodes.count) notes"
        let links = data.edges.count == 1 ? "1 link" : "\(data.edges.count) links"
        return "\(notes) · \(links)"
    }

    /// The vault's top-level folders ("" for its root) with how many notes each holds, the fullest first.
    var folders: [(name: String, count: Int)] {
        var counts: [String: Int] = [:]
        for note in store.graph.notes { counts[GraphData.topFolder(of: note.path), default: 0] += 1 }
        return counts.map { (name: $0.key, count: $0.value) }
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0.name < $1.name }
    }

    /// Shows or hides the notes of a top-level folder.
    func toggleFolder(_ name: String) {
        if let index = filter.hiddenFolders.firstIndex(of: name) {
            filter.hiddenFolders.remove(at: index)
        } else {
            filter.hiddenFolders.append(name)
        }
    }

    /// The indices of the nodes with the most links shown, at most `limit`, the most linked first.
    func mostLinked(limit: Int = 5) -> [Int] {
        data.nodes.indices
            .filter { data.nodes[$0].degree > 0 }
            .sorted { data.nodes[$0].degree != data.nodes[$1].degree
                ? data.nodes[$0].degree > data.nodes[$1].degree : data.nodes[$0].title < data.nodes[$1].title }
            .prefix(limit)
            .map { $0 }
    }

    /// True when the options differ from their defaults, which the options button shows.
    var hasCustomOptions: Bool {
        !filter.showOrphans || !filter.hiddenFolders.isEmpty || (isLocal && filter.depth != GraphData.Filter().depth)
    }

    /// What VoiceOver says about the canvas.
    var summary: String {
        let notes = data.nodes.count == 1 ? "1 note" : "\(data.nodes.count) notes"
        let links = data.edges.count == 1 ? "1 link" : "\(data.edges.count) links"
        if let c = data.center {
            return "Local graph of \(data.nodes[c].title): \(notes), \(links)"
        }
        return "Graph of the vault: \(notes), \(links)"
    }

    private func save() {
        view.setState(GraphTabState(filter: filter))
    }
}
