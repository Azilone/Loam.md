import AppKit
import MeetingsPlugin
import PluginKitUI
import SwiftUI

/// A sound level as a short bar, from silence (-60 dBFS) to loud.
struct LevelMeter: View {
    let level: Double?
    var height: CGFloat = 12

    var body: some View {
        let fill = level.map { max(0, min(1, ($0 + 60) / 50)) } ?? 0
        ThemeCapsule()
            .fill(.quaternary)
            .frame(width: 4, height: height)
            .overlay(alignment: .bottom) {
                ThemeCapsule().fill(.green).frame(height: height * fill)
            }
            .opacity(level == nil ? 0.35 : 1)
            .animation(.linear(duration: 0.12), value: fill)
            .accessibilityHidden(true)
    }
}

struct RecordingDot: View {
    @Environment(\.themeTokens) private var theme
    let paused: Bool
    @State private var dim = false

    var body: some View {
        Circle()
            .fill(paused ? theme.secondaryText : theme.danger)
            .frame(width: 7, height: 7)
            .opacity(dim && !paused ? 0.3 : 1)
            .onAppear {
                guard !Motion.reduceMotion else { return }
                withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) { dim = true }
            }
            .accessibilityLabel(paused ? "Paused" : "Recording")
    }
}

struct IconButton: View {
    let symbol: String
    let help: String
    var tint: Color?
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Image(symbol: symbol)
                .font(.ui(size: 10, weight: .semibold))
                .foregroundStyle(tint.map { AnyShapeStyle($0) } ?? AnyShapeStyle(.secondary))
                .frame(width: 20, height: 20)
                .background(Circle().fill(.primary.opacity(hovered ? 0.1 : 0)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { over in withAnimation(Motion.hover) { hovered = over } }
        .help(help)
        .accessibilityLabel(help)
    }
}

/// The floating pill: the clock, the levels, what was sent and its cost, and the controls, over every window, out of
/// screen sharing when asked. After a long silence it asks whether the meeting is still on.
struct OverlayPill: View {
    let model: RecorderModel

    var body: some View {
        HStack(spacing: 8) {
            DragGrip()
            RecordingDot(paused: model.isPaused)
            Text(clock(model.elapsed)).monospacedDigit().frame(minWidth: 40, alignment: .leading).help(model.costLine)
            if model.idle != nil {
                Text("Still on?").font(.ui(size: 12))
                PillButton(title: "Yes", action: model.continueMeeting)
                PillButton(title: "End", destructive: true) { model.stop() }
            } else {
                HStack(spacing: 3) {
                    ForEach(Array(model.levels.enumerated()), id: \.offset) { LevelMeter(level: $0.element, height: 14) }
                }
                .padding(.trailing, 2)
                PillIcon(symbol: model.isPaused ? "play.fill" : "pause.fill", help: model.isPaused ? "Resume" : "Pause",
                         action: model.togglePause)
                if !model.isVoiceNote {
                    PillIcon(symbol: "bookmark.fill", help: "Mark this moment", action: model.markMoment)
                }
                PillIcon(symbol: "arrow.counterclockwise", help: "Restart") { Task { await model.restart() } }
                PillIcon(symbol: "xmark", help: "Cancel recording") { Task { await model.cancel() } }
                PillIcon(symbol: "stop.fill", help: "Stop", tint: Color(red: 1, green: 0.37, blue: 0.34)) { model.stop() }
            }
        }
        .font(.ui(size: 13, weight: .medium))
        .foregroundStyle(.white.opacity(0.92))
        .padding(.leading, 6)
        .padding(.trailing, 4)
        .frame(height: 36)
        .background(ThemeCapsule().fill(Color(white: 0.11, opacity: 0.94)))
        .overlay(ThemeCapsule().strokeBorder(.white.opacity(0.12)))
        .shadow(color: .black.opacity(0.4), radius: 6, y: 2)
        .padding(4)
        .fixedSize()
        .animation(Motion.Spring.overlay.animation, value: model.idle != nil)
    }
}

/// The pill's grip: two columns of dots at its leading edge, brighter under the pointer; dragging it moves the pill.
struct DragGrip: View {
    @State private var hovered = false

    var body: some View {
        Grid(horizontalSpacing: 2.5, verticalSpacing: 2.5) {
            ForEach(0..<3, id: \.self) { _ in
                GridRow { dot; dot }
            }
        }
        .frame(width: 12, height: 28)
        .contentShape(Rectangle())
        .overlay(WindowDragArea())
        .onHover { over in
            withAnimation(Motion.hover) { hovered = over }
            if over { NSCursor.openHand.push() } else { NSCursor.pop() }
        }
        .help("Drag to move")
        .accessibilityLabel("Move the recorder")
    }

    private var dot: some View {
        Circle().fill(.white.opacity(hovered ? 0.6 : 0.3)).frame(width: 2.5, height: 2.5)
    }
}

/// An AppKit view that hands a mouse-down to the window, so dragging it moves the borderless panel.
private struct WindowDragArea: NSViewRepresentable {
    final class DragView: NSView {
        override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
        override var mouseDownCanMoveWindow: Bool { true }
    }
    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

struct PillIcon: View {
    let symbol: String
    let help: String
    var tint: Color?
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Image(symbol: symbol)
                .font(.ui(size: 11, weight: .semibold))
                .foregroundStyle(tint ?? .white.opacity(0.85))
                .frame(width: 28, height: 28)
                .background(Circle().fill(.white.opacity(hovered ? 0.12 : 0)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { over in withAnimation(Motion.hover) { hovered = over } }
        .help(help)
        .accessibilityLabel(help)
    }
}

struct PillButton: View {
    @Environment(\.themeTokens) private var theme
    let title: String
    var destructive = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title.uiLocalized)
                .font(.ui(size: 12))
                .padding(.horizontal, 8)
                .frame(height: 24)
                .background(ThemeCapsule().fill(destructive ? theme.danger.opacity(0.25) : .white.opacity(0.14)))
        }
        .buttonStyle(.plain)
    }
}

/// The pill's window: borderless, above every app and space, moved by dragging, kept where it was left.
@MainActor
final class OverlayWindow {
    private let panel: NSPanel
    private let model: RecorderModel
    static let originKey = "meetings.overlayOrigin"
    nonisolated(unsafe) private var moveObserver: NSObjectProtocol?

    init(model: RecorderModel, hiddenFromCapture: Bool) {
        self.model = model
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 44),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        // macOS leaves the pill out of screen sharing and screenshots.
        panel.sharingType = hiddenFromCapture ? .none : .readOnly
        let host = NSHostingView(rootView: OverlayPill(model: model))
        host.sizingOptions = [.intrinsicContentSize]
        panel.contentView = host
        moveObserver = NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification, object: panel, queue: .main) { [weak panel] _ in
            MainActor.assumeIsolated {
                guard let origin = panel?.frame.origin else { return }
                UserDefaults.standard.set([origin.x, origin.y], forKey: Self.originKey)
            }
        }
    }

    deinit {
        if let moveObserver { NotificationCenter.default.removeObserver(moveObserver) }
    }

    func show() {
        panel.setContentSize(panel.contentView?.fittingSize ?? panel.frame.size)
        if let saved = UserDefaults.standard.array(forKey: Self.originKey) as? [Double], saved.count == 2,
           NSScreen.screens.contains(where: { $0.visibleFrame.contains(NSPoint(x: saved[0] + 20, y: saved[1] + 20)) }) {
            panel.setFrameOrigin(NSPoint(x: saved[0], y: saved[1]))
        } else if let screen = NSScreen.main?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: screen.midX - panel.frame.width / 2, y: screen.maxY - panel.frame.height - 8))
        }
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Motion.reduceMotion ? 0 : 0.16
            panel.animator().alphaValue = 1
        }
    }

    /// Follows the pill's size as its content changes (the silence question is wider).
    func refresh() {
        let size = panel.contentView?.fittingSize ?? panel.frame.size
        guard abs(size.width - panel.frame.width) > 1 else { return }
        var frame = panel.frame
        frame.size = size
        panel.setFrame(frame, display: true)
    }

    func close() {
        panel.orderOut(nil)
    }
}
