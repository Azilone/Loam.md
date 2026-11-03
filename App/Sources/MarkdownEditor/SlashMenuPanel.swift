import AppKit
import PluginKitUI
import SwiftUI

/// What the `/` menu shows: the matching entries and the highlighted one.
@MainActor @Observable
final class SlashMenuModel {
    var items: [SlashMenuItem] = []
    /// Before anything is typed the entries show under their section's name, as in Craft; filtered, they don't.
    var grouped = true
    var selected = 0
    var onChoose: ((SlashMenuItem) -> Void)?
    /// The entry chosen that is still opening something (Finder's Open panel): its row says so, with a spinner.
    var loading: String?
    /// Which side of the caret the menu is on: it grows from the corner nearer the caret.
    var opening: Motion.Opening = .below
    let entrance = PanelEntrance()

    /// Where the pointer was when an arrow key last moved the highlight: the list scrolling under a pointer that
    /// stays put is not the pointer choosing a row, which sent the highlight back up under it.
    @ObservationIgnored var pointerAtKeyMove: NSPoint?

    func move(_ delta: Int) {
        guard !items.isEmpty else { return }
        pointerAtKeyMove = NSEvent.mouseLocation
        selected = (selected + delta + items.count) % items.count
    }

    /// The pointer came over the row at `index`: it takes the highlight, unless only the list moved under it.
    func hover(_ index: Int, pointer: NSPoint = NSEvent.mouseLocation) {
        if let still = pointerAtKeyMove, still == pointer { return }
        pointerAtKeyMove = nil
        selected = index
    }

    var current: SlashMenuItem? { items.indices.contains(selected) ? items[selected] : nil }

    /// The entries in runs of one section each, in the order they come.
    var sections: [(name: String, rows: [(index: Int, item: SlashMenuItem)])] {
        var result: [(name: String, rows: [(index: Int, item: SlashMenuItem)])] = []
        for (index, item) in items.enumerated() {
            if result.last?.name == item.section {
                result[result.count - 1].rows.append((index, item))
            } else {
                result.append((item.section, [(index, item)]))
            }
        }
        return result
    }
}

/// A small floating card under the caret, Craft's: white, rounded, shadowed, entries in sections. It never takes
/// keyboard focus: the text view keeps typing into the filter and forwards arrows, Return and Escape.
@MainActor
final class SlashMenuPanel: NSPanel {
    let model = SlashMenuModel()
    private let fade = PanelFade()
    static let rowHeight: CGFloat = 30
    static let headerHeight: CGFloat = 26
    static let width: CGFloat = 240

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .popUpMenu
        contentView = FirstMouseHostingView(rootView: SlashMenuList(model: model))
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// Shows `items` under `anchor` (a rect in screen coordinates), or above it when there is no room below.
    func show(_ items: [SlashMenuItem], grouped: Bool, below anchor: NSRect, in parent: NSWindow) {
        if items.map(\.id) != model.items.map(\.id) || grouped != model.grouped {
            // Filtering changes the rows; the highlight going back to the first one is not a movement.
            var quiet = Transaction()
            quiet.disablesAnimations = true
            withTransaction(quiet) {
                model.items = items
                model.grouped = grouped
                model.selected = 0
            }
        }
        let headers = grouped ? CGFloat(model.sections.count) : 0
        let content = CGFloat(items.count) * Self.rowHeight + headers * Self.headerHeight + 12
        let size = NSSize(width: Self.width, height: min(content, 360))
        var origin = NSPoint(x: anchor.minX - 12, y: anchor.minY - size.height - 6)
        var opening = Motion.Opening.below
        if let screen = parent.screen?.visibleFrame, origin.y < screen.minY {
            origin.y = anchor.maxY + 6
            opening = .above
        }
        // The window's light or dark look, which a vault may force, rather than the system's.
        appearance = parent.effectiveAppearance
        let entering = parent.childWindows?.contains(self) != true
        let frame = NSRect(origin: origin, size: size)
        if entering {
            model.loading = nil
            model.opening = opening
            setFrame(frame, display: true)
            parent.addChildWindow(self, ordered: .above)
            // Fades in and grows from the corner nearer the caret.
            model.entrance.begin()
            fade.show(self, duration: 0.12)
        } else {
            // Filtering resizes the menu without moving the edge that touches the caret.
            model.opening = opening
            PanelFade.move(self, to: frame, animated: true)
            orderFront(nil)
        }
    }

    /// Takes the menu away with a short fade. Always ends with the panel off the screen, whatever happens to the
    /// animation (`PanelFade`).
    func hide() {
        parent?.removeChildWindow(self)
        fade.hide(self, duration: Motion.Metrics.menuExit)
    }
}

final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

private struct SlashMenuList: View {
    let model: SlashMenuModel
    @Environment(\.colorScheme) private var colorScheme
    /// The highlight is one shape that slides from row to row.
    @Namespace private var highlight

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if model.grouped {
                        ForEach(model.sections, id: \.name) { section in
                            Text(section.name)
                                .font(.ui(size: 11, weight: .semibold))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 10)
                                .frame(height: SlashMenuPanel.headerHeight, alignment: .bottomLeading)
                                .padding(.bottom, 2)
                            ForEach(section.rows, id: \.item.id) { row in
                                SlashMenuRow(model: model, index: row.index, item: row.item, highlight: highlight)
                            }
                        }
                    } else {
                        ForEach(Array(model.items.enumerated()), id: \.element.id) { index, item in
                            SlashMenuRow(model: model, index: index, item: item, highlight: highlight)
                        }
                    }
                }
                .padding(6)
            }
            .scrollIndicators(.never)
            .onChange(of: model.selected) {
                if let item = model.current { withAnimation(Motion.hover) { proxy.scrollTo(item.id) } }
            }
        }
        .motion(.tap, value: model.selected)
        .background(
            RoundedRectangle(cornerRadius: Corners.r(12), style: .continuous)
                .fill(colorScheme == .dark ? Color(white: 0.17) : .white)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Corners.r(12), style: .continuous)
                .strokeBorder(Color.primary.opacity(colorScheme == .dark ? 0.15 : 0.08), lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: Corners.r(12), style: .continuous))
        .modifier(SlashMenuEntrance(entrance: model.entrance, opening: model.opening))
    }
}

/// The menu arriving: a little smaller and `menuRise` lower, growing from the corner nearer the caret. Nothing but
/// the window's fade when motion is reduced.
private struct SlashMenuEntrance: ViewModifier {
    let entrance: PanelEntrance
    let opening: Motion.Opening
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        let settled = entrance.arrived || reduceMotion
        content
            .scaleEffect(settled ? 1 : Motion.Metrics.menuScale, anchor: opening.menuAnchor)
            .offset(y: settled ? 0 : Motion.Metrics.menuRise)
    }
}

private struct SlashMenuRow: View {
    let model: SlashMenuModel
    let index: Int
    let item: SlashMenuItem
    let highlight: Namespace.ID

    var body: some View {
        let isSelected = index == model.selected
        HStack(spacing: 10) {
            let isLoading = model.loading == item.id
            Group {
                if isLoading {
                    ProgressView().controlSize(.mini)
                } else if let badge = item.badge {
                    Text(badge).font(.system(size: 11, weight: .semibold, design: .rounded))
                } else {
                    Image(symbol: item.symbol).font(.ui(size: 12))
                }
            }
            .foregroundStyle(.secondary)
            .frame(width: 20)
            Text(isLoading ? "Opening Finder…".uiLocalized : item.title.uiLocalized)
                .font(.ui(size: 13, weight: item.badge == "H1" || item.badge == "H2" ? .semibold : .regular))
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .frame(height: SlashMenuPanel.rowHeight)
        .background {
            if isSelected {
                RoundedRectangle(cornerRadius: Corners.r(8), style: .continuous)
                    .fill(Color.primary.opacity(0.07))
                    .matchedGeometryEffect(id: "highlight", in: highlight)
            }
        }
        .contentShape(Rectangle())
        .onHover { if $0 { model.hover(index) } }
        .onTapGesture { if model.loading == nil { model.onChoose?(item) } }
        .id(item.id)
    }
}
