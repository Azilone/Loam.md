import AppKit
import CanvasPlugin
import PluginKitUI

/// What is being written on the board, in an AppKit field over it: a text card's Markdown as typed (Escape or a
/// click elsewhere saves, Command-Return too), a group's or an arrow's label (Return saves, Escape cancels), a table
/// cell (Tab and Shift-Tab go across, Return goes down, Escape cancels). It follows the camera; the card under it
/// shows no text meanwhile.
@MainActor
final class BoardEditorHost: NSObject, NSTextViewDelegate, NSTextFieldDelegate {
    let target: BoardEditing.Target
    private weak var board: BoardCanvasView?
    private var model: BoardModel? { board?.model }
    /// The view over the board: a scroll view round a text view, or a capsule round a field.
    let view: NSView
    private var textView: BoardTextView?
    private var field: NSTextField?
    private var ended = false

    init?(board: BoardCanvasView, target: BoardEditing.Target) {
        self.board = board
        self.target = target
        let model = board.model
        guard let palette = board.palette else { return nil }
        switch target {
        case .node(let id):
            guard let node = model.node(id) else { return nil }
            if node.kind == .group {
                let (capsule, field) = Self.labelField(palette: palette)
                view = capsule
                self.field = field
            } else {
                let scroll = NSScrollView()
                scroll.drawsBackground = false
                scroll.hasVerticalScroller = false
                scroll.hasHorizontalScroller = false
                scroll.borderType = .noBorder
                let text = BoardTextView()
                text.drawsBackground = false
                text.isRichText = false
                text.allowsUndo = true
                text.isAutomaticQuoteSubstitutionEnabled = false
                text.textColor = palette.text
                text.insertionPointColor = palette.accent
                text.textContainerInset = .zero
                text.isVerticallyResizable = true
                text.autoresizingMask = [.width]
                text.textContainer?.widthTracksTextView = true
                scroll.documentView = text
                view = scroll
                textView = text
            }
        case .edge:
            let (capsule, field) = Self.labelField(palette: palette)
            view = capsule
            self.field = field
        case .cell:
            let field = NSTextField()
            field.isBordered = false
            field.drawsBackground = true
            field.backgroundColor = palette.background.blended(withFraction: 0.08, of: palette.accent)
            field.textColor = palette.text
            field.focusRingType = .none
            field.wantsLayer = true
            field.layer?.borderColor = palette.accent.cgColor
            field.layer?.borderWidth = 2
            field.cell?.usesSingleLineMode = true
            field.cell?.isScrollable = true
            view = field
            self.field = field
        }
        super.init()
        textView?.delegate = self
        textView?.onCommit = { [weak self] in self?.commit() }
        field?.delegate = self
        let draft = model.editing?.draft ?? ""
        textView?.string = draft
        field?.stringValue = draft
        board.addSubview(view)
        place()
        DispatchQueue.main.async { [weak self] in self?.focus() }
    }

    private static func labelField(palette: BoardPalette) -> (NSView, NSTextField) {
        let capsule = NSView()
        capsule.wantsLayer = true
        capsule.layer?.backgroundColor = palette.background.cgColor
        capsule.layer?.borderColor = palette.accent.cgColor
        capsule.layer?.borderWidth = 1.5
        let field = NSTextField()
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.textColor = palette.text
        field.placeholderString = "Label".uiLocalized
        field.cell?.usesSingleLineMode = true
        field.cell?.isScrollable = true
        capsule.addSubview(field)
        return (capsule, field)
    }

    private func focus() {
        guard let window = view.window else { return }
        if let textView {
            window.makeFirstResponder(textView)
            textView.setSelectedRange(NSRange(location: (textView.string as NSString).length, length: 0))
        } else if let field {
            window.makeFirstResponder(field)
            field.currentEditor()?.selectedRange = NSRange(location: (field.stringValue as NSString).length, length: 0)
        }
    }

    /// Whether a click lands in the editor.
    func contains(_ event: NSEvent) -> Bool {
        view.frame.contains(view.superview?.convert(event.locationInWindow, from: nil) ?? .zero)
    }

    /// Follows the model's draft when it changed elsewhere (a letter typed on a selected card started the writing).
    func refresh() {
        guard let draft = model?.editing?.draft else { return }
        if let textView, textView.string != draft, view.window?.firstResponder !== textView { textView.string = draft }
        place()
    }

    /// Puts the editor over what it writes, at the size it is drawn now.
    func place() {
        guard let model, let board else { return }
        let camera = model.camera
        let scale = camera.scale
        switch target {
        case .node(let id):
            guard let node = model.node(id) else { return }
            let frame = model.frame(of: node)
            if node.kind == .group {
                let size = max(11, BoardStyle.groupLabelSize * scale)
                let screen = camera.screenRect(CGRect(frame))
                layoutLabel(size: size, width: max(160, min(400, screen.width)),
                            origin: CGPoint(x: screen.minX, y: screen.minY - max(16, BoardStyle.groupLabelSize * scale * 1.5) - 6))
                return
            }
            guard let textView else { return }
            let inner = (node.shape ?? .rectangle).textRect(in: CanvasRect(x: 0, y: 0, width: frame.width, height: frame.height))
            let origin = camera.screenPoint(CGPoint(x: frame.x + inner.x, y: frame.y + inner.y))
            let free = node.isFreeText
            let fontSize = node.effectiveFontSize * scale
            let horizontal = free ? max(0, BoardStyle.freeTextPadding - 5) * scale : max(2, (BoardStyle.textPadding - 5) * scale)
            let vertical = free ? max(0, BoardStyle.freeTextPadding - 1) * scale : max(2, (BoardStyle.textPadding - 3) * scale)
            // Free text: the text view lays a line out a little wider than it is drawn, so it gets room for that and
            // the next letter past the outline, which hugs the text.
            let width = (inner.width + (free ? 12 + node.effectiveFontSize : 0)) * scale
            view.frame = CGRect(x: origin.x + horizontal, y: origin.y + vertical, width: max(10, width - horizontal * 2),
                                height: max(10, inner.height * scale - vertical * 2))
            let font = NSFont.ui(size: fontSize)
            if textView.font != font { textView.font = font }
            let alignment: NSTextAlignment = switch node.effectiveTextAlign {
            case .left: .left
            case .center: .center
            case .right: .right
            }
            if textView.alignment != alignment { textView.alignment = alignment }
            textView.frame.size.width = view.frame.width
        case .edge(let id):
            guard let edge = model.document.edge(id), let curve = model.curve(of: edge) else { return }
            let center = camera.screenPoint(CGPoint(curve.middle))
            let size = max(11, 13 * scale)
            layoutLabel(size: size, width: 200, origin: CGPoint(x: center.x - 100, y: center.y - (size * 1.25 + 8) / 2))
        case .cell(let id, let row, let column):
            guard let node = model.node(id), let field,
                  let layout = model.store.tableLayout(node.text ?? "", fontSize: node.effectiveFontSize),
                  let table = node.table, row < table.rowCount, column < table.columnCount else { return }
            let rect = layout.rect(row: row, column: column)
            let frame = model.frame(of: node)
            let screen = camera.screenRect(CGRect(x: frame.x + rect.minX, y: frame.y + rect.minY, width: rect.width, height: rect.height))
            field.frame = screen
            let size = CGFloat(node.effectiveFontSize) * scale
            let font = NSFont.ui(size: size, weight: row == 0 ? .semibold : .regular)
            if field.font != font { field.font = font }
            field.alignment = switch table.alignments[column] {
            case .center: .center
            case .right: .right
            case .left, .none: .left
            }
            _ = board
        }
    }

    private func layoutLabel(size: CGFloat, width: CGFloat, origin: CGPoint) {
        guard let field else { return }
        let font = NSFont.ui(size: size, weight: .semibold)
        if field.font != font { field.font = font }
        let height = ceil(font.ascender - font.descender + font.leading) + 8
        view.frame = CGRect(x: origin.x, y: origin.y, width: width, height: height)
        view.layer?.cornerRadius = Corners.r(height / 2)
        field.frame = CGRect(x: 10, y: 4, width: width - 20, height: height - 8)
    }

    func remove() {
        ended = true
        view.removeFromSuperview()
    }

    private var isCurrent: Bool { !ended && model?.editing?.target == target }

    private func commit() {
        guard isCurrent else { return }
        ended = true
        model?.commitEditing()
    }

    private func cancel() {
        guard isCurrent else { return }
        ended = true
        model?.cancelEditing()
    }

    // MARK: Text view

    func textDidChange(_ notification: Notification) {
        guard isCurrent else { return }
        if let textView { model?.editing?.draft = textView.string }
    }

    func textDidEndEditing(_ notification: Notification) {
        commit()
    }

    func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.cancelOperation(_:)) {
            commit()
            return true
        }
        return false
    }

    // MARK: Fields

    func controlTextDidChange(_ notification: Notification) {
        guard isCurrent, let field else { return }
        model?.editing?.draft = field.stringValue
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        commit()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard isCurrent, let model else { return false }
        if case .cell = target {
            switch selector {
            case #selector(NSResponder.insertTab(_:)):
                ended = true
                model.moveCell(by: 1)
                return true
            case #selector(NSResponder.insertBacktab(_:)):
                ended = true
                model.moveCell(by: -1)
                return true
            case #selector(NSResponder.insertNewline(_:)):
                ended = true
                model.moveCellDown()
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                cancel()
                return true
            default:
                return false
            }
        }
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            commit()
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            cancel()
            return true
        default:
            return false
        }
    }
}

/// The text view of a text card being written: Command-Return saves.
final class BoardTextView: NSTextView {
    var onCommit: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command), event.keyCode == 36 || event.keyCode == 76 {
            onCommit?()
            return
        }
        super.keyDown(with: event)
    }
}

extension BoardCanvasView {
    /// Opens, moves or closes the editor as the model's editing changes.
    func updateEditor() {
        let target = model.editing?.target
        if editor?.target == target {
            editor?.refresh()
            return
        }
        editor?.remove()
        editor = nil
        guard let target else {
            takeKeyboard()
            return
        }
        editor = BoardEditorHost(board: self, target: target)
    }
}
