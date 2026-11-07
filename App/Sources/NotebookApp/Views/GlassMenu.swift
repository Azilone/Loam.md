import AppKit
import PluginKitUI
import SwiftUI

/// A row of a glass menu: a symbol, a title, and at its end a checkmark, a shortcut or a small view of its own (the
/// sync's state).
struct GlassMenuEntry: Identifiable {
    let id: String
    let title: String
    let symbol: String
    var shortcut: String?
    var isChecked = false
    var detail: AnyView?
    let action: @MainActor () -> Void
}

/// A group of rows, under a small title if it has one; a hairline separates the groups.
struct GlassMenuSection: Identifiable {
    var title: String?
    let entries: [GlassMenuEntry]
    var id: String { entries.first?.id ?? title ?? "" }
}

/// The NSView behind a SwiftUI view, to place a window by it.
@MainActor
final class ViewAnchor {
    weak var view: NSView?
}

struct ViewAnchorView: NSViewRepresentable {
    let anchor: ViewAnchor
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        anchor.view = view
        return view
    }

    func updateNSView(_ view: NSView, context: Context) { anchor.view = view }
}

/// What the menu shows: its groups, the highlighted row, and whether it is out (its content grows in and out with it).
@MainActor @Observable
final class GlassMenuModel {
    var sections: [GlassMenuSection] = []
    /// The highlighted row among all the groups' rows, nil for none.
    var highlighted: Int?
    var isShown = false
    /// Grows out of the button's bottom edge (a menu above it) rather than its top.
    var opensUpward = false
    var width: CGFloat = 0
    var theme = ThemeTokens.standard
    @ObservationIgnored var choose: (GlassMenuEntry) -> Void = { _ in }

    var entries: [GlassMenuEntry] { sections.flatMap(\.entries) }

    func move(_ delta: Int) {
        let count = entries.count
        guard count > 0 else { return }
        let start = highlighted ?? (delta > 0 ? -1 : count)
        Motion.with(Motion.Spring.tap.animation) { highlighted = (start + delta + count) % count }
    }
}

/// A menu on Liquid Glass that grows out of the button that opened it (the sidebar's New and vault buttons). It is a
/// window over the page, so nothing on the page covers it, and like the `/` menu it never takes the keyboard: while it
/// is out, a watch on the app's events drives it (arrows, Return, Escape) and closes it on a click away.
@MainActor
final class GlassMenuPanel: NSPanel {
    let model = GlassMenuModel()
    private var monitor: Any?
    private var closedAt: Date?
    /// Room around the glass for its shadow and for the spring's overshoot.
    static let margin: CGFloat = 24
    /// Between the button and the menu.
    static let gap: CGFloat = 8

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .popUpMenu
        isReleasedWhenClosed = false
        let host = FirstClickHostingView(rootView: GlassMenuContent(model: model))
        host.sizingOptions = []
        contentView = host
        model.choose = { [weak self] entry in
            self?.dismiss()
            entry.action()
        }
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// Opens the menu by `anchor`'s view, below it or above it, as wide as it or `minWidth`; closes it if it is out,
    /// or if the click on the button is the one that just closed it.
    /// `colorScheme`: the button's, so the glass is dark under a dark sidebar in a light window (a dark-canvas theme).
    func toggle(_ sections: [GlassMenuSection], highlighted: Int? = nil, minWidth: CGFloat = 216, opensUpward: Bool = false,
                by anchor: ViewAnchor, theme: ThemeTokens, colorScheme: ColorScheme) {
        guard !model.isShown, !closedJustNow else { return dismiss() }
        guard !sections.isEmpty, let view = anchor.view, let parent = view.window else { return }
        let button = parent.convertToScreen(view.convert(view.bounds, to: nil))
        appearance = NSAppearance(named: colorScheme == .dark ? .darkAqua : .aqua)
        model.sections = sections
        model.highlighted = highlighted
        model.opensUpward = opensUpward
        model.width = max(minWidth, button.width)
        model.theme = theme
        let size = NSSize(width: model.width + Self.margin * 2, height: GlassMenuContent.height(of: sections) + Self.margin * 2)
        let y = opensUpward ? button.maxY + Self.gap - Self.margin : button.minY - Self.gap - size.height + Self.margin
        setFrame(NSRect(origin: NSPoint(x: button.minX - Self.margin, y: y), size: size), display: true)
        parent.addChildWindow(self, ordered: .above)
        orderFront(nil)
        // A frame later, so the small state has been drawn once and the spring has somewhere to grow from.
        DispatchQueue.main.async { [model] in
            Motion.with(Motion.Spring.pop.animation) { model.isShown = true }
        }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
            let consumed = MainActor.assumeIsolated { self?.consume(event) ?? false }
            return consumed ? nil : event
        }
    }

    func dismiss(animated: Bool = true) {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        guard model.isShown || isVisible else { return }
        closedAt = Date()
        let parentWindow = parent
        if animated, !Motion.reduceMotion {
            withAnimation(Motion.exit) { model.isShown = false }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) { [weak self] in
                guard let self, !self.model.isShown else { return }
                parentWindow?.removeChildWindow(self)
                self.orderOut(nil)
            }
        } else {
            model.isShown = false
            parentWindow?.removeChildWindow(self)
            orderOut(nil)
        }
    }

    /// The click on the button that closed the menu (a click away) does not open it again.
    private var closedJustNow: Bool { closedAt.map { Date().timeIntervalSince($0) < 0.3 } ?? false }

    /// While the menu is out: the keys that drive it (true: the menu used the key), and a click away, which still goes
    /// on to what it hit.
    private func consume(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown else {
            if event.window !== self { dismiss() }
            return false
        }
        switch event.keyCode {
        case 53: dismiss()  // Escape
        case 125: model.move(1)
        case 126: model.move(-1)
        case 36, 76:
            let entries = model.entries
            if let index = model.highlighted, entries.indices.contains(index) { model.choose(entries[index]) }
        default:
            // Typing or a shortcut goes where it was going; the menu steps aside.
            dismiss()
            return false
        }
        return true
    }
}

/// A row answers the first click, though the panel is never the key window.
private final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// The menu itself: its groups on Liquid Glass, growing out of the button, the highlight sliding from row to row, the
/// rows arriving one after the other.
private struct GlassMenuContent: View {
    let model: GlassMenuModel
    @Namespace private var highlight
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let rowHeight: CGFloat = 32
    static let titleHeight: CGFloat = 26
    static let separatorHeight: CGFloat = 11
    static let padding: CGFloat = 6

    static func height(of sections: [GlassMenuSection]) -> CGFloat {
        let rows = sections.reduce(0) { $0 + $1.entries.count }
        let titles = sections.filter { $0.title != nil }.count
        return CGFloat(rows) * rowHeight + CGFloat(titles) * titleHeight
            + CGFloat(max(sections.count - 1, 0)) * separatorHeight + padding * 2
    }

    var body: some View {
        let shown = model.isShown
        let theme = model.theme
        let anchor: UnitPoint = model.opensUpward ? .bottomLeading : .topLeading
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(model.sections.enumerated()), id: \.element.id) { number, section in
                if number > 0 {
                    Rectangle()
                        .fill(theme.text.opacity(0.08))
                        .frame(height: 1)
                        .padding(.horizontal, 10)
                        .frame(height: Self.separatorHeight)
                }
                if let title = section.title {
                    Text(title.uiLocalized)
                        .font(.ui(size: 11.5, weight: .semibold))
                        .foregroundStyle(theme.secondaryText.opacity(SidebarStyle.sectionTitleOpacity))
                        .padding(.horizontal, 10)
                        .frame(height: Self.titleHeight, alignment: .bottomLeading)
                }
                let first = model.sections.prefix(number).reduce(0) { $0 + $1.entries.count }
                ForEach(Array(section.entries.enumerated()), id: \.element.id) { offset, entry in
                    row(entry, index: first + offset)
                        .opacity(shown ? 1 : 0)
                        .offset(y: shown || reduceMotion ? 0 : (model.opensUpward ? 6 : -6))
                        .animation(
                            shown ? Motion.resolved(Motion.Spring.standard.animation).delay(Motion.stagger(index: first + offset + 1))
                                : Motion.exit,
                            value: shown
                        )
                }
            }
        }
        .padding(Self.padding)
        .frame(width: model.width)
        .glassEffect(.regular, in: .rect(cornerRadius: Corners.r(18), style: .continuous))
        .scaleEffect(shown || reduceMotion ? 1 : 0.86, anchor: anchor)
        .opacity(shown ? 1 : 0)
        .padding(GlassMenuPanel.margin)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: model.opensUpward ? .bottomLeading : .topLeading)
        .environment(\.themeTokens, theme)
        .accessibilityElement(children: .contain)
    }

    private func row(_ entry: GlassMenuEntry, index: Int) -> some View {
        let theme = model.theme
        let isHighlighted = index == model.highlighted
        return Button { model.choose(entry) } label: {
            HStack(spacing: 10) {
                icon(entry.symbol, color: isHighlighted ? theme.text : theme.secondaryText)
                    .frame(width: 20)
                Text(entry.title.uiLocalized)
                    .font(.ui(size: 13, weight: .medium))
                    .foregroundStyle(theme.text)
                    .lineLimit(1)
                Spacer(minLength: 8)
                if let detail = entry.detail {
                    detail
                }
                if let shortcut = entry.shortcut {
                    Text(shortcut)
                        .font(.ui(size: 11))
                        .foregroundStyle(theme.secondaryText)
                }
                if entry.isChecked {
                    Image(symbol: "checkmark")
                        .font(.ui(size: 11, weight: .semibold))
                        .foregroundStyle(theme.text)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: Self.rowHeight)
            .background {
                if isHighlighted {
                    RoundedRectangle(cornerRadius: Corners.r(12), style: .continuous)
                        .fill(theme.text.opacity(0.08))
                        .matchedGeometryEffect(id: "highlight", in: highlight)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: Corners.r(12), style: .continuous))
        }
        .buttonStyle(.press)
        .onHover { hovering in
            guard hovering, model.highlighted != index else { return }
            Motion.with(Motion.Spring.tap.animation) { model.highlighted = index }
        }
        .accessibilityLabel(entry.title.uiLocalized)
        .accessibilityAddTraits(entry.isChecked ? .isSelected : [])
    }

    /// An SF Symbol as is; one of Loam's own (the vault) drawn as the sidebar draws it. The sidebar's drawn icons fill
    /// their planes with the sidebar's colour, which the glass is not, so only Loam's, which have no SF form, take them.
    @ViewBuilder private func icon(_ symbol: String, color: Color) -> some View {
        if LoamSymbol.isLoam(symbol) {
            SidebarIcon(symbol, color: color, ground: model.theme.sidebarGround(selected: false), size: 17)
        } else {
            Image(symbol: symbol).font(.ui(size: 14, weight: .medium)).foregroundStyle(color)
        }
    }
}
