import AppKit
import PluginKitUI
import SwiftUI

/// The app's version, the open vault and safe mode.
struct AboutPane: View {
    let model: AppModel
    @Environment(\.themeTokens) private var theme

    private var version: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let short = info["CFBundleShortVersionString"] as? String ?? "dev"
        let build = info["CFBundleVersion"] as? String ?? ""
        return build.isEmpty ? short : "\(short) (\(build))"
    }

    var body: some View {
        SettingsPage(title: String(localized: "About")) {
            HStack(spacing: 16) {
                Image(nsImage: AppIcon.shared.image)
                    .resizable()
                    .frame(width: 64, height: 64)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Loam").font(.ui(size: 20, weight: .semibold)).foregroundStyle(theme.text)
                    Text("Version \(version)").font(.ui(size: SettingsStyle.detailSize)).foregroundStyle(theme.secondaryText)
                }
            }
            .padding(.horizontal, 6)
            .padding(.top, 8)
            AppUpdatesSection(model: model)
            // A development build sends nothing, so it has nothing to switch off.
            if model.analytics.isAvailable {
                SettingsSection(title: String(localized: "Privacy")) {
                    SettingsRow(
                        title: String(localized: "Send anonymous analytics"),
                        detail: String(localized: "Loam's version, your macOS and language, the built-in features you use and your note count as a range go to Loam's own server, with no identifier. Never your notes, files or names.")
                    ) {
                        SettingsSwitch(title: String(localized: "Send anonymous analytics"), isOn: Binding(
                            get: { model.analytics.isEnabled },
                            set: { model.analytics.isEnabled = $0 }
                        ))
                    }
                }
            }
            if model.canRun("intro.play") {
                SettingsSection(title: String(localized: "Intro")) {
                    SettingsRow(
                        title: String(localized: "Intro"),
                        detail: String(localized: "Plays the intro again over the whole screen.")
                    ) {
                        SettingsAction(title: String(localized: "Replay Intro")) { model.run("intro.play") }
                    }
                    if model.canRun(AppModel.onboardCommand) {
                        SettingsRow(
                            title: String(localized: "Onboarding"),
                            detail: String(localized: "Plays the first launch again: import, plugins, look and agent.")
                        ) {
                            SettingsAction(title: String(localized: "Replay Onboarding")) { model.run(AppModel.onboardCommand) }
                        }
                    }
                }
            }
            SettingsSection(title: String(localized: "Vault")) {
                if let session = model.session {
                    SettingsRow(title: session.name, detail: session.rootURL.path) {
                        SettingsAction(title: String(localized: "Reveal in Finder")) {
                            NSWorkspace.shared.activateFileViewerSelecting([session.rootURL])
                        }
                    }
                }
                SettingsRow(
                    title: String(localized: "Safe mode"),
                    detail: model.isSafeMode
                        ? String(localized: "On: only the essential plugins run.")
                        : String(localized: "Off. Hold Option while Loam opens to start with only the essential plugins.")
                ) {
                    if model.isSafeMode {
                        SettingsAction(title: String(localized: "Restart Normally")) { model.restartNormally() }
                    }
                }
            }
        }
    }
}
