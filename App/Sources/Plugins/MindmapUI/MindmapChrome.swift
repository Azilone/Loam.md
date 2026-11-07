import PluginKitUI
import SwiftUI

// The map's chrome, SwiftUI in hosting views of their own over the AppKit canvas (`MindmapCanvasView`): shown
// rarely or a few controls, never laid out by a pan or a zoom.

/// Shown in place of the map when its note cannot be read.
struct MindmapMissingNote: View {
    let path: String

    var body: some View {
        ContentUnavailableView {
            Label("Note not found", symbol: LoamSymbol.mindmap)
        } description: {
            Text(path)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Over a note with sections, which the map cannot write back.
struct MindmapReadOnlyBanner: View {
    @Environment(\.themeTokens) private var theme

    var body: some View {
        Label("This note has sections: the map is read only. Use “New mindmap” to make an editable one.",
              symbol: "lock")
            .font(.ui(.label))
            .foregroundStyle(theme.secondaryText)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .glassEffect(.regular, in: ThemeCapsule())
            .fixedSize()
    }
}

/// The shortcuts as an opaque card inside the map, never wider or taller than it (a popover was clipped by the
/// window).
struct MindmapShortcutsCard: View {
    let width: CGFloat
    let height: CGFloat
    @Environment(\.themeTokens) private var theme

    var body: some View {
        ScrollView {
            MindmapShortcuts(compact: width < 640)
        }
        .frame(width: min(800, max(width - 32, 200)))
        .frame(maxHeight: max(height - 90, 120))
        .fixedSize(horizontal: false, vertical: true)
        .background(theme.background, in: RoundedRectangle(cornerRadius: Corners.r(14)))
        .overlay(RoundedRectangle(cornerRadius: Corners.r(14)).strokeBorder(theme.secondaryText.opacity(0.25)))
        .shadow(color: .black.opacity(0.2), radius: 16, y: 4)
        .padding(20)
    }
}

// MARK: - Toolbar

/// The floating bar under the map: zoom, fit, layout, folding and the shortcuts.
struct MindmapToolbar: View {
    @Bindable var model: MindmapTabModel
    @Environment(\.themeTokens) private var theme

    var body: some View {
        HStack(spacing: 2) {
            button("minus", "Zoom out (⌘-)") { model.zoom(by: 0.8, animated: true) }
            Button { model.setScale(1) } label: {
                Text("\(Int((model.scale * 100).rounded())) %")
                    .font(.ui(.label).monospacedDigit())
                    .frame(minWidth: 52)
            }
            .buttonStyle(.plain)
            .help("Actual size")
            button("plus", "Zoom in (⌘+)") { model.zoom(by: 1.25, animated: true) }
            divider
            button("arrow.up.left.and.arrow.down.right", "Zoom to fit (⌘0)") { model.fit() }
            Menu {
                Picker("Layout", selection: Binding(get: { model.mode }, set: { model.setMode($0) })) {
                    ForEach(MindmapLayoutMode.allCases, id: \.self) { mode in
                        Label(mode.title, symbol: mode.systemImage).tag(mode)
                    }
                }
                .pickerStyle(.inline)
                Divider()
                Button("Fold all (⌥⇧⌘←)") { model.setAllFolded(true) }
                Button("Unfold all (⌥⇧⌘→)") { model.setAllFolded(false) }
                Divider()
                Button("Open the note") { model.openNote() }
            } label: {
                Image(symbol: model.mode.systemImage)
                    .frame(width: 30, height: 26)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Layout")
            divider
            button("keyboard", "Keyboard shortcuts (?)") { model.showsShortcuts.toggle() }
        }
        .foregroundStyle(theme.text)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .glassEffect(.regular, in: ThemeCapsule())
    }

    private var divider: some View {
        Divider().frame(height: 16).padding(.horizontal, 4)
    }

    private func button(_ image: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button { action() } label: {
            Image(symbol: image).frame(width: 30, height: 26).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

/// The list of shortcuts, from the toolbar's keyboard button, `?`, or the palette's "Mindmap: keyboard shortcuts".
/// The keys are the defaults; the palette shows a command's key after `.loam/config.json` changed it.
struct MindmapShortcuts: View {
    /// One column, for a map in a narrow pane.
    var compact = false

    static let sections: [(String, [(String, String)])] = [
        ("Add and edit", [
            ("⇥", "Add a child, also while typing"),
            ("↩", "Add a sibling, also while typing (twice: stop)"),
            ("⇧↩  ⌥↩", "Add a sibling above"), ("Space  F2", "Edit the topic, or type over it (Esc: undo that)"),
            ("Esc", "Stop editing (again: clear the selection)"), ("⌫", "Delete the topic"),
        ]),
        ("Move", [
            ("⌘↑  ⌘↓", "Move up or down among siblings"), ("⇧⇥", "Move up a level"),
            ("⌘←  ⌘→", "Move left or right, across to the other side"),
            ("Drag", "Move onto, beside, or across to the other side"),
        ]),
        ("Select and fold", [
            ("←  ↑  →  ↓", "Select the topic that way (outward: unfold)"), ("Home", "Select the central topic"),
            ("⌥⌘←  ⌥⌘→", "Fold or unfold the topic"), ("⌘.", "Fold or unfold the selected topics"),
            ("⌥⇧⌘←  ⌥⇧⌘→", "Fold all or unfold all"), ("⇧click  ⌘A", "Select several (or drag around them)"),
        ]),
        ("View", [
            ("⌘0  !", "Zoom to fit"), ("@", "Zoom to the selection"), ("⌘+  ⌘-", "Zoom (or pinch, ⌘ scroll)"),
            ("Scroll", "Pan"), ("⌘↩", "Open the note"), ("?", "These shortcuts"),
        ]),
        ("History", [("⌘Z  ⇧⌘Z", "Undo or redo"), ("⌘C  ⌘X  ⌘V", "Copy, cut, paste as a Markdown list")]),
    ]

    /// Two columns, so the list fits above the toolbar of a small window.
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Keyboard shortcuts").font(.ui(.emphasis))
                Text("? or Esc to close").font(.ui(.label)).foregroundStyle(.secondary)
            }
            if compact {
                column(Self.sections)
            } else {
                HStack(alignment: .top, spacing: 28) {
                    column(Self.sections.filter { ["Add and edit", "Move", "History"].contains($0.0) })
                    column(Self.sections.filter { !["Add and edit", "Move", "History"].contains($0.0) })
                }
            }
        }
        .padding(18)
        .frame(maxWidth: 800)
    }

    private func column(_ sections: [(String, [(String, String)])]) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 5) {
            ForEach(sections, id: \.0) { section in
                GridRow {
                    Text(section.0).font(.ui(.body, weight: .semibold)).padding(.top, 6)
                        .gridCellColumns(2)
                }
                ForEach(section.1, id: \.1) { row in
                    if compact {
                        GridRow {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(row.0).font(.ui(.label, weight: .medium)).foregroundStyle(.secondary)
                                Text(row.1).fixedSize(horizontal: false, vertical: true)
                            }
                            .gridCellColumns(2)
                        }
                    } else {
                        GridRow {
                            Text(row.1).fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Text(row.0).font(.ui(.label)).foregroundStyle(.secondary)
                                .fixedSize(horizontal: true, vertical: false)
                                .gridColumnAlignment(.trailing)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}
