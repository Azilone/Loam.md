import PluginKit
import PluginKitUI
import SwiftUI

/// Every command with its default shortcut, read only for now: the shortcut editor comes with the shortcut table.
/// The field filters by title.
struct ShortcutsPane: View {
    let session: ShellSession
    @State private var filter = ""
    @Environment(\.themeTokens) private var theme

    private struct Row: Identifiable {
        let id: String
        let title: String
        let shortcut: String
    }

    private var rows: [Row] {
        let words = filter.lowercased().split(separator: " ")
        return session.runtime.kernel.commands.all
            .map { command in
                // A key the command's view handles itself cannot be changed: it says so.
                let key = command.shortcut?.displayString ?? command.viewKey.map { "\($0.displayString) (in its view)" }
                return Row(id: command.id, title: command.title, shortcut: key ?? "")
            }
            .filter { row in words.allSatisfy { row.title.lowercased().contains($0) || row.id.contains($0) } }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    var body: some View {
        let rows = rows
        SettingsPage(title: String(localized: "Shortcuts")) {
            HStack(spacing: 8) {
                Image(symbol: "magnifyingglass").foregroundStyle(theme.secondaryText)
                TextField("Find a command", text: $filter)
                    .textFieldStyle(.plain)
                    .font(.ui(size: SettingsStyle.titleSize))
            }
            .padding(.horizontal, SettingsStyle.rowPadding)
            .frame(height: 36)
            .settingsGroup()
            SettingsSection(
                title: String(localized: "With a Shortcut"),
                subtitle: String(localized: "Change them in .loam/config.json under \"shortcuts\"; an editor will come here.")
            ) {
                ForEach(rows.filter { !$0.shortcut.isEmpty }) { row in
                    SettingsRow(title: row.title) { KeyCap(text: row.shortcut) }
                }
            }
            SettingsSection(title: String(localized: "Without One")) {
                ForEach(rows.filter { $0.shortcut.isEmpty }) { row in
                    SettingsRow(title: row.title)
                }
            }
        }
    }
}

/// A shortcut as menus print it (`⇧⌘K`), on a small key.
private struct KeyCap: View {
    let text: String
    @Environment(\.themeTokens) private var theme

    var body: some View {
        Text(text)
            .font(.ui(size: 12, weight: .medium))
            .foregroundStyle(theme.text.opacity(0.75))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(theme.background, in: .rect(cornerRadius: Corners.r(6), style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: Corners.r(6), style: .continuous).strokeBorder(theme.text.opacity(0.1)) }
    }
}
