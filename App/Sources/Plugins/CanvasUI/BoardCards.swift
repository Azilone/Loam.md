import AppKit
import CanvasPlugin
import PluginKitUI
import SwiftUI

/// One card, placed and scaled by the camera. The skin (Liquid Glass, edge, shadow) is drawn at screen size; the
/// content is laid out in board units and scaled, so text keeps its layout at any zoom, and zoomed out only the
/// title shows, at a readable size. A click selects, a drag moves the selection (Option copies it), a double-click
/// edits or opens it. Selected, it has handles on its corners and sides to resize it, and a dot on each side to draw
/// an arrow from.
struct BoardCardView: View {
    let model: BoardModel
    let node: CanvasNode
    /// May show a live view (a PDF, a video…): the board keeps only a few at once.
    let live: Bool
    /// May have glass: with many cards on screen the board draws flat paper.
    let glass: Bool
    @Environment(\.themeTokens) private var theme
    /// Where the current gesture started: a gesture SwiftUI cancelled (its view was rebuilt) never ends, so a new
    /// start, not a flag, says a new one began.
    @State private var dragging: CGPoint?
    @State private var appeared: Bool

    init(model: BoardModel, node: CanvasNode, live: Bool, glass: Bool) {
        self.model = model
        self.node = node
        self.live = live
        self.glass = glass
        _appeared = State(initialValue: !model.justAdded.contains(node.id))
    }

    /// The live view of the file behind the card (a mindmap note…), if another view is meant for it.
    private var embed: (type: ViewType, context: ViewContext)? {
        guard live, node.kind == .file, let file = node.file, let type = model.store.embeddedViewType(for: file)
            ?? model.store.mediaViewType(for: file), let context = model.embedContext(for: node) else { return nil }
        return (type, context)
    }

    @ViewBuilder var body: some View {
        if let ink = model.store.ink(node) {
            drawing(ink)
        } else {
            card
        }
    }

    /// A drawing (strokes, a free line): only its strokes, which alone take clicks; a dashed box when selected, or
    /// for a line its two ends (`BoardLineHandles`).
    private func drawing(_ ink: CanvasInk) -> some View {
        let frame = model.frame(of: node)
        let scale = model.camera.scale
        let screen = CGRect(x: frame.x * scale, y: frame.y * scale, width: frame.width * scale, height: frame.height * scale)
        let selected = model.selection.contains(node.id)
        let single = selected && model.selection.count == 1
        let lifted = model.dragged.contains(node.id)
        let isLine = ink.kind == .line
        let ends = model.lineEnds(of: node).map { ends in
            (CanvasPoint(x: ends.0.x - node.x, y: ends.0.y - node.y), CanvasPoint(x: ends.1.x - node.x, y: ends.1.y - node.y))
        }
        return BoardInkView(node: node, ink: ink, ends: ends)
            .frame(width: screen.width, height: screen.height)
            .contentShape(BoardInkHitShape(ink: ink, natural: CGSize(width: node.width, height: node.height), slop: 6))
            .background {
                if (selected && !isLine) || (model.hovered == node.id && !selected) {
                    Rectangle()
                        .strokeBorder(theme.accent.opacity(selected ? 0.9 : 0.4),
                                      style: StrokeStyle(lineWidth: 1.25, dash: [5, 4]))
                        .padding(-4)
                        .allowsHitTesting(false)
                }
            }
            .onHover { inside in
                withAnimation(BoardMotion.chrome) { model.setHovered(inside ? node.id : model.hovered == node.id ? nil : model.hovered) }
            }
            .gesture(tap)
            .gesture(drag)
            .overlay {
                if single, !isLine, model.isEditable, model.dragged.isEmpty, model.marquee == nil {
                    BoardHandles(model: model, node: node, size: screen.size, canResize: true, showsLinks: false)
                }
            }
            .contextMenu { BoardMenu(model: model, node: node) }
            .scaleEffect(lifted ? 1.018 : appeared ? 1 : 0.84)
            .opacity(appeared ? 1 : 0)
            .animation(BoardMotion.lift, value: lifted)
            .position(x: screen.midX, y: screen.midY)
            .zIndex(lifted ? 3 : selected ? 2 : 0)
            .onAppear {
                guard !appeared else { return }
                withAnimation(BoardMotion.appear) { appeared = true }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(isLine ? (ink.endArrow || ink.startArrow ? "Arrow" : "Line") : "Drawing")
            .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
            .accessibilityAction { model.tap(node, count: 1, extend: false) }
    }

    @ViewBuilder private var card: some View {
        let frame = model.frame(of: node)
        let scale = model.camera.scale
        // In the board's scaled space, which the board moves as a whole: panning does not touch the cards.
        let screen = CGRect(x: frame.x * scale, y: frame.y * scale, width: frame.width * scale, height: frame.height * scale)
        let selected = model.selection.contains(node.id)
        let single = selected && model.selection.count == 1
        let editing = model.editing?.target == .node(node.id)
        let editingCell: Bool = {
            if case .cell(let id, _, _) = model.editing?.target { return id == node.id }
            return false
        }()
        let lifted = model.dragged.contains(node.id)
        let shape = BoardShape(node.kind == .text ? node.shape : nil,
                               radius: (node.isSticky ? 4 : node.isFreeText ? 6 : BoardStyle.cornerRadius) * scale)
        // A view as big as its content (a mindmap) stands on the board with no card round it.
        let bare = model.isBare(node)
        // In a container of its own: the content changes branch when a resize starts (`content`), and the handles
        // over it must stay the same views, or the drag that started the resize is dropped.
        ZStack { content(frame: frame, scale: scale, screen: screen, editing: editing, interactive: single) }
            .frame(width: screen.width, height: screen.height)
            // Free text being written runs a little past its outline (`BoardTextEditor`).
            .mask { if editing && node.isFreeText { Rectangle().padding(.trailing, -400) } else { shape } }
            // Shapes are diagram pieces: flat paper, as Liquid Glass bends badly round a diamond or a cylinder.
            .modifier(BoardCardSurface(tint: BoardStyle.color(node.color), shape: shape,
                                       border: bare ? .invisible : node.border,
                                       glass: glass && shape.shape == nil && !node.isSticky,
                                       paper: node.kind == .text ? 0.92 : 0.7, lifted: lifted, sticky: node.isSticky))
            .overlay {
                if node.border != .invisible, !bare, !node.isSticky {
                    BoardSpecular(model: model, id: node.id, size: screen.size, shape: shape)
                }
            }
            .overlay {
                // Free text has no card: a faint outline under the pointer says it is one thing to grab.
                if node.border == .invisible || bare, !selected, model.hovered == node.id, !editing {
                    shape.strokeBorder(theme.accent.opacity(0.45), lineWidth: 1.25)
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }
            }
            .overlay {
                if selected || model.link?.target == node.id {
                    shape.strokeBorder(theme.accent, lineWidth: 2.25)
                        .padding(-3)
                        .shadow(color: theme.accent.opacity(0.35), radius: 6)
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }
            }
            .contentShape(Rectangle())
            .onContinuousHover(coordinateSpace: .local) { phase in
                switch phase {
                case .active(let point):
                    if model.hovered != node.id { withAnimation(BoardMotion.chrome) { model.setHovered(node.id) } }
                    model.hoverPoint = point
                case .ended:
                    if model.hovered == node.id { withAnimation(BoardMotion.chrome) { model.setHovered(nil) } }
                    model.hoverPoint = nil
                }
            }
            .gesture(tap)
            .gesture(drag)
            .overlay {
                // Kept while an arrow is drawn from it: the dot under the hand carries the gesture, even once the
                // pointer has left the card.
                let linking = model.link?.from == node.id && model.link?.reconnect == nil
                if !editing, model.isEditable, selected || model.hovered == node.id || linking, model.marquee == nil,
                   model.dragged.isEmpty {
                    BoardHandles(model: model, node: node, size: screen.size, canResize: single,
                                 showsLinks: single || model.hovered == node.id || linking, cornersOnly: node.sizesToText)
                        .transition(.opacity)
                }
            }
            .contextMenu { BoardMenu(model: model, node: node) }
            .scaleEffect(lifted ? 1.018 : appeared ? 1 : 0.84)
            .opacity(appeared ? 1 : 0)
            .animation(BoardMotion.lift, value: lifted)
            .position(x: screen.midX, y: screen.midY)
            .zIndex(editing || editingCell ? 4 : lifted ? 3 : selected ? 2 : model.hovered == node.id ? 1 : 0)
            .onAppear {
                guard !appeared else { return }
                withAnimation(BoardMotion.appear) { appeared = true }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(BoardCardBody.label(node))
            .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
            .accessibilityAction { model.tap(node, count: 1, extend: false) }
            .accessibilityAction(named: "Open") { model.activate(node) }
    }

    @ViewBuilder private func content(frame: CanvasRect, scale: CGFloat, screen: CGRect, editing: Bool,
                                      interactive: Bool) -> some View {
        if editing {
            BoardTextEditor(model: model, node: node, scale: scale)
        } else if let embed {
            let card = BoardEmbedCard(model: model, node: node, type: embed.type, context: embed.context,
                                      isActive: model.activeEmbed == node.id || (interactive && embeddedMedia),
                                      isLive: model.activeEmbed == node.id, scale: embeddedMedia ? scale : 1)
                .onAppear { model.embedContentChanged(node.id, bounds: embed.context.contentBounds) }
                .onChange(of: embed.context.contentBounds) { model.embedContentChanged(node.id, bounds: embed.context.contentBounds) }
            if embeddedMedia {
                // PDF, video and sound views are AppKit's: they are laid out at the size they are shown at.
                card.frame(width: screen.width, height: screen.height)
            } else if model.isBare(node), let natural = embed.context.contentBounds?.size, natural.width > 0,
                      natural.height > 0 {
                // A map is laid out at its own size and scaled as a whole to its card, which may have been resized.
                let fit = min(frame.width / natural.width, frame.height / natural.height)
                card
                    .frame(width: natural.width, height: natural.height)
                    .scaleEffect(scale * fit, anchor: .topLeading)
                    .frame(width: screen.width, height: screen.height, alignment: .topLeading)
            } else {
                card
                    .frame(width: frame.width, height: frame.height)
                    .scaleEffect(scale, anchor: .topLeading)
                    .frame(width: screen.width, height: screen.height, alignment: .topLeading)
            }
        } else if node.kind == .link {
            BoardLinkCard(model: model, node: node, isActive: model.activeEmbed == node.id)
                .frame(width: frame.width, height: frame.height)
                .scaleEffect(scale, anchor: .topLeading)
                .frame(width: screen.width, height: screen.height, alignment: .topLeading)
        } else if node.isTable, let table = node.table,
                  let layout = model.store.tableLayout(node.text ?? "", fontSize: node.effectiveFontSize) {
            // Resized, the table grows as a picture would; its font size follows when the drag ends.
            let grown = model.resizing?.id == node.id ? frame.height / max(node.height, 1) : 1
            BoardTableView(model: model, node: node, table: table, layout: layout)
                .frame(width: node.width, height: node.height, alignment: .topLeading)
                .scaleEffect(scale * grown, anchor: .topLeading)
                .frame(width: screen.width, height: screen.height, alignment: .topLeading)
        } else if node.isFreeText, model.resizing?.id == node.id {
            // Free text being resized grows as a picture would; its font size follows when the drag ends.
            let grown = frame.height / max(node.height, 1)
            BoardCardBody(node: node, frame: node.frame, store: model.store, version: model.store.previewVersion)
                .frame(width: node.width, height: node.height, alignment: .topLeading)
                .scaleEffect(scale * grown, anchor: .topLeading)
                .frame(width: screen.width, height: screen.height, alignment: .topLeading)
        } else if model.resizing?.id == node.id, let size = model.scaledFontSize(of: node, in: frame) {
            // A label card being resized: its text follows the size, live.
            BoardCardBody(node: node.withFontSize(size), frame: frame, store: model.store,
                          version: model.store.previewVersion)
                .frame(width: frame.width, height: frame.height, alignment: .topLeading)
                .scaleEffect(scale, anchor: .topLeading)
                .frame(width: screen.width, height: screen.height, alignment: .topLeading)
        } else {
            BoardCardBody(node: node, frame: frame, store: model.store, version: model.store.previewVersion)
                .frame(width: frame.width, height: frame.height, alignment: .topLeading)
                .scaleEffect(scale, anchor: .topLeading)
                .frame(width: screen.width, height: screen.height, alignment: .topLeading)
        }
    }

    /// A PDF, a video or a sound answers clicks as soon as its card is the one selected.
    private var embeddedMedia: Bool {
        guard node.kind == .file, let file = node.file else { return false }
        return CardFile.kind(of: file).isLiveMediaKind
    }

    private var tap: some Gesture {
        SpatialTapGesture()
            .onEnded { value in
                let event = NSApp.currentEvent
                let scale = model.camera.scale
                model.tap(node, count: event?.clickCount ?? 1, extend: event?.modifierFlags.contains(.shift) == true,
                          at: CGPoint(x: value.location.x / scale, y: value.location.y / scale))
            }
    }

    private var drag: some Gesture {
        DragGesture(minimumDistance: 3, coordinateSpace: .named(BoardView.space))
            .onChanged { value in
                let flags = NSEvent.modifierFlags
                if dragging != value.startLocation {
                    dragging = value.startLocation
                    model.beginDrag(node, extend: flags.contains(.shift), duplicate: flags.contains(.option))
                }
                model.updateDrag(value.translation)
            }
            .onEnded { _ in
                dragging = nil
                model.endDrag()
            }
    }
}

/// The handles of a card, in view points: a dot on each corner and a strip along each side to resize it (when it
/// is the one card selected), and a dot outside each side to draw an arrow from (drag it onto another card).
struct BoardHandles: View {
    let model: BoardModel
    let node: CanvasNode
    let size: CGSize
    let canResize: Bool
    let showsLinks: Bool
    /// Free text scales from its corners only: its sides would change its shape, not its size.
    var cornersOnly = false
    @Environment(\.themeTokens) private var theme
    @State private var linking: CGPoint?
    @State private var resizing: CGPoint?

    private var keepsRatioByDefault: Bool {
        node.kind == .file && CardFile.kind(of: node.file ?? "") == .image
    }

    var body: some View {
        ZStack {
            if canResize {
                if !cornersOnly {
                    ForEach(CanvasHandle.allCases.filter { !$0.isCorner }, id: \.self) { handle in strip(handle) }
                }
                ForEach(CanvasHandle.allCases.filter(\.isCorner), id: \.self) { handle in corner(handle) }
            }
            if addsTableCells {
                addBar(row: true)
                addBar(row: false)
            }
            if showsLinks {
                ForEach(CanvasSide.allCases, id: \.self) { side in linkDot(side) }
            }
        }
        .frame(width: size.width, height: size.height)
    }

    /// A selected table has a bar under it to add a row and one beside it to add a column, as Notion's tables do.
    private var addsTableCells: Bool { canResize && node.isTable }

    // MARK: Table

    private func addBar(row: Bool) -> some View {
        let thickness: CGFloat = 18, gap: CGFloat = 8
        return TableAddBar(help: row ? "Add a row" : "Add a column") {
            if row { model.appendTableRow(node) } else { model.appendTableColumn(node) }
        }
        // Short of the corners, which resize.
        .frame(width: row ? max(0, size.width - 28) : thickness, height: row ? thickness : max(0, size.height - 28))
        .position(x: row ? size.width / 2 : size.width + gap + thickness / 2,
                  y: row ? size.height + gap + thickness / 2 : size.height / 2)
    }

    // MARK: Resizing

    private func corner(_ handle: CanvasHandle) -> some View {
        let point = handle.position(in: CanvasRect(x: 0, y: 0, width: size.width, height: size.height))
        // A square, as in Craft and Whimsical: it never reads as the round dot an arrow starts from.
        let square = RoundedRectangle(cornerRadius: Corners.r(2.5), style: .continuous)
        return square
            .fill(Color.white)
            .overlay(square.strokeBorder(theme.accent, lineWidth: 1.75))
            .frame(width: BoardStyle.handleSize - 1, height: BoardStyle.handleSize - 1)
            .shadow(color: .black.opacity(0.18), radius: 2, y: 1)
            .padding(10)
            .contentShape(Rectangle())
            .position(x: point.x, y: point.y)
            .gesture(resize(handle))
            .pointerStyle(.frameResize(position: position(handle)))
    }

    private func strip(_ handle: CanvasHandle) -> some View {
        let horizontal = handle == .top || handle == .bottom
        let point = handle.position(in: CanvasRect(x: 0, y: 0, width: size.width, height: size.height))
        return Color.clear
            .frame(width: horizontal ? max(0, size.width - 34) : 14, height: horizontal ? 14 : max(0, size.height - 34))
            .contentShape(Rectangle())
            .position(x: point.x, y: point.y)
            .gesture(resize(handle))
            .pointerStyle(.frameResize(position: position(handle)))
    }

    private func position(_ handle: CanvasHandle) -> FrameResizePosition {
        switch handle {
        case .topLeft: return .topLeading
        case .top: return .top
        case .topRight: return .topTrailing
        case .right: return .trailing
        case .bottomRight: return .bottomTrailing
        case .bottom: return .bottom
        case .bottomLeft: return .bottomLeading
        case .left: return .leading
        }
    }

    private func resize(_ handle: CanvasHandle) -> some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .named(BoardView.space))
            .onChanged { value in
                if resizing != value.startLocation {
                    resizing = value.startLocation
                    model.beginResize(node, handle: handle)
                }
                let flags = NSEvent.modifierFlags
                model.updateResize(value.translation, keepRatio: flags.contains(.shift) != keepsRatioByDefault)
            }
            .onEnded { _ in
                resizing = nil
                model.endResize()
            }
    }

    // MARK: Arrows

    private func linkDot(_ side: CanvasSide) -> some View {
        // Past a table's bars on the sides that have one.
        let outside: CGFloat = addsTableCells && (side == .right || side == .bottom) ? 46 : 24
        let point: CGPoint
        switch side {
        case .top: point = CGPoint(x: size.width / 2, y: -outside)
        case .right: point = CGPoint(x: size.width + outside, y: size.height / 2)
        case .bottom: point = CGPoint(x: size.width / 2, y: size.height + outside)
        case .left: point = CGPoint(x: -outside, y: size.height / 2)
        }
        return LinkDot(side: side)
            .padding(7)
            .contentShape(Circle())
            .position(point)
            .gesture(link(from: side))
            .help("Drag to another card to connect")
    }

    private func link(from side: CanvasSide) -> some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .named(BoardView.space))
            .onChanged { value in
                if linking != value.startLocation {
                    linking = value.startLocation
                    model.beginLink(from: node, side: side)
                }
                model.updateLink(to: value.location)
            }
            .onEnded { _ in
                linking = nil
                model.endLink()
            }
    }
}

/// A bar along a selected table: a plus under the pointer, a click adds a row or a column.
private struct TableAddBar: View {
    let help: String
    let action: () -> Void
    @Environment(\.themeTokens) private var theme
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            RoundedRectangle(cornerRadius: Corners.r(6), style: .continuous)
                .fill(hovered ? theme.accent.opacity(0.16) : theme.text.opacity(0.06))
                .overlay {
                    Image(symbol: "plus")
                        .font(.ui(size: 10, weight: .bold))
                        .foregroundStyle(hovered ? theme.accent : theme.secondaryText)
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { inside in withAnimation(Motion.hover) { hovered = inside } }
        .help(help)
        .accessibilityLabel(help)
    }
}

/// The dot an arrow starts from: it grows under the pointer and shows an arrow pointing out of that side, so it
/// does not read as a button that adds something.
private struct LinkDot: View {
    let side: CanvasSide
    @Environment(\.themeTokens) private var theme
    @State private var hovered = false

    private var symbol: String {
        switch side {
        case .top: return "arrow.up"
        case .right: return "arrow.right"
        case .bottom: return "arrow.down"
        case .left: return "arrow.left"
        }
    }

    var body: some View {
        // Filled and round, away from the card: a place to pull an arrow from, unlike the white squares that resize.
        Circle()
            .fill(theme.accent.opacity(hovered ? 1 : 0.85))
            .overlay(Circle().strokeBorder(Color.white, lineWidth: 1.5))
            .overlay {
                Image(symbol: symbol)
                    .font(.ui(size: 7, weight: .heavy))
                    .foregroundStyle(.white)
                    .opacity(hovered ? 1 : 0)
            }
            .frame(width: BoardStyle.handleSize - 1, height: BoardStyle.handleSize - 1)
            .scaleEffect(hovered ? 1.6 : 1)
            .shadow(color: .black.opacity(0.18), radius: 2, y: 1)
            .animation(BoardMotion.lift, value: hovered)
            .onHover { hovered = $0 }
    }
}

/// What a card shows, at 100 %: a note's title and first blocks, a text card's Markdown, an image, a board, a
/// file's name. `version` changes when a previewed note changed.
struct BoardCardBody: View, Equatable {
    let node: CanvasNode
    let frame: CanvasRect
    let store: BoardStore
    let version: Int
    @Environment(\.themeTokens) private var theme

    nonisolated static func == (lhs: BoardCardBody, rhs: BoardCardBody) -> Bool {
        lhs.node == rhs.node && lhs.frame == rhs.frame && lhs.version == rhs.version
    }

    var body: some View {
        content.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder private var content: some View {
        switch node.kind {
        case .text:
            textContent
        case .file:
            fileContent
        case .group, .link, .other:
            Color.clear
        }
    }

    /// A text card: its Markdown at its font size, wrapped to the card; faded out at the bottom when it overflows.
    private var textContent: some View {
        let text = node.text ?? ""
        let inner = (node.shape ?? .rectangle).textRect(in: CanvasRect(x: 0, y: 0, width: frame.width, height: frame.height))
        let free = node.isFreeText
        let needed = free ? 0 : store.textHeight(text, fontSize: node.effectiveFontSize, width: inner.width)
        let align = node.effectiveTextAlign
        return NotePreviewView(store.preview(ofText: text), size: node.effectiveFontSize, roomy: true,
                               alignment: align.swiftUI)
            .padding(free ? BoardStyle.freeTextPadding : BoardStyle.textPadding)
            .frame(width: inner.width, height: inner.height,
                   alignment: Alignment(horizontal: align.horizontal, vertical: node.centresText ? .center : .top))
            .offset(x: inner.x, y: inner.y)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .mask {
                if needed > inner.height + 1 {
                    LinearGradient(stops: [.init(color: .black, location: 0.82), .init(color: .clear, location: 1)],
                                   startPoint: .top, endPoint: .bottom)
                } else {
                    Color.black
                }
            }
    }

    @ViewBuilder private var fileContent: some View {
        let file = store.file(node.file ?? "")
        switch file.kind {
        case .image where file.exists:
            if let image = store.image(file.path) {
                Image(nsImage: image).resizable().scaledToFill()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                missing(file)
            }
        case _ where !file.exists:
            missing(file)
        case .note:
            VStack(alignment: .leading, spacing: 0) {
                Text(file.title)
                    .font(.ui(size: BoardStyle.titleSize, weight: .bold))
                    .foregroundStyle(theme.text)
                    .lineLimit(2)
                if let preview = file.preview, !preview.blocks.isEmpty {
                    Rectangle().fill(theme.text.opacity(0.08)).frame(height: 1).padding(.vertical, 10)
                    NotePreviewView(preview, size: 15, roomy: true)
                }
            }
            .padding(BoardStyle.textPadding)
            .mask {
                LinearGradient(stops: [.init(color: .black, location: 0.86), .init(color: .clear, location: 1)],
                               startPoint: .top, endPoint: .bottom)
            }
        case .board:
            VStack(alignment: .leading, spacing: 0) {
                Label(file.title, symbol: CanvasUIPlugin.symbol)
                    .font(.ui(size: BoardStyle.titleSize, weight: .bold))
                    .foregroundStyle(theme.text)
                    .lineLimit(1)
                    .padding(BoardStyle.textPadding)
                BoardThumbnail(document: store.thumbnail(file.path))
                    .padding([.horizontal, .bottom], BoardStyle.textPadding)
            }
        case .image, .pdf, .audio, .video, .other:
            VStack(spacing: 10) {
                Image(symbol: Self.symbol(for: file.kind))
                    .font(.ui(size: 38, weight: .light))
                    .foregroundStyle(theme.secondaryText)
                Text(file.title)
                    .font(.ui(size: BoardStyle.titleSize - 2, weight: .semibold))
                    .foregroundStyle(theme.text)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
            }
            .padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    static func symbol(for kind: CardFile.Kind) -> String {
        switch kind {
        case .pdf: return "doc.richtext"
        case .audio: return "waveform"
        case .video: return "play.rectangle"
        case .image: return "photo"
        case .note: return "doc.text"
        case .board: return CanvasUIPlugin.symbol
        case .other: return "doc"
        }
    }

    private func missing(_ file: CardFile) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(file.title).font(.ui(size: BoardStyle.titleSize - 2, weight: .semibold))
            Text("Not found: \(file.path)").font(.ui(size: 13))
        }
        .foregroundStyle(theme.secondaryText)
        .padding(16)
    }

    static func label(_ node: CanvasNode) -> String {
        switch node.kind {
        case .text: return node.text ?? "Text card"
        case .file: return "Card: " + CardFile.title(of: node.file ?? "")
        case .link: return "Link: " + (node.url ?? "")
        case .group: return "Group: " + (node.label ?? "")
        case .other(let type): return "Card of type \(type)"
        }
    }
}

/// A group: a tinted area under its cards, with its label above it. The label and the border are the handles: a
/// click selects the group, a drag moves it with everything inside, a double-click renames it. Clicks inside fall
/// through to the board, so a selection rectangle can start there.
struct BoardGroupView: View {
    let model: BoardModel
    let node: CanvasNode
    @Environment(\.themeTokens) private var theme
    /// Where the current gesture started: a gesture SwiftUI cancelled (its view was rebuilt) never ends, so a new
    /// start, not a flag, says a new one began.
    @State private var dragging: CGPoint?
    @State private var appeared: Bool

    init(model: BoardModel, node: CanvasNode) {
        self.model = model
        self.node = node
        _appeared = State(initialValue: !model.justAdded.contains(node.id))
    }

    var body: some View {
        let frame = model.frame(of: node)
        let scale = model.camera.scale
        let screen = CGRect(x: frame.x * scale, y: frame.y * scale, width: frame.width * scale, height: frame.height * scale)
        let selected = model.selection.contains(node.id)
        let tint = BoardStyle.color(node.color) ?? theme.secondaryText
        // A frame is a slide: a page of paper on the board, with sharper corners than a group.
        let isFrame = node.ratio != nil
        let shape = RoundedRectangle(cornerRadius: Corners.r((isFrame ? 10 : BoardStyle.cornerRadius) * scale), style: .continuous)
        ZStack(alignment: .topLeading) {
            shape.fill(isFrame ? AnyShapeStyle(theme.background) : AnyShapeStyle(tint.opacity(0.07)))
                .overlay { if isFrame, node.color != nil { shape.fill(tint.opacity(0.05)) } }
                .shadow(color: .black.opacity(isFrame ? 0.08 : 0), radius: 12, y: 4)
                .overlay(shape.strokeBorder(selected ? theme.accent : tint.opacity(0.4), lineWidth: selected ? 2.25 : 1.25))
                .frame(width: screen.width, height: screen.height)
                .allowsHitTesting(false)
            // A slide is a page: grabbed anywhere, as in Whimsical and Miro (a double-click writes on it). A group
            // lets clicks inside fall through to the board.
            if isFrame {
                shape.fill(Color.clear)
                    .contentShape(shape)
                    .frame(width: screen.width, height: screen.height)
                    .gesture(SpatialTapGesture(coordinateSpace: .named(BoardView.space)).onEnded { value in
                        let event = NSApp.currentEvent
                        if (event?.clickCount ?? 1) >= 2, model.isEditable {
                            model.addText(at: CanvasPoint(model.camera.worldPoint(value.location)))
                        } else {
                            model.tap(node, count: 1, extend: event?.modifierFlags.contains(.shift) == true)
                        }
                    })
                    .gesture(drag)
            }
            // The border, a strip wide enough to grab.
            shape.stroke(lineWidth: 18)
                .fill(Color.clear)
                .contentShape(shape.stroke(lineWidth: 18))
                .frame(width: screen.width, height: screen.height)
                .gesture(tap)
                .gesture(drag)
            label(scale: scale, tint: tint, selected: selected)
                .offset(y: -labelHeight(scale) - 6)
            if selected, model.isEditable, model.selection.count == 1, model.dragged.isEmpty {
                BoardHandles(model: model, node: node, size: screen.size, canResize: true, showsLinks: false)
            }
        }
        .frame(width: screen.width, height: screen.height, alignment: .topLeading)
        .scaleEffect(appeared ? 1 : 0.94, anchor: .center)
        .opacity(appeared ? 1 : 0)
        .offset(x: screen.minX, y: screen.minY)
        .onAppear {
            guard !appeared else { return }
            withAnimation(BoardMotion.appear) { appeared = true }
        }
    }

    private func labelHeight(_ scale: CGFloat) -> CGFloat { max(16, BoardStyle.groupLabelSize * scale * 1.5) }

    private var tap: some Gesture {
        SpatialTapGesture().onEnded { _ in
            let event = NSApp.currentEvent
            model.tap(node, count: event?.clickCount ?? 1, extend: event?.modifierFlags.contains(.shift) == true)
        }
    }

    private var drag: some Gesture {
        DragGesture(minimumDistance: 3, coordinateSpace: .named(BoardView.space))
            .onChanged { value in
                let flags = NSEvent.modifierFlags
                if dragging != value.startLocation {
                    dragging = value.startLocation
                    model.beginDrag(node, extend: false, duplicate: flags.contains(.option))
                }
                model.updateDrag(value.translation)
            }
            .onEnded { _ in
                dragging = nil
                model.endDrag()
            }
    }

    @ViewBuilder private func label(scale: CGFloat, tint: Color, selected: Bool) -> some View {
        let size = max(11, BoardStyle.groupLabelSize * scale)
        if model.editing?.target == .node(node.id) {
            BoardLabelField(model: model, size: size)
                .frame(width: max(160, min(400, model.camera.screenRect(CGRect(node.frame)).width)))
        } else {
            HStack(spacing: 5) {
                if let number = model.slideNumbers[node.id] {
                    Text("\(number)")
                        .font(.ui(size: size * 0.8, weight: .bold).monospacedDigit())
                        .foregroundStyle(.white)
                        .padding(.horizontal, size * 0.35)
                        .frame(minWidth: size * 1.3, minHeight: size * 1.3)
                        .background(ThemeCapsule().fill(selected ? theme.accent : tint.opacity(0.9)))
                }
                Text(node.label?.isEmpty == false ? node.label! : node.ratio != nil ? "Frame" : "Group")
                    .font(.ui(size: size, weight: .semibold))
                    .foregroundStyle(node.label?.isEmpty == false ? theme.text : theme.secondaryText)
                    .lineLimit(1)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 3)
                    .background(ThemeCapsule().fill(selected ? theme.accent.opacity(0.18) : tint.opacity(0.14)))
            }
            .contentShape(ThemeCapsule())
            .gesture(tap)
            .gesture(drag)
            .contextMenu { BoardMenu(model: model, node: node) }
        }
    }
}

private extension CanvasNode {
    func withFontSize(_ size: Double) -> CanvasNode {
        var node = self
        node.fontSize = size
        return node
    }
}

/// The menu of a card or group.
struct BoardMenu: View {
    let model: BoardModel
    let node: CanvasNode

    var body: some View {
        Button(node.kind == .file || node.kind == .link ? "Open" : "Edit") { select(); model.activate(node) }
        if node.kind == .link { Button("Open in Browser") { model.openInBrowser(node) } }
        if node.kind == .file, let file = node.file, model.store.vault.exists(file) {
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([model.store.vault.rootURL.appendingPathComponent(file)])
            }
        }
        Divider()
        if node.isTable {
            Button("Add Row Below") { select(); model.insertTableRow(node) }
            Button("Add Column to the Right") { select(); model.insertTableColumn(node) }
            let names = model.tableMenuNames(node)
            let cell = model.menuCell(in: node)
            Button("Delete Row \(names.row)") { select(); model.removeTableRow(node) }
                .disabled(cell.row == 0 || (node.table?.rowCount ?? 0) <= 2)
            Button("Delete Column \(names.column)") { select(); model.removeTableColumn(node) }
                .disabled((node.table?.columnCount ?? 0) <= 1)
            Divider()
        }
        if node.isDrawing, node.drawing?.kind == .line {
            Button("Arrow at the End") { select(); model.setLineHeads(start: false, end: true) }
            Button("Arrows at Both Ends") { select(); model.setLineHeads(start: true, end: true) }
            Button("No Arrow Head") { select(); model.setLineHeads(start: false, end: false) }
            Button("Dashed") { select(); model.toggleLineDashed() }
            Divider()
        }
        if node.kind == .text, !node.isTable, !node.isDrawing {
            Menu("Text Size") {
                ForEach(CanvasNode.fontSizes, id: \.self) { size in
                    Button("\(Int(size)) pt") { select(); model.setFontSize(size) }
                }
            }
            Button("Fit Height to Text") { select(); model.fitToText() }
            Menu("Shape") {
                Button("Text") { select(); model.makeFreeText() }
                Button("Card") { select(); model.clearShape() }
                ForEach(CanvasNodeShape.allCases, id: \.self) { shape in
                    Button(shape.name) { select(); model.setShape(shape) }
                }
            }
            Menu("Outline") {
                ForEach(CanvasBorder.allCases, id: \.self) { border in
                    Button(border.rawValue.capitalized) { select(); model.setBorder(border) }
                }
            }
        }
        Menu("Color") {
            Button("None") { select(); model.setColor(nil) }
            ForEach(BoardStyle.presets, id: \.value) { preset in
                Button(preset.name) { select(); model.setColor(preset.value) }
            }
        }
        if node.kind == .group {
            Button("Present from Here") { model.present(from: node.id) }
            if node.ratio != nil, model.document.startNode != node.id {
                Button("Start the Presentation Here") { model.makeStartSlide(node.id) }
            }
        }
        Button("Duplicate") { select(); model.duplicateSelection() }
        Button("Group") { select(); model.groupSelection() }
        if model.selection.count > 1 && model.selection.contains(node.id) {
            Menu("Align") {
                Button("Left") { model.align(.left) }
                Button("Center") { model.align(.centerX) }
                Button("Right") { model.align(.right) }
                Divider()
                Button("Top") { model.align(.top) }
                Button("Middle") { model.align(.centerY) }
                Button("Bottom") { model.align(.bottom) }
                if model.selection.count > 2 {
                    Divider()
                    Button("Distribute Horizontally") { model.distribute(.horizontal) }
                    Button("Distribute Vertically") { model.distribute(.vertical) }
                }
            }
        }
        Divider()
        Button("Bring to Front") { select(); model.bringToFront() }
        Button("Send to Back") { select(); model.sendToBack() }
        Divider()
        Button("Remove from Board") { select(); model.deleteSelection() }
    }

    /// A menu acts on the selection, or on its card when that card is not part of it.
    private func select() {
        if !model.selection.contains(node.id) {
            model.selection = [node.id]
            model.selectedEdge = nil
        }
    }
}
