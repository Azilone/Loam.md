import AppKit
import SwiftUI

/// An invisible AppKit view that becomes the window's first responder when the map is clicked, so keys reach the
/// map and not the note editor beside it. It answers the Edit menu's Copy, Cut, Paste and Select All, and undo goes
/// through the window's undo manager. Clicks pass through it.
struct MindmapKeyCatcher: NSViewRepresentable {
    let model: MindmapTabModel
    /// Changes when the map asks for the keyboard (`MindmapTabModel.requestKeyboard`).
    let focusRequest: Int
    let onKey: (NSEvent) -> Bool

    func makeNSView(context: Context) -> MindmapKeyView {
        let view = MindmapKeyView()
        view.model = model
        view.onKey = onKey
        model.keyView = view
        return view
    }

    func updateNSView(_ view: MindmapKeyView, context: Context) {
        view.model = model
        view.onKey = onKey
        model.keyView = view
        guard view.focusRequest != focusRequest else { return }
        view.focusRequest = focusRequest
        DispatchQueue.main.async { [weak view, model] in
            // A topic being edited keeps the keyboard.
            guard let view, let window = view.window, window.firstResponder !== view,
                  model.editingID == nil else { return }
            window.makeFirstResponder(view)
        }
    }
}

final class MindmapKeyView: NSView {
    weak var model: MindmapTabModel?
    var onKey: ((NSEvent) -> Bool)?
    var focusRequest = -1

    override var acceptsFirstResponder: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func becomeFirstResponder() -> Bool {
        MainActor.assumeIsolated { model?.hasKeyboard = true }
        return true
    }

    override func resignFirstResponder() -> Bool {
        MainActor.assumeIsolated { model?.hasKeyboard = false }
        return true
    }

    override func keyDown(with event: NSEvent) {
        if onKey?(event) != true { super.keyDown(with: event) }
    }

    override func keyUp(with event: NSEvent) {
        if onKey?(event) != true { super.keyUp(with: event) }
    }

    /// Command keys of the map (⌘+ ⌘- ⌘↩, and ⌘. ⌘0 when a keyboard layout keeps them from the commands) while it
    /// has the keyboard; the Edit menu keeps the others.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self, event.type == .keyDown,
              event.modifierFlags.contains(.command) else { return super.performKeyEquivalent(with: event) }
        let key = event.charactersIgnoringModifiers ?? ""
        guard [".", "0", "à", "=", "+", "-", "\r"].contains(key) else { return super.performKeyEquivalent(with: event) }
        return onKey?(event) == true
    }

    @objc func copy(_ sender: Any?) {
        MainActor.assumeIsolated {
            guard let text = model?.copySelection() else { return }
            put(text)
        }
    }

    @objc func cut(_ sender: Any?) {
        MainActor.assumeIsolated {
            guard let text = model?.cutSelection() else { return }
            put(text)
        }
    }

    @objc func paste(_ sender: Any?) {
        MainActor.assumeIsolated {
            guard let text = NSPasteboard.general.string(forType: .string) else { return }
            model?.paste(text)
        }
    }

    override func selectAll(_ sender: Any?) {
        MainActor.assumeIsolated { model?.selectAll() }
    }

    private func put(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

/// The keys of the map, from an AppKit key event.
enum MindmapKey {
    case tab, returnKey, space, delete, escape, up, down, left, right, home, f2
    case character(String)

    var isCharacter: Bool {
        if case .character = self { return true }
        return false
    }

    /// The text the key types, when it types some: a character or a space, not a control or function key.
    var typedText: String? {
        switch self {
        case .space: return " "
        case .character(let text):
            let printable = text.unicodeScalars.allSatisfy {
                !CharacterSet.controlCharacters.contains($0) && !(0xF700 ... 0xF8FF).contains($0.value)
            }
            return printable ? text : nil
        default: return nil
        }
    }

    init?(_ event: NSEvent) {
        switch event.keyCode {
        case 48: self = .tab
        case 36, 76: self = .returnKey
        case 49: self = .space
        case 51, 117: self = .delete
        case 53: self = .escape
        case 126: self = .up
        case 125: self = .down
        case 123: self = .left
        case 124: self = .right
        case 115: self = .home
        case 120: self = .f2
        default:
            guard let characters = event.characters, !characters.isEmpty else { return nil }
            self = .character(characters)
        }
    }
}

/// The text field of the topic being edited, an AppKit field so it takes the keyboard for sure. Return saves and
/// opens a sibling (Shift or Option: above), Tab saves and opens a child, Shift-Tab moves the topic up a level,
/// Escape and a click elsewhere save (Escape after typing over a topic puts its text back).
struct MindmapTextField: NSViewRepresentable {
    let model: MindmapTabModel
    let font: NSFont
    let color: NSColor

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    func makeNSView(context: Context) -> NSTextField {
        let field = FocusingTextField(string: model.draft)
        field.selectsAll = model.selectsAllWhenEditing
        model.selectsAllWhenEditing = false
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = font
        field.textColor = color
        field.placeholderString = "Topic"
        field.lineBreakMode = .byWordWrapping
        field.usesSingleLineMode = false
        field.cell?.wraps = true
        field.cell?.isScrollable = false
        field.delegate = context.coordinator
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.model = model
        field.font = font
        field.textColor = color
        if field.currentEditor() == nil, field.stringValue != model.draft { field.stringValue = model.draft }
    }

    /// Takes the keyboard as soon as it is in a window, the caret at the end of its text.
    final class FocusingTextField: NSTextField {
        var selectsAll = false

        /// ⌘A selects the topic's text, whatever the Edit menu has.
        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "a",
               let editor = currentEditor() {
                editor.selectAll(nil)
                return true
            }
            return super.performKeyEquivalent(with: event)
        }

        /// SwiftUI adds the field a frame or two after the topic starts being edited, and may move it while it is
        /// edited: each time, it takes the text typed meanwhile (`MindmapTabModel.handleKey`) and the keyboard.
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard window != nil else { return }
            if let model = (delegate as? Coordinator)?.model, model.editingID != nil, stringValue != model.draft {
                stringValue = model.draft
            }
            focus(retries: 3)
        }

        private func focus(retries: Int) {
            guard let window else { return }
            guard window.makeFirstResponder(self), let editor = currentEditor() else {
                guard retries > 0 else { return }
                DispatchQueue.main.async { [weak self] in self?.focus(retries: retries - 1) }
                return
            }
            let length = stringValue.utf16.count
            editor.selectedRange = selectsAll ? NSRange(location: 0, length: length)
                : NSRange(location: length, length: 0)
            selectsAll = false
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var model: MindmapTabModel
        /// Set once the edit is finished by a key, so losing the focus afterwards does nothing.
        private var done = false

        init(model: MindmapTabModel) { self.model = model }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            model.draft = field.stringValue
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.insertNewline(_:)):
                let above = NSApp.currentEvent?.modifierFlags.contains(.shift) == true
                finish { $0.returnWhileEditing(above: above) }
            case #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)):
                // ⌥↩, as in MindNode; a topic is one line of the note's list, so no line break.
                finish { $0.returnWhileEditing(above: true) }
            case #selector(NSResponder.insertTab(_:)):
                finish { $0.tabWhileEditing() }
            case #selector(NSResponder.insertBacktab(_:)):
                finish { $0.backtabWhileEditing() }
            case #selector(NSResponder.cancelOperation(_:)):
                finish { $0.escapeWhileEditing() }
            case #selector(NSResponder.insertLineBreak(_:)):
                return true
            default:
                return false
            }
            return true
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            // A click elsewhere saves; a field SwiftUI rebuilds does not.
            guard !done, let field = notification.object as? NSTextField else { return }
            let editing = model.editingID
            DispatchQueue.main.async { [model] in
                guard field.window != nil, field.currentEditor() == nil, editing != nil,
                      model.editingID == editing else { return }
                model.commitEdit()
            }
        }

        private func finish(_ action: (MindmapTabModel) -> Void) {
            let editing = model.editingID
            // Set first: this field losing the keyboard below is not a click elsewhere.
            done = true
            action(model)
            guard model.editingID != editing else {
                done = false
                return
            }
            // Typing goes on in another topic, or stops. The map takes the keyboard at once, so no key is lost
            // before the next topic's field is up (it hands the keyboard over then).
            model.takeKeyboard()
        }
    }
}
