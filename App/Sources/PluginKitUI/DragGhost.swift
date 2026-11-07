import AppKit
import Observation
import SwiftUI

/// Where the pointer is during a drag of a note or a tab, for the picture that follows it.
public enum DragRegion: Equatable, Sendable {
    /// Over a sidebar: the picture shrinks to a row, so the folders it passes over stay in sight.
    case sidebar
    /// Over a page, or anywhere else: a card of the note.
    case page
    /// Over a split zone of a pane: the card grows, as what is about to take half the window.
    case split
}

/// The picture that follows the pointer while a note or a tab is dragged, drawn by the app instead of the system's
/// fixed drag image so that it can change with where it is (`DragRegion`): a row over the sidebar, a card over the
/// pages, a larger card over a split zone, morphing from one to the other with `Motion.Spring.standard`.
///
/// A borderless panel that ignores the mouse (drops go through it to what is under it), moved under the pointer on
/// every frame of the display.
@MainActor
public final class DragGhost {
    public static let shared = DragGhost()

    /// Says what is under a point of the screen (the window below the picture): set by the shell, which knows its
    /// sidebars. Without it the picture stays a card.
    public static var region: (@MainActor (NSPoint, _ below: Int) -> DragRegion)?

    /// Set by a pane while the pointer is on one of its split zones.
    public var isOverSplitZone = false

    private let model = DragGhostModel()
    private var panel: NSPanel?
    private var link: CADisplayLink?

    /// The room around the picture inside its panel, for its shadow and its growth.
    private static let panelSize = NSSize(width: 380, height: 280)
    private static let margin: CGFloat = 24
    /// Where the pointer holds the picture, from its top left corner: it grows away from the hand.
    private static let grip = NSPoint(x: 22, y: 15)

    /// Shows the picture of `title` (a page's `snapshot` when there is one) under the pointer.
    public func show(title: String, symbol: String, snapshot: NSImage?) {
        model.title = title
        model.symbol = symbol
        model.snapshot = snapshot
        isOverSplitZone = false
        let panel = self.panel ?? makePanel()
        self.panel = panel
        model.region = currentRegion(of: panel)
        model.visible = false
        move(panel)
        panel.orderFront(nil)
        DispatchQueue.main.async { [model] in
            Motion.with(Motion.Spring.overlay.animation) { model.visible = true }
        }
        link?.invalidate()
        if let view = panel.contentView {
            let link = view.displayLink(target: self, selector: #selector(step(_:)))
            link.add(to: .main, forMode: .common)
            self.link = link
        }
    }

    /// Takes the picture away: it fades where it is, as the drop lands.
    public func hide() {
        link?.invalidate()
        link = nil
        guard let panel, panel.isVisible else { return }
        withAnimation(Motion.exit) { model.visible = false }
        let current = panel
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.14) { [weak self] in
            guard self?.link == nil else { return }
            current.orderOut(nil)
        }
    }

    @objc private func step(_ link: CADisplayLink) {
        guard let panel else { return }
        move(panel)
        let region = currentRegion(of: panel)
        if region != model.region {
            Motion.with(Motion.Spring.standard.animation) { model.region = region }
        }
    }

    private func currentRegion(of panel: NSPanel) -> DragRegion {
        if isOverSplitZone { return .split }
        return Self.region?(NSEvent.mouseLocation, panel.windowNumber) ?? .page
    }

    /// The panel placed so that the grip of the picture is under the pointer.
    private func move(_ panel: NSPanel) {
        let pointer = NSEvent.mouseLocation
        let origin = NSPoint(
            x: (pointer.x - Self.grip.x - Self.margin).rounded(),
            y: (pointer.y + Self.grip.y + Self.margin - Self.panelSize.height).rounded()
        )
        if panel.frame.origin != origin { panel.setFrameOrigin(origin) }
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: Self.panelSize),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle]
        let host = NSHostingView(rootView: DragGhostView(model: model, margin: Self.margin))
        host.frame = NSRect(origin: .zero, size: Self.panelSize)
        panel.contentView = host
        return panel
    }
}

@MainActor @Observable
final class DragGhostModel {
    var title = ""
    var symbol = "doc.text"
    var snapshot: NSImage?
    var region: DragRegion = .page
    var visible = false
}

/// The picture itself: one rounded surface whose size and content follow the region.
struct DragGhostView: View {
    let model: DragGhostModel
    let margin: CGFloat
    @Environment(\.colorScheme) private var colorScheme

    private var size: CGSize {
        switch model.region {
        case .sidebar: CGSize(width: rowWidth, height: 30)
        case .page: CGSize(width: 200, height: 124)
        case .split: CGSize(width: 280, height: 176)
        }
    }

    /// A row as wide as its title needs, within a sidebar's width.
    private var rowWidth: CGFloat {
        let text = (model.title as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 13, weight: .medium)]).width
        return min(max(text + 48, 90), 230)
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Corners.r(model.region == .sidebar ? 8 : 12), style: .continuous)
        let row = model.region == .sidebar
        ZStack(alignment: .topLeading) {
            shape.fill(colorScheme == .dark ? Color(white: 0.17) : .white)
            if row {
                HStack(spacing: 8) {
                    Image(symbol: model.symbol)
                        .font(.ui(size: 13))
                        .foregroundStyle(.secondary)
                    Text(model.title.isEmpty ? "Untitled" : model.title)
                        .font(.ui(size: 13, weight: .medium))
                        .lineLimit(1)
                }
                .padding(.horizontal, 10)
                .frame(height: 30)
                .transition(.opacity)
            } else if let snapshot = model.snapshot {
                Image(nsImage: snapshot)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: size.width, height: size.height, alignment: .top)
                    .clipShape(shape)
                    .transition(.opacity)
            } else {
                VStack(alignment: .leading, spacing: 7) {
                    Text(model.title.isEmpty ? "Untitled" : model.title)
                        .font(.ui(size: 13, weight: .semibold))
                        .lineLimit(1)
                    ForEach(0..<4, id: \.self) { line in
                        ThemeCapsule().fill(.secondary.opacity(0.22)).frame(width: line == 3 ? 80 : nil, height: 5)
                    }
                }
                .padding(14)
                .transition(.opacity)
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .clipShape(shape)
        .overlay { shape.strokeBorder(.secondary.opacity(0.22), lineWidth: 1) }
        .background {
            shape.fill(.clear)
                .shadow(color: .black.opacity(row ? 0.14 : 0.2), radius: row ? 8 : model.region == .split ? 22 : 14, y: row ? 3 : 8)
        }
        .scaleEffect(model.visible ? 1 : 0.9, anchor: .topLeading)
        .opacity(model.visible ? 0.96 : 0)
        .padding(margin)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .allowsHitTesting(false)
    }
}

/// The system's own drag image, made invisible: the app draws the picture that follows the pointer (`DragGhost`).
public struct HiddenDragPreview: View {
    public init() {}

    public var body: some View { Color.clear.frame(width: 1, height: 1) }
}
