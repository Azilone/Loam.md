import AppKit
import SwiftUI

extension View {
    /// The pointer over this view, set by AppKit over its frame and nothing beyond it.
    ///
    /// SwiftUI's `pointerStyle` follows the pointer from the hosting view it is in, and a side column's hosting view
    /// tracks the whole window: it set its pointer on every move anywhere, which fought the editor's I-beam over the
    /// text and left the resize pointer over the sidebar.
    func pointerCursor(_ cursor: NSCursor) -> some View {
        background(PointerCursor(cursor: cursor))
    }
}

private struct PointerCursor: NSViewRepresentable {
    let cursor: NSCursor

    func makeNSView(context: Context) -> PointerCursorView { PointerCursorView(cursor: cursor) }

    func updateNSView(_ view: PointerCursorView, context: Context) {
        if view.cursor != cursor { view.cursor = cursor }
    }
}

/// Shows its cursor while the pointer is over its bounds, and the arrow again as it leaves; takes no clicks, which go to
/// the SwiftUI view it is behind. A tracking area of its own bounds rather than a cursor rect, which the window of a
/// SwiftUI scene does not apply.
///
/// A drag that starts over it (a column's edge, which lags behind the pointer) keeps its cursor until the button is
/// up, over whatever it crosses: the window's cursor rects, the text's I-beam among them, are off meanwhile.
final class PointerCursorView: NSView {
    var cursor: NSCursor {
        didSet { if isInside || dragMonitor != nil { cursor.set() } }
    }
    private var area: NSTrackingArea?
    private var isInside = false
    /// Watches for a press while the pointer is over the view, then for the drag that follows.
    private var monitor: Any?
    private var dragMonitor: Any?

    init(cursor: NSCursor) {
        self.cursor = cursor
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area { removeTrackingArea(area) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow], owner: self)
        addTrackingArea(area)
        self.area = area
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) {
        isInside = true
        cursor.set()
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            if let self, self.isInside, event.window === self.window { self.beginDrag() }
            return event
        }
    }

    override func mouseMoved(with event: NSEvent) {
        if isInside { cursor.set() }
    }

    override func mouseExited(with event: NSEvent) {
        isInside = false
        stopWatchingPresses()
        if dragMonitor == nil { NSCursor.arrow.set() }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            stopWatchingPresses()
            endDrag()
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    private func beginDrag() {
        guard dragMonitor == nil else { return }
        window?.disableCursorRects()
        cursor.set()
        dragMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDragged, .leftMouseUp]) { [weak self] event in
            guard let self else { return event }
            if event.type == .leftMouseUp {
                // After the gesture has the release.
                DispatchQueue.main.async { self.endDrag() }
            } else {
                self.cursor.set()
            }
            return event
        }
    }

    private func endDrag() {
        guard let dragMonitor else { return }
        NSEvent.removeMonitor(dragMonitor)
        self.dragMonitor = nil
        window?.enableCursorRects()
        window?.resetCursorRects()
        // Still over the edge: its cursor; elsewhere, the views under the pointer set theirs on the next move.
        (isInside ? cursor : NSCursor.arrow).set()
    }

    private func stopWatchingPresses() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}
