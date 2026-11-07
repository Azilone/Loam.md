import AppKit
import CanvasPlugin
import Foundation
import Observation
import PluginKitUI
import SwiftUI

/// What the pointer does on the board: select (a drag on the empty board draws a selection rectangle), move the
/// board, or draw: a pen or a highlighter stroke, a free line or arrow, or erase strokes.
enum BoardTool: String, Codable {
    case select, hand, pen, highlighter, eraser, line, arrow

    /// The tools whose drags draw rather than select.
    var draws: Bool { ![.select, .hand].contains(self) }
}

/// The end of a free line being dragged: which end, and where it is now (board units).
struct LineEndDrag: Equatable {
    let id: String
    let movesStart: Bool
    var point: CanvasPoint
}

/// Text being edited in place: a text card's Markdown, a group's label or an edge's label.
struct BoardEditing: Equatable {
    enum Target: Equatable {
        case node(String)
        case edge(String)
        /// A cell of a table card: its row (0 is the header) and column.
        case cell(String, Int, Int)
    }

    let target: Target
    var draft: String
}

/// An arrow being drawn from a card's side; `target` is the card under the pointer, if any. When `reconnect` is
/// set it is an existing arrow whose end is being moved: `from` and `side` are the end that stays.
struct PendingLink: Equatable {
    struct Reconnect: Equatable {
        let edge: String
        /// True when the arrow's start is the end being moved.
        let movesStart: Bool
    }

    let from: String
    let side: CanvasSide
    var point: CanvasPoint
    var target: String?
    var reconnect: Reconnect?
}

/// A presentation in progress: the slides in the order they are shown, and the one on screen.
struct BoardPresentation: Equatable {
    var slides: [String]
    var index: Int

    var current: String { slides[index] }
}

/// The slide going away while the next one comes in, as in Keynote's Push: drawn where it was on screen
/// (`screen`, view points) and pushed out by `shift` towards the side opposite the new slide's.
struct BoardSlideChange: Equatable {
    let id: UUID
    let slide: String
    let rect: CanvasRect
    let screen: CGRect
    /// The way the slides go: 1 to the next (the old one leaves to the left), -1 back.
    var shift: CGFloat
    var opacity: Double
}

/// What a board tab saves: where the camera was, and whether the minimap is shown.
struct BoardTabState: Codable, Equatable {
    var x: Double
    var y: Double
    var scale: Double
    var minimap: Bool?
}

/// One board tab: the board as last read or edited, the camera, the selection and the gesture in progress. Every
/// edit is one undo step and is saved shortly after (`saveDelay`), through the `canvas` service.
@MainActor
@Observable
final class BoardModel {
    let path: String
    let camera = CanvasCamera(minScale: 0.05, maxScale: 4)
    @ObservationIgnored let pointer = CanvasPointer()

    private(set) var document = CanvasDocument()
    /// Why the board cannot be shown or edited (the file does not parse): it is never written then.
    private(set) var loadError: String?
    var selection: Set<String> = []
    var selectedEdge: String?
    var tool: BoardTool = .select {
        didSet { if tool != oldValue { inkSession = nil } }
    }
    /// The colour and width of new strokes and lines; nil is the text colour.
    var inkColor: String?
    var inkWidth: Double = 3
    var highlighterColor: String = "3"
    /// The stroke or line being drawn, in board units.
    private(set) var liveStroke: [CanvasPoint] = []
    /// The end of a line being moved.
    private(set) var lineEnd: LineEndDrag?
    /// The drawing the pen adds to while it stays near: strokes made one after the other are one drawing.
    @ObservationIgnored private var inkSession: String?
    @ObservationIgnored private var eraseStart: CanvasDocument?
    /// The shape the toolbar's shape button adds: the last one chosen.
    var lastShape: CanvasNodeShape = .rectangle
    var editing: BoardEditing?
    private(set) var hovered: String?
    /// Where the pointer is over the hovered card, in the card's own points: the light on its glass follows it.
    var hoverPoint: CGPoint?
    var showsMinimap = false
    /// The camera moved a moment ago: far-away cards are drawn without their titles, which cost most, until it rests.
    private(set) var isNavigating = false

    /// A move in progress: the cards moved (groups' contents included) and by how much, in board units.
    private(set) var dragged: Set<String> = []
    private(set) var dragDelta = CGSize.zero
    /// A resize in progress: the card and its frame so far.
    private(set) var resizing: (id: String, frame: CanvasRect)?
    /// Cards and arrows that have just been made: they animate in, once.
    private(set) var justAdded: Set<String> = []
    private(set) var edgeBirths: [String: Date] = [:]
    /// The selection rectangle, in view coordinates.
    private(set) var marquee: CGRect?
    private(set) var link: PendingLink?
    /// The slide shown, while the board is presented.
    private(set) var presentation: BoardPresentation?
    /// Each slide's place in the presentation, from 1: frames show it on their label.
    private(set) var slideNumbers: [String: Int] = [:]
    /// The slide leaving the screen during a change of slide.
    private(set) var slideChange: BoardSlideChange?
    /// How far sideways the board (the slide coming in) is drawn from its place, during a change of slide.
    private(set) var presentShift: CGFloat = 0
    /// Counts the pointer's moves while presenting: the presentation's bar shows again.
    var pointerMoves = 0
    @ObservationIgnored private var cameraBeforePresenting: (offset: CGSize, scale: CGFloat)?

    var hasKeyboard = false
    /// Something the board takes is being dragged over it.
    var dropTargeted = false
    private(set) var focusRequest = 0
    /// The card whose live view (a mindmap…) has been entered with a double-click: it takes the clicks, the keys
    /// and the scrolling until the board is clicked again.
    private(set) var activeEmbed: String?
    @ObservationIgnored private var embedContexts: [String: ViewContext] = [:]
    /// Where each fitted card's content was last (`ViewContext.contentBounds`): a card moves by as much as its
    /// content's origin does, so a map growing to the left stays where it is on the board.
    @ObservationIgnored private var embedBounds: [String: CGRect] = [:]


    @ObservationIgnored weak var undoManager: UndoManager?
    @ObservationIgnored private(set) var index = CanvasSpatialIndex(nodes: [])
    @ObservationIgnored private var positions: [String: Int] = [:]
    @ObservationIgnored private var curves: [String: CanvasCurve] = [:]
    @ObservationIgnored private var settleTask: Task<Void, Never>?
    @ObservationIgnored private var lastText: String?
    @ObservationIgnored private var dirty = false
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var fitted = false
    @ObservationIgnored private var marqueeBase: Set<String> = []
    @ObservationIgnored private var resizeStart: CanvasRect?
    @ObservationIgnored private var resizeHandle = CanvasHandle.bottomRight
    @ObservationIgnored let store: BoardStore
    @ObservationIgnored let view: ViewContext

    static let saveDelay: Duration = .milliseconds(400)
    /// Levels of detail. From `nearScale` up, every card is a view with its real content; below `farScale` cards are
    /// drawn small, all in one pass (`BoardFarCards`); in between the two cross-fade, so zooming never jumps.
    static let farScale: CGFloat = 0.30
    static let nearScale: CGFloat = 0.40
    /// From this scale, cards get their glass (a glass view per card is the dearest thing on the board).
    static let glassScale: CGFloat = 0.5
    /// At most this many cards show glass at once.
    static let glassLimit = 70
    /// How many cards are views at once: the nearest the middle of the view; the rest of those in view are drawn in the
    /// same pass as the far ones. A dense board at a middling zoom stays fluid.
    static let viewBudget = 60
    /// How many live views (PDFs, videos, mindmaps…) the board keeps at once.
    static let liveLimit = 6
    /// How many maps drawn at their own size are live at once: a board of several mindmaps shows them all.
    static let liveMapLimit = 16

    /// How much of the real cards shows at a scale: 0 (only the small drawing) to 1 (only the cards).
    static func detailAlpha(_ scale: CGFloat) -> Double {
        Double(min(1, max(0, (scale - farScale) / (nearScale - farScale))))
    }

    init(store: BoardStore, view: ViewContext) {
        self.store = store
        self.view = view
        path = view.resource.path
        load()
        if let state = view.state(BoardTabState.self) {
            camera.offset = CGSize(width: state.x, height: state.y)
            camera.scale = min(max(state.scale, camera.minScale), camera.maxScale)
            showsMinimap = state.minimap ?? false
            fitted = true
        }
        store.register(self)
    }

    var title: String { CardFile.title(of: path) }
    var isEditable: Bool { loadError == nil }

    // MARK: - Reading and saving

    private func load() {
        do {
            let text = try store.vault.read(path)
            document = try CanvasDocument(text: text)
            lastText = text
            fitFreeText()
            loadError = nil
        } catch let error as CanvasError {
            loadError = error.description
        } catch {
            loadError = "The board could not be read."
        }
        rebuild()
    }

    /// Free text is as big as its text: one written elsewhere with another size is shown fitted (and saved so with the
    /// next edit; opening a board never writes it).
    private func fitFreeText() {
        for index in document.nodes.indices where document.nodes[index].sizesToText {
            let node = document.nodes[index]
            let size = store.fittedSize(of: node)
            if abs(size.width - node.width) > 0.5 || abs(size.height - node.height) > 0.5 {
                document.nodes[index].width = size.width
                document.nodes[index].height = size.height
            }
        }
    }

    /// Reads the file again when it changed outside this tab (another tab, an agent, a moved note). Unsaved edits
    /// win: they are written over it shortly after.
    func reloadFromDisk() {
        guard !dirty, let text = try? store.vault.read(path), text != lastText else { return }
        let before = document
        load()
        if document != before {
            selection = selection.filter { positions[$0] != nil }
            if let edge = selectedEdge, document.edge(edge) == nil { selectedEdge = nil }
        }
    }

    private func rebuild() {
        index = CanvasSpatialIndex(nodes: document.nodes)
        curves = [:]
        positions = Dictionary(uniqueKeysWithValues: document.nodes.enumerated().map { ($1.id, $0) })
        let slides = document.nodes.contains { $0.ratio != nil } ? document.slides() : []
        let numbers = Dictionary(uniqueKeysWithValues: slides.enumerated().map { ($1, $0 + 1) })
        if numbers != slideNumbers { slideNumbers = numbers }
    }

    private func scheduleSave() {
        dirty = true
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: Self.saveDelay)
            guard !Task.isCancelled else { return }
            self?.flush()
        }
    }

    /// Writes pending edits now (the tab closes, the app quits).
    func flush() {
        saveTask?.cancel()
        guard dirty, isEditable else { return }
        do {
            try store.service.write(path, document)
            lastText = document.text
            dirty = false
        } catch {
            loadError = "The board could not be saved: \(error)"
        }
    }

    func saveCamera() {
        view.setState(BoardTabState(x: camera.offset.width, y: camera.offset.height, scale: camera.scale,
                                    minimap: showsMinimap ? true : nil))
    }

    // MARK: - Edits

    /// Applies a change that follows from something else (a card fitting its map): saved, but no undo step of its own.
    private func adjust(_ change: (inout CanvasDocument) -> Void) {
        guard isEditable else { return }
        let before = document
        change(&document)
        guard document != before else { return }
        rebuild()
        scheduleSave()
    }

    /// Applies one edit as one undo step and saves it.
    func edit(_ name: String, _ change: (inout CanvasDocument) throws -> Void) rethrows {
        guard isEditable else { return }
        let before = document
        try change(&document)
        guard document != before else { return }
        rebuild()
        registerUndo(restoring: before, name: name)
        scheduleSave()
    }

    private func registerUndo(restoring old: CanvasDocument, name: String) {
        undoManager?.registerUndo(withTarget: self) { model in
            MainActor.assumeIsolated {
                let current = model.document
                model.document = old
                model.rebuild()
                model.selection = model.selection.filter { model.positions[$0] != nil }
                model.registerUndo(restoring: current, name: name)
                model.scheduleSave()
            }
        }
        undoManager?.setActionName(name)
    }

    /// The arrow whose label is being edited.
    var editedEdge: String? {
        if case .edge(let id) = editing?.target { return id }
        return nil
    }

    func node(_ id: String) -> CanvasNode? { positions[id].map { document.nodes[$0] } }

    /// Where a node is drawn now, with the move or resize in progress.
    func frame(of node: CanvasNode) -> CanvasRect {
        if let resizing, resizing.id == node.id { return resizing.frame }
        if dragged.contains(node.id) { return node.frame.offsetBy(dragDelta.width, dragDelta.height) }
        // Free text being written is as big as what is typed so far.
        if let editing, editing.target == .node(node.id), node.isFreeText {
            let size = store.freeTextSize(editing.draft, fontSize: node.effectiveFontSize)
            // Hugs the text, as it will once written: the editor takes the room it needs past it (`BoardTextEditor`).
            return CanvasRect(x: node.x, y: node.y, width: size.width, height: size.height)
        }
        return node.frame
    }

    /// The nodes to draw: those near the screen, bottom to top, and the ones being moved.
    func visibleNodes() -> [CanvasNode] {
        let margin = 240 / camera.scale
        let visible = camera.visibleWorldRect.insetBy(dx: -margin, dy: -margin)
        var ids = Set(index.nodes(in: CanvasRect(visible)))
        ids.formUnion(dragged)
        if let resizing { ids.insert(resizing.id) }
        // In the board's order, found through the positions: a big board is not walked whole at every frame.
        return ids.compactMap { positions[$0] }.sorted().map { document.nodes[$0] }
    }

    /// The cards to build as views: all of them, or when there are too many, those nearest the middle of the view (and
    /// whatever is selected, moved, edited or entered, which must stay a view).
    func viewCards(among cards: [CanvasNode]) -> [CanvasNode] {
        guard cards.count > Self.viewBudget else { return cards }
        let middle = CanvasPoint(camera.worldPoint(CGPoint(x: camera.viewSize.width / 2, y: camera.viewSize.height / 2)))
        var keep = selection.union(dragged)
        if let resizing { keep.insert(resizing.id) }
        if let activeEmbed { keep.insert(activeEmbed) }
        if case .node(let id) = editing?.target { keep.insert(id) }
        if case .cell(let id, _, _) = editing?.target { keep.insert(id) }
        let nearest = cards.filter { !keep.contains($0.id) }.sorted {
            ($0.frame.center - middle).length < ($1.frame.center - middle).length
        }.prefix(max(0, Self.viewBudget - keep.count))
        let ids = keep.union(nearest.map(\.id))
        return cards.filter { ids.contains($0.id) }
    }

    /// The cards that may show a live view (a PDF, a video, a mindmap): the few nearest the middle of the view, big
    /// enough on screen to be worth it, and the one entered. The others show their name and kind.
    func liveEmbeds(among cards: [CanvasNode]) -> Set<String> {
        let middle = CGPoint(x: camera.viewSize.width / 2, y: camera.viewSize.height / 2)
        let scale = camera.scale
        var candidates: [(id: String, distance: CGFloat)] = []
        var maps: [(id: String, distance: CGFloat)] = []
        for node in cards where node.kind == .file {
            guard let file = node.file, store.embeddedViewType(for: file) != nil || store.mediaViewType(for: file) != nil
            else { continue }
            let rect = camera.screenRect(CGRect(frame(of: node)))
            // A map drawn at its own size is the board's content, not a window onto a file: it stays live smaller.
            let bare = isBare(node)
            guard rect.width >= (bare ? 40 : 140), rect.height >= (bare ? 20 : 100), scale >= Self.farScale,
                  rect.intersects(CGRect(origin: .zero, size: camera.viewSize)) else { continue }
            let item = (node.id, hypot(rect.midX - middle.x, rect.midY - middle.y))
            if bare { maps.append(item) } else { candidates.append(item) }
        }
        var live = Set(candidates.sorted { $0.distance < $1.distance }.prefix(Self.liveLimit).map(\.id))
        live.formUnion(maps.sorted { $0.distance < $1.distance }.prefix(Self.liveMapLimit).map(\.id))
        if let activeEmbed { live.insert(activeEmbed) }
        return live
    }

    /// The card under a view point, for cards that are only drawn (far out, or past `viewBudget`): they are not views,
    /// so the board answers their clicks. A card that is a view takes its clicks first and never gets here.
    func card(atViewPoint location: CGPoint) -> CanvasNode? {
        node(at: CanvasPoint(camera.worldPoint(location))).flatMap(node).flatMap { $0.kind == .group ? nil : $0 }
    }

    // MARK: - The selection

    var selectedNodes: [CanvasNode] { document.nodes.filter { selection.contains($0.id) } }

    /// Where the selected cards are drawn now, in board units.
    var selectionBounds: CanvasRect? { CanvasRect.bounds(selectedNodes.map { frame(of: $0) }) }

    var selectedEdgeValue: CanvasEdge? { selectedEdge.flatMap { document.edge($0) } }

    /// The font size shared by the selected text cards; nil when they differ or none is selected.
    var selectedFontSize: Double? {
        let sizes = Set(selectedNodes.filter { $0.kind == .text }.map(\.effectiveFontSize))
        return sizes.count == 1 ? sizes.first : nil
    }

    var selectionHasText: Bool { selectedNodes.contains { $0.kind == .text } }

    /// The colour shared by the selection (or the selected arrow); nil when mixed or none.
    var selectedColor: String? {
        if let edge = selectedEdgeValue { return edge.color }
        let colors = Set(selectedNodes.map { $0.drawing?.strokes.first.map { $0.color ?? "" } ?? $0.color ?? "" })
        return colors.count == 1 ? colors.first.flatMap { $0.isEmpty ? nil : $0 } : nil
    }

    /// Marks cards or arrows as new, so they animate in; the mark goes away once they have.
    private func markAppeared(_ ids: some Sequence<String>, edges: Bool = false) {
        let ids = Array(ids)
        if edges {
            for id in ids { edgeBirths[id] = Date() }
        } else {
            justAdded.formUnion(ids)
        }
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard let self else { return }
            if edges { for id in ids { self.edgeBirths[id] = nil } } else { self.justAdded.subtract(ids) }
        }
    }

    /// The new card's top-left corner: centred on `point`, at a free spot.
    /// A free spot for a new card near `point`. It may be past the edge of the view when the middle is full: the view
    /// then moves to it, so what was just added is never out of sight.
    private func spot(for size: (width: Double, height: Double), around point: CanvasPoint) -> CanvasPoint {
        let origin = CanvasGeometry.freeSpot(for: size, near: CanvasPoint(x: point.x - size.width / 2,
                                                                          y: point.y - size.height / 2),
                                             in: document, gap: 24)
        camera.reveal(CGRect(x: origin.x, y: origin.y, width: size.width, height: size.height))
        return origin
    }

    var viewCenter: CanvasPoint {
        CanvasPoint(camera.worldPoint(CGPoint(x: camera.viewSize.width / 2, y: camera.viewSize.height / 2)))
    }

    /// Where a card made from the keyboard or the toolbar goes: under the pointer, else the middle of the view.
    var insertionPoint: CanvasPoint {
        pointer.location.map { CanvasPoint(camera.worldPoint($0)) } ?? viewCenter
    }

    /// The size new free text is written at.
    static let freeTextFontSize = 20.0

    /// Text where `point` is: free text standing on the board (no card around it, as big as its text) whose first
    /// line starts at the point, or with `card` a text card at a free spot around it.
    @discardableResult
    func addText(at point: CanvasPoint, text: String = "", editNow: Bool = true, card: Bool = false) -> String? {
        guard isEditable else { return nil }
        let id = document.newID()
        var node: CanvasNode
        if card {
            let size = CanvasDocument.textSize
            let origin = spot(for: size, around: point)
            node = CanvasNode(id: id, kind: .text, x: origin.x.rounded(), y: origin.y.rounded(), width: size.width,
                              height: size.height, text: text)
        } else {
            let fontSize = Self.freeTextFontSize
            let size = store.freeTextSize(text, fontSize: fontSize)
            node = CanvasNode(id: id, kind: .text, x: (point.x - Double(BoardStyle.freeTextPadding)).rounded(),
                              y: (point.y - fontSize * 0.75).rounded(), width: size.width, height: size.height,
                              text: text, fontSize: fontSize)
            node.border = .invisible
        }
        edit(card ? "Add Card" : "Add Text") { $0.add(node) }
        selection = [id]
        selectedEdge = nil
        markAppeared([id])
        if editNow { beginEditing(.node(id)) }
        return id
    }

    /// The size of a new sticky note, and its colour (yellow).
    static let stickySize = (width: 220.0, height: 220.0)
    static let stickyFontSize = 18.0

    /// A sticky note centred on `point` (at a free spot), its text being typed.
    @discardableResult
    func addSticky(at point: CanvasPoint) -> String? {
        guard isEditable else { return nil }
        let size = Self.stickySize
        let origin = spot(for: size, around: point)
        let id = document.newID()
        var node = CanvasNode(id: id, kind: .text, x: origin.x.rounded(), y: origin.y.rounded(), width: size.width,
                              height: size.height, color: "3", text: "", fontSize: Self.stickyFontSize)
        node.isSticky = true
        edit("Add Sticky Note") { $0.add(node) }
        selection = [id]
        selectedEdge = nil
        markAppeared([id])
        beginEditing(.node(id))
        return id
    }

    /// A Kanban to start from: three groups side by side (To do, Doing, Done), a sticky note in the first.
    @discardableResult
    func addKanban(at point: CanvasPoint) -> [String] {
        guard isEditable else { return [] }
        let column = (width: 300.0, height: 520.0), gap = 40.0
        let left = (point.x - (column.width * 3 + gap * 2) / 2).rounded(), top = (point.y - column.height / 2).rounded()
        var ids: [String] = []
        edit("Add Kanban") { document in
            for (index, label) in ["To do", "Doing", "Done"].enumerated() {
                let id = document.newID()
                document.add(CanvasNode(id: id, kind: .group, x: left + Double(index) * (column.width + gap), y: top,
                                        width: column.width, height: column.height, color: ["2", "5", "4"][index],
                                        label: label))
                ids.append(id)
            }
            var sticky = CanvasNode(id: document.newID(), kind: .text, x: left + 30, y: top + 30, width: column.width - 60,
                                    height: 120, color: "3", text: "A first task", fontSize: Self.stickyFontSize)
            sticky.isSticky = true
            document.add(sticky)
            ids.append(sticky.id)
        }
        selection = []
        markAppeared(ids)
        return ids
    }

    /// A few sticky notes to start a brainstorm, the first being written.
    @discardableResult
    func addStickies(at point: CanvasPoint) -> [String] {
        guard isEditable else { return [] }
        let size = Self.stickySize, gap = 30.0
        let left = (point.x - (size.width * 3 + gap * 2) / 2).rounded(), top = (point.y - size.height / 2).rounded()
        var ids: [String] = []
        edit("Add Sticky Notes") { document in
            for (index, color) in ["3", "5", "1"].enumerated() {
                var sticky = CanvasNode(id: document.newID(), kind: .text, x: left + Double(index) * (size.width + gap),
                                        y: top, width: size.width, height: size.height, color: color, text: "",
                                        fontSize: Self.stickyFontSize)
                sticky.isSticky = true
                document.add(sticky)
                ids.append(sticky.id)
            }
        }
        markAppeared(ids)
        if let first = ids.first {
            selection = [first]
            beginEditing(.node(first))
        }
        return ids
    }

    /// A shape (a text card drawn as a diamond, a circle…) centred on `point`, its text being typed. A rectangle is
    /// a plain card with centred text.
    @discardableResult
    func addShape(_ shape: CanvasNodeShape, at point: CanvasPoint, editNow: Bool = true) -> String? {
        guard isEditable else { return nil }
        let size = shape.defaultSize
        let origin = spot(for: size, around: point)
        let id = document.newID()
        var node = CanvasNode(id: id, kind: .text, x: origin.x.rounded(), y: origin.y.rounded(), width: size.width,
                              height: size.height, text: "")
        node.shape = shape
        if shape == .rectangle { node.textAlign = .center }
        lastShape = shape
        edit("Add Shape") { $0.add(node) }
        selection = [id]
        selectedEdge = nil
        markAppeared([id])
        if editNow { beginEditing(.node(id)) }
        return id
    }

    @discardableResult
    func addFile(_ file: String, at point: CanvasPoint) -> String? {
        guard isEditable, file != path else { return nil }
        let size = CardFile.defaultSize(of: file, imageSize: CardFile.kind(of: file) == .image ? store.image(file)?.size : nil)
        let origin = spot(for: size, around: point)
        let id = document.newID()
        edit("Add Card") {
            $0.add(CanvasNode(id: id, kind: .file, x: origin.x.rounded(), y: origin.y.rounded(), width: size.width,
                              height: size.height, file: file))
        }
        selection = [id]
        selectedEdge = nil
        markAppeared([id])
        return id
    }

    /// Files dropped or pasted from outside the vault become cards: copied into the attachments folder unless they
    /// are in the vault already. Several are fanned out from `point`.
    func addFiles(_ urls: [URL], at point: CanvasPoint) async {
        var added: [String] = []
        // A folder brings its files, the first `folderLimit` of them.
        let urls = urls.flatMap { url -> [URL] in
            guard url.hasDirectoryPath else { return [url] }
            let inside = (try? FileManager.default.contentsOfDirectory(
                at: url, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
            )) ?? []
            return Array(inside.filter { !$0.hasDirectoryPath }.sorted { $0.lastPathComponent < $1.lastPathComponent }
                .prefix(Self.folderLimit))
        }
        for (index, url) in urls.enumerated() {
            guard let path = await store.bringIn(url) else { continue }
            let at = CanvasPoint(x: point.x + Double(index) * 36, y: point.y + Double(index) * 36)
            if let id = addFile(path, at: at) { added.append(id) }
        }
        if added.count > 1 { selection = Set(added) }
        requestKeyboard()
    }

    /// How many files a dropped folder brings at most.
    static let folderLimit = 40

    /// A folder of the vault dragged from the sidebar: a card for each of its files, fanned out from `point`.
    func addFolder(_ folder: String, at point: CanvasPoint) {
        let files = store.files(in: folder).prefix(Self.folderLimit)
        var added: [String] = []
        for (index, file) in files.enumerated() {
            let at = CanvasPoint(x: point.x + Double(index) * 36, y: point.y + Double(index) * 36)
            if let id = addFile(file, at: at) { added.append(id) }
        }
        if added.count > 1 { selection = Set(added) }
    }

    func addImage(_ data: Data, pathExtension: String, at point: CanvasPoint) async {
        guard let path = await store.bringIn(imageData: data, pathExtension: pathExtension) else { return }
        addFile(path, at: point)
        requestKeyboard()
    }

    @discardableResult
    func addLink(_ url: String, at point: CanvasPoint) -> String? {
        guard isEditable else { return nil }
        let size = URL(string: url).map { CanvasLinkKind($0).cardSize } ?? CanvasDocument.linkSize
        let origin = spot(for: size, around: point)
        let id = document.newID()
        edit("Add Card") {
            $0.add(CanvasNode(id: id, kind: .link, x: origin.x.rounded(), y: origin.y.rounded(), width: size.width,
                              height: size.height, url: url))
        }
        selection = [id]
        selectedEdge = nil
        markAppeared([id])
        return id
    }

    func deleteSelection() {
        if let edge = selectedEdge {
            edit("Delete Arrow") { $0.remove([edge]) }
            selectedEdge = nil
            return
        }
        guard !selection.isEmpty else { return }
        edit(selection.count == 1 ? "Delete Card" : "Delete Cards") { $0.remove(selection) }
        selection = []
    }

    @discardableResult
    func duplicateSelection(offset: Double = 40) -> [String] {
        guard !selection.isEmpty else { return [] }
        let fragment = document.fragment(selection)
        var added: [String] = []
        edit("Duplicate") { added = $0.paste(fragment, offsetBy: offset, offset) }
        selection = Set(added)
        markAppeared(added)
        return added
    }

    /// The size of a group made empty, to drop cards into.
    static let emptyGroupSize = (width: 520.0, height: 340.0)

    /// An empty group around `point`, its label being typed: cards dragged or dropped into it then belong to it (a
    /// group holds what lies inside it).
    @discardableResult
    func addGroup(at point: CanvasPoint) -> String? {
        guard isEditable else { return nil }
        let size = Self.emptyGroupSize
        let origin = spot(for: size, around: point)
        let id = document.newID()
        edit("Add Group") {
            $0.add(CanvasNode(id: id, kind: .group, x: origin.x.rounded(), y: origin.y.rounded(), width: size.width,
                              height: size.height, label: "Group"))
        }
        selection = [id]
        selectedEdge = nil
        markAppeared([id])
        beginEditing(.node(id))
        return id
    }

    /// A frame (a 16:9 slide) around the selection, or with nothing selected an empty one centred on `point`.
    @discardableResult
    func addFrame(at point: CanvasPoint) -> String? {
        guard isEditable else { return nil }
        let rect: CanvasRect
        if let bounds = selectionBounds {
            rect = CanvasDocument.frame(around: bounds)
        } else {
            let size = CanvasDocument.frameSize
            rect = CanvasRect(x: (point.x - size.width / 2).rounded(), y: (point.y - size.height / 2).rounded(),
                              width: size.width, height: size.height)
        }
        var id = ""
        edit("Add Frame") { id = $0.addFrame(rect) }
        selection = [id]
        selectedEdge = nil
        markAppeared([id])
        if CanvasRect(camera.visibleWorldRect).contains(rect) == false { camera.show(CGRect(rect), maxScale: 1) }
        return id
    }

    /// Makes a frame the first slide of the presentation.
    func makeStartSlide(_ id: String) { edit("Start Slide") { $0.startNode = id } }

    // MARK: - Presenting

    /// Shows the board slide by slide, from `id` (else the selected frame, else the first slide). Nothing happens on
    /// a board without frames or groups.
    func present(from id: String? = nil) {
        commitEditing()
        let slides = document.slides()
        guard !slides.isEmpty else { return }
        let start = id ?? selection.first(where: { slides.contains($0) })
        cameraBeforePresenting = camera.destination
        presentation = BoardPresentation(slides: slides, index: start.flatMap { slides.firstIndex(of: $0) } ?? 0)
        selection = []
        selectedEdge = nil
        leaveEmbed()
        showSlide()
        requestKeyboard()
    }

    func nextSlide() { moveSlide(by: 1) }
    func previousSlide() { moveSlide(by: -1) }

    /// A classic slide change, not a flight across the board: the slide on screen is pushed out to the left while the
    /// next one comes in from the right (the other way going back), both with `Spring.smooth`; under Reduce Motion
    /// the old slide fades out over the new one.
    private func moveSlide(by step: Int) {
        guard var current = presentation else { return }
        let index = current.index + step
        guard current.slides.indices.contains(index) else { return }
        let leaving = current.current
        let leavingRect = presentedFrame
        let leavingScreen = leavingRect.map { camera.screenRect(CGRect($0)) }
        current.index = index
        presentation = current
        showSlide()
        guard let leavingRect, let leavingScreen, camera.viewSize.width > 0 else { return }
        let id = UUID()
        // The board view pushes the old slide out and the board in from the side (a fade under Reduce Motion): the
        // camera is already on the new slide, so nothing is laid out again on the way.
        slideChange = BoardSlideChange(id: id, slide: leaving, rect: leavingRect, screen: leavingScreen,
                                       shift: step > 0 ? 1 : -1, opacity: 1)
        DispatchQueue.main.asyncAfter(deadline: .now() + Motion.Spring.smooth.duration * 1.5) { [weak self] in
            if self?.slideChange?.id == id { self?.slideChange = nil }
        }
    }

    func stopPresenting() {
        guard presentation != nil else { return }
        presentation = nil
        slideChange = nil
        presentShift = 0
        if let before = cameraBeforePresenting {
            camera.move(to: before.offset, scale: before.scale, animated: true)
        }
        cameraBeforePresenting = nil
    }

    /// Where the slide on screen is, in board units.
    var presentedFrame: CanvasRect? { presentation.flatMap { node($0.current)?.frame } }

    /// The camera framing the slide: as large as the view allows, a little room round it.
    private func showSlide() {
        guard let rect = presentedFrame, camera.viewSize.width > 0 else { return }
        let margin: CGFloat = 28
        let scale = min((camera.viewSize.width - margin * 2) / CGFloat(rect.width),
                        (camera.viewSize.height - margin * 2) / CGFloat(rect.height))
        camera.scale = min(max(scale, camera.minScale), camera.maxScale)
        camera.offset = CGSize(width: camera.viewSize.width / 2 - CGFloat(rect.center.x) * camera.scale,
                               height: camera.viewSize.height / 2 - CGFloat(rect.center.y) * camera.scale)
    }

    /// Cmd-G: groups the selection, or with nothing selected makes an empty group to drop cards into.
    func groupSelection() {
        guard !selection.isEmpty else {
            addGroup(at: insertionPoint)
            return
        }
        var group = ""
        edit("Group") { group = try! $0.group(selection, label: "Group") }
        selection = [group]
        markAppeared([group])
        beginEditing(.node(group))
    }

    func selectAll() {
        selection = Set(document.nodes.map(\.id))
        selectedEdge = nil
    }

    func nudge(_ dx: Double, _ dy: Double) {
        guard !selection.isEmpty else { return }
        edit("Move") { $0.move(selection, by: dx, dy) }
    }

    func setColor(_ color: String?) {
        if let edge = selectedEdge {
            edit("Color") { document in
                if let index = document.edges.firstIndex(where: { $0.id == edge }) { document.edges[index].color = color }
            }
            return
        }
        edit("Color") { document in
            for index in document.nodes.indices where selection.contains(document.nodes[index].id) {
                let node = document.nodes[index]
                // A drawing's colour is its strokes' (a highlighter's stays see-through).
                if var ink = node.drawing {
                    ink.strokes = ink.strokes.map { stroke in
                        var changed = stroke
                        changed.color = color ?? (stroke.opacity < 1 ? "3" : nil)
                        return changed
                    }
                    if let redrawn = CanvasNode.drawing(id: node.id, ink) {
                        document.nodes[index].frame = redrawn.frame
                        document.nodes[index].text = redrawn.text
                    }
                    continue
                }
                document.nodes[index].color = color
            }
        }
    }

    /// Changes the text cards of the selection.
    private func editSelectedText(_ name: String, _ change: (inout CanvasNode) -> Void) {
        let ids = Set(selectedNodes.filter { $0.kind == .text }.map(\.id))
        guard !ids.isEmpty else { return }
        edit(name) { document in
            for index in document.nodes.indices where ids.contains(document.nodes[index].id) { change(&document.nodes[index]) }
        }
    }

    /// Draws the selected text cards as `shape`; a card keeps its size, but grows if its text no longer fits.
    func setShape(_ shape: CanvasNodeShape) {
        editSelectedText("Shape") { node in
            let wasPlain = node.shape == nil && node.textAlign == nil
            node.shape = shape
            if shape == .rectangle, wasPlain { node.textAlign = .center }
            node.height = max(node.height, BoardText.height(of: node.text ?? "", fontSize: node.effectiveFontSize,
                                                            width: node.width, shape: node.shape))
        }
    }

    /// Back to a plain card: no shape, an outline, text on the left; free text gets a card's room around it.
    func clearShape() {
        editSelectedText("Shape") { node in
            let wasFree = node.isFreeText
            node.shape = nil
            if node.border == .invisible { node.border = nil }
            if node.textAlign == .center { node.textAlign = nil }
            if wasFree {
                node.width = max(node.width + Double(BoardStyle.textPadding - BoardStyle.freeTextPadding) * 2,
                                 BoardStyle.minimumCard.width)
                node.height = BoardText.height(of: node.text ?? "", fontSize: node.effectiveFontSize, width: node.width)
            }
        }
    }

    /// Text standing on the board by itself: no card, as big as its text.
    func makeFreeText() {
        editSelectedText("Text") { node in
            node.shape = nil
            node.border = .invisible
            self.setFreeFontSize(&node, node.effectiveFontSize, anchor: .topLeft)
        }
    }

    func setBorder(_ border: CanvasBorder) { editSelectedText("Border") { $0.border = border } }
    func setTextAlign(_ align: CanvasTextAlign) { editSelectedText("Text Alignment") { $0.textAlign = align } }

    /// The shape shared by the selected text cards; nil when they differ or are plain cards.
    var selectionIsFreeText: Bool {
        let texts = selectedNodes.filter { $0.kind == .text }
        return !texts.isEmpty && texts.allSatisfy(\.isFreeText)
    }

    var selectedShape: CanvasNodeShape? {
        let shapes = Set(selectedNodes.filter { $0.kind == .text }.map { node in
            node.shape?.rawValue ?? (node.textAlign == .center ? CanvasNodeShape.rectangle.rawValue : "")
        })
        return shapes.count == 1 ? shapes.first.flatMap(CanvasNodeShape.init(rawValue:)) : nil
    }

    func bringToFront() { edit("Bring to Front") { $0.bringToFront(selection) } }
    func sendToBack() { edit("Send to Back") { $0.sendToBack(selection) } }

    // MARK: - Text size, alignment, arrows

    /// One step larger or smaller for the text cards of the selection. A card whose height fitted its text keeps
    /// fitting; one the user made taller only grows when the text no longer fits.
    func stepFontSize(larger: Bool) {
        let ids = Set(selectedNodes.filter { $0.kind == .text }.map(\.id))
        guard !ids.isEmpty else { return }
        edit("Text Size") { document in
            for index in document.nodes.indices where ids.contains(document.nodes[index].id) {
                let node = document.nodes[index]
                if node.sizesToText {
                    self.setFreeFontSize(&document.nodes[index], node.steppedFontSize(larger: larger), anchor: .topLeft)
                    continue
                }
                let wasFitted = abs(node.height - BoardText.height(of: node.text ?? "", fontSize: node.effectiveFontSize,
                                                                    width: node.width, shape: node.shape)) < 4
                let size = node.steppedFontSize(larger: larger)
                document.nodes[index].fontSize = size == CanvasNode.defaultFontSize ? nil : size
                let needed = BoardText.height(of: node.text ?? "", fontSize: size, width: node.width, shape: node.shape)
                document.nodes[index].height = wasFitted ? needed : max(node.height, needed)
            }
        }
    }

    func setFontSize(_ size: Double) {
        let ids = Set(selectedNodes.filter { $0.kind == .text }.map(\.id))
        guard !ids.isEmpty else { return }
        edit("Text Size") { document in
            for index in document.nodes.indices where ids.contains(document.nodes[index].id) {
                let node = document.nodes[index]
                if node.sizesToText {
                    self.setFreeFontSize(&document.nodes[index], size, anchor: .topLeft)
                    continue
                }
                document.nodes[index].fontSize = size == CanvasNode.defaultFontSize ? nil : size
                document.nodes[index].height = max(node.height, BoardText.height(of: node.text ?? "", fontSize: size,
                                                                                  width: node.width, shape: node.shape))
            }
        }
    }

    /// Makes the selected text cards just tall enough for their text.
    func fitToText() {
        let ids = Set(selectedNodes.filter { $0.kind == .text }.map(\.id))
        guard !ids.isEmpty else { return }
        edit("Fit to Text") { document in
            for index in document.nodes.indices where ids.contains(document.nodes[index].id) {
                let node = document.nodes[index]
                if node.sizesToText {
                    self.setFreeFontSize(&document.nodes[index], node.effectiveFontSize, anchor: .topLeft)
                    continue
                }
                document.nodes[index].height = BoardText.height(of: node.text ?? "", fontSize: node.effectiveFontSize,
                                                                width: node.width, shape: node.shape)
            }
        }
    }

    /// Gives free text a font size and makes it as big as its text at that size, the corner `anchor` staying put.
    private func setFreeFontSize(_ node: inout CanvasNode, _ size: Double, anchor: CanvasHandle) {
        let fontSize = (min(max(size, BoardStyle.freeTextSizes.lowerBound), BoardStyle.freeTextSizes.upperBound) * 2)
            .rounded() / 2
        let fitted = store.fittedSize(of: node, fontSize: fontSize)
        let fixed = anchor.position(in: node.frame)
        node.fontSize = fontSize
        node.x = (anchor.movesRight ? fixed.x - fitted.width : anchor.movesLeft ? fixed.x : node.x).rounded()
        node.y = (anchor.movesBottom ? fixed.y - fitted.height : anchor.movesTop ? fixed.y : node.y).rounded()
        node.width = fitted.width
        node.height = fitted.height
    }

    func align(_ alignment: CanvasAlignment) { edit("Align") { $0.align(selection, to: alignment) } }
    func distribute(_ axis: CanvasAxis) { edit("Distribute") { $0.distribute(selection, along: axis) } }

    /// Changes the selected arrow.
    func editSelectedEdge(_ name: String, _ change: (inout CanvasEdge) -> Void) {
        guard let id = selectedEdge else { return }
        edit(name) { document in
            guard let index = document.edges.firstIndex(where: { $0.id == id }) else { return }
            change(&document.edges[index])
        }
    }

    func setEdgeShape(_ shape: CanvasEdgeShape) {
        editSelectedEdge("Arrow Shape") { $0.shape = shape == .curve ? nil : shape }
    }

    func toggleEdgeDashed() { editSelectedEdge("Dashes") { $0.dashed = $0.isDashed ? nil : true } }

    /// Which ends of the selected arrow carry a head.
    func setEdgeHeads(start: Bool, end: Bool) {
        editSelectedEdge("Arrow Heads") {
            $0.fromEnd = start ? .arrow : nil
            $0.toEnd = end ? nil : CanvasEnd.none
        }
    }

    func reverseEdge() {
        editSelectedEdge("Reverse Arrow") { edge in
            swap(&edge.fromNode, &edge.toNode)
            swap(&edge.fromSide, &edge.toSide)
            swap(&edge.fromEnd, &edge.toEnd)
        }
    }

    // MARK: - Pasteboard

    /// The selection as a JSON Canvas fragment, itself a board; nil when nothing is selected.
    func copySelection() -> String? {
        guard !selection.isEmpty else { return nil }
        return document.fragment(selection).text
    }

    func cutSelection() -> String? {
        let text = copySelection()
        if text != nil { deleteSelection() }
        return text
    }

    /// Pastes cards copied from a board around `point`; a web address becomes a link card, other text a text card.
    func paste(_ text: String, at point: CanvasPoint) {
        guard isEditable else { return }
        if let fragment = try? CanvasDocument(text: text), !fragment.nodes.isEmpty,
           let bounds = CanvasRect.bounds(fragment.nodes.map(\.frame)) {
            var added: [String] = []
            edit("Paste") {
                added = $0.paste(fragment, offsetBy: (point.x - bounds.center.x).rounded(),
                                 (point.y - bounds.center.y).rounded())
            }
            selection = Set(added)
            markAppeared(added)
            return
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if let url = URL(string: trimmed), let scheme = url.scheme, ["http", "https"].contains(scheme),
           !trimmed.contains(" ") {
            addLink(trimmed, at: point)
        } else {
            // A line or two stands on the board as text; more is a card to read.
            addText(at: point, text: trimmed, editNow: false, card: trimmed.count > 280 || trimmed.contains("\n\n"))
        }
    }

    /// What the pasteboard holds, pasted at the pointer: files and pictures become cards, text as `paste(_:at:)`.
    func pasteFromPasteboard(_ pasteboard: NSPasteboard) {
        let point = insertionPoint
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           !urls.isEmpty {
            Task { await addFiles(urls, at: point) }
            return
        }
        if let text = pasteboard.string(forType: .string), !text.isEmpty {
            paste(text, at: point)
            return
        }
        for (type, ext) in [(NSPasteboard.PasteboardType.png, "png"), (.tiff, "png")] {
            guard var data = pasteboard.data(forType: type) else { continue }
            if type == .tiff, let png = NSBitmapImageRep(data: data)?.representation(using: .png, properties: [:]) {
                data = png
            }
            Task { await addImage(data, pathExtension: ext, at: point) }
            return
        }
    }

    /// Whatever is dropped becomes cards where it lands: a note or a folder dragged from the sidebar, files and folders
    /// from the Finder (any kind of file: a picture, a PDF, a video, an archive), a picture or a link dragged from a
    /// browser, some text from another app. False when the pasteboard holds none of these.
    @discardableResult
    func drop(_ pasteboard: NSPasteboard, at point: CanvasPoint) -> Bool {
        if let data = pasteboard.data(forType: NSPasteboard.PasteboardType(DragPayload.type.identifier)) {
            guard let string = String(data: data, encoding: .utf8), case .resource(let resource) = DragPayload(string: string)
            else { return false }
            switch resource.kind {
            case .file: addFile(resource.path, at: point)
            case .folder: addFolder(resource.path, at: point)
            default: return false
            }
            requestKeyboard()
            return true
        }
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           !urls.isEmpty {
            Task { await addFiles(urls, at: point) }
            return true
        }
        for type in [NSPasteboard.PasteboardType.png, .tiff] {
            guard var data = pasteboard.data(forType: type) else { continue }
            if type == .tiff, let png = NSBitmapImageRep(data: data)?.representation(using: .png, properties: [:]) {
                data = png
            }
            Task { await addImage(data, pathExtension: "png", at: point) }
            return true
        }
        if let url = (pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL])?.first {
            paste(url.absoluteString, at: point)
            return true
        }
        if let text = pasteboard.string(forType: .string), !text.isEmpty {
            paste(text, at: point)
            return true
        }
        return false
    }

    /// The pasteboard types `drop(_:at:)` takes.
    static let dropTypes: [NSPasteboard.PasteboardType] = [
        NSPasteboard.PasteboardType(DragPayload.type.identifier), .fileURL, .png, .tiff, .URL, .string,
    ]

    // MARK: - Selecting and moving

    /// A click on a card at `point` (in board units from its top-left corner): a table's cell takes a double-click.
    func tap(_ node: CanvasNode, count: Int, extend: Bool, at point: CGPoint) {
        guard node.isTable, let layout = store.tableLayout(node.text ?? "", fontSize: node.effectiveFontSize),
              let cell = layout.cell(at: point) else {
            tap(node, count: count, extend: extend)
            return
        }
        tableCursor = (node.id, cell.row, cell.column)
        if count >= 2, isEditable {
            if activeEmbed != nil { leaveEmbed() }
            selection = [node.id]
            selectedEdge = nil
            beginEditing(.cell(node.id, cell.row, cell.column))
            return
        }
        tap(node, count: count, extend: extend)
    }

    func tap(_ node: CanvasNode, count: Int, extend: Bool) {
        if activeEmbed != node.id { leaveEmbed() }
        selectedEdge = nil
        if count >= 2 {
            selection = [node.id]
            activate(node)
            // An entered card (a mindmap) takes the keyboard itself: the board's shortcuts must not get the typing.
            if activeEmbed != node.id { requestKeyboard() }
            return
        }
        requestKeyboard()
        if extend {
            if selection.contains(node.id) { selection.remove(node.id) } else { selection.insert(node.id) }
        } else {
            selection = [node.id]
        }
    }

    /// Double-click: edit a text card or a group's label, open a note or a board, open a web page.
    func activate(_ node: CanvasNode) {
        switch node.kind {
        case .text where node.isDrawing:
            break
        case .text where node.isTable:
            beginEditing(.cell(node.id, tableCursor?.id == node.id ? tableCursor!.row : 0,
                               tableCursor?.id == node.id ? tableCursor!.column : 0))
        case .text, .group:
            beginEditing(.node(node.id))
        case .file:
            guard let file = node.file else { return }
            if store.embeddedViewType(for: file) != nil {
                enterEmbed(node.id)
                return
            }
            if CardFile.kind(of: file).isLiveMediaKind {
                store.open(file, placement: .beside)
                return
            }
            store.open(file, placement: CardFile.kind(of: file) == .board ? .replace : .beside)
        case .link:
            // A PDF already scrolls once selected; anything else is browsed in the card.
            if let url = node.url.flatMap(URL.init(string:)), CanvasLinkKind(url) == .pdf { return }
            enterEmbed(node.id)
        case .other:
            break
        }
    }

    func openInBrowser(_ node: CanvasNode) {
        if let url = node.url.flatMap(URL.init(string:)) { NSWorkspace.shared.open(url) }
    }

    func tapBackground(at location: CGPoint, count: Int, extend: Bool = false) {
        // An arrow whose drag never ended (its gesture was lost) is let go.
        link = nil
        leaveEmbed()
        requestKeyboard()
        commitEditing()
        // A card that is only drawn (far out, or past `viewBudget`) is not a view: the board answers for it.
        if let card = card(atViewPoint: location) {
            tap(card, count: count, extend: extend)
            return
        }
        if let edge = edge(at: location) {
            selection = []
            selectedEdge = edge
            if count >= 2 { beginEditing(.edge(edge)) }
            return
        }
        selectedEdge = nil
        selection = []
        if count >= 2 { addText(at: CanvasPoint(camera.worldPoint(location))) }
    }

    /// The edge within a few points of a view point.
    func edge(at location: CGPoint) -> String? {
        let point = CanvasPoint(camera.worldPoint(location))
        // A thin line is hard to hit: a finger's width round it counts.
        let tolerance = 14 / camera.scale
        var best: (id: String, distance: Double)?
        for edge in document.edges {
            guard let curve = curve(of: edge),
                  curve.bounds.insetBy(-tolerance).contains(point) else { continue }
            let distance = curve.distance(to: point)
            if distance <= tolerance, distance < (best?.distance ?? .infinity) { best = (edge.id, distance) }
        }
        return best?.id
    }

    /// An edge's curve between its nodes as drawn now. Kept while nothing moves: panning and zooming do not
    /// compute a thousand curves again.
    func curve(of edge: CanvasEdge) -> CanvasCurve? {
        let still = dragged.isEmpty && resizing == nil
        if still, let known = curves[edge.id] { return known }
        guard let from = node(edge.fromNode), let to = node(edge.toNode) else { return nil }
        let curve = CanvasGeometry.curve(from: frame(of: from), side: edge.fromSide, to: frame(of: to), side: edge.toSide,
                                         straight: edge.isStraight)
        if still { curves[edge.id] = curve }
        return curve
    }

    /// The card under a board point: the top-most card, else the innermost group, as they are drawn (groups always
    /// under cards, whatever their order in the file).
    func node(at point: CanvasPoint) -> String? {
        let hits = index.nodes(in: CanvasRect(x: point.x, y: point.y, width: 0.01, height: 0.01)).compactMap(node)
        return (hits.last { $0.kind != .group } ?? hits.last)?.id
    }

    func setHovered(_ id: String?) {
        if hovered != id { hovered = id }
    }

    func beginDrag(_ node: CanvasNode, extend: Bool, duplicate: Bool = false) {
        guard isEditable else { return }
        commitEditing()
        selectedEdge = nil
        if !selection.contains(node.id) { selection = extend ? selection.union([node.id]) : [node.id] }
        if duplicate {
            // Option-drag moves a copy and leaves the card where it was.
            let copies = duplicateSelection(offset: 0)
            dragged = document.expandingGroups(Set(copies))
        } else {
            dragged = document.expandingGroups(selection)
        }
        dragDelta = .zero
    }

    /// Moves what is dragged by a pointer translation (view points), freely: no magnet, no guides.
    func updateDrag(_ translation: CGSize) {
        guard !dragged.isEmpty else { return }
        dragDelta = CGSize(width: (translation.width / camera.scale).rounded(),
                           height: (translation.height / camera.scale).rounded())
    }

    func endDrag() {
        guard !dragged.isEmpty else { return }
        let moved = dragged, delta = dragDelta
        dragged = []
        dragDelta = .zero
        guard delta != .zero else { return }
        edit("Move") { document in
            for index in document.nodes.indices where moved.contains(document.nodes[index].id) {
                document.nodes[index].x += delta.width
                document.nodes[index].y += delta.height
            }
        }
    }

    func beginResize(_ node: CanvasNode, handle: CanvasHandle) {
        guard isEditable else { return }
        commitEditing()
        resizeStart = node.frame
        resizeHandle = handle
        resizing = (node.id, node.frame)
    }

    /// Drags the handle by a pointer translation (view points); `keepRatio` holds the proportions.
    func updateResize(_ translation: CGSize, keepRatio: Bool = false) {
        guard let start = resizeStart, let id = resizing?.id else { return }
        let resized = node(id)
        let minimum = resized?.kind == .group ? BoardStyle.minimumGroup : resized?.sizesToText == true ? (16, 12)
            : BoardStyle.minimumCard
        // Free text scales as a whole, and a slide keeps its proportions.
        // A map drawn at its own size scales as a whole too.
        let keepRatio = keepRatio || resized?.sizesToText == true || resized?.ratio != nil
            || resized.map(isBare) == true
        let frame = start.resized(resizeHandle, by: Double(translation.width / camera.scale),
                                  Double(translation.height / camera.scale), minimum: minimum, keepRatio: keepRatio)
        resizing = (id, CanvasRect(x: frame.x.rounded(), y: frame.y.rounded(), width: frame.width.rounded(),
                                   height: frame.height.rounded()))
    }

    func endResize() {
        guard let resizing else { return }
        self.resizing = nil
        resizeStart = nil
        if let node = node(resizing.id), node.sizesToText {
            // The text took the new size: its font grows or shrinks with it.
            let size = node.effectiveFontSize * resizing.frame.height / max(node.height, 1)
            let anchor = resizeHandle.opposite
            edit("Text Size") { document in
                guard let index = document.nodes.firstIndex(where: { $0.id == node.id }) else { return }
                document.nodes[index].frame = resizing.frame
                self.setFreeFontSize(&document.nodes[index], size, anchor: anchor)
            }
            return
        }
        if let node = node(resizing.id), let ink = node.drawing {
            // Strokes are stretched to the new frame.
            let scaled = ink.offsetBy(-node.x, -node.y)
                .scaledBy(resizing.frame.width / max(node.width, 1), resizing.frame.height / max(node.height, 1))
                .offsetBy(resizing.frame.x, resizing.frame.y)
            setDrawing(node.id, scaled, name: "Resize")
            return
        }
        if let node = node(resizing.id), let size = scaledFontSize(of: node, in: resizing.frame) {
            edit("Resize") { document in
                guard let index = document.nodes.firstIndex(where: { $0.id == node.id }) else { return }
                document.nodes[index].frame = resizing.frame
                document.nodes[index].fontSize = size
            }
            return
        }
        edit("Resize") { try? $0.setFrame(resizing.id, resizing.frame) }
        // A link card keeps the height its content needs at its new width: no empty space.
        fitLink(resizing.id)
    }

    /// The font size of a card whose text is centred (a shape, a label card) resized to `frame`: its text grows and
    /// shrinks with it, as a label does, as far as it still fits. Nil for a card whose text flows (it rewraps).
    func scaledFontSize(of node: CanvasNode, in frame: CanvasRect) -> Double? {
        guard node.kind == .text, node.centresText, !node.isSticky, !node.isTable, !node.isDrawing, !node.sizesToText,
              node.width > 0, node.height > 0 else { return nil }
        let ratio = ((frame.width / node.width) * (frame.height / node.height)).squareRoot()
        guard abs(ratio - 1) > 0.01 else { return nil }
        let text = node.text ?? ""
        var size = min(max(node.effectiveFontSize * ratio, 8), 200)
        // As big as it would be, unless the text would no longer fit: then as big as fits.
        for _ in 0..<12 where size > 8
            && BoardText.height(of: text, fontSize: size, width: frame.width, shape: node.shape) > frame.height + 1 {
            size = max(8, size * 0.9)
        }
        return (size * 2).rounded() / 2
    }

    func beginMarquee(extend: Bool) {
        commitEditing()
        marqueeBase = extend ? selection : []
        selectedEdge = nil
    }

    func updateMarquee(_ rect: CGRect) {
        marquee = rect
        let world = CanvasRect(CGRect(origin: camera.worldPoint(rect.origin),
                                      size: CGSize(width: rect.width / camera.scale, height: rect.height / camera.scale)))
        let inside = index.nodes(in: world).filter { id in
            guard let node = node(id) else { return false }
            // A group is caught only when the rectangle covers it all, so selecting cards inside one is easy.
            return node.kind != .group || world.contains(node.frame)
        }
        selection = marqueeBase.union(inside)
    }

    func endMarquee() {
        marquee = nil
        marqueeBase = []
    }

    // MARK: - Arrows

    func beginLink(from node: CanvasNode, side: CanvasSide) {
        guard isEditable else { return }
        commitEditing()
        link = PendingLink(from: node.id, side: side, point: frame(of: node).anchor(side), target: nil)
    }

    /// Starts moving one end of the selected arrow: dragged onto another card, it is attached there.
    func beginReconnect(_ edge: CanvasEdge, movesStart: Bool) {
        guard isEditable, let from = node(edge.fromNode), let to = node(edge.toNode) else { return }
        commitEditing()
        let sides = CanvasGeometry.sides(from: from.frame, to: to.frame)
        let anchor = movesStart ? to : from
        let side = movesStart ? (edge.toSide ?? sides.1) : (edge.fromSide ?? sides.0)
        link = PendingLink(from: anchor.id, side: side, point: frame(of: movesStart ? from : to)
            .anchor(movesStart ? (edge.fromSide ?? sides.0) : (edge.toSide ?? sides.1)), target: nil,
                           reconnect: .init(edge: edge.id, movesStart: movesStart))
    }

    func updateLink(to location: CGPoint) {
        guard var pending = link else { return }
        let point = CanvasPoint(camera.worldPoint(location))
        pending.point = point
        let target = node(at: point)
        pending.target = target == pending.from ? nil : target
        link = pending
    }

    /// The side of `node` nearest to a board point.
    private func nearestSide(of node: CanvasNode, to point: CanvasPoint) -> CanvasSide {
        CanvasSide.allCases.min {
            (node.frame.anchor($0) - point).length < (node.frame.anchor($1) - point).length
        } ?? .left
    }

    /// Connects to the card under the pointer, entering by its side nearest the pointer; dropped on the empty
    /// board, the arrow gets a new text card there, edited at once. A moved arrow end dropped on the empty board
    /// goes back where it was.
    func endLink() {
        guard let pending = link else { return }
        link = nil
        if let reconnect = pending.reconnect {
            guard let target = pending.target, let to = node(target) else { return }
            let side = nearestSide(of: to, to: pending.point)
            editSelectedEdge("Move Arrow") { edge in
                if reconnect.movesStart {
                    edge.fromNode = target
                    edge.fromSide = side
                } else {
                    edge.toNode = target
                    edge.toSide = side
                }
            }
            return
        }
        if let target = pending.target, let to = node(target) {
            let side = nearestSide(of: to, to: pending.point)
            var made: String?
            edit("Connect") { made = try? $0.connect(pending.from, to: target, fromSide: pending.side, toSide: side) }
            if let made {
                selectedEdge = made
                selection = []
                markAppeared([made], edges: true)
            }
            return
        }
        guard let from = node(pending.from), (pending.point - from.frame.anchor(pending.side)).length > 40 else { return }
        let size = CanvasDocument.textSize
        let origin: CanvasPoint
        switch pending.side {
        case .right: origin = CanvasPoint(x: pending.point.x, y: pending.point.y - size.height / 2)
        case .left: origin = CanvasPoint(x: pending.point.x - size.width, y: pending.point.y - size.height / 2)
        case .bottom: origin = CanvasPoint(x: pending.point.x - size.width / 2, y: pending.point.y)
        case .top: origin = CanvasPoint(x: pending.point.x - size.width / 2, y: pending.point.y - size.height)
        }
        let id = document.newID()
        var edgeID: String?
        edit("Add Card") { document in
            document.add(CanvasNode(id: id, kind: .text, x: origin.x.rounded(), y: origin.y.rounded(),
                                    width: size.width, height: size.height, text: ""))
            edgeID = try? document.connect(pending.from, to: id, fromSide: pending.side, toSide: pending.side.opposite)
        }
        selection = [id]
        markAppeared([id])
        if let edgeID { markAppeared([edgeID], edges: true) }
        beginEditing(.node(id))
    }

    // MARK: - Drawing

    /// The widths the style bar offers for a pen, and the highlighter's.
    static let inkWidths: [Double] = [2, 4, 8]
    static let highlighterWidth = 18.0
    static let highlighterOpacity = 0.35

    func beginStroke(at point: CanvasPoint) {
        guard isEditable else { return }
        commitEditing()
        selection = []
        selectedEdge = nil
        if tool == .eraser {
            eraseStart = document
            erase(at: point)
            return
        }
        liveStroke = [point]
    }

    /// The pointer moved with the button down: the stroke goes on; a line or arrow keeps its start and follows, at
    /// 45° steps when `snaps`.
    func continueStroke(to point: CanvasPoint, snaps: Bool = false) {
        switch tool {
        case .eraser:
            erase(at: point)
        case .line, .arrow:
            guard let start = liveStroke.first else { return }
            liveStroke = [start, snaps ? Self.snapped(point, from: start) : point]
        default:
            guard let last = liveStroke.last, (point - last).length * Double(camera.scale) >= 1 else { return }
            liveStroke.append(point)
        }
    }

    /// The pointer went up: the stroke becomes part of a drawing, a line becomes one.
    func endStroke() {
        defer { liveStroke = [] }
        switch tool {
        case .eraser:
            if let before = eraseStart, before != document { registerUndo(restoring: before, name: "Erase") }
            eraseStart = nil
        case .line, .arrow:
            guard liveStroke.count == 2, (liveStroke[1] - liveStroke[0]).length * Double(camera.scale) > 8 else { return }
            let line = CanvasInk(kind: .line, strokes: [CanvasInkStroke(points: liveStroke, color: inkColor,
                                                                        width: inkWidth)],
                                 endArrow: tool == .arrow)
            let id = document.newID()
            guard let node = CanvasNode.drawing(id: id, line) else { return }
            edit(tool == .arrow ? "Draw Arrow" : "Draw Line") { $0.add(node) }
            markAppeared([id])
        case .pen, .highlighter:
            guard !liveStroke.isEmpty else { return }
            let highlights = tool == .highlighter
            let points = CanvasInkStroke.simplify(liveStroke, tolerance: 0.6 / Double(camera.scale))
            let stroke = CanvasInkStroke(points: points, color: highlights ? highlighterColor : inkColor,
                                         width: highlights ? Self.highlighterWidth : inkWidth,
                                         opacity: highlights ? Self.highlighterOpacity : 1)
            addStroke(stroke)
        default:
            break
        }
    }

    /// Adds a stroke to the drawing being made if it is near, else starts a new one.
    private func addStroke(_ stroke: CanvasInkStroke) {
        let strokeBounds = CanvasInk(strokes: [stroke]).bounds
        if let id = inkSession, let node = node(id), var ink = node.drawing, ink.kind == .ink,
           let strokeBounds, node.frame.insetBy(-160).intersects(strokeBounds) {
            ink.strokes.append(stroke)
            guard let grown = CanvasNode.drawing(id: id, ink) else { return }
            edit("Draw") { document in
                guard let index = document.nodes.firstIndex(where: { $0.id == id }) else { return }
                document.nodes[index].frame = grown.frame
                document.nodes[index].text = grown.text
            }
            return
        }
        let id = document.newID()
        guard let node = CanvasNode.drawing(id: id, CanvasInk(strokes: [stroke])) else { return }
        edit("Draw") { $0.add(node) }
        inkSession = id
    }

    /// Takes away the strokes of drawings under the pointer; a drawing left empty goes. No undo step until the
    /// pointer goes up (`endStroke`).
    private func erase(at point: CanvasPoint) {
        let radius = 8 / Double(camera.scale)
        let near = index.nodes(in: CanvasRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2))
        for id in near {
            guard let node = node(id), var ink = node.drawing else { continue }
            let hit = ink.strokes(near: point, radius: radius)
            guard !hit.isEmpty else { continue }
            ink.strokes = ink.strokes.enumerated().filter { !hit.contains($0.offset) }.map(\.element)
            adjust { document in
                guard let index = document.nodes.firstIndex(where: { $0.id == id }) else { return }
                if ink.strokes.isEmpty || ink.kind == .line {
                    document.remove([id])
                } else if let redrawn = CanvasNode.drawing(id: id, ink) {
                    document.nodes[index].frame = redrawn.frame
                    document.nodes[index].text = redrawn.text
                }
            }
        }
    }

    /// The point at 45° steps from `start`, as far as `point`.
    static func snapped(_ point: CanvasPoint, from start: CanvasPoint) -> CanvasPoint {
        let delta = point - start
        let angle = (atan2(delta.y, delta.x) / (.pi / 4)).rounded() * (.pi / 4)
        return CanvasPoint(x: start.x + cos(angle) * delta.length, y: start.y + sin(angle) * delta.length)
    }

    /// Writes a drawing back into its node, the node's frame becoming its bounds.
    private func setDrawing(_ id: String, _ ink: CanvasInk, name: String) {
        guard let redrawn = CanvasNode.drawing(id: id, ink) else { return }
        edit(name) { document in
            guard let index = document.nodes.firstIndex(where: { $0.id == id }) else { return }
            document.nodes[index].frame = redrawn.frame
            document.nodes[index].text = redrawn.text
        }
    }

    var selectedLine: CanvasNode? {
        guard selection.count == 1, let node = selectedNodes.first, node.drawing?.kind == .line else { return nil }
        return node
    }

    func beginLineEnd(_ node: CanvasNode, movesStart: Bool) {
        guard isEditable, let ends = node.drawing?.ends else { return }
        lineEnd = LineEndDrag(id: node.id, movesStart: movesStart, point: movesStart ? ends.0 : ends.1)
    }

    func updateLineEnd(to point: CanvasPoint, snaps: Bool) {
        guard var drag = lineEnd, let ends = node(drag.id)?.drawing?.ends else { return }
        drag.point = snaps ? Self.snapped(point, from: drag.movesStart ? ends.1 : ends.0) : point
        lineEnd = drag
    }

    func endLineEnd() {
        guard let drag = lineEnd else { return }
        lineEnd = nil
        guard var ink = node(drag.id)?.drawing, !ink.strokes.isEmpty else { return }
        let index = drag.movesStart ? 0 : ink.strokes[0].points.count - 1
        ink.strokes[0].points[index] = drag.point
        setDrawing(drag.id, ink, name: "Move Line End")
    }

    /// A line's ends as drawn now, with an end being dragged.
    func lineEnds(of node: CanvasNode) -> (CanvasPoint, CanvasPoint)? {
        guard let ends = node.drawing?.ends else { return nil }
        guard let drag = lineEnd, drag.id == node.id else { return ends }
        return drag.movesStart ? (drag.point, ends.1) : (ends.0, drag.point)
    }

    /// The selected line's heads.
    func setLineHeads(start: Bool, end: Bool) {
        guard let node = selectedLine, var ink = node.drawing else { return }
        ink.startArrow = start
        ink.endArrow = end
        setDrawing(node.id, ink, name: "Arrow Heads")
    }

    func toggleLineDashed() {
        guard let node = selectedLine, var ink = node.drawing, !ink.strokes.isEmpty else { return }
        ink.strokes[0].dashed.toggle()
        setDrawing(node.id, ink, name: "Dashes")
    }

    /// Thinner or thicker strokes for the selected drawings.
    func setDrawingWidth(_ width: Double) {
        for node in selectedNodes {
            guard var ink = node.drawing else { continue }
            ink.strokes = ink.strokes.map { stroke in
                var changed = stroke
                if stroke.opacity >= 1 { changed.width = width }
                return changed
            }
            setDrawing(node.id, ink, name: "Width")
        }
    }

    var selectionHasDrawing: Bool { selectedNodes.contains { $0.isDrawing } }

    // MARK: - Live cards

    /// The context of a card's live view, kept for the card's life so the view keeps its state.
    func embedContext(for node: CanvasNode) -> ViewContext? {
        guard let file = node.file else { return nil }
        let key = node.id + "\u{0}" + file
        if let known = embedContexts[key] { return known }
        let context = ViewContext(resource: .file(file), isActive: activeEmbed == node.id, presentation: .embedded)
        embedContexts[key] = context
        return context
    }

    /// A card whose view draws its content at its own size (a mindmap): no card round it.
    func isBare(_ node: CanvasNode) -> Bool {
        node.kind == .file && node.file.flatMap { store.embeddedViewType(for: $0) }?.sizesToContent == true
    }

    /// A fitted card's view says where its content is now: the card takes that size, moved by as much as the
    /// content's origin moved.
    /// A card resized by hand keeps its size: the content is drawn scaled to it (`embedScale`), and grows at that
    /// scale. The same content shown again (the card scrolled back into view, the board presented) changes nothing.
    func embedContentChanged(_ id: String, bounds: CGRect?) {
        guard let bounds, bounds.width > 0, bounds.height > 0 else { return }
        let previous = embedBounds[id]
        embedBounds[id] = bounds
        guard let node = node(id), previous != bounds, resizing?.id != id else { return }
        var frame = node.frame
        let scale: Double
        if let previous {
            scale = node.width / max(Double(previous.width), 1)
            frame.x += Double(bounds.minX - previous.minX) * scale
            frame.y += Double(bounds.minY - previous.minY) * scale
        } else {
            // First seen: a card in the content's proportions was scaled by hand and keeps its size; any other
            // (a card just added) takes the content's own.
            let ratio = node.width / max(node.height, 1)
            let content = Double(bounds.width / bounds.height)
            scale = abs(ratio / content - 1) < 0.03 ? node.width / Double(bounds.width) : 1
        }
        frame.width = (Double(bounds.width) * scale).rounded()
        frame.height = (Double(bounds.height) * scale).rounded()
        frame.x = frame.x.rounded()
        frame.y = frame.y.rounded()
        guard frame != node.frame else { return }
        adjust { try? $0.setFrame(id, frame) }
    }

    /// A new mindmap (a note in the format of the mindmap plugin, beside the board) on the board at `point`, entered
    /// so its central topic can be typed at once.
    @discardableResult
    func addMindmap(at point: CanvasPoint) -> String? {
        guard isEditable, let path = try? store.createMindmap(near: self.path, title: title) else { return nil }
        guard let id = addFile(path, at: point) else { return nil }
        if store.embeddedViewType(for: path) != nil { enterEmbed(id) }
        return id
    }

    /// A link card takes the height its preview needs at its width, once the preview (and its picture) is known.
    func fitLink(_ id: String) {
        guard let node = node(id), node.kind == .link, let url = node.url.flatMap(URL.init(string:)),
              resizing?.id != id else { return }
        let preview = store.links.preview(for: url)
        let hasImage = preview?.image.map { store.links.image($0) != nil } ?? false
        let height = BoardLinkLayout.height(CanvasLinkKind(url), preview, hasImage: hasImage, width: node.width)
        guard abs(height - node.height) > 1 else { return }
        adjust { try? $0.setFrame(id, CanvasRect(x: node.x, y: node.y, width: node.width, height: height)) }
    }

    func enterEmbed(_ id: String) {
        guard activeEmbed != id else { return }
        leaveEmbed()
        activeEmbed = id
        selection = [id]
        for (key, context) in embedContexts where key.hasPrefix(id + "\u{0}") { context.isActive = true }
    }

    func leaveEmbed() {
        guard let id = activeEmbed else { return }
        activeEmbed = nil
        for (key, context) in embedContexts where key.hasPrefix(id + "\u{0}") { context.isActive = false }
        requestKeyboard()
    }

    /// Whether a view point is over the entered live card, which scrolls by itself.
    func isOverActiveEmbed(_ location: CGPoint) -> Bool {
        // The selected PDF link scrolls its pages.
        let pdf = selection.count == 1 ? selection.first.flatMap(node).flatMap { node -> String? in
            guard node.kind == .link, let url = node.url.flatMap(URL.init(string:)), CanvasLinkKind(url) == .pdf else { return nil }
            return node.id
        } : nil
        guard let id = activeEmbed ?? pdf, let node = node(id) else { return false }
        return camera.screenRect(CGRect(frame(of: node))).contains(location)
    }

    // MARK: - Editing text in place

    func beginEditing(_ target: BoardEditing.Target) {
        guard isEditable else { return }
        commitEditing()
        switch target {
        case .node(let id):
            guard let node = node(id) else { return }
            editing = BoardEditing(target: target, draft: node.kind == .group ? node.label ?? "" : node.text ?? "")
        case .edge(let id):
            guard let edge = document.edge(id) else { return }
            editing = BoardEditing(target: target, draft: edge.label ?? "")
        case .cell(let id, let row, let column):
            guard let table = node(id)?.table else { return }
            tableCursor = (id, row, column)
            editing = BoardEditing(target: target, draft: table[row, column])
        }
    }

    /// Starts writing in the one selected text card or shape with `text` typed after what it holds. False when
    /// nothing like that is selected, or `text` is not something to write (an arrow key, Return, Escape…).
    func typeIntoSelection(_ text: String) -> Bool {
        guard isEditable, editing == nil, selectedEdge == nil, selection.count == 1, let id = selection.first,
              let node = node(id), node.kind == .text, !node.isTable, !node.isDrawing,
              !text.trimmingCharacters(in: .whitespaces).isEmpty,
              text.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0)
                  && !(0xF700...0xF8FF).contains($0.value) }) else { return false }
        beginEditing(.node(id))
        editing?.draft += text
        return true
    }

    func commitEditing() {
        commitEditing(keepsFocus: false)
    }

    /// Saves what is being written; `keepsFocus` when another field takes over at once (the next table cell), so the
    /// board does not take the keyboard back in between.
    private func commitEditing(keepsFocus: Bool) {
        guard let current = editing else { return }
        editing = nil
        let draft = current.draft
        switch current.target {
        case .node(let id):
            guard let node = node(id) else { return }
            if node.kind == .text, !node.centresText, !node.isSticky,
               draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                // An emptied card is removed, as Heptabase and Obsidian do; a shape stays, it says something empty.
                edit("Delete Card") { $0.remove([id]) }
                selection.remove(id)
                return
            }
            edit(node.kind == .group ? "Rename Group" : "Edit Card") { document in
                guard let index = document.nodes.firstIndex(where: { $0.id == id }) else { return }
                if node.kind == .group {
                    document.nodes[index].label = draft.isEmpty ? nil : draft
                } else {
                    document.nodes[index].text = draft
                    if node.isFreeText {
                        let size = self.store.freeTextSize(draft, fontSize: node.effectiveFontSize)
                        document.nodes[index].width = size.width
                        document.nodes[index].height = size.height
                        return
                    }
                    document.nodes[index].height = max(
                        document.nodes[index].height,
                        BoardText.height(of: draft, fontSize: document.nodes[index].effectiveFontSize,
                                         width: document.nodes[index].width, shape: document.nodes[index].shape)
                    )
                }
            }
        case .edge(let id):
            edit("Edit Label") { document in
                guard let index = document.edges.firstIndex(where: { $0.id == id }) else { return }
                document.edges[index].label = draft.isEmpty ? nil : draft
            }
        case .cell(let id, let row, let column):
            editTable(id, "Edit Cell") { $0[row, column] = draft }
        }
        if !keepsFocus { requestKeyboard() }
    }

    // MARK: - Tables

    /// The cell last written in or double-clicked: where the menu adds or removes rows and columns.
    @ObservationIgnored var tableCursor: (id: String, row: Int, column: Int)?

    /// The size new tables are written at.
    static let tableFontSize = 14.0

    /// A new table (a header and two rows of three columns) centred on `point`, its first header cell being written.
    @discardableResult
    func addTable(at point: CanvasPoint) -> String? {
        guard isEditable else { return nil }
        let id = document.newID()
        var node = CanvasNode(id: id, kind: .text, x: 0, y: 0, width: 1, height: 1, text: CanvasTable.empty().markdown,
                              fontSize: Self.tableFontSize)
        node.border = .invisible
        let size = store.fittedSize(of: node)
        node.frame = CanvasRect(x: (point.x - size.width / 2).rounded(), y: (point.y - size.height / 2).rounded(),
                                width: size.width, height: size.height)
        edit("Add Table") { $0.add(node) }
        selection = [id]
        selectedEdge = nil
        markAppeared([id])
        beginEditing(.cell(id, 0, 0))
        return id
    }

    /// Changes a table card and makes it the size of its table, its top-left corner staying put.
    func editTable(_ id: String, _ name: String, _ change: (inout CanvasTable) -> Void) {
        guard let node = node(id), var table = node.table else { return }
        change(&table)
        let text = table.markdown
        let size = store.fittedSize(of: node, text: text)
        edit(name) { document in
            guard let index = document.nodes.firstIndex(where: { $0.id == id }) else { return }
            document.nodes[index].text = text
            document.nodes[index].width = size.width
            document.nodes[index].height = size.height
        }
    }

    /// Tab and Shift-Tab: the next or previous cell, row by row; Tab past the last cell adds a row.
    func moveCell(by step: Int) {
        guard case .cell(let id, let row, let column) = editing?.target, let table = node(id)?.table else { return }
        var index = row * table.columnCount + column + step
        commitEditing(keepsFocus: true)
        if index >= table.rowCount * table.columnCount {
            editTable(id, "Add Row") { $0.insertRow() }
        }
        index = max(0, index)
        beginEditing(.cell(id, index / table.columnCount, index % table.columnCount))
    }

    /// Return: the cell below; past the last row, writing stops.
    func moveCellDown() {
        guard case .cell(let id, let row, let column) = editing?.target, let table = node(id)?.table else { return }
        guard row + 1 < table.rowCount else {
            commitEditing()
            return
        }
        commitEditing(keepsFocus: true)
        beginEditing(.cell(id, row + 1, column))
    }

    /// The row or column the menu acts on: the cursor's in this table, else the last one.
    private func cursor(in node: CanvasNode) -> (row: Int, column: Int) {
        let table = node.table ?? CanvasTable.empty()
        if let tableCursor, tableCursor.id == node.id, tableCursor.row < table.rowCount, tableCursor.column < table.columnCount {
            return (tableCursor.row, tableCursor.column)
        }
        return (table.rowCount - 1, table.columnCount - 1)
    }

    /// The cell a table's menu acts on: the one under the pointer when the menu opens, else the cursor's.
    func menuCell(in node: CanvasNode) -> (row: Int, column: Int) {
        if hovered == node.id, let point = hoverPoint,
           let layout = store.tableLayout(node.text ?? "", fontSize: node.effectiveFontSize),
           let cell = layout.cell(at: CGPoint(x: point.x / camera.scale, y: point.y / camera.scale)) {
            tableCursor = (node.id, cell.row, cell.column)
        }
        return cursor(in: node)
    }

    /// How a table's menu names a row and a column: by their first cell and their header, so it is clear which goes.
    func tableMenuNames(_ node: CanvasNode) -> (row: String, column: String) {
        let table = node.table ?? CanvasTable.empty()
        let cell = menuCell(in: node)
        func quoted(_ text: String, else fallback: String) -> String {
            let text = text.trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { return fallback }
            return "“\(text.count > 24 ? text.prefix(23) + "…" : text)”"
        }
        return (quoted(table[cell.row, 0], else: "\(cell.row)"), quoted(table[0, cell.column], else: "\(cell.column + 1)"))
    }

    func insertTableRow(_ node: CanvasNode) {
        let at = cursor(in: node).row + 1
        editTable(node.id, "Add Row") { $0.insertRow(at: at) }
    }

    func insertTableColumn(_ node: CanvasNode) {
        let at = cursor(in: node).column + 1
        editTable(node.id, "Add Column") { $0.insertColumn(at: at) }
    }

    /// The bars under and beside a selected table: a row at the bottom, a column at the right.
    func appendTableRow(_ node: CanvasNode) { editTable(node.id, "Add Row") { $0.insertRow() } }
    func appendTableColumn(_ node: CanvasNode) { editTable(node.id, "Add Column") { $0.insertColumn() } }

    func removeTableRow(_ node: CanvasNode) {
        let row = cursor(in: node).row
        if case .cell(let id, _, _) = editing?.target, id == node.id { editing = nil }
        editTable(node.id, "Delete Row") { $0.removeRow(row) }
    }

    func removeTableColumn(_ node: CanvasNode) {
        let column = cursor(in: node).column
        if case .cell(let id, _, _) = editing?.target, id == node.id { editing = nil }
        editTable(node.id, "Delete Column") { $0.removeColumn(column) }
    }

    func cancelEditing() {
        guard let current = editing else { return }
        editing = nil
        if case .node(let id) = current.target, let node = node(id), node.kind == .text, !node.centresText,
           !node.isSticky, (node.text ?? "").isEmpty {
            edit("Delete Card") { $0.remove([id]) }
            selection.remove(id)
        }
        requestKeyboard()
    }

    // MARK: - Camera

    func viewResized(_ size: CGSize) {
        let first = camera.viewResized(size)
        if presentation != nil { showSlide() }
        if first, !fitted {
            fitted = true
            fit(animated: false)
        }
    }

    func fit(animated: Bool = true) {
        guard let bounds = CanvasRect.bounds(document.nodes.map(\.frame)) else {
            camera.offset = CGSize(width: camera.viewSize.width / 2, height: camera.viewSize.height / 2)
            return
        }
        camera.show(CGRect(bounds), maxScale: 1, animated: animated)
    }

    func zoomToSelection() {
        let frames = document.nodes.filter { selection.contains($0.id) }.map(\.frame)
        guard let bounds = CanvasRect.bounds(frames) else { return }
        camera.show(CGRect(bounds), maxScale: 1.5)
    }

    /// Called as the camera moves; it is back at rest a moment after the last move.
    func cameraMoved() {
        if !isNavigating { isNavigating = true }
        settleTask?.cancel()
        settleTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(140))
            if !Task.isCancelled { self?.isNavigating = false }
        }
    }

    /// Centres the view on a board point (the minimap's click).
    func center(on point: CanvasPoint, animated: Bool = true) {
        camera.move(to: CGSize(width: camera.viewSize.width / 2 - point.x * camera.scale,
                               height: camera.viewSize.height / 2 - point.y * camera.scale),
                    scale: camera.scale, animated: animated)
    }

    func toggleMinimap() {
        showsMinimap.toggle()
        saveCamera()
    }

    func requestKeyboard() { focusRequest += 1 }
}

// MARK: - Conversions

extension CanvasPoint {
    init(_ point: CGPoint) { self.init(x: point.x, y: point.y) }
}

extension CGPoint {
    init(_ point: CanvasPoint) { self.init(x: point.x, y: point.y) }
}

extension CanvasRect {
    init(_ rect: CGRect) { self.init(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height) }
}

extension CGRect {
    init(_ rect: CanvasRect) { self.init(x: rect.x, y: rect.y, width: rect.width, height: rect.height) }
}
