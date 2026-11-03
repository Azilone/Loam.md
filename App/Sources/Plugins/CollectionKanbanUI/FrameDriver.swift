import AppKit
import SwiftUI

/// Calls `onFrame` with the time and the time since the last call, once per screen refresh, while `isRunning`.
/// What a drag needs when nothing moves: the board scrolling under a still pointer, a card settling.
struct FrameDriver: NSViewRepresentable {
    var isRunning: Bool
    var onFrame: @MainActor (CFTimeInterval, CFTimeInterval) -> Void

    func makeNSView(context: Context) -> NSView {
        NSView(frame: .zero)
    }

    func updateNSView(_ view: NSView, context: Context) {
        context.coordinator.onFrame = onFrame
        context.coordinator.set(running: isRunning, in: view)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) {
        coordinator.set(running: false, in: view)
    }

    @MainActor
    final class Coordinator: NSObject {
        var onFrame: (@MainActor (CFTimeInterval, CFTimeInterval) -> Void)?
        private var link: CADisplayLink?
        private var last: CFTimeInterval = 0

        func set(running: Bool, in view: NSView) {
            if running, link == nil, view.window != nil {
                let link = view.displayLink(target: self, selector: #selector(step(_:)))
                link.add(to: .main, forMode: .common)
                last = 0
                self.link = link
            } else if !running, let link {
                link.invalidate()
                self.link = nil
            }
        }

        @objc private func step(_ link: CADisplayLink) {
            let now = link.timestamp
            let dt = last == 0 ? 1.0 / 60 : min(now - last, 1.0 / 20)
            last = now
            onFrame?(now, dt)
        }
    }
}
