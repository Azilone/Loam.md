import PluginKitUI
import SwiftUI

/// The pure part of the ticks at a long note's right edge: when they show, which heading is current, how much
/// each tick grows under the pointer. Tested without a view.
enum OutlineTickLayout {
    /// Fewer headings than this, or a note shorter than `minScreens` screens, shows no ticks: there is nothing to
    /// find again.
    static let minHeadings = 2
    static let minScreens: CGFloat = 2
    /// Tick sizes, in points: a level 1 heading's width, each level below it narrower, never under `minWidth`.
    static let topWidth: CGFloat = 16
    static let levelStep: CGFloat = 4
    static let minWidth: CGFloat = 6
    static let height: CGFloat = 2
    /// The gap between ticks, shrunk down to `minGap` when they would not fit in `maxColumnShare` of the page.
    static let gap: CGFloat = 8
    static let minGap: CGFloat = 3
    static let maxColumnShare: CGFloat = 0.6
    /// The magnet: a tick within `magnetRadius` points of the pointer grows, up to `magnetGrowth` times its width
    /// right under it, falling off smoothly.
    static let magnetRadius: CGFloat = 36
    static let magnetGrowth: CGFloat = 0.9
    /// A heading this close below the toolbar's edge already counts as the one being read.
    static let readingMargin: CGFloat = 32

    static func isShown(headings: Int, scroll: PageScroll) -> Bool {
        headings >= minHeadings && scroll.visibleHeight > 0 && scroll.contentHeight >= scroll.visibleHeight * minScreens
    }

    /// The width of a tick at `level`, given the note's highest level `top`.
    static func width(level: Int, top: Int) -> CGFloat {
        max(minWidth, topWidth - CGFloat(max(0, level - top)) * levelStep)
    }

    /// The gap that fits `count` ticks in `available` points.
    static func gap(count: Int, available: CGFloat) -> CGFloat {
        guard count > 1 else { return gap }
        let fitting = (available - CGFloat(count) * height) / CGFloat(count - 1)
        return min(gap, max(minGap, fitting))
    }

    /// The heading being read: the last one whose top has passed under the toolbar (with `readingMargin`); the
    /// last one when the page is scrolled to its end; nil above the first.
    static func current(ys: [CGFloat?], scroll: PageScroll, topInset: CGFloat) -> Int? {
        guard !ys.isEmpty else { return nil }
        if scroll.contentHeight > 0, scroll.offset + scroll.visibleHeight >= scroll.contentHeight - 1 { return ys.count - 1 }
        let line = scroll.offset + topInset + readingMargin
        return ys.lastIndex { ($0 ?? .infinity) <= line }
    }

    /// How much a tick `distance` points from the pointer is widened: 1 far away, 1 + `magnetGrowth` under it.
    static func magnet(distance: CGFloat) -> CGFloat {
        let t = max(0, 1 - abs(distance) / magnetRadius)
        return 1 + magnetGrowth * t * t * (3 - 2 * t)
    }

    /// The middle of tick `index`, from the top of the column: each tick takes `height + gap` points.
    static func center(of index: Int, gap: CGFloat) -> CGFloat {
        (CGFloat(index) + 0.5) * (height + gap)
    }

    /// The tick whose share of the column holds `y`.
    static func nearest(y: CGFloat, count: Int, gap: CGFloat) -> Int? {
        guard count > 0 else { return nil }
        return min(max(Int((y / (height + gap)).rounded(.down)), 0), count - 1)
    }
}

/// A long note's headings as ticks at the right edge of the page, the one being read darker. The pointer on them
/// draws the ticks near it out, as a magnet would, and opens a card listing the headings; a click on a tick or a
/// row glides the page to that heading.
struct OutlineTicks: View {
    let page: PageContext
    @State private var headings: [OutlineHeading] = []
    /// Where each heading starts in the text, in the order of `headings`; measured when the text or its height
    /// changes, not while scrolling.
    @State private var ys: [CGFloat?] = []
    /// The pointer's height over the column of ticks, nil when it is elsewhere.
    @State private var pointerY: CGFloat?
    /// The heading under the pointer, in the ticks or the card.
    @State private var hovered: Int?
    @State private var expanded = false
    @State private var closing: Task<Void, Never>?
    @Environment(\.themeTokens) private var theme
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.sidebarSliding) private var sidebarSliding

    private static let cardWidth: CGFloat = 248
    private static let rowHeight: CGFloat = 28

    var body: some View {
        let scroll = page.scroll
        let shown = OutlineTickLayout.isShown(headings: headings.count, scroll: scroll)
        // Measured for these headings only: right after the text changes, `ys` is still the old ones'.
        let current = ys.count == headings.count ? OutlineTickLayout.current(ys: ys, scroll: scroll, topInset: page.topInset) : nil
        let available = max(0, (scroll.visibleHeight - page.topInset) * OutlineTickLayout.maxColumnShare)
        let gap = OutlineTickLayout.gap(count: headings.count, available: available)

        HStack(alignment: .center, spacing: 4) {
            if expanded && shown {
                card(current: current, maxHeight: available)
                    .transition(Motion.overlay(from: .trailing))
            }
            // Its own view, compared before its body runs: typing in a long note changes the page's scroll (TextKit's
            // estimate of the height) at each key, and the hundreds of ticks were made again each time.
            OutlineTickColumn(
                headings: headings, current: current, gap: gap, pointerY: pointerY, hovered: hovered,
                onPointer: { y, nearest in
                    pointerY = y
                    if y != nil { hovered = nearest }
                },
                onJump: jump(to:)
            )
            .equatable()
        }
        .onHover { inside in inside ? open() : close() }
        .padding(.trailing, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
        .padding(.top, page.topInset)
        .opacity(shown ? 1 : 0)
        .allowsHitTesting(shown)
        .motion(.overlay, value: expanded)
        .animation(Motion.ambient, value: shown)
        .task(id: page.text) {
            let text = page.text
            let new = await Task.detached(priority: .userInitiated) { OutlineHeadings.extract(from: text) }.value
            if !Task.isCancelled, new != headings { headings = new }
        }
        // The headings move when the text or its layout does (a picture loading, the window resizing). Not while a
        // sidebar slides: measuring lays the note out, which took frames from the slide; it measures once it ends.
        .task(id: MeasureKey(headings: headings, height: scroll.contentHeight.rounded(), sliding: sidebarSliding)) {
            guard !sidebarSliding else { return }
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            let measured = page.ys(ofLines: headings.map(\.line))
            if measured != ys { ys = measured }
        }
    }

    // MARK: Card

    private func card(current: Int?, maxHeight: CGFloat) -> some View {
        let top = headings.map(\.level).min() ?? 1
        return ScrollViewReader { proxy in
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(headings.enumerated()), id: \.element.id) { index, heading in
                        row(heading, index: index, depth: heading.level - top, isCurrent: index == current)
                            .id(index)
                    }
                }
                .padding(6)
            }
            .scrollIndicators(.never)
            .frame(width: Self.cardWidth)
            .frame(maxHeight: min(maxHeight, CGFloat(headings.count) * Self.rowHeight + 12))
            .fixedSize(horizontal: false, vertical: true)
            .onAppear { if let current { proxy.scrollTo(current, anchor: .center) } }
            .onChange(of: hovered) {
                if let hovered, pointerY != nil { withAnimation(Motion.hover) { proxy.scrollTo(hovered) } }
            }
        }
        .background(
            RoundedRectangle(cornerRadius: Corners.r(12), style: .continuous)
                .fill(colorScheme == .dark ? Color(white: 0.17) : .white)
                .shadow(color: .black.opacity(colorScheme == .dark ? 0.4 : 0.12), radius: 16, y: 6)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Corners.r(12), style: .continuous)
                .strokeBorder(Color.primary.opacity(colorScheme == .dark ? 0.15 : 0.08), lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: Corners.r(12), style: .continuous).inset(by: -24))
    }

    private func row(_ heading: OutlineHeading, index: Int, depth: Int, isCurrent: Bool) -> some View {
        Button { jump(to: index) } label: { rowLabel(heading, index: index, depth: depth, isCurrent: isCurrent) }
            .buttonStyle(.plain)
    }

    private func rowLabel(_ heading: OutlineHeading, index: Int, depth: Int, isCurrent: Bool) -> some View {
        Text(heading.text)
            .font(.ui(size: 13, weight: isCurrent ? .semibold : (depth == 0 ? .medium : .regular)))
            .lineLimit(1)
            .truncationMode(.tail)
            .foregroundStyle(theme.text.opacity(isCurrent ? 1 : (depth == 0 ? 0.85 : 0.65)))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 8 + CGFloat(min(depth, 3)) * 12)
            .padding(.trailing, 8)
            .frame(height: Self.rowHeight)
            .background {
                RoundedRectangle(cornerRadius: Corners.r(8), style: .continuous)
                    .fill(Color.primary.opacity(index == hovered ? 0.07 : 0))
            }
            .animation(Motion.hover, value: hovered)
            .contentShape(Rectangle())
            .onHover { inside in if inside { hovered = index } }
            .help(heading.text)
    }

    // MARK: Actions

    private func open() {
        closing?.cancel()
        closing = nil
        expanded = true
    }

    /// Waits a moment before closing, so crossing the gap between the ticks and the card does not close it.
    private func close() {
        closing?.cancel()
        closing = Task {
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled else { return }
            withAnimation(Motion.exit) { expanded = false }
            hovered = nil
        }
    }

    private func jump(to index: Int) {
        guard headings.indices.contains(index) else { return }
        page.scroll(toLine: headings[index].line)
    }
}

/// What makes the ticks measure where the headings are again.
private struct MeasureKey: Equatable {
    let headings: [OutlineHeading]
    let height: CGFloat
    let sliding: Bool
}

/// The column of ticks: one capsule per heading, the current one darker, the ones near the pointer drawn out.
private struct OutlineTickColumn: View, @MainActor Equatable {
    let headings: [OutlineHeading]
    let current: Int?
    let gap: CGFloat
    let pointerY: CGFloat?
    let hovered: Int?
    /// The pointer moved over the column (nil: it left), and the tick nearest to it.
    let onPointer: (CGFloat?, Int?) -> Void
    let onJump: (Int) -> Void
    @Environment(\.themeTokens) private var theme
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static func == (a: Self, b: Self) -> Bool {
        a.headings == b.headings && a.current == b.current && a.gap == b.gap && a.pointerY == b.pointerY && a.hovered == b.hovered
    }

    var body: some View {
        let top = headings.map(\.level).min() ?? 1
        let pitch = OutlineTickLayout.height + gap
        VStack(alignment: .trailing, spacing: 0) {
            ForEach(Array(headings.enumerated()), id: \.element.id) { index, heading in
                let growth = pointerY.map {
                    reduceMotion ? 1 : OutlineTickLayout.magnet(distance: $0 - OutlineTickLayout.center(of: index, gap: gap))
                } ?? 1
                // A plain shape, not a button: the body runs again on every scroll and resize frame, and a long
                // note's hundred buttons (behaviour, style, focus, commands each) were most of the window's update.
                // The column takes the clicks.
                ThemeCapsule()
                    .fill(theme.text.opacity(tickOpacity(index: index)))
                    .frame(width: OutlineTickLayout.width(level: heading.level, top: top) * growth, height: OutlineTickLayout.height)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .frame(height: pitch)
                    .accessibilityElement()
                    .accessibilityLabel(heading.text)
                    .accessibilityAddTraits(.isButton)
                    .accessibilityAction { onJump(index) }
            }
        }
        .animation(Motion.follow, value: pointerY)
        .animation(Motion.hover, value: hovered)
        .animation(Motion.hover, value: current)
        // A column wider than the ticks, so they are easy to reach.
        .frame(width: OutlineTickLayout.topWidth * (1 + OutlineTickLayout.magnetGrowth) + 8, alignment: .trailing)
        .contentShape(Rectangle())
        .onTapGesture { location in
            if let index = OutlineTickLayout.nearest(y: location.y, count: headings.count, gap: gap) { onJump(index) }
        }
        .onContinuousHover { phase in
            switch phase {
            case let .active(location):
                let nearest = OutlineTickLayout.nearest(y: location.y, count: headings.count, gap: gap)
                // A tick under the finger for each heading passed, as on a scrubber.
                if nearest != hovered { Haptics.alignment() }
                onPointer(location.y, nearest)
            case .ended:
                onPointer(nil, nil)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Outline")
    }

    private func tickOpacity(index: Int) -> Double {
        if index == hovered && pointerY != nil { return 0.7 }
        if index == current { return 0.75 }
        return colorScheme == .dark ? 0.28 : 0.2
    }
}
