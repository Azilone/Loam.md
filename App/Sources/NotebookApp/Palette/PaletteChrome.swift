import PluginKitUI
import AppKit
import Observation
import SwiftUI

// What the palette adds to a vault window (`ShellRootView`): the quick pick popup (`PaletteLayerView`), the command
// toast (`ToastRoot`), and the key monitor that runs commands from their shortcuts while the window is open.

/// The command toast at the window's bottom, in a hosting view of its own over the pages (`OverlayHostingView`): a
/// new toast changes only it.
struct ToastRoot: View {
    let runner: CommandRunner
    let look: ShellLook
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
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
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .environment(\.themeTokens, look.theme)
        .environment(\.windowCanvas, look.canvas)
        .tint(look.theme.accent)
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

/// Whether the palette's content is there: still for its fade out once the palette is closed.
@MainActor @Observable
final class PaletteVisibility {
    var shown = false
}

struct PaletteRoot: View {
    let controller: QuickPickController
    let visibility: PaletteVisibility
    var theme: ThemeTokens

    var body: some View {
        ZStack {
            if visibility.shown {
                QuickPickView(controller: controller)
                    .id(controller.presentation)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .environment(\.themeTokens, theme)
        .tint(theme.accent)
    }
}

/// The palette over the window, in its own hosting view: its arrival and its typing update only it. It fades in and
/// out as a Core Animation layer, so the motion never waits for the main thread (a new tab builds its page in the same
/// frames). It takes no click while it is closed.
final class PaletteLayerView: NSHostingView<PaletteRoot> {
    private let controller: QuickPickController
    private let visibility: PaletteVisibility
    var theme: ThemeTokens {
        didSet { if theme != oldValue { rootView = PaletteRoot(controller: controller, visibility: visibility, theme: theme) } }
    }

    init(controller: QuickPickController, theme: ThemeTokens) {
        self.controller = controller
        self.theme = theme
        let visibility = PaletteVisibility()
        self.visibility = visibility
        super.init(rootView: PaletteRoot(controller: controller, visibility: visibility, theme: theme))
        safeAreaRegions = []
        sizingOptions = []
        wantsLayer = true
        visibility.shown = controller.isPresented
        observe()
    }

    required init(rootView: PaletteRoot) { fatalError("init(rootView:) is not supported") }

    @MainActor required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func hitTest(_ point: NSPoint) -> NSView? {
        controller.isPresented ? super.hitTest(point) : nil
    }

    private func observe() {
        withObservationTracking {
            _ = controller.isPresented
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                guard let self else { return }
                self.presentedChanged(self.controller.isPresented)
                self.observe()
            }
        }
    }

    /// In: there at once, faded in from nothing, a few points high. Out: faded faster than it came, then gone.
    private func presentedChanged(_ presented: Bool) {
        guard let layer else { return }
        let reduce = Motion.reduceMotion
        layer.removeAllAnimations()
        if presented {
            visibility.shown = true
            layer.opacity = 1
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0
            fade.toValue = 1
            fade.duration = reduce ? 0.1 : 0.14
            fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
            layer.add(fade, forKey: "paletteIn")
            if !reduce {
                let rise = CABasicAnimation(keyPath: "sublayerTransform.translation.y")
                rise.fromValue = -6
                rise.toValue = 0
                rise.duration = 0.18
                rise.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1)
                layer.add(rise, forKey: "paletteRise")
            }
        } else {
            CATransaction.begin()
            CATransaction.setCompletionBlock { [weak self] in
                guard let self, !self.controller.isPresented else { return }
                self.visibility.shown = false
                self.layer?.opacity = 1
            }
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 1
            fade.toValue = 0
            fade.duration = 0.1
            fade.timingFunction = CAMediaTimingFunction(name: .easeIn)
            layer.opacity = 0
            layer.add(fade, forKey: "paletteOut")
            CATransaction.commit()
        }
    }
}
