import PluginKitUI
import SwiftUI

/// Settings > Sidebars: a switch per panel, grouped by column, with the panel's display options under it. Off by default except the first panel of each
/// side column, so the window starts simple; choices go to `.loam/config.json` (`PanelVisibility`).
struct SidebarsPane: View {
    let session: ShellSession
    @State private var notice: String?
    @Environment(\.themeTokens) private var theme

    var body: some View {
        let visibility = session.panelVisibility
        SettingsPage(title: String(localized: "Sidebars")) {
            if let notice {
                SettingsNotice(text: notice, symbol: "exclamationmark.triangle")
            }
            column(.leading, title: String(localized: "Left Sidebar"), visibility: visibility)
            column(.trailing, title: String(localized: "Right Sidebar"), visibility: visibility)
            column(.statusBar, title: String(localized: "Status Bar"), visibility: visibility)
            SettingsSection {
                SettingsRow(
                    title: String(localized: "Simple layout"),
                    detail: String(localized: "Only the first panel of each sidebar, as when the vault was new.")
                ) {
                    SettingsAction(title: String(localized: "Restore")) { save { try visibility.reset() } }
                        .disabled(visibility.choices.isEmpty)
                }
            }
        }
        .onAppear { visibility.reload() }
    }

    @ViewBuilder
    private func column(_ slot: Slot, title: String, visibility: PanelVisibility) -> some View {
        let panels = session.panels.panels(in: slot)
        if !panels.isEmpty {
            SettingsSection(title: title) {
                ForEach(panels) { panel in
                    let shown = visibility.isShown(panel, among: panels)
                    SettingsRow(title: panel.title) {
                        Image(symbol: panel.symbol)
                            .font(.ui(size: 13))
                            .foregroundStyle(theme.secondaryText)
                            .frame(width: 18)
                    } trailing: {
                        SettingsSwitch(title: panel.title, isOn: Binding(
                            get: { shown },
                            set: { shown in save { try visibility.set(panel, shown: shown, among: panels) } }
                        ))
                    }
                    ForEach(panel.options) { option in
                        PanelOptionRow(option: option)
                            .padding(.leading, 30)
                            .disabled(!shown)
                    }
                }
            }
        }
    }

    private func save(_ change: () throws -> Void) {
        do {
            notice = nil
            try change()
        } catch {
            notice = String(localized: "Could not save: \(String(describing: error))")
        }
    }
}

/// A panel's display option; keeps its own copy of the value so the switch moves at once.
private struct PanelOptionRow: View {
    let option: PanelOption
    @State private var isOn: Bool?

    var body: some View {
        SettingsRow(title: option.title) {
            SettingsSwitch(title: option.title, isOn: Binding(
                get: { isOn ?? option.isOn() },
                set: { newValue in
                    isOn = newValue
                    option.set(newValue)
                }
            ))
        }
    }
}
