import PluginKitUI
import SwiftUI

/// The quick pick popup: a glass sheet near the top of the window, over a slightly dimmed window, with a search
/// field, the rows and a line of key hints. Up and Down move the selection, Return chooses, Escape or a click
/// outside closes it.
struct QuickPickView: View {
    let controller: QuickPickController
    @FocusState private var fieldFocused: Bool
    @Environment(\.themeTokens) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let radius: CGFloat = 26

    var body: some View {
        // The two parts have their own transitions: the panel grows from the top centre and leaves first, the scrim
        // fades behind it. Neither blocks: the field has the keys from the first frame, a click on the scrim closes.
        ZStack(alignment: .top) {
            Color(hex: 0x14193A).opacity(0.12)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { controller.dismiss() }
                .transition(Self.scrimTransition(reduceMotion: reduceMotion))
            panel
                .padding(.top, 72)
                .padding(.horizontal, 24)
                .transition(Self.panelTransition(reduceMotion: reduceMotion))
        }
        .onAppear { fieldFocused = true }
    }

    /// The dimming: fades in over `scrimIn`, and out just after the panel has started to go.
    static func scrimTransition(reduceMotion: Bool) -> AnyTransition {
        if reduceMotion { return .opacity.animation(Motion.fade) }
        return .asymmetric(
            insertion: .opacity.animation(.easeOut(duration: Motion.Metrics.scrimIn)),
            removal: .opacity.animation(Motion.exit.delay(0.04))
        )
    }

    /// The panel: grows from its top centre (`overlayScale` → 1, dropping in `paletteDrop`); leaves shrinking a
    /// little (`paletteExitScale`) and fading, faster than it came.
    static func panelTransition(reduceMotion: Bool) -> AnyTransition {
        if reduceMotion { return .opacity.animation(Motion.fade) }
        return .asymmetric(
            insertion: .opacity
                .combined(with: .scale(scale: Motion.Metrics.overlayScale, anchor: .top))
                .combined(with: .offset(y: -Motion.Metrics.paletteDrop))
                .animation(Motion.Spring.overlay.animation),
            removal: .opacity
                .combined(with: .scale(scale: Motion.Metrics.paletteExitScale, anchor: .top))
                .animation(Motion.exit)
        )
    }

    private var panel: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(symbol: controller.activeTab?.symbol ?? "magnifyingglass")
                    .font(.ui(size: 17, weight: .medium))
                    .foregroundStyle(theme.secondaryText)
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 22)
                field
                if controller.activeTab != nil {
                    QuickPickTabs(controller: controller)
                } else {
                    KeyCaps(text: "esc")
                }
            }
            .padding(.leading, 18)
            .padding(.trailing, 10)
            .frame(height: 60)

            if !controller.results.isEmpty {
                Divider().opacity(0.6)
                // Switching tab (⌘O, ⌘P, Tab) cross-fades the rows in both directions, the panel's height following.
                ZStack(alignment: .top) {
                    QuickPickList(controller: controller, results: controller.results)
                        .id(controller.rowsGeneration)
                        .transition(.opacity.animation(Motion.crossfade))
                }
                Divider().opacity(0.6)
                footer
            }
        }
        .frame(maxWidth: 680)
        // The panel's height follows the number of results; the rows themselves never animate while typing.
        .motion(.standard, value: controller.results.isEmpty ? 0 : min(controller.results.count, 10))
        // Frosted under the glass, so the rows stay readable over a page full of text. The shadow is cast by that
        // shape, not by the panel: a shadow on the panel rendered its rows off screen on the CPU on every frame of its
        // arrival and exit, and half of those frames came late.
        .background {
            RoundedRectangle(cornerRadius: Corners.r(Self.radius), style: .continuous)
                .fill(.thickMaterial)
                .shadow(color: Color(hex: 0x141E46).opacity(0.22), radius: 40, y: 24)
        }
        .glassEffect(.regular, in: .rect(cornerRadius: Corners.r(Self.radius), style: .continuous))
    }

    private var field: some View {
        TextField(controller.placeholder, text: Binding(
            get: { controller.query },
            set: { controller.query = $0 }
        ))
        .textFieldStyle(.plain)
        .font(.ui(size: 21))
        .focused($fieldFocused)
        // Only a move by key slides the highlight; typing sends it back to the first row at once.
        .onKeyPress(.upArrow) {
            Motion.with(Motion.Spring.tap.animation) { controller.move(-1) }
            return .handled
        }
        .onKeyPress(.downArrow) {
            Motion.with(Motion.Spring.tap.animation) { controller.move(1) }
            return .handled
        }
        .onKeyPress(.tab) {
            guard controller.activeTab != nil else { return .ignored }
            controller.cycleTab()
            return .handled
        }
        .onKeyPress(.return) {
            controller.chooseSelected()
            return .handled
        }
        .onKeyPress(.escape) {
            controller.dismiss()
            return .handled
        }
        .onSubmit { controller.chooseSelected() }
        .onExitCommand { controller.dismiss() }
    }

    /// Key hints on the left, the count on the right: "↑↓ choose  ↩ open  ⇥ commands … 64 commands".
    private var footer: some View {
        let count = controller.results.count
        let tab = controller.activeTab
        let other = controller.tabs.first { $0.commandID != tab?.commandID }
        let noun = tab?.noun ?? "results"
        return HStack(spacing: 14) {
            hint("↑↓", "choose")
            hint("↩", tab?.noun == "commands" ? "run" : "open")
            if tab != nil, let other { hint("⇥", other.noun) }
            Spacer()
            Text(count == 1 ? "1 " + String(noun.dropLast()) : "\(count) \(noun)")
                .monospacedDigit()
                .contentTransition(.numericText())
        }
        .font(.ui(size: 12))
        .foregroundStyle(theme.secondaryText)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func hint(_ key: String, _ label: String) -> some View {
        HStack(spacing: 6) {
            KeyCaps(text: key)
            Text(label.uiLocalized)
        }
    }
}

/// The tabs at the end of the field: "Notes ⌘O | Commands ⌘P". The open one sits on a raised pill that slides to
/// the other on a click, Tab, ⌘O or ⌘P.
private struct QuickPickTabs: View {
    let controller: QuickPickController
    @Namespace private var pill
    @Environment(\.themeTokens) private var theme

    var body: some View {
        HStack(spacing: 2) {
            ForEach(controller.tabs, id: \.commandID) { tab in
                let active = tab.commandID == controller.activeTabID
                Button { controller.switchTab(to: tab.commandID) } label: {
                    HStack(spacing: 6) {
                        Text(tab.title.uiLocalized)
                            .font(.ui(size: 13, weight: active ? .semibold : .regular))
                            .foregroundStyle(active ? theme.text : theme.secondaryText)
                        if !tab.shortcut.isEmpty {
                            Text(tab.shortcut)
                                .font(.ui(size: 11, weight: .medium))
                                .foregroundStyle(theme.secondaryText)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(Color.primary.opacity(0.06), in: .rect(cornerRadius: Corners.r(6), style: .continuous))
                        }
                    }
                    .padding(.horizontal, 10)
                    .frame(height: 28)
                    .background {
                        if active {
                            ThemeCapsule(style: .continuous)
                                .fill(.background)
                                .shadow(color: .black.opacity(0.08), radius: 3, y: 1)
                                .matchedGeometryEffect(id: "pill", in: pill)
                        }
                    }
                    .contentShape(ThemeCapsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(Color.primary.opacity(0.05), in: ThemeCapsule(style: .continuous))
        .motion(.tap, value: controller.activeTabID)
    }
}

/// Keys drawn as small caps, one per key: "⌘⇧T" is ⌘, ⇧ and T.
struct KeyCaps: View {
    let text: String
    @Environment(\.themeTokens) private var theme

    var body: some View {
        HStack(spacing: 3) {
            ForEach(Array(Self.keys(text).enumerated()), id: \.offset) { _, key in
                Text(key)
                    .font(.ui(size: 11, weight: .medium))
                    .foregroundStyle(theme.secondaryText)
                    .frame(minWidth: 20, minHeight: 20)
                    .padding(.horizontal, key.count > 1 ? 4 : 0)
                    .background(Color.primary.opacity(0.06), in: .rect(cornerRadius: Corners.r(6), style: .continuous))
            }
        }
    }

    /// The modifiers one by one, then the key whole (`F5`, `Space`); a hint like "↑↓" or "esc" stays one cap.
    static func keys(_ text: String) -> [String] {
        let modifiers: Set<Character> = ["⌃", "⌥", "⇧", "⌘"]
        guard let first = text.first, modifiers.contains(first) else { return [text] }
        let mods = text.prefix { modifiers.contains($0) }.map(String.init)
        let rest = String(text.drop { modifiers.contains($0) })
        return mods + (rest.isEmpty ? [] : [rest])
    }
}

/// The rows under their section headings, scrolled so the selected one stays visible.
private struct QuickPickList: View {
    let controller: QuickPickController
    /// The rows, held by value: while a switch of tab cross-fades, the leaving list keeps the old ones.
    let results: [QuickPickItem]
    /// The selected row's fill is one shape that slides from row to row.
    @Namespace private var selection
    @Environment(\.themeTokens) private var theme

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(results.indices, id: \.self) { index in
                        let item = results[index]
                        if let section = item.section,
                           index == 0 || results[index - 1].section != section {
                            Text(section)
                                .font(.ui(size: 12, weight: .semibold))
                                .foregroundStyle(theme.secondaryText)
                                .padding(.horizontal, 16)
                                .padding(.top, index == 0 ? 6 : 14)
                                .padding(.bottom, 4)
                        }
                        QuickPickRow(
                            item: item,
                            isSelected: index == controller.selectedIndex,
                            selection: selection
                        )
                        .transition(.identity)
                        .id(index)
                        .contentShape(Rectangle())
                        .tappableRow { controller.choose(at: index) }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 8)
            }
            .softScrollEdges()
            .frame(maxHeight: 460)
            .fixedSize(horizontal: false, vertical: true)
            .onChange(of: controller.selectedIndex) { _, index in
                proxy.scrollTo(index)
            }
        }
    }
}

/// A row: the symbol in white on a coloured tile, the title (with its subtitle under it, or only once selected for a
/// long one), the shortcut as key caps on the right. The selected row sits on a soft accent fill.
private struct QuickPickRow: View {
    let item: QuickPickItem
    let isSelected: Bool
    let selection: Namespace.ID
    @Environment(\.themeTokens) private var theme

    var body: some View {
        let showsSubtitle = item.subtitle.map { !$0.isEmpty } == true && (!item.subtitleOnSelection || isSelected)
        HStack(spacing: 12) {
            if let symbol = item.symbol {
                Image(symbol: symbol)
                    .font(.ui(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 28, height: 28)
                    .background(InkFill(.rect(cornerRadius: Corners.r(8), style: .continuous), color: Self.tint(for: symbol)))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.ui(size: 14, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(theme.text)
                    .lineLimit(1)
                if showsSubtitle, let subtitle = item.subtitle {
                    Text(subtitle.uiLocalized)
                        .font(.ui(size: 12))
                        .foregroundStyle(theme.secondaryText)
                        .lineLimit(1)
                        .transition(.opacity)
                }
            }
            Spacer(minLength: 12)
            if let detail = item.detail, !detail.isEmpty {
                KeyCaps(text: detail)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(minHeight: 44)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            if isSelected {
                RoundedRectangle(cornerRadius: Corners.r(12), style: .continuous)
                    .fill(theme.accent.opacity(0.13))
                    .matchedGeometryEffect(id: "selection", in: selection)
            }
        }
        .motion(.tap, value: isSelected)
    }

    /// One colour per symbol, so a plugin's commands share theirs; the shell's own are Earth grey. Inks around Loam
    /// Blue, a little deeper and less saturated than system colours, so they read as print, not as candy.
    static func tint(for symbol: String) -> Color {
        if CommandPalette.shellSymbols.values.contains(symbol) || symbol == "macwindow" { return Color(hex: 0x7C8494) }
        let colors: [UInt32] = [0x2563FF, 0x2E9E6E, 0xE5853A, 0x7656E8, 0xD9487A, 0x1694A6, 0x4954D8, 0xC08A2E]
        let hash = symbol.unicodeScalars.reduce(UInt32(7)) { ($0 &* 31) &+ $1.value }
        return Color(hex: colors[Int(hash % UInt32(colors.count))])
    }
}
