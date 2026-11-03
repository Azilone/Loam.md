import PluginKitUI
import SwiftUI

/// The Recently Deleted page (`trash:`): an icon and title with how long items are kept and Empty, then the items
/// grouped by when they were trashed, each group a card with Restore All. A row shows its folder and first line;
/// on hover, Restore and a menu replace the ring that counts down the days left. What just happened shows in a
/// toast at the bottom.
struct TrashView: View {
    @Bindable var model: TrashModel
    @Environment(\.themeTokens) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovered: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header.padding(.bottom, PageMetrics.headerGap)
                if model.items.isEmpty {
                    EmptyState("Nothing deleted", symbol: "trash", message: "Notes you delete stay here for a while before they go for good.")
                }
                ForEach(model.groups, id: \.title) { group in
                    section(group.title, group.items).padding(.bottom, Space.xl)
                }
            }
            .pageColumn(.reading)
            .padding(.bottom, 80)
        }
        .softScrollEdges()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(theme.background)
        .overlay(alignment: .bottom) { toast }
        .alert(alertTitle, isPresented: Binding(get: { model.pending != nil }, set: { if !$0 { model.pending = nil } })) {
            Button(model.pending == .empty ? "Empty Recently Deleted" : "Delete Forever", role: .destructive) { model.confirm() }
            Button("Cancel", role: .cancel) { model.pending = nil }
        } message: {
            Text("You can't undo this action.")
        }
    }

    private var alertTitle: String {
        switch model.pending {
        case .delete(let item): "Are you sure you want to permanently erase “\(TrashModel.name(of: item))”?"
        case .empty: "Are you sure you want to permanently erase the items?"
        case nil: ""
        }
    }

    // MARK: Header

    private var header: some View {
        PageHeader("Recently Deleted", subtitle: model.summary) {
            Button("Empty…") { model.pending = .empty }
                .buttonStyle(PillStyle(foreground: theme.danger, background: theme.danger.opacity(0.1)))
                .disabled(model.items.isEmpty)
            Menu {
                Menu("Keep Items For") {
                    ForEach(TrashModel.retentionChoices, id: \.self) { days in
                        Button {
                            model.chooseRetention(days)
                        } label: {
                            Text(TrashModel.retentionLabel(days))
                            if model.retentionDays == days { Image(symbol: "checkmark") }
                        }
                    }
                }
            } label: {
                Image(symbol: "ellipsis")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("Recently Deleted options")
        }
    }

    // MARK: Groups

    private func section(_ title: String, _ items: [TrashedItem]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(title.uiLocalized).foregroundStyle(theme.secondaryText).fontWeight(.medium)
                Text("· \(items.count == 1 ? "1 item" : "\(items.count) items")").themeLabel(size: UIType.caption.size).foregroundStyle(theme.secondaryText.opacity(0.7))
                Spacer()
                Button("Restore All") { model.restoreAll(items) }
                    .buttonStyle(.borderless)
                    .foregroundStyle(theme.accent)
            }
            .font(.ui(.caption))
            .padding(.horizontal, 4)
            VStack(spacing: 0) {
                ForEach(Array(items.enumerated()), id: \.element.path) { index, item in
                    if index > 0 { Divider().overlay(theme.separator.opacity(0.6)) }
                    row(item)
                }
            }
            .background(theme.background, in: RoundedRectangle(cornerRadius: Corners.r(10), style: .continuous))
            .clipShape(RoundedRectangle(cornerRadius: Corners.r(10), style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Corners.r(10), style: .continuous).strokeBorder(theme.separator))
        }
    }

    private func row(_ item: TrashedItem) -> some View {
        let isHovered = hovered == item.path
        return HStack(spacing: 12) {
            icon(item)
            VStack(alignment: .leading, spacing: 2) {
                Text(TrashModel.name(of: item)).font(.ui(.body, weight: .medium)).foregroundStyle(theme.text).lineLimit(1)
                Text(subtitle(item)).font(.ui(.caption)).foregroundStyle(theme.secondaryText).lineLimit(1)
            }
            Spacer(minLength: 12)
            ZStack(alignment: .trailing) {
                countdown(item).opacity(isHovered ? 0 : 1)
                HStack(spacing: 6) {
                    Button { model.restore(item) } label: {
                        Label("Restore", symbol: "arrow.uturn.backward")
                    }
                    .buttonStyle(PillStyle(foreground: .white, background: theme.accent))
                    Menu {
                        Button("Restore") { model.restore(item) }
                        Button("Delete Forever", role: .destructive) { model.pending = .delete(item) }
                    } label: {
                        Image(symbol: "ellipsis")
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .frame(width: 26, height: 26)
                    .background(theme.secondaryText.opacity(0.12), in: Circle())
                    .accessibilityLabel("More")
                }
                .opacity(isHovered ? 1 : 0)
                .allowsHitTesting(isHovered)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(isHovered ? theme.fillSubtle : .clear)
        .contentShape(Rectangle())
        .onHover { inside in
            withAnimation(Motion.hover) { hovered = inside ? item.path : (hovered == item.path ? nil : hovered) }
        }
        .contextMenu {
            Button("Restore") { model.restore(item) }
            Button("Delete Forever", role: .destructive) { model.pending = .delete(item) }
        }
    }

    private func icon(_ item: TrashedItem) -> some View {
        let tint = Self.tint(for: TrashModel.folder(of: item))
        return Image(symbol: item.isFolder ? "folder" : "doc.text")
            .font(.ui(size: 13))
            .foregroundStyle(tint)
            .frame(width: 28, height: 28)
            .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: Corners.r(8), style: .continuous))
    }

    /// A stable colour per folder, so notes from the same place look alike; grey at the root.
    static func tint(for folder: String) -> Color {
        guard !folder.isEmpty else { return .gray }
        let colors: [Color] = [.orange, .red, .green, .blue, .purple, .pink, .teal, .indigo]
        let hash = folder.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF }
        return colors[hash % colors.count]
    }

    @ViewBuilder private func countdown(_ item: TrashedItem) -> some View {
        if let fraction = model.remaining(item), let days = item.daysLeft {
            let soon = days <= 7
            HStack(spacing: 6) {
                ZStack {
                    Circle().fill(theme.secondaryText.opacity(0.25))
                    Circle()
                        .trim(from: 0, to: 1 - fraction)
                        .stroke(soon ? theme.danger : theme.secondaryText.opacity(0.6), lineWidth: 6)
                        .rotationEffect(.degrees(-90))
                        .padding(3)
                        .opacity(fraction < 1 ? 1 : 0)
                }
                .frame(width: 13, height: 13)
                .clipShape(Circle())
                Text("\(days) d").font(.ui(.caption)).monospacedDigit()
                    .foregroundStyle(soon ? theme.danger : theme.secondaryText)
            }
            .help(model.daysLeftText(item))
            .accessibilityElement(children: .combine)
            .accessibilityLabel(model.daysLeftText(item))
        }
    }

    private func subtitle(_ item: TrashedItem) -> String {
        let folder = TrashModel.folder(of: item)
        let preview = model.preview(item)
        return [folder.isEmpty ? "Vault" : folder, preview.isEmpty ? nil : preview].compactMap { $0 }.joined(separator: " · ")
    }

    // MARK: Toast

    @ViewBuilder private var toast: some View {
        if let message = model.message {
            HStack(spacing: 10) {
                Image(symbol: message.hasPrefix("Could not") ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                    .foregroundStyle(message.hasPrefix("Could not") ? theme.danger : theme.success)
                Text(message.uiLocalized).font(.ui(.body)).foregroundStyle(theme.text).lineLimit(2)
                Button("OK") { withAnimation(Motion.exit) { model.message = nil } }
                    .buttonStyle(PillStyle(foreground: theme.text, background: theme.secondaryText.opacity(0.12)))
            }
            .padding(.leading, 14)
            .padding(.trailing, 8)
            .padding(.vertical, 8)
            .background(theme.background, in: ThemeCapsule())
            .overlay(ThemeCapsule().strokeBorder(theme.separator))
            .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
            .padding(.bottom, 20)
            .transition(reduceMotion ? .opacity : .opacity.combined(with: .offset(y: Motion.Metrics.toastRise)))
            .id(message)
            .task(id: message) {
                try? await Task.sleep(for: .seconds(5))
                withAnimation(Motion.exit) { if model.message == message { model.message = nil } }
            }
        }
    }
}

/// A small capsule button: Empty, Restore, OK.
private struct PillStyle: ButtonStyle {
    let foreground: Color
    let background: Color
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.ui(.label, weight: .medium))
            .foregroundStyle(foreground)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(background, in: ThemeCapsule())
            .opacity(isEnabled ? (configuration.isPressed ? 0.75 : 1) : 0.4)
            .scaleEffect(configuration.isPressed && !Motion.reduceMotion ? Motion.Metrics.pressScale : 1)
            .animation(Motion.Spring.tap.animation, value: configuration.isPressed)
    }
}
