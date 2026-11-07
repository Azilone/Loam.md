import AssistantPlugin
import PluginKitUI
import SwiftUI

/// The panel's menus, drawn above it next to their button: Conversation History under the list button, the agent,
/// the mode and Add Additional Context above the composer, as Craft's.
struct AssistantMenus: View {
    @Bindable var model: AssistantModel
    let menu: AssistantModel.Menu
    let anchor: CGRect
    let colors: CraftColors
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        content
            .padding(4)
            .frame(width: width)
            .background(RoundedRectangle(cornerRadius: Corners.r(12), style: .continuous).fill(colors.menu))
            .craftFloatingShadow(colors, radius: 12)
            .foregroundStyle(colors.ink)
            .environment(\.craftColors, colors)
            .alignmentGuide(.leading) { _ in 0 }
            .fixedSize(horizontal: false, vertical: true)
            .modifier(MenuPlacement(anchor: anchor, below: menu == .history))
            .transition(.scale(scale: Motion.Metrics.overlayScale, anchor: menu == .history ? .topLeading : .bottomLeading)
                .combined(with: .opacity))
            .animation(reduceMotion ? Motion.fade : Motion.Spring.overlay.animation, value: menu)
    }

    private var width: CGFloat {
        switch menu {
        case .history: 260
        case .agent: 320
        case .mode: 230
        case .context: 260
        case .slash, .mention: 280
        }
    }

    @ViewBuilder private var content: some View {
        switch menu {
        case .history: HistoryMenu(model: model)
        case .agent: AgentMenu(model: model)
        case .mode: ModeMenu(model: model)
        case .context: ContextMenu(model: model)
        case .slash, .mention: InlineMenu(model: model)
        }
    }
}

/// Puts the menu under its button (history) or above it (the composer's), its leading edge on the button's.
private struct MenuPlacement: ViewModifier {
    let anchor: CGRect
    let below: Bool

    func body(content: Content) -> some View {
        content
            .background(GeometryReader { proxy in Color.clear.preference(key: MenuHeight.self, value: proxy.size.height) })
            .modifier(Offset(anchor: anchor, below: below))
    }

    private struct Offset: ViewModifier {
        let anchor: CGRect
        let below: Bool
        @State private var height: CGFloat = 0

        func body(content: Content) -> some View {
            content
                .onPreferenceChange(MenuHeight.self) { height = $0 }
                .offset(x: anchor.minX, y: below ? anchor.maxY + 6 : anchor.minY - 6 - height)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }
}

private struct MenuHeight: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// One row of a menu: 32 points, radius 10, an optional icon and subtitle, a check on the current one.
struct MenuRow: View {
    var symbol: String?
    var icon: AnyView?
    let title: String
    var subtitle: String?
    var checked = false
    var enabled = true
    var trailing: String?
    var highlighted = false
    let action: () -> Void
    @Environment(\.craftColors) private var colors
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: subtitle == nil ? .center : .top, spacing: 8) {
                if let icon {
                    icon.frame(width: 20, height: 20)
                } else if let symbol {
                    Image(symbol: symbol).font(.ui(size: 13)).frame(width: 20, height: 20)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(CraftStyle.font(13))
                        .tracking(CraftStyle.tracking)
                    if let subtitle {
                        Text(subtitle).font(CraftStyle.font(12)).opacity(0.6)
                    }
                }
                .lineLimit(1)
                Spacer(minLength: 4)
                if let trailing {
                    Text(trailing).font(CraftStyle.font(12)).opacity(0.5)
                }
                if checked {
                    Image(symbol: "checkmark").font(.ui(size: 12, weight: .semibold))
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(minHeight: 32)
            .opacity(enabled ? 1 : 0.4)
            .background(RoundedRectangle(cornerRadius: Corners.r(10), style: .continuous)
                .fill((hovered || highlighted) && enabled ? colors.hoverFill : .clear))
            .contentShape(RoundedRectangle(cornerRadius: Corners.r(10), style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .onHover { hovering in withAnimation(CraftStyle.hover) { hovered = hovering } }
    }
}

private struct MenuSection: View {
    let title: String

    var body: some View {
        Text(title.uppercased())
            .font(CraftStyle.font(11, .semibold))
            .opacity(0.45)
            .padding(.horizontal, 8)
            .padding(.top, 8)
            .padding(.bottom, 2)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct MenuDivider: View {
    @Environment(\.craftColors) private var colors

    var body: some View {
        Rectangle().fill(colors.ink.opacity(0.08)).frame(height: 1).padding(.vertical, 4).padding(.horizontal, 8)
    }
}

// MARK: The menus

/// What `/` and `@` open above the field: the rows follow the typing, the arrows move the highlight, Return or Tab
/// picks it (Craft's saved prompts and "Focus on…", folders, documents).
private struct InlineMenu: View {
    @Bindable var model: AssistantModel

    var body: some View {
        let items = model.inlineItems
        VStack(alignment: .leading, spacing: 0) {
            if items.isEmpty {
                Text(model.menu == .mention ? "No notes" : "No saved prompts")
                    .font(CraftStyle.font(13))
                    .opacity(0.45)
                    .padding(8)
            }
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                if let section = item.section, index == 0 || items[index - 1].section != section {
                    MenuSection(title: section)
                }
                MenuRow(symbol: item.symbol, title: item.title, subtitle: item.subtitle,
                        highlighted: index == model.highlighted) { model.choose(item) }
                    .onHover { if $0 { model.highlighted = index } }
            }
        }
    }
}

private struct HistoryMenu: View {
    @Bindable var model: AssistantModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Conversation History")
                    .font(CraftStyle.font(13, .semibold))
                    .tracking(CraftStyle.tracking)
                Spacer()
                Button { model.menu = nil } label: {
                    Image(symbol: "xmark.circle.fill").font(.ui(size: 15)).opacity(0.35)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 8)
            .frame(height: 32)
            if model.history.isEmpty {
                Text("No conversation history")
                    .font(CraftStyle.font(13))
                    .opacity(0.45)
                    .padding(.horizontal, 8)
                    .frame(height: 32)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(model.history) { chat in
                            MenuRow(symbol: nil, icon: AnyView(AgentIcon(kind: chat.agent)),
                                    title: chat.title, checked: chat.id == model.chat.id,
                                    trailing: Self.age(chat.updated)) { model.show(chat.id) }
                                .contextMenu {
                                    Button("Delete", role: .destructive) { model.delete(chat.id) }
                                }
                        }
                    }
                }
                .frame(maxHeight: 280)
            }
            MenuDivider()
            MenuRow(symbol: nil, title: "Usage and Limits") {
                model.menu = nil
                model.openSettings()
            }
        }
    }

    static func age(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

/// One menu for the agent and its model, as Tolaria's: each agent ready on this Mac under its logo (picking the
/// agent is its default model), its models below it, Pi's by provider; a dot on the current one. Agents that are
/// missing or signed out wait in Settings.
private struct AgentMenu: View {
    @Bindable var model: AssistantModel
    /// Agents whose whole list of models shows; the others show their first few.
    @State private var expanded: Set<AgentKind> = []
    @State private var query = ""
    @FocusState private var searching: Bool
    @Environment(\.craftColors) private var colors
    static let visible = 4

    var body: some View {
        let ready = model.statuses.filter { $0.state == .ready }
        VStack(alignment: .leading, spacing: 0) {
            // Pi through OpenRouter alone offers hundreds of models: type to find one.
            HStack(spacing: 6) {
                Image(symbol: "magnifyingglass").font(.ui(size: 12)).opacity(0.5)
                TextField("Search Models", text: $query)
                    .textFieldStyle(.plain)
                    .font(CraftStyle.font(13))
                    .focused($searching)
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(RoundedRectangle(cornerRadius: Corners.r(10), style: .continuous).fill(colors.chip))
            .padding(.bottom, 4)
            if !query.trimmingCharacters(in: .whitespaces).isEmpty {
                let matches = ready.flatMap { status in status.models.map { (status.kind, $0) } }
                let ranked = Fuzzy.rank(matches, query: query) { "\($0.0.name) \($0.1.provider ?? "") \($0.1.name)" }.prefix(30)
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        if ranked.isEmpty {
                            Text("No models").font(CraftStyle.font(13)).opacity(0.45).padding(8)
                        }
                        ForEach(Array(ranked.enumerated()), id: \.offset) { _, match in
                            ModelRow(icon: match.1.provider.map { AnyView(ProviderIcon(provider: $0)) }
                                         ?? AnyView(AgentIcon(kind: match.0, size: 14)),
                                     title: match.1.name,
                                     caption: [match.1.provider, match.0.name].compactMap { $0 }.joined(separator: " · "),
                                     selected: isCurrent(match.0, match.1.id)) {
                                model.choose(agent: match.0, model: match.1.id)
                            }
                        }
                    }
                }
                .frame(maxHeight: 440)
            } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(ready.enumerated()), id: \.element.kind) { index, status in
                        if index > 0 { MenuDivider() }
                        ModelRow(icon: AnyView(AgentIcon(kind: status.kind, size: 18)), title: status.kind.name,
                                 bold: true, selected: isCurrent(status.kind, "")) {
                            model.choose(agent: status.kind, model: "")
                        }
                        let all = status.models
                        let shown = expanded.contains(status.kind) ? all : Array(all.prefix(Self.visible))
                        ForEach(groups(shown), id: \.0) { provider, models in
                            if let provider, status.kind == .pi || status.kind == .opencode {
                                Text(provider).font(CraftStyle.font(11, .semibold)).opacity(0.45)
                                    .padding(.leading, 36).padding(.top, 4)
                            }
                            ForEach(models, id: \.self) { option in
                                ModelRow(icon: option.provider.map { AnyView(ProviderIcon(provider: $0)) },
                                         title: option.name, selected: isCurrent(status.kind, option.id)) {
                                    model.choose(agent: status.kind, model: option.id)
                                }
                            }
                        }
                        if all.count > Self.visible {
                            Button {
                                withAnimation(CraftStyle.hover) {
                                    if expanded.contains(status.kind) { expanded.remove(status.kind) } else { expanded.insert(status.kind) }
                                }
                            } label: {
                                Text(expanded.contains(status.kind) ? "Show Less" : "\(all.count - Self.visible) More Models")
                                    .font(CraftStyle.font(12))
                                    .opacity(0.5)
                                    .padding(.leading, 44)
                                    .frame(maxWidth: .infinity, minHeight: 24, alignment: .leading)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    if ready.isEmpty {
                        Text("Checking the agents on this Mac…").font(CraftStyle.font(13)).opacity(0.5).padding(8)
                    }
                }
            }
            .frame(maxHeight: 440)
            }
            MenuDivider()
            MenuRow(symbol: "gearshape", title: "Manage Agents", trailing: "↗") {
                model.menu = nil
                model.openSettings()
            }
        }
        .onAppear { searching = true }
    }

    private func isCurrent(_ kind: AgentKind, _ id: String) -> Bool {
        model.chat.agent == kind && model.chat.model == id
    }

    /// Models by provider, in the order they come.
    private func groups(_ models: [AgentModel]) -> [(String?, [AgentModel])] {
        var order: [String?] = []
        var byProvider: [String?: [AgentModel]] = [:]
        for model in models {
            if byProvider[model.provider] == nil { order.append(model.provider) }
            byProvider[model.provider, default: []].append(model)
        }
        return order.map { ($0, byProvider[$0] ?? []) }
    }
}

/// A row of the model menu: an agent (its logo, bold) or one of its models, indented, with Tolaria's ring on the
/// current one.
private struct ModelRow: View {
    var icon: AnyView?
    let title: String
    /// Where a search result comes from: "openrouter · Pi".
    var caption: String?
    var bold = false
    let selected: Bool
    let action: () -> Void
    @Environment(\.craftColors) private var colors
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if bold {
                    icon.frame(width: 20, height: 20)
                } else {
                    Circle()
                        .strokeBorder(colors.ink.opacity(selected ? 0.8 : 0), lineWidth: 1.5)
                        .frame(width: 8, height: 8)
                        .frame(width: 20)
                    if let icon { icon.frame(width: 14, height: 14) }
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(CraftStyle.font(13, bold ? .semibold : .medium))
                        .tracking(CraftStyle.tracking)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let caption {
                        Text(caption).font(CraftStyle.font(11)).opacity(0.5).lineLimit(1)
                    }
                }
                Spacer(minLength: 4)
                if bold && selected {
                    Text("Default").font(CraftStyle.font(11)).opacity(0.5)
                    Image(symbol: "checkmark").font(.ui(size: 11, weight: .semibold))
                }
            }
            .padding(.leading, bold ? 8 : 16)
            .padding(.trailing, 8)
            .frame(height: bold ? 34 : caption == nil ? 28 : 38)
            .background(RoundedRectangle(cornerRadius: Corners.r(10), style: .continuous).fill(hovered ? colors.hoverFill : .clear))
            .contentShape(RoundedRectangle(cornerRadius: Corners.r(10), style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering in withAnimation(CraftStyle.hover) { hovered = hovering } }
    }
}

/// The permission menu, as Tolaria's: its title with the current one, then Read only, Guard, Full access, and the
/// default in Settings.
private struct ModeMenu: View {
    @Bindable var model: AssistantModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(symbol: ModeIcon.symbol(.ask)).font(.ui(size: 13)).frame(width: 20)
                Text("Permission").font(CraftStyle.font(13, .semibold))
                Spacer()
                Text(model.chat.mode.title).font(CraftStyle.font(13)).opacity(0.5)
            }
            .padding(.horizontal, 8)
            .frame(height: 32)
            MenuDivider()
            ForEach([AgentMode.readOnly, .ask, .auto], id: \.self) { mode in
                MenuRow(symbol: ModeIcon.symbol(mode), title: mode.title, checked: mode == model.chat.mode) {
                    model.choose(mode: mode)
                }
                .help(mode.subtitle)
            }
            MenuDivider()
            MenuRow(symbol: nil, title: "Global Setting", trailing: "↗") {
                model.menu = nil
                model.openSettings()
            }
        }
    }
}

/// Craft's Add Additional Context: a search field, "Focus on…", then folders and notes.
private struct ContextMenu: View {
    @Bindable var model: AssistantModel
    @State private var query = ""
    @FocusState private var focused: Bool
    @Environment(\.craftColors) private var colors

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(symbol: "magnifyingglass").font(.ui(size: 12)).opacity(0.5)
                TextField("Add Additional Context", text: $query)
                    .textFieldStyle(.plain)
                    .font(CraftStyle.font(13))
                    .focused($focused)
            }
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background(RoundedRectangle(cornerRadius: Corners.r(10), style: .continuous).fill(colors.chip))
            .overlay(RoundedRectangle(cornerRadius: Corners.r(10), style: .continuous).strokeBorder(colors.send.opacity(0.6), lineWidth: 1))
            .padding(.bottom, 4)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if query.isEmpty {
                        MenuSection(title: "Focus on…")
                        if let active = model.activeNote {
                            MenuRow(symbol: "doc.text", title: "This Note") {
                                model.dismissedActiveNote = false
                                model.addContext(active)
                            }
                        }
                        MenuRow(symbol: "doc.on.doc", title: "All Notes") {
                            model.dismissedActiveNote = true
                            model.extraContext = []
                            model.menu = nil
                        }
                        let folders = model.listFolders()
                        if !folders.isEmpty {
                            MenuSection(title: "Folders")
                            ForEach(folders.prefix(8), id: \.self) { folder in
                                MenuRow(symbol: "folder", title: folder) { model.addContext(folder + "/") }
                            }
                        }
                    } else {
                        let matches = Fuzzy.rank(model.listNotes(), query: query) { $0 }.prefix(8)
                        if matches.isEmpty {
                            Text("No notes").font(CraftStyle.font(13)).opacity(0.45).padding(8)
                        }
                        ForEach(Array(matches), id: \.self) { path in
                            MenuRow(symbol: "doc.text", title: ((path as NSString).lastPathComponent as NSString)
                                .deletingPathExtension, subtitle: (path as NSString).deletingLastPathComponent) {
                                model.addContext(path)
                            }
                        }
                    }
                }
            }
            .frame(maxHeight: 300)
        }
        .onAppear { focused = true }
    }
}
