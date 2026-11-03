import AppKit
import PluginKitUI
import SwiftUI

/// What the format bar can do to the selection.
enum FormatAction: Equatable {
    case toggle(InlineFormat)
    case highlight(HighlightColor?)
    case link
}

/// What the format bar shows: which styles the selection has, and whether the colours replace the buttons.
@MainActor @Observable
final class FormatBarModel {
    var active: Set<InlineFormat> = []
    var showsColors = false
    /// The theme's own highlight, which yellow (a plain `==mark==`) is drawn in; yellow when the theme has none.
    var themeHighlight: NSColor?
    var onAction: ((FormatAction) -> Void)?
    /// The bar changed size.
    var onResize: (() -> Void)?
    /// Which side of the selection the bar is on: it grows from the edge nearer the selection.
    var opening: Motion.Opening = .above
    let entrance = PanelEntrance()
}

/// Craft's format bar: a capsule of Liquid Glass above the selection, with the inline styles. Like the `/` menu it
/// never takes keyboard focus, so the selection stays in the text view.
@MainActor
final class FormatBarPanel: NSPanel {
    let model = FormatBarModel()
    private let fade = PanelFade()
    private let host: FirstMouseHostingView<FormatBar>

    init() {
        host = FirstMouseHostingView(rootView: FormatBar(model: model))
        // The panel's frame is ours alone: the hosting view reports its size, it never resizes the panel or limits it.
        host.sizingOptions = [.intrinsicContentSize]
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        // The glass draws its own edge and shadow.
        hasShadow = false
        level = .popUpMenu
        contentView = host
        model.onResize = { [weak self] in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.fit() } }
        }
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// The size the bar takes for what it shows. Its height never changes: only its width follows the buttons or the
    /// colours, and a layout in the middle of the cross-fade (both on screen) cannot make it taller.
    private var barSize: NSSize { NSSize(width: host.fittingSize.width, height: FormatBar.panelHeight) }

    /// Whether the pointer is over the bar: the bar then leaves the selection's updates alone, as the click is on it.
    var isPointerOver: Bool { isVisible && frame.contains(NSEvent.mouseLocation) }

    /// Shows the bar centred above `anchor` (the selection's first line, in screen coordinates), or under `below`
    /// (its last line) when there is no room above inside `bounds` (the visible text, in screen coordinates).
    /// `animated` is false while the page scrolls: the bar then stays on its line, it does not trail behind.
    func show(above anchor: NSRect, below: NSRect, within bounds: NSRect, in parent: NSWindow, animated: Bool = true) {
        appearance = parent.effectiveAppearance
        let entering = parent.childWindows?.contains(self) != true
        // A new selection starts on the buttons.
        if entering { model.showsColors = false }
        let size = barSize
        var origin = NSPoint(x: anchor.minX - 16, y: anchor.maxY + 8)
        var opening = Motion.Opening.above
        if origin.y + size.height > bounds.maxY {
            origin.y = below.minY - size.height - 8
            opening = .below
        }
        origin.x = min(max(origin.x, bounds.minX + 8), bounds.maxX - size.width - 8)
        let frame = NSRect(origin: origin, size: size)
        if entering {
            model.opening = opening
            setFrame(frame, display: true)
            parent.addChildWindow(self, ordered: .above)
            // Fades in and grows from the edge nearer the selection.
            model.entrance.begin()
            fade.show(self, duration: 0.12)
        } else {
            // A selection that changes under the bar carries it along: it slides there, it does not reappear.
            model.opening = opening
            PanelFade.move(self, to: frame, animated: animated)
            orderFront(nil)
        }
    }

    /// The bar's size changed (the colours replaced the buttons): keeps its left edge and its bottom.
    func fit() {
        let size = barSize
        guard isVisible, size != frame.size else { return }
        PanelFade.move(self, to: NSRect(origin: frame.origin, size: size), animated: true, duration: Motion.Spring.smooth.duration)
    }

    func hide() {
        if model.showsColors {
            model.showsColors = false
            model.onResize?()
        }
        parent?.removeChildWindow(self)
        fade.hide(self, duration: Motion.Metrics.exitDuration)
    }
}

struct FormatBar: View {
    /// The capsule's height, and the margin around it for the glass's edge.
    static let capsuleHeight: CGFloat = 50
    static let margin: CGFloat = 10
    static let panelHeight = capsuleHeight + 2 * margin

    let model: FormatBarModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The capsule's full width, measured: it unfolds to it from a circle at its leading end.
    @State private var width: CGFloat = 0

    var body: some View {
        let settled = model.entrance.arrived || reduceMotion
        HStack(spacing: 2) {
            // The colours replace the buttons with a cross-fade while the bar's width follows.
            if model.showsColors {
                colors.transition(.opacity)
            } else {
                buttons.transition(.opacity)
            }
        }
        .motion(Motion.Spring.smooth, value: model.showsColors)
        .padding(.horizontal, 8)
        .frame(height: Self.capsuleHeight)
        .glassEffect(.regular, in: .capsule)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        // Arriving, it unfolds: the capsule opens from a circle at its leading end (where the selection starts)
        // to its full width, its buttons coming in one after the other behind the opening edge.
        .mask(alignment: .leading) {
            Capsule()
                .frame(width: settled || width == 0 ? width + 24 : Self.capsuleHeight + 24, height: Self.capsuleHeight + 24)
                .offset(x: -12)
        }
        .padding(Self.margin)
        .fixedSize()
        .offset(y: settled ? 0 : Motion.Metrics.barRise * model.opening.barRiseSign)
    }

    @ViewBuilder private var buttons: some View {
        let settled = model.entrance.arrived || reduceMotion
        FormatButton(symbol: "highlighter", help: "Highlight", isOn: model.active.contains(.highlight)) {
            model.onAction?(.highlight(model.active.contains(.highlight) ? nil : .yellow))
        }
        .unfolding(index: 0, settled: settled)
        FormatButton(symbol: "chevron.down", help: "Highlight Colour", width: 20, size: 11) {
            model.showsColors = true
            model.onResize?()
        }
        .unfolding(index: 1, settled: settled)
        FormatButton(symbol: "bold", help: "Bold (⌘B)", isOn: model.active.contains(.bold)) {
            model.onAction?(.toggle(.bold))
        }
        .unfolding(index: 2, settled: settled)
        FormatButton(symbol: "italic", help: "Italic (⌘I)", isOn: model.active.contains(.italic)) {
            model.onAction?(.toggle(.italic))
        }
        .unfolding(index: 3, settled: settled)
        FormatButton(symbol: "strikethrough", help: "Strikethrough", isOn: model.active.contains(.strikethrough)) {
            model.onAction?(.toggle(.strikethrough))
        }
        .unfolding(index: 4, settled: settled)
        FormatButton(symbol: "chevron.left.forwardslash.chevron.right", help: "Code", isOn: model.active.contains(.code)) {
            model.onAction?(.toggle(.code))
        }
        .unfolding(index: 5, settled: settled)
        FormatButton(symbol: "link", help: "Link (⌘K)") {
            model.onAction?(.link)
        }
        .unfolding(index: 6, settled: settled)
    }

    @ViewBuilder private var colors: some View {
        ColorSwatch(color: nil) { model.onAction?(.highlight(nil)) }
        Divider().frame(height: 20).padding(.horizontal, 4)
        ForEach(HighlightColor.allCases, id: \.self) { color in
            ColorSwatch(color: color, fill: color == .yellow ? model.themeHighlight : nil) { model.onAction?(.highlight(color)) }
        }
    }
}

extension View {
    /// A format bar button coming in as the bar unfolds: faded and a few points back, then in place, each a beat
    /// after the one before it (`Motion.stagger`).
    fileprivate func unfolding(index: Int, settled: Bool) -> some View {
        opacity(settled ? 1 : 0)
            .offset(x: settled ? 0 : -6)
            .animation(Motion.Spring.overlay.animation.delay(settled ? Motion.stagger(index: index + 1) : 0), value: settled)
    }
}

private struct FormatButton: View {
    let symbol: String
    let help: String
    var isOn = false
    var width: CGFloat = 38
    var size: CGFloat = 17
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(symbol: symbol)
                .font(.ui(size: size, weight: .medium))
                .foregroundStyle(isOn ? Color.accentColor : Color.primary)
                .frame(width: width, height: 34)
                .background(
                    RoundedRectangle(cornerRadius: Corners.r(8), style: .continuous)
                        .fill(Color.primary.opacity(isOn ? 0.1 : hovering ? 0.06 : 0))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .onHover { hovering = $0 }
    }
}

/// One of Craft's colour squares; nil is the "no highlight" circle.
private struct ColorSwatch: View {
    let color: HighlightColor?
    /// Drawn instead of the colour's own: what the page shows for it.
    var fill: NSColor? = nil
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Group {
                if let color {
                    RoundedRectangle(cornerRadius: Corners.r(6), style: .continuous)
                        .fill(Color(nsColor: fill ?? NSColor(hex: color.hex) ?? .yellow))
                        .overlay(
                            RoundedRectangle(cornerRadius: Corners.r(6), style: .continuous)
                                .strokeBorder(Color.black.opacity(0.12), lineWidth: 1)
                        )
                } else {
                    Circle()
                        .strokeBorder(Color.secondary.opacity(0.5), lineWidth: 1)
                        .overlay(
                            Rectangle().fill(Color.secondary.opacity(0.5)).frame(width: 1).rotationEffect(.degrees(40))
                        )
                        .clipShape(Circle())
                }
            }
            .frame(width: 26, height: 26)
            .scaleEffect(hovering ? 1.12 : 1)
            .motion(Motion.hover, value: hovering)
            .frame(width: 36, height: 34)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(color.map { $0.rawValue.capitalized } ?? "No Highlight")
        .onHover { hovering = $0 }
    }
}
