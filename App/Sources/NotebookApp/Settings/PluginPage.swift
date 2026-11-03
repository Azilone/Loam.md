import AppKit
import PluginKit
import PluginKitUI
import SwiftUI

/// A plugin's own page in Settings > Plugins: its icon, name, version and what it does; its switch; its settings
/// when it has some (any plugin's, from `PluginManagerModel.settingFields`); for a plugin from the vault, its code;
/// then what it declares it does, what it needs and provides, and its id.
struct PluginPage: View {
    let model: PluginManagerModel
    let id: String
    let back: () -> Void
    /// Opens another plugin's page (one this one needs).
    let open: (String) -> Void
    /// The generic settings of a plugin that draws its own sections, folded until asked for.
    @State private var showsAdvanced = false
    @Environment(\.themeTokens) private var theme

    var body: some View {
        if let row = model.row(id) {
            SettingsPage(title: row.name, parent: String(localized: "Plugins"), back: back) {
                header(row)
                SettingsSection {
                    let status = PluginStatusText(model: model, row: row)
                    SettingsRow(title: String(localized: "Use \(row.name)"), detail: status.text, detailColor: status.color) {
                        EnabledSwitch(model: model, row: row)
                    }
                }
                if model.needsRelaunch.contains(model.packageID(of: id)) { RelaunchNotice(model: model) }
                if let notice = model.notice {
                    SettingsNotice(text: notice, symbol: "exclamationmark.triangle")
                }
                // Sections that matter more than the generic settings (`order` below 0) come before them.
                pluginSections(placedFirst: true)
                let fields = model.settingFields(for: id)
                // A plugin that draws its own settings keeps the raw ones out of the way.
                let folds = !model.session.settingsSections.sections(for: id).isEmpty
                if !fields.isEmpty, folds, !showsAdvanced {
                    Button {
                        withAnimation(Motion.resolved(Motion.Spring.standard.animation)) { showsAdvanced = true }
                    } label: {
                        Text(String(localized: "Advanced settings"))
                            .font(.ui(size: SettingsStyle.detailSize))
                            .foregroundStyle(theme.secondaryText)
                            .underline()
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 6)
                } else if !fields.isEmpty {
                    SettingsSection(
                        title: String(localized: "Settings"),
                        // Known from its manifest: they can be set before it runs.
                        subtitle: row.active ? nil : String(localized: "They apply once it runs.")
                    ) {
                        ForEach(fields) { field in
                            SettingFieldRow(model: model, pluginID: id, field: field)
                        }
                    }
                } else if !row.active, model.manifest(of: id)?.settings.isEmpty == false {
                    // Its defaults are known once it has run.
                    SettingsSection(title: String(localized: "Settings")) {
                        SettingsRow(
                            title: row.enabled
                                ? String(localized: "Its settings appear once it runs")
                                : String(localized: "Turn it on to change its settings"),
                            detail: row.enabled ? nil : String(localized: "They appear here once it runs.")
                        )
                    }
                }
                pluginSections(placedFirst: false)
                if row.isFromVault {
                    VaultPluginCode(model: model, row: row)
                }
                permissions(row)
                requirements
                SettingsSection(title: String(localized: "Details")) {
                    SettingsRow(title: String(localized: "Identifier")) {
                        Text(row.id)
                            .font(.system(size: SettingsStyle.detailSize, design: .monospaced))
                            .foregroundStyle(theme.secondaryText)
                            .textSelection(.enabled)
                    }
                    SettingsRow(title: String(localized: "Source")) {
                        // A plugin from the vault shows its folder under Code.
                        Text(row.isFromVault ? String(localized: "This vault") : String(localized: "Built into Loam"))
                            .font(.ui(size: SettingsStyle.detailSize))
                            .foregroundStyle(theme.secondaryText)
                    }
                }
            }
        }
    }

    /// What the plugin draws itself (`context.addSettingsSection`): those with a negative `order` above its settings,
    /// the others under them.
    @ViewBuilder
    private func pluginSections(placedFirst: Bool) -> some View {
        ForEach(model.session.settingsSections.sections(for: id).filter { ($0.order < 0) == placedFirst }) { section in
            VStack(alignment: .leading, spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(section.title.uiLocalized)
                        .font(.ui(size: SettingsStyle.titleSize, weight: .semibold))
                        .foregroundStyle(theme.text)
                    if !section.subtitle.isEmpty {
                        Text(section.subtitle.uiLocalized)
                            .font(.ui(size: SettingsStyle.detailSize))
                            .foregroundStyle(theme.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.horizontal, 6)
                section.makeView()
                    .settingsGroup()
            }
        }
    }

    private func header(_ row: PluginStatusRow) -> some View {
        HStack(alignment: .center, spacing: 18) {
            PluginIconView(symbol: row.icon, imageURL: model.iconFileURL(of: id), size: 64)
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(row.name)
                        .font(.ui(size: 20, weight: .semibold))
                        .foregroundStyle(theme.text)
                    if !row.version.isEmpty {
                        Text("Version \(row.version)")
                            .font(.ui(size: SettingsStyle.detailSize))
                            .foregroundStyle(theme.secondaryText)
                    }
                }
                if let description = row.description, !description.isEmpty {
                    Text(description)
                        .font(.ui(size: SettingsStyle.titleSize))
                        .foregroundStyle(theme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.horizontal, 6)
        .padding(.top, 8)
    }

    @ViewBuilder
    private func permissions(_ row: PluginStatusRow) -> some View {
        let permissions = model.permissions(of: id)
        SettingsSection(
            title: String(localized: "Permissions"),
            subtitle: row.isFromVault
                ? String(localized: "What it says it does. It runs with the same access as the app.")
                : String(localized: "What it says it does.")
        ) {
            ForEach(permissions) { permission in
                SettingsRow(
                    title: permission.summary,
                    detailColor: nil,
                    icon: {
                        Image(symbol: permission.symbol)
                            .font(.ui(size: 13))
                            .foregroundStyle(permission.risk == .high ? AnyShapeStyle(.orange) : AnyShapeStyle(theme.secondaryText))
                            .frame(width: 18)
                    },
                    trailing: {
                        if permission.risk == .high {
                            Text("High risk")
                                .font(.ui(size: 11, weight: .medium))
                                .foregroundStyle(.orange)
                        }
                    }
                )
                .help(permission.rawValue)
            }
            if permissions.isEmpty {
                SettingsRow(title: String(localized: "Declares no permissions"))
            }
        }
    }

    @ViewBuilder
    private var requirements: some View {
        let requirements = model.requirements(of: id)
        if !requirements.isEmpty {
            SettingsSection(title: String(localized: "Requirements")) {
                ForEach(requirements) { requirement in
                    let row = SettingsRow(
                        title: Self.title(requirement),
                        detail: Self.detail(requirement),
                        detailColor: requirement.kind == .needs && requirement.peers.isEmpty ? .orange : nil
                    ) {
                        if requirement.kind != .provides, requirement.peers.count == 1 { SettingsChevron() }
                    }
                    // The plugin it needs is one click away, to turn it on.
                    if requirement.kind != .provides, let peer = requirement.peers.first, requirement.peers.count == 1 {
                        Button { open(peer.id) } label: { row.contentShape(Rectangle()) }
                            .buttonStyle(.plain)
                            .accessibilityHint(Text("Opens its page"))
                    } else {
                        row
                    }
                }
            }
        }
    }

    private static func title(_ requirement: PluginRequirement) -> String {
        let names = requirement.names.joined(separator: ", ")
        switch requirement.kind {
        case .needs:
            return requirement.peers.isEmpty
                ? String(localized: "Needs \(requirement.service)")
                : String(localized: "Needs \(names)")
        case .uses:
            return requirement.peers.isEmpty
                ? String(localized: "Works with \(requirement.service)")
                : String(localized: "Works with \(names)")
        case .provides:
            return String(localized: "Provides \(requirement.service)")
        }
    }

    private static func detail(_ requirement: PluginRequirement) -> String {
        switch requirement.kind {
        case .needs:
            return requirement.peers.isEmpty
                ? String(localized: "No installed plugin provides it, so this one cannot start.")
                : String(localized: "The \(requirement.service) service. Does not start without it.")
        case .uses:
            return String(localized: "The \(requirement.service) service, when it is on.")
        case .provides:
            return requirement.peers.isEmpty
                ? String(localized: "A service for other plugins.")
                : String(localized: "Used by \(requirement.names.joined(separator: ", ")).")
        }
    }
}

/// A plugin from the vault: where its code is, building it again, and removing it.
private struct VaultPluginCode: View {
    let model: PluginManagerModel
    let row: PluginStatusRow
    @Environment(\.themeTokens) private var theme

    private var package: String { model.packageID(of: row.id) }

    var body: some View {
        SettingsSection(title: String(localized: "Code")) {
            VaultPluginVersion(model: model, row: row)
            SettingsRow(
                title: model.isNotBuilt(row) ? String(localized: "Not built yet") : String(localized: "Build"),
                detail: model.busy[package]?.label
                    ?? String(localized: "Compiled from its sources for this version of the app.")
            ) {
                if model.busy[package] != nil {
                    ProgressView().controlSize(.small)
                }
                SettingsAction(title: model.isNotBuilt(row) ? String(localized: "Build") : String(localized: "Rebuild")) {
                    Task { await model.rebuild(row.id) }
                }
                .disabled(!model.isAvailable(.build) || model.busy[package] != nil)
                .help(model.unavailableHelp(.build) ?? String(localized: "Compiles it again for this version of the app."))
            }
            if let log = model.buildFailures[package] {
                Text(log)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(theme.danger)
                    .textSelection(.enabled)
                    .lineLimit(12)
                    .padding(SettingsStyle.rowPadding)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            SettingsRow(title: String(localized: "Folder"), detail: model.folderPath(of: row.id)) {
                SettingsAction(title: String(localized: "Reveal in Finder")) {
                    NSWorkspace.shared.activateFileViewerSelecting([model.folderURL(of: row.id)])
                }
            }
            SettingsRow(title: String(localized: "Remove"), detail: String(localized: "Moves its folder and its build to the Trash.")) {
                SettingsAction(title: String(localized: "Remove…"), role: .destructive) {
                    model.requestRemove(row.id)
                }
                .disabled(!model.isAvailable(.remove) || model.busy[package] != nil)
                .help(model.unavailableHelp(.remove) ?? String(localized: "Moves it to the Trash."))
            }
        }
    }
}

/// The version a vault plugin runs, the newer one its source has, and the update, automatic updates and roll back.
private struct VaultPluginVersion: View {
    let model: PluginManagerModel
    let row: PluginStatusRow
    @Environment(\.themeTokens) private var theme

    private var package: String { model.packageID(of: row.id) }
    private var version: String { model.vaultManifests[package]?.version ?? "" }

    private var detail: String {
        if model.isCheckingUpdates { return String(localized: "Checking…") }
        guard let info = model.updates[package] else {
            return String(localized: "Installed from a folder: update it by installing it again.")
        }
        if let error = info.error { return String(localized: "Could not check: \(error)") }
        if info.updateAvailable, let sdk = info.needsApp {
            return String(localized: "\(info.latest ?? "") needs a newer Loam (plugin SDK \(sdk)).")
        }
        if info.updateAvailable { return String(localized: "\(info.latest ?? "") is available.") }
        return String(localized: "Up to date.")
    }

    var body: some View {
        let update = model.availableUpdate(of: row.id)
        SettingsRow(
            title: String(localized: "Version \(version)"),
            detail: detail,
            detailColor: update != nil && update?.needsApp == nil ? theme.accent : nil
        ) {
            if let update, update.needsApp == nil {
                SettingsAction(title: String(localized: "Update to \(update.latest ?? "")")) {
                    Task { await model.update(row.id) }
                }
                .disabled(!model.isAvailable(.update) || model.busy[package] != nil)
                .help(String(localized: "Downloads and builds it; the current version is kept for Roll Back."))
            } else if model.isUpdatable(row.id) || model.updates.isEmpty {
                SettingsAction(title: String(localized: "Check for Updates")) {
                    Task { await model.checkForUpdates() }
                }
                .disabled(!model.isAvailable(.outdated) || model.isCheckingUpdates)
            }
        }
        if let info = model.updates[package] {
            SettingsRow(
                title: String(localized: "Update automatically"),
                detail: String(localized: "Once a day, unless the update asks for a new permission.")
            ) {
                SettingsSwitch(title: String(localized: "Update automatically"), isOn: Binding(
                    get: { info.autoUpdate },
                    set: { on in Task { await model.setAutoUpdate(on, id: row.id) } }
                ))
            }
        }
        if model.hasPreviousVersion(row.id) {
            SettingsRow(title: String(localized: "Roll Back"), detail: String(localized: "Goes back to the version the last update replaced.")) {
                SettingsAction(title: String(localized: "Roll Back")) {
                    Task { await model.rollBack(row.id) }
                }
                .disabled(!model.isAvailable(.rollback) || model.busy[package] != nil)
            }
        }
    }
}
