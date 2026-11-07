import PluginKitUI
import SwiftUI

/// "New" at the head of the left sidebar: a pill printed in the accent that opens a glass menu of what can be created
/// (a note, then the kinds plugins add: Mindmap, Canvas, Drawing). The focused page's kind is highlighted, so Return
/// makes another of it; arrows move, Escape or a click away closes it.
struct NewMenuButton: View {
    /// The view type of the focused page, whose kind the menu highlights.
    var pageKind: String?
    @State private var panel: GlassMenuPanel?
    @State private var anchor = ViewAnchor()
    @Environment(\.pageActions) private var actions
    @Environment(\.themeTokens) private var theme
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: SidebarStyle.iconGap) {
                Image(symbol: "plus")
                    .font(.ui(size: 15, weight: .semibold))
                    .frame(width: SidebarStyle.iconSize)
                Text("New")
                Spacer(minLength: 0)
                Text("⌘N").font(.ui(size: 12, weight: .semibold)).opacity(0.5)
            }
            .foregroundStyle(theme.onAccent)
            .sidebarPill(ink: theme.accent)
        }
        .buttonStyle(.press)
        .background(ViewAnchorView(anchor: anchor))
        .onDisappear { panel?.dismiss(animated: false) }
        .help("New (⌘N)")
        .accessibilityLabel("New")
    }

    private func toggle() {
        var entries: [GlassMenuEntry] = []
        var kinds: [String?] = []
        if let newNote = actions.newNote {
            entries.append(GlassMenuEntry(id: "note", title: "Note", symbol: "doc", shortcut: "⌘N") { newNote() })
            kinds.append(nil)
        }
        for item in actions.newItems {
            let title = item.title.hasPrefix("New ") ? String(item.title.dropFirst(4)) : item.title
            entries.append(GlassMenuEntry(id: item.id, title: title, symbol: item.symbol) { item.create(VaultPath.inbox) })
            kinds.append(item.viewType)
        }
        guard !entries.isEmpty else { return }
        let highlighted = kinds.firstIndex { $0 != nil && $0 == pageKind } ?? 0
        let panel = panel ?? GlassMenuPanel()
        self.panel = panel
        panel.toggle([GlassMenuSection(entries: entries)], highlighted: highlighted, by: anchor, theme: theme, colorScheme: colorScheme)
    }
}
