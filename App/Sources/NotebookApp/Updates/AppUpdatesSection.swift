import SwiftUI

/// Settings > About: the app's own updates, their channel and the daily check.
struct AppUpdatesSection: View {
    let model: AppModel
    @Environment(\.themeTokens) private var theme

    private var updater: AppUpdater { model.updater }

    private var status: String {
        if let reason = updater.unavailableReason { return reason }
        switch updater.state {
        case .idle: return String(localized: "Checks once a day.")
        case .checking: return String(localized: "Checking…")
        case .upToDate: return String(localized: "Loam \(updater.currentVersion) is the latest version.")
        case .downloading(let release): return String(localized: "Downloading Loam \(release.version)…")
        case .ready(let release): return String(localized: "Loam \(release.version) is ready. Restart to use it.")
        case .failed(let message): return message
        }
    }

    var body: some View {
        SettingsSection(title: String(localized: "Updates")) {
            SettingsRow(title: String(localized: "Loam updates"), detail: status, detailColor: statusColor) {
                switch updater.state {
                case .checking, .downloading:
                    ProgressView().controlSize(.small)
                case .ready:
                    SettingsAction(title: String(localized: "Restart to Update")) { model.installUpdate() }
                default:
                    SettingsAction(title: String(localized: "Check Now")) { Task { await updater.check() } }
                        .disabled(updater.unavailableReason != nil)
                }
            }
            if case .ready(let release) = updater.state, let notes = release.notes, !notes.isEmpty {
                Text(notes)
                    .font(.ui(size: SettingsStyle.detailSize))
                    .foregroundStyle(theme.secondaryText)
                    .textSelection(.enabled)
                    .padding(SettingsStyle.rowPadding)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            SettingsRow(
                title: String(localized: "Check automatically"),
                detail: String(localized: "Downloads new versions in the background; they install when you restart.")
            ) {
                SettingsSwitch(title: String(localized: "Check automatically"), isOn: Binding(
                    get: { updater.checksAutomatically },
                    set: { updater.checksAutomatically = $0 }
                ))
            }
            SettingsRow(
                title: String(localized: "Channel"),
                detail: String(localized: "Beta gets new versions first, before they are fully tested.")
            ) {
                Picker(String(localized: "Channel"), selection: Binding(
                    get: { updater.channel },
                    set: { channel in
                        updater.channel = channel
                        Task { await updater.check() }
                    }
                )) {
                    Text("Stable").tag(AppUpdater.Channel.stable)
                    Text("Beta").tag(AppUpdater.Channel.beta)
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
            }
        }
    }

    private var statusColor: Color? {
        switch updater.state {
        case .ready: return theme.accent
        case .failed: return .orange
        default: return nil
        }
    }
}
