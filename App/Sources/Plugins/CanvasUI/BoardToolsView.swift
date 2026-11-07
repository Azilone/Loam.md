import AppKit
import CanvasPlugin
import PluginKitUI

/// The board's tools in AppKit, in a Liquid Glass capsule at the bottom: select or move the board, draw, then add a
/// text, a shape, a sticky note, a table, a mindmap, a note, files or a web page, group or frame, present. A button
/// with variants (the drawing tools, the shapes) does its main thing on a click and opens its menu when held.
/// Placed by hand: a board opening makes it in its first frame.
@MainActor
final class BoardToolsView: NSView {
    private let model: BoardModel
    private let glass = NSGlassEffectView()
    private let content = NSView()
    private var items: [NSView] = []
    private var buttons: [BoardToolButton] = []
    private var follow: Follow<Shown>?
    var palette: BoardPalette { didSet { if palette != oldValue { restyle() } } }

    private struct Shown: Equatable {
        var tool: BoardTool
        var lastShape: CanvasNodeShape
        var nothingSelected: Bool
        var canPresent: Bool
        var editable: Bool
    }

    static let height: CGFloat = 38

    init(model: BoardModel, palette: BoardPalette) {
        self.model = model
        self.palette = palette
        super.init(frame: .zero)
        glass.contentView = content
        addSubview(glass)
        let m = model
        items = [
            tool(.select, "cursorarrow", "Select (V)"),
            tool(.hand, "hand.raised", "Move the board (H, or hold Space)"),
            divider(),
            drawMenu(.arrow, "arrow.up.right", "Draw an arrow (A); hold for a line (L)",
                     [(.arrow, "Arrow (A)", "arrow.up.right"), (.line, "Line (L)", "line.diagonal")]),
            drawMenu(.pen, "pencil.tip", "Draw with the pen (P); hold for the highlighter",
                     [(.pen, "Pen (P)", "pencil.tip"), (.highlighter, "Highlighter", "highlighter")]),
            tool(.eraser, "eraser", "Erase strokes (E)"),
            divider(),
            button("textformat", "Add text (T, or double-click the board)") { m.addText(at: m.viewCenter) },
            shapeButton(),
            button("note", "Add a sticky note (S)") { m.addSticky(at: m.viewCenter) },
            button("tablecells", "Add a table: Tab goes to the next cell") { m.addTable(at: m.viewCenter) },
            button(LoamSymbol.mindmap, "Add a mindmap: Tab adds a topic, Return the next one") { m.addMindmap(at: m.viewCenter) },
            addButton(),
            divider(),
            button("square.on.square.dashed", "Group the selection (⌘G)") {
                if m.selection.isEmpty { m.addGroup(at: m.viewCenter) } else { m.groupSelection() }
            },
            button("tv", "Frame the selection as a slide (F)") { m.addFrame(at: m.viewCenter) },
            divider(),
            button("play.fill", "Present the frames (⌥⌘P)") { m.present() },
        ]
        for item in items { content.addSubview(item) }
        follow = Follow({ [model] in
            Shown(tool: model.tool, lastShape: model.lastShape, nothingSelected: model.selection.isEmpty,
                  canPresent: !model.document.slideCandidates.isEmpty, editable: model.isEditable)
        }) { [weak self] shown in self?.show(shown) }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override var intrinsicContentSize: NSSize {
        NSSize(width: items.reduce(16) { $0 + $1.frame.width + 2 } - 2, height: Self.height)
    }

    override func layout() {
        super.layout()
        glass.frame = bounds
        content.frame = bounds
        glass.cornerRadius = Corners.cap.map { min($0, bounds.height / 2) } ?? bounds.height / 2
        var x: CGFloat = 8
        for item in items {
            item.frame.origin = CGPoint(x: x, y: (bounds.height - item.frame.height) / 2)
            x += item.frame.width + 2
        }
    }

    private func show(_ shown: Shown) {
        for button in buttons {
            button.isOn = button.tools.contains(shown.tool)
            if let current = button.variants.first(where: { $0.tool == shown.tool }) { button.symbol = current.symbol }
            else if let first = button.variants.first { button.symbol = first.symbol }
            if button.isShapes { button.symbol = shown.lastShape.symbol }
            if button.isPresent { button.isEnabled = shown.canPresent && shown.editable } else { button.isEnabled = shown.editable }
            if button.isGroup {
                button.toolTip = (shown.nothingSelected ? "Add a group to drop cards into (⌘G)" : "Group the selection (⌘G)").uiLocalized
            }
            if button.isFrame {
                button.toolTip = (shown.nothingSelected ? "Add a frame, a slide (F)" : "Frame the selection as a slide (F)").uiLocalized
            }
            button.palette = palette
        }
    }

    private func restyle() {
        for button in buttons { button.palette = palette }
    }

    // MARK: Pieces

    private func make(_ symbol: String, _ help: String) -> BoardToolButton {
        let button = BoardToolButton(symbol: symbol, palette: palette)
        button.toolTip = help.uiLocalized
        button.setAccessibilityLabel(help.uiLocalized)
        buttons.append(button)
        if symbol == "square.on.square.dashed" { button.isGroup = true }
        if symbol == "tv" { button.isFrame = true }
        if symbol == "play.fill" { button.isPresent = true }
        return button
    }

    private func tool(_ tool: BoardTool, _ symbol: String, _ help: String) -> NSView {
        let button = make(symbol, help)
        button.tools = [tool]
        button.primary = { [weak model] in model?.tool = tool }
        return button
    }

    private func button(_ symbol: String, _ help: String, action: @escaping () -> Void) -> NSView {
        let button = make(symbol, help)
        button.primary = action
        return button
    }

    /// A drawing tool and its variants: a click picks the one shown, holding opens the others.
    private func drawMenu(_ main: BoardTool, _ symbol: String, _ help: String,
                          _ variants: [(tool: BoardTool, name: String, symbol: String)]) -> NSView {
        let button = make(symbol, help)
        button.variants = variants.map { ($0.tool, $0.symbol) }
        button.tools = Set(variants.map(\.tool))
        button.primary = { [weak model, weak button] in
            guard let model else { return }
            model.tool = button?.variants.first { $0.symbol == button?.symbol }?.tool ?? main
        }
        button.menu = {
            let menu = NSMenu()
            for variant in variants {
                menu.addItem(ActionMenuItem(variant.name.uiLocalized, symbol: variant.symbol) { [weak model] in model?.tool = variant.tool })
            }
            return menu
        }()
        return button
    }

    /// Adds the last shape chosen; held, the menu chooses another.
    private func shapeButton() -> NSView {
        let button = make(model.lastShape.symbol, "Add a shape (R, O, D; hold for the others)")
        button.isShapes = true
        let m = model
        button.primary = { m.addShape(m.lastShape, at: m.viewCenter) }
        let menu = NSMenu()
        menu.addItem(ActionMenuItem("Text Card".uiLocalized, symbol: "note.text") { m.addText(at: m.viewCenter, card: true) })
        menu.addItem(.separator())
        for shape in CanvasNodeShape.allCases {
            menu.addItem(ActionMenuItem(shape.name.uiLocalized + (shape.key.map { " (\($0))" } ?? ""), symbol: shape.symbol) {
                m.addShape(shape, at: m.viewCenter)
            })
        }
        button.menu = menu
        return button
    }

    /// A note, files or a web page: a menu at once.
    private func addButton() -> NSView {
        let button = make("plus.rectangle.on.rectangle", "Add a note, files or a web page (or drag them here)")
        let m = model
        let menu = NSMenu()
        menu.addItem(ActionMenuItem("Note… (N)".uiLocalized, symbol: "doc.text") { BoardActions.addNote(m) })
        menu.addItem(ActionMenuItem("Pictures, PDFs, Videos…".uiLocalized, symbol: "photo.on.rectangle") { BoardActions.addFiles(m) })
        menu.addItem(ActionMenuItem("Web Page…".uiLocalized, symbol: "globe") { [weak button] in
            guard let button else { return }
            BoardLinkPrompt.show(from: button, model: m)
        })
        button.menu = menu
        button.opensMenuAtOnce = true
        return button
    }

    private func divider() -> NSView {
        let line = NSView(frame: CGRect(x: 0, y: 0, width: 9, height: 18))
        let bar = NSView(frame: CGRect(x: 4, y: 0, width: 1, height: 18))
        bar.wantsLayer = true
        bar.layer?.backgroundColor = NSColor.separatorColor.cgColor
        line.addSubview(bar)
        return line
    }
}

/// A button of the board's tools: a symbol on a rounded square that takes the accent when its tool is on. With a
/// menu, a click runs `primary` and holding opens the menu (or a click opens it, `opensMenuAtOnce`).
@MainActor
final class BoardToolButton: NSView {
    var symbol: String { didSet { if symbol != oldValue { restyle() } } }
    var palette: BoardPalette { didSet { if palette != oldValue { restyle() } } }
    var isOn = false { didSet { if isOn != oldValue { restyle() } } }
    var isEnabled = true { didSet { if isEnabled != oldValue { restyle() } } }
    var primary: (() -> Void)?
    var tools: Set<BoardTool> = []
    var variants: [(tool: BoardTool, symbol: String)] = []
    var opensMenuAtOnce = false
    var isShapes = false, isGroup = false, isFrame = false, isPresent = false
    private let glyph = CALayer()
    private var hold: Timer?
    private var opened = false

    init(symbol: String, palette: BoardPalette) {
        self.symbol = symbol
        self.palette = palette
        super.init(frame: CGRect(x: 0, y: 0, width: 34, height: 28))
        wantsLayer = true
        layer?.cornerRadius = Corners.r(10)
        layer?.cornerCurve = .continuous
        glyph.contentsGravity = .center
        glyph.frame = bounds
        layer?.addSublayer(glyph)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        restyle()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private func restyle() {
        let color = !isEnabled ? palette.text.withAlphaComponent(0.3) : isOn ? palette.accent : palette.text
        glyph.contents = tintedSymbol(symbol, size: 15, color: color)
        glyph.contentsScale = window?.backingScaleFactor ?? 2
        layer?.backgroundColor = isOn ? palette.accent.withAlphaComponent(0.18).cgColor : nil
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        restyle()
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        opened = false
        if let menu, opensMenuAtOnce {
            open(menu)
            return
        }
        guard menu != nil else { return }
        hold = Timer.scheduledTimer(withTimeInterval: 0.35, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let menu = self.menu else { return }
                self.open(menu)
            }
        }
    }

    override func mouseUp(with event: NSEvent) {
        hold?.invalidate()
        hold = nil
        guard isEnabled, !opened, bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        if menu == nil || !opensMenuAtOnce { primary?() }
    }

    private func open(_ menu: NSMenu) {
        opened = true
        menu.popUp(positioning: nil, at: CGPoint(x: 0, y: bounds.height + 4), in: self)
    }

    override func accessibilityPerformPress() -> Bool {
        primary?()
        return true
    }
}

/// The address of a web page to put on the board, asked in a popover over the tools.
@MainActor
enum BoardLinkPrompt {
    static func show(from view: NSView, model: BoardModel) {
        let controller = NSViewController()
        let field = NSTextField(frame: CGRect(x: 12, y: 12, width: 260, height: 24))
        field.placeholderString = "https://…"
        let add = NSButton(title: "Add".uiLocalized, target: nil, action: nil)
        add.bezelStyle = .push
        add.keyEquivalent = "\r"
        add.frame = CGRect(x: 280, y: 9, width: 70, height: 30)
        let root = NSView(frame: CGRect(x: 0, y: 0, width: 362, height: 48))
        root.addSubview(field)
        root.addSubview(add)
        controller.view = root
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = controller
        let action = BoardClosureTarget {
            guard let url = BoardActions.webAddress(field.stringValue) else { return }
            model.addLink(url, at: model.viewCenter)
            popover.close()
            model.requestKeyboard()
        }
        add.target = action
        add.action = #selector(BoardClosureTarget.run)
        field.target = action
        field.action = #selector(BoardClosureTarget.run)
        objc_setAssociatedObject(popover, &BoardClosureTarget.key, action, .OBJC_ASSOCIATION_RETAIN)
        popover.show(relativeTo: view.bounds, of: view, preferredEdge: .maxY)
        view.window?.makeFirstResponder(field)
    }
}

/// A target for an AppKit control's action that runs a closure.
final class BoardClosureTarget: NSObject {
    nonisolated(unsafe) static var key = 0
    private let body: @MainActor () -> Void

    init(_ body: @escaping @MainActor () -> Void) {
        self.body = body
    }

    @MainActor @objc func run() { body() }
}
