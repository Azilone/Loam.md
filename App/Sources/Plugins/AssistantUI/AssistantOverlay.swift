import AssistantPlugin
import PluginKitUI
import SwiftUI
import ThinkingOrbsKit

/// The bubble at the window's bottom right that grows into the Assistant panel, as Craft's: one container whose
/// size springs from 112×40 to 464×704 while its content cross-fades. Menus float above it, unclipped.
struct AssistantOverlay: View {
    @Bindable var model: AssistantModel
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let colors = CraftColors(scheme)
        GeometryReader { proxy in
            ZStack(alignment: .bottomTrailing) {
                if model.menu != nil {
                    // A click anywhere else closes the menu, as in Craft.
                    Color.black.opacity(0.001)
                        .onTapGesture { model.menu = nil }
                }
                container(colors, available: proxy.size)
                    .padding(CraftStyle.inset)
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .bottomTrailing)
        }
        .overlayPreferenceValue(MenuAnchors.self) { anchors in
            GeometryReader { proxy in
                if let menu = model.menu, let anchor = anchors[menu] {
                    AssistantMenus(model: model, menu: menu, anchor: proxy[anchor], colors: colors)
                }
            }
        }
        .environment(\.craftColors, colors)
    }

    private func panelSize(_ available: CGSize) -> CGSize {
        let height = min(CraftStyle.panelSize.height,
                         max(320, available.height - CraftStyle.inset * 2 - CraftStyle.topClearance))
        let width = min(CraftStyle.panelSize.width, max(300, available.width - CraftStyle.inset * 2))
        return CGSize(width: width, height: height)
    }

    private func container(_ colors: CraftColors, available: CGSize) -> some View {
        let size = model.isOpen ? panelSize(available) : CraftStyle.bubbleSize
        return ZStack(alignment: .bottomTrailing) {
            if model.isOpen {
                AssistantPanel(model: model)
                    .frame(width: panelSize(available).width, height: panelSize(available).height)
                    .transition(contentTransition)
            } else {
                BubbleLabel(state: model.isBusy ? MessageView.orbState(model.chat.messages.last) : nil) { model.toggle() }
                    .frame(width: CraftStyle.bubbleSize.width, height: CraftStyle.bubbleSize.height)
                    .transition(contentTransition)
            }
        }
        .frame(width: size.width, height: size.height, alignment: .bottomTrailing)
        .background(model.isOpen ? AnyShapeStyle(colors.panel) : AnyShapeStyle(colors.bubble))
        .clipShape(RoundedRectangle(cornerRadius: Corners.r(CraftStyle.cornerRadius), style: .continuous))
        .craftFloatingShadow(colors, radius: CraftStyle.cornerRadius)
        .animation(reduceMotion ? Motion.fade : CraftStyle.morph, value: model.isOpen)
    }

    private var contentTransition: AnyTransition {
        .asymmetric(
            insertion: .opacity.animation(reduceMotion ? Motion.fade : CraftStyle.contentIn),
            removal: .opacity.animation(CraftStyle.contentOut)
        )
    }
}

/// The closed state: Libraries.dev's orb, at rest or doing what the agent does, and "Assistant".
private struct BubbleLabel: View {
    let state: OrbState?
    let action: () -> Void
    @Environment(\.craftColors) private var colors
    @Environment(\.themeTokens) private var theme
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                // At rest the orb holds still unless hovered: a clock running at the display's rate kept the
                // window's view graph updating on every frame, under every resize, scroll and slide.
                ThinkingOrb(state: state ?? .breathing, size: .px20, paused: state == nil && !hovered, displaySize: 22)
                    // The print look draws the orb in the accent.
                    .environment(\.orbTint, theme.accent)
                    .frame(width: 24, height: 24)
                Text("Assistant")
                    .font(CraftStyle.font(13))
                    .tracking(CraftStyle.tracking)
                    .foregroundStyle(colors.ink)
            }
            .padding(.leading, 7)
            .padding(.trailing, 13)
            .frame(height: 32)
            .background(RoundedRectangle(cornerRadius: Corners.r(14), style: .continuous)
                .fill(hovered ? colors.hoverFill : .clear))
            .contentShape(RoundedRectangle(cornerRadius: Corners.r(14), style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering in withAnimation(CraftStyle.hover) { hovered = hovering } }
        .accessibilityLabel("Assistant")
        .accessibilityIdentifier("assistant.bubble")
    }
}

// MARK: Menu anchors

/// Where each menu's button is, so its menu opens next to it above the panel's clip.
struct MenuAnchors: PreferenceKey {
    static let defaultValue: [AssistantModel.Menu: Anchor<CGRect>] = [:]

    static func reduce(value: inout [AssistantModel.Menu: Anchor<CGRect>],
                       nextValue: () -> [AssistantModel.Menu: Anchor<CGRect>]) {
        value.merge(nextValue()) { $1 }
    }
}

extension View {
    func menuAnchor(_ menu: AssistantModel.Menu) -> some View {
        anchorPreference(key: MenuAnchors.self, value: .bounds) { [menu: $0] }
    }
}

private struct CraftColorsKey: EnvironmentKey {
    static let defaultValue = CraftColors(.light)
}

extension EnvironmentValues {
    var craftColors: CraftColors {
        get { self[CraftColorsKey.self] }
        set { self[CraftColorsKey.self] = newValue }
    }
}

// MARK: Buttons

/// Craft's quiet icon button: no fill until hovered.
struct CraftIconButton: View {
    let symbol: String
    var size: CGFloat = 32
    var corner: CGFloat = 10
    var symbolSize: CGFloat = 15
    var label: String
    let action: () -> Void
    @Environment(\.craftColors) private var colors
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Image(symbol: symbol)
                .font(.ui(size: symbolSize, weight: .regular))
                .foregroundStyle(colors.ink)
                .frame(width: size, height: size)
                .background(RoundedRectangle(cornerRadius: Corners.r(corner), style: .continuous)
                    .fill(hovered ? colors.hoverFill : .clear))
                .contentShape(RoundedRectangle(cornerRadius: Corners.r(corner), style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering in withAnimation(CraftStyle.hover) { hovered = hovering } }
        .help(label)
        .accessibilityLabel(label)
    }
}

/// A composer control: 32 points high with Craft's inset ring, round or a rounded pill.
struct CraftPillButton<Label: View>: View {
    var round = false
    let action: () -> Void
    @ViewBuilder let label: () -> Label
    @Environment(\.craftColors) private var colors
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            label()
                .font(CraftStyle.font(13))
                .tracking(CraftStyle.tracking)
                .foregroundStyle(colors.ink)
                .padding(.horizontal, round ? 0 : 8)
                .frame(minWidth: 32, minHeight: 32, maxHeight: 32)
                .background(shape.fill(hovered ? colors.hoverFill : .clear))
                .craftInsetRing(shape, colors.controlRing)
                .contentShape(shape)
        }
        .buttonStyle(.plain)
        .onHover { hovering in withAnimation(CraftStyle.hover) { hovered = hovering } }
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: Corners.r(round ? 16 : 10), style: .continuous)
    }
}
