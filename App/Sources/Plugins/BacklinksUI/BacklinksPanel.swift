import AppKit
import PluginKitUI
import SwiftUI

/// The groups of a note's "Links" tab: the linking notes with their context lines, the boards showing the note,
/// then the unlinked mentions.
struct BacklinksSectionView: View {
    enum Part { case linked, boards, mentions }

    let model: BacklinksModel
    let part: Part

    var body: some View {
        if model.active != nil {
            switch part {
            case .linked:
                group("Backlinks", entries: model.backlinks, empty: "No backlinks yet", symbol: "arrow.uturn.left")
            case .boards:
                if !model.boards.isEmpty { group("On boards", entries: model.boards, empty: "", symbol: nil) }
            case .mentions:
                group("Unlinked mentions", entries: model.mentions, empty: "No unlinked mentions", symbol: "text.magnifyingglass")
            }
        }
    }

    private func group(_ title: String, entries: [BacklinksModel.Entry], empty: String, symbol: String?) -> some View {
        InspectorGroup(title, accessory: entries.isEmpty ? nil : "\(entries.count)") {
            if entries.isEmpty {
                InspectorEmpty(empty, systemImage: symbol)
            } else {
                InspectorCard {
                    ForEach(entries) { entry in
                        EntryRow(model: model, entry: entry)
                    }
                }
            }
        }
    }
}

/// A linking or mentioning note: its title, its folder, and the lines where it names the open note.
private struct EntryRow: View {
    let model: BacklinksModel
    let entry: BacklinksModel.Entry
    @Environment(\.themeTokens) private var theme
    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: theme.spacing.small) {
                Image(symbol: entry.kind == .board ? "rectangle.on.rectangle.angled" : "doc.text")
                    .foregroundStyle(theme.secondaryText)
                    .font(.ui(size: 12))
                Text(entry.title).lineLimit(1).foregroundStyle(theme.text.opacity(0.85))
                Spacer(minLength: 0)
                if !entry.folder.isEmpty {
                    Text(entry.folder).lineLimit(1).font(.ui(size: 11)).foregroundStyle(theme.secondaryText)
                }
            }
            .font(.ui(size: InspectorStyle.fontSize))
            ForEach(entry.lines) { line in
                Text(attributed(line))
                    .font(.ui(size: 12))
                    .foregroundStyle(theme.secondaryText)
                    .lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 20)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background {
            RoundedRectangle(cornerRadius: Corners.r(8), style: .continuous).fill(theme.text.opacity(isHovered ? 0.04 : 0))
        }
        .onHover { isHovered = $0 }
        .animation(Motion.hover, value: isHovered)
        .contentShape(Rectangle())
        .tappableRow { model.open(entry.path, beside: NSEvent.modifierFlags.contains(.command)) }
        .draggableResource(.file(entry.path))
        .help(entry.path)
    }

    private func attributed(_ line: BacklinksModel.ContextLine) -> AttributedString {
        var result = AttributedString()
        for fragment in line.fragments {
            var part = AttributedString(fragment.text)
            if fragment.isMatch {
                part.font = .ui(size: 12, weight: .semibold)
                part.foregroundColor = theme.text
            }
            result += part
        }
        return result
    }
}
