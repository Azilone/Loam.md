import AppKit
import PluginKitUI
import SwiftUI

/// A panel that takes the keyboard without making Loam the active app, as Spotlight: the app the user was in stays
/// in front underneath.
final class KeyPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// The capture window and the line, two borderless panels above every app and space, full-screen apps included.
@MainActor
final class CaptureWindows {
    private let model: CaptureModel
    private var panel: KeyPanel?
    private var linePanel: NSPanel?
    private var keyMonitor: Any?
    private var resignObserver: NSObjectProtocol?

    init(model: CaptureModel) {
        self.model = model
    }

    func tearDown() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        panel?.orderOut(nil)
        linePanel?.orderOut(nil)
        panel = nil
        linePanel = nil
    }

    // MARK: The window

    func show() {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        let host = panel.contentView as? NSHostingView<CaptureView>
        host?.invalidateIntrinsicContentSize()
        let size = host?.fittingSize ?? NSSize(width: 452, height: 220)
        let screen = Self.screenWithMouse()
        let frame = screen.visibleFrame
        // The upper third, where the eye already is.
        let origin = NSPoint(x: frame.midX - size.width / 2, y: frame.maxY - frame.height / 3 - size.height / 2)
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        panel.alphaValue = 0
        panel.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Motion.appKitDuration(0.18)
            panel.animator().alphaValue = 1
        }
        watchKeys()
    }

    func hide() {
        guard let panel, panel.isVisible else { return }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = Motion.appKitDuration(0.12)
            panel.animator().alphaValue = 0
        }, completionHandler: {
            MainActor.assumeIsolated { panel.orderOut(nil) }
        })
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }

    /// The content grew or shrank (an item added or removed): the panel follows, its top edge kept.
    func fit() {
        guard let panel, panel.isVisible, let host = panel.contentView else { return }
        let size = host.fittingSize
        var frame = panel.frame
        frame.origin.y += frame.height - size.height
        frame.size = size
        panel.setFrame(frame, display: true, animate: false)
    }

    private func makePanel() -> KeyPanel {
        let panel = KeyPanel(contentRect: NSRect(x: 0, y: 0, width: 452, height: 220),
                             styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView], backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .modalPanel
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.isReleasedWhenClosed = false
        panel.title = "Capture"
        panel.setAccessibilityIdentifier("capture.panel")
        let host = NSHostingView(rootView: CaptureView(model: model))
        host.sizingOptions = [.intrinsicContentSize]
        panel.contentView = host
        // Clicking elsewhere closes it, as a popover.
        resignObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: panel, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.model.isOpen else { return }
                self.model.close()
            }
        }
        return panel
    }

    /// ⌘V adds what the clipboard holds as an item, unless it is text and the note field is where the user types.
    private func watchKeys() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let panel = self.panel, event.window === panel else { return event }
            if event.keyCode == 53 { // Escape
                self.model.close()
                return nil
            }
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if flags == .command, event.charactersIgnoringModifiers == "v" {
                let pasteboard = NSPasteboard.general
                let onlyText = pasteboard.types?.contains(.string) == true
                    && pasteboard.types?.contains(.fileURL) != true && pasteboard.types?.contains(.png) != true
                    && pasteboard.types?.contains(.tiff) != true && pasteboard.types?.contains(.URL) != true
                if !onlyText || self.model.drafts.isEmpty {
                    self.model.paste()
                    DispatchQueue.main.async { self.fit() }
                    return nil
                }
            }
            return event
        }
    }

    // MARK: The line

    func showLine() {
        let panel = linePanel ?? makeLinePanel()
        linePanel = panel
        let screen = Self.screenWithMouse().visibleFrame
        let width: CGFloat = 540
        panel.setFrame(NSRect(x: screen.midX - width / 2, y: screen.maxY - 64, width: width, height: 56), display: true)
        panel.orderFrontRegardless()
    }

    private func makeLinePanel() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 540, height: 56),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.setAccessibilityIdentifier("capture.line")
        let host = NSHostingView(rootView: CaptureLineView(model: model).frame(maxWidth: .infinity, alignment: .top))
        panel.contentView = host
        return panel
    }

    static func screenWithMouse() -> NSScreen {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main ?? NSScreen.screens[0]
    }
}
