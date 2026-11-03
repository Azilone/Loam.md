import AppKit
import PluginKitUI
import SwiftUI

/// The comings and goings of a floating panel (the `/` menu, the format bar): the window fades in while its content
/// grows from an anchor (the SwiftUI side reads `PanelEntrance`), and fades out before it leaves the screen.
///
/// Leaving never trusts the animation: the panel is taken off the screen by the animation's completion and, should
/// that never run (a window that is hidden or occluded), by a timer a little later. Showing again cancels both.
@MainActor
final class PanelFade {
    /// Bumped by every show and hide; a pending order-out only runs for the generation that asked for it.
    private var generation = 0

    /// Puts `panel` on screen, fading from its current opacity (0 for a panel that was not showing).
    func show(_ panel: NSPanel, duration: TimeInterval) {
        generation += 1
        if !panel.isVisible { panel.alphaValue = 0 }
        panel.orderFront(nil)
        guard panel.alphaValue < 1 else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Motion.appKitDuration(duration)
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        }
    }

    /// Fades `panel` out and takes it off the screen. At once when it is not showing.
    func hide(_ panel: NSPanel, duration: TimeInterval) {
        generation += 1
        let current = generation
        let length = Motion.appKitDuration(duration)
        guard panel.isVisible, panel.alphaValue > 0 else {
            panel.orderOut(nil)
            panel.alphaValue = 1
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = length
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
        } completionHandler: { [weak self, weak panel] in
            MainActor.assumeIsolated { self?.finish(panel, generation: current) }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + length + 0.15) { [weak self, weak panel] in
            MainActor.assumeIsolated { self?.finish(panel, generation: current) }
        }
    }

    private func finish(_ panel: NSPanel?, generation current: Int) {
        guard current == generation, let panel else { return }
        panel.orderOut(nil)
        panel.alphaValue = 1
    }

    /// Moves `panel` to `frame`: at once, or sliding there when it is showing and `animated`.
    static func move(_ panel: NSPanel, to frame: NSRect, animated: Bool, duration: TimeInterval = 0.22) {
        guard frame != panel.frame else { return }
        guard animated, panel.isVisible, !Motion.reduceMotion else {
            panel.setFrame(frame, display: true)
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1)
            panel.animator().setFrame(frame, display: true)
        }
    }
}

/// Whether a panel's content has grown to its place yet. The panel sets it to `false` as it appears and to `true`
/// a frame later, with a spring, so the content animates from the small state.
@MainActor @Observable
final class PanelEntrance {
    var arrived = true

    /// Starts from the small state and, a frame later (so it has been drawn once), grows with `Motion.Spring.overlay`.
    func begin() {
        guard !Motion.reduceMotion else {
            arrived = true
            return
        }
        arrived = false
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(16))
            withAnimation(Motion.Spring.overlay.animation) { self?.arrived = true }
        }
    }
}
