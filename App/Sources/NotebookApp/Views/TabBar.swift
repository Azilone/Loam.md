import PluginKitUI
import SwiftUI
import WorkspaceModel

/// The tab bars' metrics and motion; the bar itself is AppKit (`TabBarView`), its tabs SwiftUI (`TabStrip`).
enum TabBar {
    static let height: CGFloat = 40

    /// A tab opening grows from its left edge while the others slide over; one closing shrinks back toward that edge
    /// and fades faster than it came (`Motion.exit`), while the others close the gap. Under Reduce Motion only the
    /// fade is left (`motionTransition`).
    static var tabTransition: AnyTransition {
        let grown = AnyTransition.opacity.combined(with: .scale(scale: 0.6, anchor: .leading))
        return .asymmetric(insertion: grown, removal: grown.animation(Motion.exit))
    }
}

/// A pane's tabs, each as wide as its title (up to a limit), as in Craft: click to select, the cross to close, drag to
/// move (onto another tab bar, or a pane's edge to split). They sit in the AppKit tab bar (`TabBarView`), which
/// scrolls them when the pane is too narrow, drags the window from its empty area and takes the drops.
struct TabStrip: View {
    let pane: Pane
    let isFocused: Bool
    let workspace: WorkspaceController
    let views: ViewRegistryStore
    /// Each tab's frame in the strip, for the bar's drops. Outside the view's state: only a drop reads them.
    let frames: Measured<[TabID: CGRect]>
    /// Called when the tabs or the selection change: the bar sizes the strip and scrolls the selected tab into view.
    var onChange: (() -> Void)?
    @Environment(\.pageActions) private var actions
    /// The selected tab's white capsule slides from tab to tab.
    @Namespace private var selection

    private static let space = "tabstrip"

    private func title(of tab: WorkspaceModel.Tab) -> String {
        workspace.isNewTab(tab.id) ? "New Tab" : views.title(for: tab.resource)
    }

    var body: some View {
        let titles = pane.tabs.map(title(of:))
        HStack(spacing: 4) {
            ForEach(pane.tabs, id: \.id) { tab in
                TabButton(
                    title: title(of: tab),
                    isSelected: tab.id == pane.selected,
                    isFocusedPane: isFocused,
                    selection: selection,
                    select: { workspace.select(tab.id) },
                    close: { workspace.close(tab.id) }
                )
                .rightClickMenu { [actions, workspace] in
                    actions.menuItems(for: workspace.isNewTab(tab.id) ? nil : tab.resource)
                        + [.separator, RightClickItem(title: "Close Tab") { workspace.close(tab.id) }]
                }
                .id(tab.id.raw)
                .motionTransition(TabBar.tabTransition)
                .onDrag {
                    DragSession.shared.begin(.tab(tab.id.raw), snapshot: workspace.snapshot(of: pane.id),
                                             title: views.title(for: tab.resource))
                    return DragPayload.tab(tab.id.raw).itemProvider()
                } preview: {
                    HiddenDragPreview()
                }
                .onGeometryChange(for: CGRect.self) { proxy in
                    proxy.frame(in: .named(Self.space))
                } action: { frame in
                    frames.value[tab.id] = frame
                }
            }
            // The room after the last tab, which drags the window and takes drops at the end, as the bar does.
            Color.clear.frame(width: 24)
        }
        .fixedSize(horizontal: true, vertical: false)
        // A tab opening or closing, and the selected capsule sliding to the new tab.
        .motion(.standard, value: pane.tabs.map(\.id))
        .motion(.standard, value: pane.selected)
        // Inside the strip, so the selected capsule's shadow isn't clipped.
        .padding(.vertical, 5)
        // From the bar's leading edge, whatever room the strip is given.
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: TabBar.height)
        // The gaps between the tabs drag the window too.
        .background(Color.clear.contentShape(Rectangle()).gesture(WindowDragGesture()))
        .coordinateSpace(.named(Self.space))
        .background(PaneClickDetector { workspace.focus(pane.id) })
        .onChange(of: pane.tabs.map(\.id)) { _, ids in
            frames.value = frames.value.filter { ids.contains($0.key) }
            onChange?()
        }
        .onChange(of: titles) { onChange?() }
        .onChange(of: pane.selected) { onChange?() }
        .onAppear { onChange?() }
    }
}

/// The Home button that starts the first pane's tab bar: it opens the home page (the first navigation link).
struct HomeButton: View {
    let pane: PaneID
    let workspace: WorkspaceController
    @Environment(\.pageActions) private var actions

    var body: some View {
        WindowButton(title: "Home", symbol: "house") {
            if let home = actions.home { workspace.open(home, placement: .replace) }
        }
        .background(PaneClickDetector { workspace.focus(pane) })
    }
}

/// One tab: plain text, or a white raised capsule when selected (Craft's), with the accent dot in the focused pane.
struct TabButton: View {
    let title: String
    let isSelected: Bool
    let isFocusedPane: Bool
    let selection: Namespace.ID
    let select: () -> Void
    let close: () -> Void
    @State private var isHovered = false
    @Environment(\.themeTokens) private var theme
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 6) {
            if isSelected && isFocusedPane {
                TabDot(color: theme.accent)
            }
            Text(title.isEmpty ? "Untitled" : title)
                .lineLimit(1)
                .frame(maxWidth: 180)
                .fontWeight(isSelected ? .medium : .regular)
                .foregroundStyle(isSelected ? theme.text : theme.secondaryText)
            Button(action: close) {
                Image(symbol: "xmark")
                    .font(.ui(size: 9, weight: .semibold))
                    .frame(width: 16, height: 16)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(theme.secondaryText)
            .opacity(isSelected || isHovered ? 1 : 0)
            .help("Close Tab")
        }
        .font(.ui(.label))
        .padding(.leading, 12)
        .padding(.trailing, 6)
        .frame(minWidth: 80, maxHeight: .infinity)
        .background {
            if isSelected {
                TabGlass(isDark: colorScheme == .dark)
                    .matchedGeometryEffect(id: "selected-tab", in: selection)
            } else if isHovered {
                ThemeCapsule().fill(Color.primary.opacity(0.05))
            }
        }
        .contentShape(ThemeCapsule())
        .onTapGesture(perform: select)
        .onHover { isHovered = $0 }
        .animation(Motion.hover, value: isHovered)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityLabel(title.isEmpty ? "Untitled" : title)
        .accessibilityAction { select() }
    }
}

/// The selected tab as a bead of glass: frosted white over the sidebar, a rim lit from the top and a shade at its
/// foot, lifted by a soft shadow. Drawn rather than `glassEffect`, which over the sidebar's flat paper shows as
/// nothing at all.
private struct TabGlass: View {
    let isDark: Bool

    var body: some View {
        let shape = ThemeCapsule()
        shape
            .fill(.ultraThinMaterial)
            .overlay(shape.fill(LinearGradient(
                colors: isDark ? [.white.opacity(0.16), .white.opacity(0.08)] : [.white.opacity(0.95), .white.opacity(0.72)],
                startPoint: .top, endPoint: .bottom
            )))
            .overlay(shape.strokeBorder(LinearGradient(
                colors: [.white.opacity(isDark ? 0.35 : 1), .white.opacity(0), .black.opacity(isDark ? 0.3 : 0.07)],
                startPoint: .top, endPoint: .bottom
            ), lineWidth: 1))
            .shadow(color: .black.opacity(isDark ? 0.3 : 0.07), radius: 0.5, y: 0.5)
            .shadow(color: .black.opacity(isDark ? 0.25 : 0.06), radius: 6, y: 3)
    }
}

/// The focused tab's dot, as a notification badge: a lit bead of the accent in a soft halo of it.
private struct TabDot: View {
    let color: Color

    var body: some View {
        Circle()
            .fill(RadialGradient(colors: [color.mix(with: .white, by: 0.35), color], center: UnitPoint(x: 0.35, y: 0.3),
                                 startRadius: 0, endRadius: 4))
            .overlay(Circle().strokeBorder(.white.opacity(0.4), lineWidth: 0.5))
            .frame(width: 7, height: 7)
            .shadow(color: color.opacity(0.45), radius: 2)
            .background(Circle().fill(color.opacity(0.12)).frame(width: 12, height: 12))
            .accessibilityHidden(true)
    }
}

extension EnvironmentValues {
    /// How far the last pane's tab bar keeps clear of the right sidebar button.
    @Entry var tabBarTrailingInset: CGFloat = 0
}
