import AppKit
import PluginKitUI
import SwiftUI

/// What the link field shows and does: the destination being typed, and what Return, Escape and the remove button do.
@MainActor @Observable
final class LinkEditorModel {
    var text = ""
    /// Whether the selection is already a link, which the field then edits and the remove button can unlink.
    var isExisting = false
    var onCommit: ((String) -> Void)?
    var onRemove: (() -> Void)?
    var onCancel: (() -> Void)?
}

/// The field a link's destination is typed in (Craft's link popover), so the destination is never typed as `](...)` in
/// the text. A glass capsule under the selection that takes the keyboard while it is open: Return sets the link,
/// Escape or a click away leaves it as it was.
@MainActor
final class LinkEditorPanel: NSPanel {
    let model = LinkEditorModel()
    private let fade = PanelFade()
    private let host: NSHostingView<LinkEditor>
    private var resignObserver: Any?

    init() {
        host = NSHostingView(rootView: LinkEditor(model: model))
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .popUpMenu
        contentView = host
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// Shows the field under `anchor` (the selection's last line, in screen coordinates), or above `above` when there is
    /// no room under it inside `bounds`.
    func show(below anchor: NSRect, above: NSRect, within bounds: NSRect, in parent: NSWindow) {
        appearance = parent.effectiveAppearance
        let size = host.fittingSize
        var origin = NSPoint(x: anchor.minX - 16, y: anchor.minY - size.height - 6)
        if origin.y < bounds.minY { origin.y = above.maxY + 6 }
        origin.x = min(max(origin.x, bounds.minX + 8), bounds.maxX - size.width - 8)
        setFrame(NSRect(origin: origin, size: size), display: true)
        parent.addChildWindow(self, ordered: .above)
        makeKeyAndOrderFront(nil)
        fade.show(self, duration: 0.12)
        // A click away, in the text or elsewhere, leaves the link as it was.
        resignObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: self, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.model.onCancel?() }
        }
    }

    func hide() {
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        resignObserver = nil
        parent?.removeChildWindow(self)
        fade.hide(self, duration: Motion.Metrics.exitDuration)
    }

    override func cancelOperation(_ sender: Any?) {
        model.onCancel?()
    }
}

struct LinkEditor: View {
    @Bindable var model: LinkEditorModel
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(symbol: "link")
                .font(.ui(size: 14, weight: .medium))
                .foregroundStyle(.secondary)
            TextField("Paste or type a link", text: $model.text)
                .textFieldStyle(.plain)
                .font(.ui(size: 14))
                .focused($focused)
                .onSubmit { model.onCommit?(model.text) }
                .onExitCommand { model.onCancel?() }
                .frame(width: 250)
            if model.isExisting {
                Button { model.onRemove?() } label: {
                    Image(symbol: "link.badge.plus")
                        .rotationEffect(.degrees(0))
                        .overlay(Rectangle().fill(.secondary).frame(width: 1.5, height: 20).rotationEffect(.degrees(45)))
                        .font(.ui(size: 14))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Remove Link")
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 44)
        .glassEffect(.regular, in: .capsule)
        .padding(10)
        .fixedSize()
        .onAppear { focused = true }
    }
}

extension InlineFormatting {
    /// The selected text as a link to `destination`: `[text](destination)`, the caret after it. A destination with a
    /// space or a parenthesis goes in angle brackets, as Markdown asks.
    public static func link(to destination: String, in text: String, selection: NSRange) -> TextEdit {
        let label = (text as NSString).substring(with: selection)
        let replacement = "[\(label)](\(written(destination)))"
        return TextEdit(range: selection, replacement: replacement, selection: NSRange(location: selection.location + (replacement as NSString).length, length: 0))
    }

    /// The destination of the link whose closing syntax (`](old)`) is at `closing` replaced by `destination`.
    public static func setDestination(_ destination: String, closing: NSRange) -> TextEdit {
        let replacement = "](\(written(destination)))"
        return TextEdit(range: closing, replacement: replacement, selection: NSRange(location: closing.location + (replacement as NSString).length, length: 0))
    }

    /// The link written from `open` (`[`) to `close` (`](url)`) as its text alone.
    public static func unlink(open: NSRange, close: NSRange, in text: String) -> TextEdit {
        let ns = text as NSString
        let label = ns.substring(with: NSRange(location: NSMaxRange(open), length: close.location - NSMaxRange(open)))
        let whole = NSRange(location: open.location, length: NSMaxRange(close) - open.location)
        return TextEdit(range: whole, replacement: label, selection: NSRange(location: open.location + (label as NSString).length, length: 0))
    }

    static func written(_ destination: String) -> String {
        let trimmed = destination.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.contains(where: { $0 == " " || $0 == "(" || $0 == ")" }) ? "<\(trimmed)>" : trimmed
    }
}

extension EditorController {
    /// Cmd+K and the format bar's link button: a field for the destination of the selected text, or of the link the
    /// caret is in. A selected address links to itself at once. False when there is no selection and no link.
    func beginLinkEdit() -> Bool {
        guard let textView, let window = textView.window else { return false }
        let text = textView.string
        let selection = textView.selectedRange()
        // Showing the source, the destination is text like any other.
        guard syntaxMode == .rendered, isHiddenSyntaxCurrentForLinks else {
            guard selection.length > 0 else { return false }
            let edit = InlineFormatting.link(in: text, selection: selection)
            textView.window?.makeFirstResponder(textView)
            applyEdit(edit)
            return true
        }
        let existing = existingLink(near: selection)
        if existing == nil {
            guard selection.length > 0, !(text as NSString).substring(with: selection).contains("\n") else { return false }
            let label = (text as NSString).substring(with: selection).trimmingCharacters(in: .whitespaces)
            if label.hasPrefix("http://") || label.hasPrefix("https://"), !label.contains(" ") {
                applyEdit(InlineFormatting.link(to: label, in: text, selection: selection))
                return true
            }
        }
        let panel = linkEditorPanel ?? LinkEditorPanel()
        linkEditorPanel = panel
        let anchorRange = existing?.text ?? selection
        let first = textView.firstRect(forCharacterRange: NSRange(location: anchorRange.location, length: min(1, anchorRange.length)), actualRange: nil)
        let last = textView.firstRect(forCharacterRange: NSRange(location: max(anchorRange.location, NSMaxRange(anchorRange) - 1), length: min(1, anchorRange.length)), actualRange: nil)
        let area = textView.enclosingScrollView.map { $0.convert($0.bounds, to: nil) } ?? window.contentLayoutRect
        let visible = window.convertToScreen(area)
        hideFormatBar()
        panel.model.text = existing?.destination ?? ""
        panel.model.isExisting = existing != nil
        let close: () -> Void = { [weak self, weak panel] in
            panel?.hide()
            self?.textView?.window?.makeFirstResponder(self?.textView)
        }
        panel.model.onCancel = { close() }
        panel.model.onCommit = { [weak self] destination in
            close()
            guard let self, !destination.trimmingCharacters(in: .whitespaces).isEmpty else { return }
            if let existing {
                self.applyEdit(InlineFormatting.setDestination(destination, closing: existing.closing))
            } else {
                self.applyEdit(InlineFormatting.link(to: destination, in: text, selection: selection))
            }
        }
        panel.model.onRemove = { [weak self] in
            close()
            guard let self, let existing else { return }
            self.applyEdit(InlineFormatting.unlink(open: existing.open, close: existing.closing, in: text))
        }
        panel.show(below: last, above: first, within: visible, in: window)
        return true
    }

    private var isHiddenSyntaxCurrentForLinks: Bool {
        guard let textView else { return false }
        return hiddenSyntax.text.isEqual(to: textView.string)
    }

    /// The link the selection touches: its text, destination and the two runs of syntax around the text.
    private func existingLink(near selection: NSRange) -> (text: NSRange, destination: String, open: NSRange, closing: NSRange)? {
        for span in styledSpans {
            guard case .link(let destination) = span.style else { continue }
            let touches = selection.length == 0
                ? selection.location >= span.range.location && selection.location <= NSMaxRange(span.range)
                : NSIntersectionRange(selection, span.range).length > 0
            guard touches, let pair = hiddenSyntax.pairs.first(where: { NSMaxRange($0.open) == span.range.location && $0.close.location == NSMaxRange(span.range) })
            else { continue }
            return (span.range, destination, pair.open, pair.close)
        }
        return nil
    }
}
