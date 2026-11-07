import AppKit
import SwiftUI

/// Calls `onMouseDown` when a click lands anywhere inside the view's frame, without taking the click.
///
/// SwiftUI gestures never see clicks that an AppKit view handles itself (the editor's text view), so a pane cannot
/// learn it was clicked with a tap gesture. This sits behind the pane and watches mouse-downs in its window with a
/// local event monitor, which sees every click before any view does and passes it on unchanged.
struct PaneClickDetector: NSViewRepresentable {
    let onMouseDown: () -> Void

    func makeNSView(context: Context) -> DetectorView {
        let view = DetectorView()
        view.onMouseDown = onMouseDown
        return view
    }

    func updateNSView(_ view: DetectorView, context: Context) {
        view.onMouseDown = onMouseDown
    }

    final class DetectorView: NSView {
        var onMouseDown: (() -> Void)?
        private var monitor: Any?

        /// Never the target of a click: it only watches.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            removeMonitor()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) {
                [weak self] event in
                MainActor.assumeIsolated { self?.handle(event) }
                return event
            }
        }

        private func handle(_ event: NSEvent) {
            guard let window, event.window === window, !isHiddenOrHasHiddenAncestor else { return }
            if bounds.contains(convert(event.locationInWindow, from: nil)) { onMouseDown?() }
        }

        private func removeMonitor() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }

        isolated deinit {
            removeMonitor()
        }
    }
}
