import AppKit
import PluginKitUI
import SwiftUI

/// The vaults opened on this Mac, Obsidian's vault manager as a pane: open one, reveal it, take it off the list, or
/// make a new one. Opening replaces the vault in the window.
struct VaultsPane: View {
    let model: AppModel
    @Environment(\.themeTokens) private var theme

    private var currentPath: String? { model.session.map { VaultLibrary.path(of: $0.rootURL) } }

    var body: some View {
        SettingsPage(title: String(localized: "Vaults")) {
            SettingsSection(title: String(localized: "Add")) {
                SettingsRow(
                    title: String(localized: "Create new vault"),
                    detail: String(localized: "Makes an empty vault in a folder you choose.")
                ) {
                    SettingsAction(title: String(localized: "Create")) { model.createVault() }
                }
                SettingsRow(
                    title: String(localized: "Open folder as vault"),
                    detail: String(localized: "Choose an existing folder of Markdown notes.")
                ) {
                    SettingsAction(title: String(localized: "Open")) { model.chooseVault() }
                }
            }
            SettingsSection(
                title: String(localized: "On this Mac"),
                subtitle: String(localized: "The vaults you opened, the latest first.")
            ) {
                ForEach(model.library.entries) { entry in
                    row(entry)
                }
            }
        }
    }

    private func row(_ entry: VaultLibrary.Entry) -> some View {
        let isCurrent = entry.id == currentPath
        return SettingsRow(title: entry.name, detail: entry.url.path) {
            if isCurrent {
                Text("Open now")
                    .font(.ui(size: SettingsStyle.detailSize))
                    .foregroundStyle(theme.secondaryText)
            } else {
                SettingsAction(title: String(localized: "Open")) { model.openVault(entry.url) }
            }
            SettingsAction(title: String(localized: "Reveal in Finder")) {
                NSWorkspace.shared.activateFileViewerSelecting([entry.url])
            }
            if !isCurrent {
                SettingsAction(title: String(localized: "Remove from List")) { model.library.forget(entry.url) }
            }
        }
    }
}
