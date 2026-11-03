import AppKit
import CanvasPlugin
import PluginKitUI
import SwiftUI

struct BoardTab: View {
    let view: ViewContext
    @State private var model: BoardModel

    init(store: BoardStore, view: ViewContext) {
        self.view = view
        _model = State(wrappedValue: store.model(for: view))
    }

    var body: some View {
        // A board on a card (a folder page, another board) is only its picture until it is entered.
        BoardView(model: model, showsChrome: view.presentation == .page || view.isActive)
            // The canvas runs under the page's toolbar, which floats on it with its glass, as in Craft.
            .ignoresSafeArea(.container, edges: .top)
            .onAppear { [model] in
                if view.presentation == .page { view.toolbarTitle = ToolbarTitle(title: model.title) }
                view.setInspector(viewType: CanvasUIPlugin.viewTypeID, tabs: [
                    InspectorTab(id: "canvas.board", title: "Board") { AnyView(BoardInspector(model: model)) },
                ])
            }
    }
}

/// A board: the dotted infinite canvas, groups under the arrows under the cards. Only what is near the screen is
/// built; zoomed out, cards show only their title. Scrolling pans, the wheel, pinching or Command-scrolling zooms.
struct BoardView: View {
    let model: BoardModel
    /// False for a board shown as a picture: no toolbar, no minimap.
    var showsChrome = true
    @Environment(\.themeTokens) private var theme
    @Environment(\.undoManager) private var undoManager
    @Environment(\.colorScheme) private var colorScheme
    @State private var panStart: CGSize?
    @State private var spaceDown = false
    @State private var dragMode: DragMode?

    private enum DragMode { case marquee, cards }

    private var panning: Bool { spaceDown || model.tool == .hand }

    var body: some View {
        GeometryReader { proxy in
            board
                // Presenting, the next slide comes in from the side (`BoardModel.moveSlide`).
                .offset(x: model.presentShift)
                .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
                .clipped()
                .background {
                    BoardKeyCatcher(model: model, focusRequest: model.focusRequest) { handle($0) }
                }
                .coordinateSpace(.named(BoardView.space))
                .infiniteCanvasNavigation(model.camera, pointer: model.pointer, wheelZooms: true, scrolls: { location in
                    model.editing != nil || model.isOverActiveEmbed(location)
                })
                .overlay {
                    if model.presentation == nil {
                        ZStack {
                            BoardEdgeHandles(model: model)
                            BoardLineHandles(model: model)
                            BoardSelectionBar(model: model)
                        }
                    }
                }
                .overlay { BoardPresentationOverlay(model: model) }
                .animation(BoardMotion.chrome, value: model.presentation == nil)
                .overlay(alignment: .bottomLeading) {
                    if showsChrome, model.showsMinimap, model.presentation == nil {
                        BoardMinimap(model: model)
                            .padding(14)
                            .transition(.scale(scale: 0.92, anchor: .bottomLeading).combined(with: .opacity))
                    }
                }
                .overlay(alignment: .bottom) {
                    if showsChrome, model.presentation == nil { bottomBar }
                }
                .overlay(alignment: .top) {
                    if let error = model.loadError { banner(error).padding(.top, 56) }
                }
                .overlay {
                    if model.dropTargeted {
                        RoundedRectangle(cornerRadius: Corners.r(18), style: .continuous)
                            .strokeBorder(theme.accent.opacity(0.8), style: StrokeStyle(lineWidth: 3, dash: [10, 8]))
                            .background(theme.accent.opacity(0.05))
                            .padding(8)
                            .allowsHitTesting(false)
                            .transition(.opacity)
                    }
                }
                .animation(BoardMotion.chrome, value: model.dropTargeted)
                // The click that brings the window back from another app acts at once, as in Craft: a drag on a
                // handle resizes on the first try, not only once the window is key.
                .allowsWindowActivationEvents()
                .onAppear {
                    model.undoManager = undoManager
                    model.viewResized(proxy.size)
                    model.requestKeyboard()
                }
                .onChange(of: proxy.size) { model.viewResized(proxy.size) }
                .onChange(of: undoManager) { model.undoManager = undoManager }
                .onChange(of: CameraKey(model.camera)) { model.cameraMoved() }
                .task(id: CameraKey(model.camera)) {
                    try? await Task.sleep(for: .seconds(1))
                    if !Task.isCancelled { model.saveCamera() }
                }
                .onDisappear {
                    model.commitEditing()
                    model.flush()
                    model.saveCamera()
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Board \(model.title)")
        }
        .background {
            // A floor a shade apart from the cards, so their paper lifts off it.
            ZStack {
                theme.background
                Color.primary.opacity(0.03)
            }
        }
    }

    static let space = "canvas.board"

    private var bottomBar: some View {
        VStack(spacing: 8) {
            if model.tool.draws, model.tool != .hand {
                BoardInkStyleBar(model: model)
                    .transition(.scale(scale: 0.92, anchor: .bottom).combined(with: .opacity))
            }
            bottomTools
        }
        .animation(BoardMotion.chrome, value: model.tool)
    }

    private var bottomTools: some View {
        BoardBottomBarLayout {
            BoardToolbar(model: model)
            CanvasZoomControls(camera: model.camera, fit: { model.fit() }) {
                Button { model.toggleMinimap() } label: {
                    Image(symbol: "map")
                        .frame(width: 30, height: 26)
                        .foregroundStyle(model.showsMinimap ? theme.accent : theme.text)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Minimap")
            }
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 14)
    }

    private var board: some View {
        let camera = model.camera
        let scale = camera.scale
        let nodes = BoardProfile.measure("visibleNodes") { model.visibleNodes() }
        let groups = nodes.filter { $0.kind == .group }
        let cards = nodes.filter { $0.kind != .group }
        let showsCards = scale >= BoardModel.farScale
        let views = BoardProfile.measure("viewCards") { showsCards ? model.viewCards(among: cards) : [] }
        let viewIDs = Set(views.map(\.id))
        let live = BoardProfile.measure("liveEmbeds") { showsCards ? model.liveEmbeds(among: views) : [] }
        let glass = scale >= BoardModel.glassScale && views.count <= BoardModel.glassLimit
        return ZStack(alignment: .topLeading) {
            CanvasDotGrid(offset: camera.offset, scale: scale, color: theme.secondaryText)
            Color.clear
                .contentShape(Rectangle())
                .gesture(backgroundTap)
                .gesture(backgroundDrag)
                .contextMenu { backgroundMenu }
            // Groups and cards are laid out once for a scale and moved as a whole: panning redraws neither.
            ZStack(alignment: .topLeading) {
                ForEach(groups, id: \.id) { node in BoardGroupView(model: model, node: node) }
            }
            .offset(camera.offset)
            BoardEdges(model: model)
            BoardFarCards(model: model, views: viewIDs)
            if showsCards {
                ZStack(alignment: .topLeading) {
                    ForEach(views, id: \.id) { node in
                        BoardCardView(model: model, node: node, live: live.contains(node.id), glass: glass)
                    }
                }
                .offset(camera.offset)
                .opacity(BoardModel.detailAlpha(scale))
            }
            BoardEdgeLabelEditor(model: model)
            if let marquee = model.marquee {
                Rectangle()
                    .fill(theme.accent.opacity(0.08))
                    .strokeBorder(theme.accent.opacity(0.6), lineWidth: 1)
                    .frame(width: marquee.width, height: marquee.height)
                    .offset(x: marquee.minX, y: marquee.minY)
                    .allowsHitTesting(false)
            }
            if model.document.nodes.isEmpty, model.isEditable { emptyHint }
            if model.tool.draws, !panning, model.presentation == nil {
                BoardDrawingLayer(model: model)
            }
            if panning {
                // Over everything, so a drag anywhere moves the board.
                Color.clear
                    .contentShape(Rectangle())
                    .gesture(panDrag)
                    .pointerStyle(panStart == nil ? .grabIdle : .grabActive)
            }
        }
    }

    @ViewBuilder private var backgroundMenu: some View {
        Button("New Text") { model.addText(at: model.insertionPoint) }
        Button("New Text Card") { model.addText(at: model.insertionPoint, card: true) }
        Menu("New Shape") {
            ForEach(CanvasNodeShape.allCases, id: \.self) { shape in
                Button(shape.name) { model.addShape(shape, at: model.insertionPoint) }
            }
        }
        Button("Add Note…") { BoardActions.addNote(model) }
        Button("Add Files…") { BoardActions.addFiles(model) }
        Button("New Mindmap") { model.addMindmap(at: model.insertionPoint) }
        Button("New Table") { model.addTable(at: model.insertionPoint) }
        Button("New Sticky Note") { model.addSticky(at: model.insertionPoint) }
        Button("New Group") { model.addGroup(at: model.insertionPoint) }
        Button("New Frame") { model.addFrame(at: model.insertionPoint) }
        Divider()
        Button("Present") { model.present() }
            .disabled(model.document.slideCandidates.isEmpty)
        Divider()
        Button("Paste") { model.pasteFromPasteboard(.general) }
        Button("Select All") { model.selectAll() }
        Divider()
        Menu("Export") {
            Button(model.selection.isEmpty ? "Board as PNG…" : "Selection as PNG…") {
                BoardExport.save(model, format: .png, slides: false, theme: theme, scheme: colorScheme)
            }
            Button(model.selection.isEmpty ? "Board as PDF…" : "Selection as PDF…") {
                BoardExport.save(model, format: .pdf, slides: false, theme: theme, scheme: colorScheme)
            }
            if model.document.nodes.contains(where: { $0.ratio != nil }) {
                Button("Slides as PDF…") {
                    BoardExport.save(model, format: .pdf, slides: true, theme: theme, scheme: colorScheme)
                }
            }
        }
        .disabled(model.document.nodes.isEmpty)
        Divider()
        Button("Zoom to Fit") { model.fit() }
        Button(model.showsMinimap ? "Hide Minimap" : "Show Minimap") { model.toggleMinimap() }
    }

    private var emptyHint: some View {
        BoardEmptyState(model: model)
            .fixedSize(horizontal: false, vertical: true)
            .frame(width: max(0, model.camera.viewSize.width - 24))
            .position(x: model.camera.viewSize.width / 2, y: model.camera.viewSize.height / 2 - 20)
            .transition(.opacity)
    }

    private func banner(_ text: String) -> some View {
        Label(text, symbol: "exclamationmark.triangle")
            .font(.ui(.label))
            .foregroundStyle(theme.secondaryText)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .glassEffect(.regular, in: ThemeCapsule())
    }

    // MARK: - Gestures on the empty board

    private var backgroundTap: some Gesture {
        SpatialTapGesture(coordinateSpace: .named(BoardView.space))
            .onEnded { value in
                let event = NSApp.currentEvent
                model.tapBackground(at: value.location, count: event?.clickCount ?? 1,
                                    extend: event?.modifierFlags.contains(.shift) == true)
            }
    }

    /// Dragging the empty board draws a selection rectangle; dragging a card that is only drawn (far out, or past the
    /// board's `viewBudget`) moves it.
    private var backgroundDrag: some Gesture {
        DragGesture(minimumDistance: 3, coordinateSpace: .named(BoardView.space))
            .onChanged { value in
                let flags = NSEvent.modifierFlags
                if dragMode == nil {
                    if let card = model.card(atViewPoint: value.startLocation) {
                        dragMode = .cards
                        model.beginDrag(card, extend: flags.contains(.shift), duplicate: flags.contains(.option))
                    } else {
                        dragMode = .marquee
                        model.beginMarquee(extend: flags.contains(.shift))
                    }
                }
                if dragMode == .cards {
                    model.updateDrag(value.translation)
                    return
                }
                model.updateMarquee(CGRect(
                    x: min(value.startLocation.x, value.location.x),
                    y: min(value.startLocation.y, value.location.y),
                    width: abs(value.location.x - value.startLocation.x),
                    height: abs(value.location.y - value.startLocation.y)
                ))
            }
            .onEnded { _ in
                if dragMode == .cards { model.endDrag() } else { model.endMarquee() }
                dragMode = nil
            }
    }

    /// With Space held or the hand tool, a drag anywhere moves the board.
    private var panDrag: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named(BoardView.space))
            .onChanged { value in
                let start = panStart ?? model.camera.offset
                if panStart == nil { panStart = start }
                model.camera.offset = CGSize(width: start.width + value.translation.width,
                                             height: start.height + value.translation.height)
            }
            .onEnded { _ in panStart = nil }
    }

    // MARK: - Keyboard

    /// The board's keys, from its key view. True when the key was used.
    private func handle(_ event: NSEvent) -> Bool {
        let key = BoardKey(event)
        if event.type == .keyUp {
            if key == .space { spaceDown = false }
            return false
        }
        guard model.editing == nil, let key else { return false }
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if model.presentation != nil {
            switch key {
            case .right, .down, .space, .returnKey: model.nextSlide()
            case .left, .up, .delete: model.previousSlide()
            case .escape: model.stopPresenting()
            default: return mods.contains(.command) ? false : true
            }
            return true
        }
        if mods == [.command, .option], key == .character("p") || key == .character("π") {
            model.present()
            return true
        }
        if mods.contains(.command) {
            if mods.contains(.option) {
                switch key {
                case .character("="), .character("+"): model.stepFontSize(larger: true)
                case .character("-"): model.stepFontSize(larger: false)
                default: return false
                }
                return true
            }
            switch key {
            case .digit(0): model.camera.setScale(1)
            case .character("="), .character("+"): model.camera.zoom(by: 1.25, animated: true)
            case .character("-"): model.camera.zoom(by: 0.8, animated: true)
            case .character("g"): model.groupSelection()
            case .character("]"): model.bringToFront()
            case .character("["): model.sendToBack()
            default: return false
            }
            return true
        }
        if mods.contains(.control) || mods.contains(.option) { return false }
        // A letter typed on a selected shape or card is written in it, as Whimsical and Miro do: a shortcut would
        // otherwise add a frame or a shape for each letter.
        if let text = event.characters, model.typeIntoSelection(text) { return true }
        let step: Double = mods.contains(.shift) ? 10 : 1
        switch key {
        case .delete: model.deleteSelection()
        case .escape where model.tool.draws:
            model.tool = .select
        case .escape:
            model.leaveEmbed()
            model.selection = []
            model.selectedEdge = nil
        case .returnKey:
            guard model.selection.count == 1, let id = model.selection.first, let node = model.node(id) else { return false }
            model.activate(node)
        case .space: spaceDown = true
        case .up: model.nudge(0, -step)
        case .down: model.nudge(0, step)
        case .left: model.nudge(-step, 0)
        case .right: model.nudge(step, 0)
        case .character("t"): model.addText(at: model.insertionPoint)
        case .character("r"): model.addShape(.rectangle, at: model.insertionPoint)
        case .character("o"): model.addShape(.circle, at: model.insertionPoint)
        case .character("d"): model.addShape(.diamond, at: model.insertionPoint)
        case .character("f"): model.addFrame(at: model.insertionPoint)
        case .character("s"): model.addSticky(at: model.insertionPoint)
        case .character("p"): model.tool = .pen
        case .character("e"): model.tool = .eraser
        case .character("l"): model.tool = .line
        case .character("a"): model.tool = .arrow
        case .character("n"): BoardActions.addNote(model)
        case .character("m"): model.toggleMinimap()
        case .character("v"): model.tool = .select
        case .character("h"): model.tool = .hand
        case .digit(1) where mods.contains(.shift): model.fit()
        case .digit(2) where mods.contains(.shift): model.zoomToSelection()
        default: return false
        }
        return true
    }
}

/// What the camera shows, to save it once it rests.
private struct CameraKey: Hashable {
    let x: Double, y: Double, scale: Double

    @MainActor init(_ camera: CanvasCamera) {
        x = camera.offset.width
        y = camera.offset.height
        scale = camera.scale
    }
}

/// Actions shared by the keyboard, the toolbar and the menus.
@MainActor
enum BoardActions {
    /// A popup of the vault's notes (like Cmd+O); the one picked becomes a card.
    static func addNote(_ model: BoardModel) {
        guard model.isEditable, let quickPick = model.store.quickPick() else { return }
        let point = model.insertionPoint
        let notes = model.store.notes()
        quickPick.show(placeholder: "Add a note to the board", items: { query in
            Fuzzy.rank(notes, query: query, key: { CardFile.title(of: $0) }).prefix(60).map { path in
                QuickPickItem(id: path, title: CardFile.title(of: path),
                              subtitle: (path as NSString).deletingLastPathComponent, symbol: "doc.text")
            }
        }, choose: { item in
            model.addFile(item.id, at: point)
            model.requestKeyboard()
        })
    }

    /// Pictures, PDFs, videos, sounds or any other files, chosen in a panel and put on the board.
    static func addFiles(_ model: BoardModel) {
        guard model.isEditable else { return }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.message = "Choose files to put on the board"
        panel.directoryURL = model.store.vault.rootURL
        guard panel.runModal() == .OK else { return }
        let point = model.viewCenter
        let urls = panel.urls
        Task { await model.addFiles(urls, at: point) }
    }

    /// A typed address as a web address: `https://` is added when missing; nil when it cannot be one.
    static func webAddress(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(" ") else { return nil }
        let full = trimmed.contains("://") ? trimmed : "https://" + trimmed
        guard let url = URL(string: full), let scheme = url.scheme, ["http", "https"].contains(scheme),
              let host = url.host(), host.contains(".") || host == "localhost" else { return nil }
        return full
    }
}

/// The board's bottom bar: the tools centred, the zoom controls at the trailing edge. When the window is too narrow to
/// centre the tools beside the zoom, the tools slide to the leading edge; narrower still, the zoom rises above them.
struct BoardBottomBarLayout: Layout {
    var spacing: CGFloat = 10

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard subviews.count == 2 else { return .zero }
        let tools = subviews[0].sizeThatFits(.unspecified), zoom = subviews[1].sizeThatFits(.unspecified)
        let width = proposal.width ?? (tools.width + spacing + zoom.width)
        let stacked = tools.width + spacing + zoom.width > width
        return CGSize(width: width, height: stacked ? tools.height + spacing + zoom.height : max(tools.height, zoom.height))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 2 else { return }
        let tools = subviews[0].sizeThatFits(.unspecified), zoom = subviews[1].sizeThatFits(.unspecified)
        subviews[1].place(at: CGPoint(x: bounds.maxX, y: bounds.maxY - (fitsInline(tools, zoom, bounds) ? 0 : tools.height + spacing)),
                          anchor: .bottomTrailing, proposal: ProposedViewSize(zoom))
        // Centred unless that would run under the zoom controls; then as far left as it needs, never past the edge.
        let centred = bounds.midX - tools.width / 2
        let limit = fitsInline(tools, zoom, bounds) ? bounds.maxX - zoom.width - spacing - tools.width : bounds.maxX - tools.width
        let x = max(bounds.minX, min(centred, limit))
        subviews[0].place(at: CGPoint(x: x, y: bounds.maxY), anchor: .bottomLeading, proposal: ProposedViewSize(tools))
    }

    private func fitsInline(_ tools: CGSize, _ zoom: CGSize, _ bounds: CGRect) -> Bool {
        tools.width + spacing + zoom.width <= bounds.width
    }
}
