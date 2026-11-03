import AppKit
import SwiftUI

extension View {
    /// What the palette adds to a vault window: the quick pick popup, the command toast, and the key monitor that
    /// runs commands from their shortcuts while the window is open.
    func paletteChrome(_ session: ShellSession) -> some View {
        modifier(PaletteChrome(session: session))
    }
}

private struct PaletteChrome: ViewModifier {
    let session: ShellSession
    @State private var monitor = KeyMonitor()
    @State private var focus = PickerFocus()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        let quickPick = session.quickPick
        let runner = session.commandRunner
        content
            .overlay {
                ZStack {
                    if quickPick.isPresented {
                        QuickPickView(controller: quickPick)
                            .id(quickPick.presentation)
                    }
                }
                .motion(.overlay, value: quickPick.isPresented)
            }
            .overlay(alignment: .bottom) {
                ZStack {
                    if let toast = runner.toast {
                        // One view for every message: a new toast changes the capsule in place instead of stacking another.
                        ToastView(
                            toast: toast,
                            dismiss: { runner.dismissToast() },
                            hover: { runner.holdToast($0) }
                        )
                        .transition(ToastView.transition(reduceMotion: reduceMotion))
                    }
                }
                .motion(.pop, value: runner.toast)
            }
            .background {
                WindowReader { window in
                    monitor.window = window
                }
            }
            .onAppear {
                let session = session
                monitor.start { shortcut in
                    session.handleKey(shortcut)
                }
            }
            .onDisappear {
                monitor.stop()
            }
            .onChange(of: quickPick.isPresented) { _, presented in
                guard let window = monitor.window else { return }
                if presented { focus.shown(in: window) } else { focus.hidden(in: window) }
            }
    }
}

/// Closing the popup gives the keyboard back to the view that had it (a note's caret, a mindmap), so the keyboard
/// goes on where it was. Unless something took it meanwhile: a note the choice opened, a field.
@MainActor
final class PickerFocus {
    /// The first responder before the popup opened, held weakly so a view that went away is not kept.
    private weak var responder: NSResponder?

    func shown(in window: NSWindow) {
        responder = window.firstResponder
    }

    /// Gives the keyboard back once the popup's field has let it go, on the next turn of the main queue.
    func hidden(in window: NSWindow) {
        let previous = responder
        responder = nil
        DispatchQueue.main.async {
            guard window.firstResponder === window || window.firstResponder == nil,
                  let view = previous as? NSView, view.window === window else { return }
            window.makeFirstResponder(view)
        }
    }
}

/// Reports the window a view is in, once it has one.
private struct WindowReader: NSViewRepresentable {
    let found: @MainActor (NSWindow?) -> Void

    func makeNSView(context: Context) -> WindowReaderView {
        let view = WindowReaderView()
        view.found = found
        return view
    }

    func updateNSView(_ view: WindowReaderView, context: Context) {
        view.found = found
        view.found?(view.window)
    }
}

final class WindowReaderView: NSView {
    var found: (@MainActor (NSWindow?) -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        found?(window)
    }
}
