import AppKit
import CanvasPlugin
import PluginKitUI
import SwiftUI

/// The board's right-click menus, in AppKit.
@MainActor
enum BoardMenus {
    /// The menu of a card or group: it acts on the selection, or on its card when that card is not part of it.
    static func node(_ model: BoardModel, _ node: CanvasNode) -> NSMenu {
        let menu = NSMenu()
        func select() {
            if !model.selection.contains(node.id) {
                model.selection = [node.id]
                model.selectedEdge = nil
            }
        }
        func item(_ title: String, _ run: @escaping () -> Void) -> NSMenuItem { ActionMenuItem(title.uiLocalized, run: run) }
        func submenu(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
            let parent = NSMenuItem(title: title.uiLocalized, action: nil, keyEquivalent: "")
            let child = NSMenu()
            for item in items { child.addItem(item) }
            parent.submenu = child
            return parent
        }
        menu.addItem(item(node.kind == .file || node.kind == .link ? "Open" : "Edit") { select(); model.activate(node) })
        if node.kind == .link { menu.addItem(item("Open in Browser") { model.openInBrowser(node) }) }
        if node.kind == .file, let file = node.file, model.store.vault.exists(file) {
            menu.addItem(item("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([model.store.vault.rootURL.appendingPathComponent(file)])
            })
        }
        menu.addItem(.separator())
        if node.isTable {
            menu.addItem(item("Add Row Below") { select(); model.insertTableRow(node) })
            menu.addItem(item("Add Column to the Right") { select(); model.insertTableColumn(node) })
            let names = model.tableMenuNames(node)
            let cell = model.menuCell(in: node)
            let row = item("Delete Row \(names.row)") { select(); model.removeTableRow(node) }
            row.isEnabled = !(cell.row == 0 || (node.table?.rowCount ?? 0) <= 2)
            menu.addItem(row)
            let column = item("Delete Column \(names.column)") { select(); model.removeTableColumn(node) }
            column.isEnabled = (node.table?.columnCount ?? 0) > 1
            menu.addItem(column)
            menu.addItem(.separator())
        }
        if node.isDrawing, node.drawing?.kind == .line {
            menu.addItem(item("Arrow at the End") { select(); model.setLineHeads(start: false, end: true) })
            menu.addItem(item("Arrows at Both Ends") { select(); model.setLineHeads(start: true, end: true) })
            menu.addItem(item("No Arrow Head") { select(); model.setLineHeads(start: false, end: false) })
            menu.addItem(item("Dashed") { select(); model.toggleLineDashed() })
            menu.addItem(.separator())
        }
        if node.kind == .text, !node.isTable, !node.isDrawing {
            menu.addItem(submenu("Text Size", CanvasNode.fontSizes.map { size in
                item("\(Int(size)) pt") { select(); model.setFontSize(size) }
            }))
            menu.addItem(item("Fit Height to Text") { select(); model.fitToText() })
            menu.addItem(submenu("Shape", [
                item("Text") { select(); model.makeFreeText() },
                item("Card") { select(); model.clearShape() },
            ] + CanvasNodeShape.allCases.map { shape in item(shape.name) { select(); model.setShape(shape) } }))
            menu.addItem(submenu("Outline", CanvasBorder.allCases.map { border in
                item(border.rawValue.capitalized) { select(); model.setBorder(border) }
            }))
        }
        menu.addItem(submenu("Color", [item("None") { select(); model.setColor(nil) }] + BoardStyle.presets.map { preset in
            item(preset.name) { select(); model.setColor(preset.value) }
        }))
        if node.kind == .group {
            menu.addItem(item("Present from Here") { model.present(from: node.id) })
            if node.ratio != nil, model.document.startNode != node.id {
                menu.addItem(item("Start the Presentation Here") { model.makeStartSlide(node.id) })
            }
        }
        menu.addItem(item("Duplicate") { select(); model.duplicateSelection() })
        menu.addItem(item("Group") { select(); model.groupSelection() })
        if model.selection.count > 1 && model.selection.contains(node.id) {
            var align = [
                item("Left") { model.align(.left) }, item("Center") { model.align(.centerX) },
                item("Right") { model.align(.right) }, .separator(),
                item("Top") { model.align(.top) }, item("Middle") { model.align(.centerY) },
                item("Bottom") { model.align(.bottom) },
            ]
            if model.selection.count > 2 {
                align += [.separator(), item("Distribute Horizontally") { model.distribute(.horizontal) },
                          item("Distribute Vertically") { model.distribute(.vertical) }]
            }
            menu.addItem(submenu("Align", align))
        }
        menu.addItem(.separator())
        menu.addItem(item("Bring to Front") { select(); model.bringToFront() })
        menu.addItem(item("Send to Back") { select(); model.sendToBack() })
        menu.addItem(.separator())
        menu.addItem(item("Remove from Board") { select(); model.deleteSelection() })
        return menu
    }

    /// The menu of the empty board: what to add there, present, paste, export, zoom.
    static func background(_ model: BoardModel, theme: ThemeTokens, appearance: NSAppearance) -> NSMenu {
        let menu = NSMenu()
        func item(_ title: String, _ run: @escaping () -> Void) -> NSMenuItem { ActionMenuItem(title.uiLocalized, run: run) }
        let scheme: ColorScheme = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .dark : .light
        menu.addItem(item("New Text") { model.addText(at: model.insertionPoint) })
        menu.addItem(item("New Text Card") { model.addText(at: model.insertionPoint, card: true) })
        let shapes = NSMenuItem(title: "New Shape".uiLocalized, action: nil, keyEquivalent: "")
        shapes.submenu = NSMenu()
        for shape in CanvasNodeShape.allCases {
            shapes.submenu?.addItem(item(shape.name) { model.addShape(shape, at: model.insertionPoint) })
        }
        menu.addItem(shapes)
        menu.addItem(item("Add Note…") { BoardActions.addNote(model) })
        menu.addItem(item("Add Files…") { BoardActions.addFiles(model) })
        menu.addItem(item("New Mindmap") { model.addMindmap(at: model.insertionPoint) })
        menu.addItem(item("New Table") { model.addTable(at: model.insertionPoint) })
        menu.addItem(item("New Sticky Note") { model.addSticky(at: model.insertionPoint) })
        menu.addItem(item("New Group") { model.addGroup(at: model.insertionPoint) })
        menu.addItem(item("New Frame") { model.addFrame(at: model.insertionPoint) })
        menu.addItem(.separator())
        let present = item("Present") { model.present() }
        present.isEnabled = !model.document.slideCandidates.isEmpty
        menu.addItem(present)
        menu.addItem(.separator())
        menu.addItem(item("Paste") { model.pasteFromPasteboard(.general) })
        menu.addItem(item("Select All") { model.selectAll() })
        menu.addItem(.separator())
        let export = NSMenuItem(title: "Export".uiLocalized, action: nil, keyEquivalent: "")
        export.submenu = NSMenu()
        export.submenu?.addItem(item(model.selection.isEmpty ? "Board as PNG…" : "Selection as PNG…") {
            BoardExport.save(model, format: .png, slides: false, theme: theme, scheme: scheme)
        })
        export.submenu?.addItem(item(model.selection.isEmpty ? "Board as PDF…" : "Selection as PDF…") {
            BoardExport.save(model, format: .pdf, slides: false, theme: theme, scheme: scheme)
        })
        if model.document.nodes.contains(where: { $0.ratio != nil }) {
            export.submenu?.addItem(item("Slides as PDF…") {
                BoardExport.save(model, format: .pdf, slides: true, theme: theme, scheme: scheme)
            })
        }
        export.isEnabled = !model.document.nodes.isEmpty
        menu.addItem(export)
        menu.addItem(.separator())
        menu.addItem(item("Zoom to Fit") { model.fit() })
        menu.addItem(item(model.showsMinimap ? "Hide Minimap" : "Show Minimap") { model.toggleMinimap() })
        return menu
    }
}

/// A small map of the whole board, with the part on screen outlined. Click or drag in it to go there.
@MainActor
final class BoardMinimapView: NSView {
    static let size = CGSize(width: 190, height: 128)
    private let model: BoardModel
    var palette: BoardPalette { didSet { needsDisplay = true } }
    private let glass = NSGlassEffectView()
    private let map = BoardMinimapDrawing()
    /// The map's scale and origin, held while it is dragged so the board does not slide under the finger.
    private var held: (fit: CGFloat, origin: CGPoint)?
    private var shown: (fit: CGFloat, origin: CGPoint) = (1, .zero)

    init(model: BoardModel, palette: BoardPalette) {
        self.model = model
        self.palette = palette
        super.init(frame: CGRect(origin: .zero, size: Self.size))
        glass.cornerRadius = Corners.r(16)
        glass.frame = bounds
        glass.autoresizingMask = [.width, .height]
        addSubview(glass)
        map.frame = bounds
        map.autoresizingMask = [.width, .height]
        addSubview(map)
        toolTip = "Click or drag to go somewhere on the board".uiLocalized
        update()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Draws the map again for the board and the camera as they are now.
    func update() {
        guard !isHidden else { return }
        let size = Self.size
        let visible = model.camera.visibleWorldRect
        let all = CanvasRect.bounds(model.document.nodes.map(\.frame)).map { CGRect($0).union(visible) } ?? visible
        let inset = size.width * 0.06
        let fit = min((size.width - inset * 2) / max(all.width, 1), (size.height - inset * 2) / max(all.height, 1))
        let origin = CGPoint(x: (size.width - all.width * fit) / 2 - all.minX * fit, y: (size.height - all.height * fit) / 2 - all.minY * fit)
        shown = held ?? (fit, origin)
        map.content = (model.document.nodes, visible, shown.fit, shown.origin, palette)
    }

    override func mouseDown(with event: NSEvent) {
        held = shown
        go(event)
    }

    override func mouseDragged(with event: NSEvent) { go(event) }

    override func mouseUp(with event: NSEvent) {
        held = nil
        update()
    }

    private func go(_ event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let (fit, origin) = shown
        model.center(on: CanvasPoint(x: (point.x - origin.x) / fit, y: (point.y - origin.y) / fit), animated: false)
    }
}

/// The minimap's drawing: groups' outlines, cards as small tinted blocks, the view's rectangle.
private final class BoardMinimapDrawing: NSView {
    var content: (nodes: [CanvasNode], visible: CGRect, fit: CGFloat, origin: CGPoint, palette: BoardPalette)? {
        didSet { needsDisplay = true }
    }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard let content, let context = NSGraphicsContext.current?.cgContext else { return }
        let (nodes, visible, fit, origin, palette) = content
        context.addPath(CGPath(roundedRect: bounds, cornerWidth: Corners.r(16), cornerHeight: Corners.r(16), transform: nil))
        context.clip()
        func rect(_ world: CGRect) -> CGRect {
            CGRect(x: world.minX * fit + origin.x, y: world.minY * fit + origin.y, width: world.width * fit, height: world.height * fit)
        }
        context.setLineWidth(0.75)
        for node in nodes where node.kind == .group {
            let color = BoardStyle.nsColor(node.color) ?? palette.text
            context.addPath(CGPath(roundedRect: rect(CGRect(node.frame)), cornerWidth: 2, cornerHeight: 2, transform: nil))
            context.setStrokeColor(color.withAlphaComponent(0.4).cgColor)
            context.strokePath()
        }
        for node in nodes where node.kind != .group {
            let r = rect(CGRect(node.frame))
            context.addPath(CGPath(roundedRect: r, cornerWidth: min(1.5, r.width / 2), cornerHeight: min(1.5, r.height / 2), transform: nil))
            context.setFillColor((BoardStyle.nsColor(node.color)?.withAlphaComponent(0.75) ?? palette.text.withAlphaComponent(0.28)).cgColor)
            context.fillPath()
        }
        let view = rect(visible)
        let path = CGPath(roundedRect: view, cornerWidth: Corners.r(4), cornerHeight: Corners.r(4), transform: nil)
        context.addPath(path)
        context.setFillColor(palette.accent.withAlphaComponent(0.1).cgColor)
        context.fillPath()
        context.addPath(path)
        context.setStrokeColor(palette.accent.cgColor)
        context.setLineWidth(1.5)
        context.strokePath()
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
