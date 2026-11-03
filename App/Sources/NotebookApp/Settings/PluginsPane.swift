import AppKit
import PluginKit
import PluginKitUI
import SwiftUI

/// Settings > Plugins: the list of plugins (features, the services they build on, then the vault's own from
/// `.loam/plugins/`), each row opening the plugin's page. The logic is in `PluginManagerModel`; these views only
/// present it.
struct PluginsPane: View {
    @Bindable var model: PluginManagerModel
    let navigation: SettingsNavigation

    var body: some View {
        Group {
            if let id = navigation.pluginID, model.row(id) != nil {
                PluginPage(model: model, id: id, back: { navigation.back() }, open: { navigation.openPlugin($0) })
                    .id(id)
            } else {
                PluginList(model: model) { navigation.open(.plugins, plugin: $0) }
            }
        }
        .alert(
            disableTitle,
            isPresented: Binding(
                get: { model.confirmation != nil },
                set: { presented in if !presented { model.cancelConfirmation() } }
            ),
            presenting: model.confirmation
        ) { confirmation in
            Button("Turn Off", role: .destructive) {
                Task { await model.confirm(confirmation) }
            }
            // Return keeps everything on: turning off several plugins takes a click.
            Button("Cancel", role: .cancel) {}
                .keyboardShortcut(.defaultAction)
        } message: { confirmation in
            Text("Also turns off: \(confirmation.dependentNames.joined(separator: ", "))")
        }
        .alert(
            removeTitle,
            isPresented: Binding(
                get: { model.removeConfirmation != nil },
                set: { presented in if !presented { model.cancelRemove() } }
            ),
            presenting: model.removeConfirmation
        ) { confirmation in
            Button("Move to Trash", role: .destructive) {
                Task {
                    await model.confirmRemove(confirmation)
                    if model.row(confirmation.pluginID) == nil { navigation.open(.plugins) }
                }
            }
            Button("Cancel", role: .cancel) {}
                .keyboardShortcut(.defaultAction)
        } message: { _ in
            Text("Its folder in .loam/plugins/ and its build are moved to the Trash.")
        }
        .sheet(item: Binding(
            get: { model.enableConfirmation },
            set: { value in if value == nil { model.cancelEnable() } }
        )) { confirmation in
            EnableSheet(model: model, confirmation: confirmation)
        }
    }

    private var disableTitle: String {
        guard let confirmation = model.confirmation else { return "" }
        return String(localized: "Turn off \(confirmation.pluginName)?")
    }

    private var removeTitle: String {
        guard let confirmation = model.removeConfirmation else { return "" }
        return String(localized: "Remove \(confirmation.pluginName)?")
    }
}

/// The notices above the plugins: safe mode, the last action that did not go as asked, a build waiting for a relaunch.
private struct PluginNotices: View {
    let model: PluginManagerModel

    var body: some View {
        if model.isSafeMode {
            SettingsNotice(
                text: String(localized: "Safe mode: only the essential plugins run, and plugins from this vault are off."),
                symbol: "exclamationmark.shield"
            )
        }
        if let notice = model.notice {
            SettingsNotice(text: notice, symbol: "exclamationmark.triangle")
        }
        if !model.needsRelaunch.isEmpty { RelaunchNotice(model: model) }
    }
}

/// "Relaunch to load the new build", with the button that does it.
struct RelaunchNotice: View {
    let model: PluginManagerModel

    var body: some View {
        SettingsNotice(text: String(localized: "Relaunch to load the new build."), symbol: "arrow.clockwise.circle") {
            if let relaunch = model.relaunch {
                SettingsAction(title: String(localized: "Relaunch")) { relaunch() }
            }
        }
    }
}

struct PluginList: View {
    @Bindable var model: PluginManagerModel
    let open: (String) -> Void

    var body: some View {
        SettingsPage(title: String(localized: "Plugins")) {
            PluginNotices(model: model)
            DependenciesSection(model: model)
            SettingsSection(
                title: String(localized: "Features"),
                subtitle: String(localized: "What you see in the window. Each one can be turned off.")
            ) {
                ForEach(model.featureRows) { row in
                    PluginListRow(model: model, row: row) { open(row.id) }
                }
            }
            SettingsSection(
                title: String(localized: "Services"),
                subtitle: String(localized: "What the features build on. Turning one off also turns off the features that need it.")
            ) {
                ForEach(model.serviceRows) { row in
                    PluginListRow(model: model, row: row) { open(row.id) }
                }
            }
            SettingsSection(title: String(localized: "From This Vault"), subtitle: PluginManagerModel.explanation) {
                ForEach(PluginManagerModel.byName(model.vaultRows)) { row in
                    PluginListRow(model: model, row: row) { open(row.id) }
                }
                if model.vaultRows.isEmpty {
                    SettingsRow(
                        title: String(localized: "No plugins in .loam/plugins/ yet"),
                        detail: String(localized: "Install one from its Git URL, or start your own with loam plugin new.")
                    )
                }
                InstallField(model: model)
            }
            let available = model.catalog.filter { $0.installed == nil }
            if !available.isEmpty {
                SettingsSection(
                    title: String(localized: "Catalog"),
                    subtitle: String(localized: "Plugins shared by others, reviewed and pinned to the exact code that was checked.")
                ) {
                    ForEach(available) { plugin in CatalogRow(model: model, plugin: plugin) }
                }
            }
        }
        // A program installed (here, in the Terminal, by Apple's installer): the plugins that waited for it started.
        .onChange(of: model.toolSetup.revision) { Task { await model.refresh() } }
        // Asks the vault plugins' sources once per opening of Settings, when the daily check has not run yet.
        .task {
            await model.loadCatalog()
            if !model.vaultRows.isEmpty, model.updates.isEmpty { await model.checkForUpdates() }
        }
    }
}

/// A plugin in the list: its icon, its name, what it does (or why it is not running), its switch, and a chevron to
/// its page.
private struct PluginListRow: View {
    let model: PluginManagerModel
    let row: PluginStatusRow
    let open: () -> Void
    @State private var isHovered = false
    @Environment(\.themeTokens) private var theme

    var body: some View {
        HStack(spacing: 12) {
            Button { open() } label: {
                HStack(spacing: 12) {
                    PluginIconView(symbol: row.icon, imageURL: model.iconFileURL(of: row.id), size: 28)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(row.name)
                                .font(.ui(size: SettingsStyle.titleSize))
                                .foregroundStyle(theme.text.opacity(0.88))
                            if let update = model.availableUpdate(of: row.id), update.needsApp == nil {
                                Text("Update")
                                    .font(.ui(size: 10, weight: .semibold))
                                    .foregroundStyle(theme.accent)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 1)
                                    .background(theme.accent.opacity(0.12), in: ThemeCapsule())
                                    .help(String(localized: "\(update.latest ?? "") is available"))
                            }
                        }
                        let status = PluginStatusText(model: model, row: row)
                        // No empty second line: a plugin without a description is centred on its icon.
                        if let detail = status.text ?? row.description, !detail.isEmpty {
                            Text(detail.uiLocalized)
                                .font(.ui(size: SettingsStyle.detailSize))
                                .foregroundStyle(status.color ?? theme.secondaryText)
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 8)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint(Text("Opens its page"))
            if case .skipped(let reason) = row.state, PluginStatusText.missingTools(reason) != nil {
                if model.toolSetup.phase == .idle {
                    SettingsAction(title: String(localized: "Install")) { Task { await model.toolSetup.install() } }
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            EnabledSwitch(model: model, row: row)
            Button { open() } label: { SettingsChevron().padding(.vertical, 8).contentShape(Rectangle()) }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Open \(row.name)"))
        }
        .padding(.horizontal, SettingsStyle.rowPadding)
        .padding(.vertical, 8)
        .frame(minHeight: 52)
        .background(isHovered ? theme.text.opacity(0.03) : .clear)
        .onHover { isHovered = $0 }
    }
}

/// What a row says instead of its description when the plugin is not doing what its switch says, nil otherwise.
struct PluginStatusText {
    let text: String?
    let color: Color?

    /// The programs a plugin waits for, from the host's "needs ffmpeg, cwebp, not installed"; nil for another reason.
    static func missingTools(_ reason: String) -> String? {
        guard reason.hasPrefix("needs "), reason.hasSuffix(", not installed") else { return nil }
        return String(reason.dropFirst("needs ".count).dropLast(", not installed".count))
    }

    @MainActor
    init(model: PluginManagerModel, row: PluginStatusRow) {
        self.init(row: row, busy: model.busy[model.packageID(of: row.id)], offProviders: model.disabledProviders(of: row.id))
    }

    /// - Parameter offProviders: the turned-off plugins that provide what it requires.
    init(row: PluginStatusRow, busy: VaultActivity?, offProviders: [String] = []) {
        if let busy {
            text = busy.label
            color = nil
            return
        }
        switch row.state {
        case .active, .disabled:
            text = nil
            color = nil
        case .skipped(let reason) where reason.hasPrefix("safe mode"):
            text = String(localized: "Off in safe mode")
            color = nil
        case .skipped(let reason) where PluginStatusText.missingTools(reason) != nil:
            let tools = PluginStatusText.missingTools(reason) ?? ""
            text = String(localized: "Waiting for \(tools): install it in Dependencies")
            color = .orange
        case .skipped where !offProviders.isEmpty:
            text = String(localized: "Needs \(offProviders.joined(separator: ", ")), which is off.")
            color = .orange
        case .failed:
            text = row.state.label
            color = .red
        case .skipped, .inactive, .notLoaded:
            text = row.state.label
            color = .orange
        }
    }
}

struct EnabledSwitch: View {
    let model: PluginManagerModel
    let row: PluginStatusRow

    var body: some View {
        SettingsSwitch(title: String(localized: "Use \(row.name)"), isOn: Binding(
            get: { row.enabled },
            set: { enabled in Task { await model.setEnabled(enabled, id: row.id) } }
        ))
    }
}

private struct InstallField: View {
    @Bindable var model: PluginManagerModel

    var body: some View {
        HStack(spacing: 10) {
            Image(symbol: "arrow.down.circle")
                .font(.ui(size: 15))
                .foregroundStyle(.secondary)
                .frame(width: 28)
            TextField("Git URL of a plugin", text: $model.installURL)
                .textFieldStyle(.plain)
                .font(.ui(size: SettingsStyle.titleSize))
                .onSubmit { Task { await model.install() } }
            if model.isInstalling {
                ProgressView().controlSize(.small)
            }
            SettingsAction(title: String(localized: "Install")) {
                Task { await model.install() }
            }
            .disabled(!model.isAvailable(.install) || model.isInstalling
                || model.installURL.trimmingCharacters(in: .whitespaces).isEmpty)
            .help(model.unavailableHelp(.install) ?? String(localized: "Clones and builds it; it stays off until you enable it."))
        }
        .padding(.horizontal, SettingsStyle.rowPadding)
        .frame(minHeight: 48)
        .disabled(!model.isAvailable(.install))
        .help(model.unavailableHelp(.install) ?? "")
    }
}

/// A plugin of the catalog: what it does, who made it, what it asks for, and Install.
private struct CatalogRow: View {
    let model: PluginManagerModel
    let plugin: CatalogPlugin

    private var detail: String {
        var parts = [plugin.description ?? plugin.repo]
        if let author = plugin.author { parts.append(String(localized: "by \(author)")) }
        if let sdk = plugin.needsApp { parts.append(String(localized: "needs a newer Loam (plugin SDK \(sdk))")) }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        SettingsRow(title: "\(plugin.name) \(plugin.latest ?? "")", detail: detail) {
            if model.busy[plugin.id] != nil { ProgressView().controlSize(.small) }
            SettingsAction(title: String(localized: "Install")) {
                Task { await model.install(fromCatalog: plugin) }
            }
            .disabled(plugin.needsApp != nil || model.isInstalling)
            .help(DeclaredPermission.list(plugin.permissions).map(\.summary).joined(separator: ", "))
        }
    }
}

/// Icons and labels of what a plugin declares; high-risk ones in orange.
struct PermissionLabel: View {
    let permission: DeclaredPermission

    var body: some View {
        Label {
            Text(permission.summary)
                .fontWeight(permission.risk == .high ? .semibold : .regular)
        } icon: {
            Image(symbol: permission.symbol)
                .frame(width: 16)
        }
        .foregroundStyle(permission.risk == .high ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
        .help(permission.rawValue)
    }
}

/// Shown before a plugin from the vault runs: what it declares, and that it runs with the app's access.
private struct EnableSheet: View {
    let model: PluginManagerModel
    let confirmation: EnableConfirmation
    @Environment(\.themeTokens) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                PluginIconView(
                    symbol: model.row(confirmation.pluginID)?.icon,
                    imageURL: model.iconFileURL(of: confirmation.pluginID),
                    size: 40
                )
                Text(title.uiLocalized).font(.ui(.body, weight: .semibold))
            }
            if confirmation.permissions.isEmpty {
                Text("It declares no permissions.").foregroundStyle(.secondary)
            } else {
                Text("It says it will:").foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(confirmation.permissions) { permission in
                        PermissionLabel(permission: permission)
                    }
                }
                .padding(.leading, 4)
            }
            if !confirmation.highRisk.isEmpty {
                Label("Highlighted permissions can harm your Mac or your data if the plugin misbehaves.",
                      symbol: "exclamationmark.triangle")
                    .font(.ui(.caption))
                    .foregroundStyle(.orange)
            }
            Text(PluginManagerModel.explanation)
                .font(.ui(.caption))
                .foregroundStyle(.secondary)
            if let log = confirmation.buildLog {
                Text("It could not be built, so it cannot be enabled yet. Rebuild it from its page.")
                    .font(.ui(.label))
                    .foregroundStyle(theme.danger)
                Text(log)
                    .font(.ui(.caption).monospaced())
                    .lineLimit(12)
                    .textSelection(.enabled)
            }
            HStack {
                Spacer()
                Button(confirmation.justInstalled ? "Not Now" : "Cancel", role: .cancel) {
                    model.cancelEnable()
                }
                .keyboardShortcut(.cancelAction)
                Button("Enable") {
                    Task { await model.confirmEnable(confirmation) }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!confirmation.canEnable)
            }
        }
        .padding(20)
        .frame(width: 440)
    }

    private var title: String {
        confirmation.justInstalled
            ? String(localized: "\(confirmation.pluginName) is installed. Enable it now?")
            : String(localized: "Enable \(confirmation.pluginName)?")
    }
}

extension PluginState {
    var color: Color {
        switch self {
        case .active: return .green
        case .failed: return .red
        case .skipped, .notLoaded: return .orange
        case .disabled, .inactive: return .secondary
        }
    }
}

extension DeclaredPermission {
    /// The SF Symbol shown next to it.
    var symbol: String {
        switch self {
        case .unknown: return "questionmark.diamond"
        case .known(let permission):
            switch permission {
            case .vaultRead: return "doc.text"
            case .vaultWrite: return "square.and.pencil"
            case .diskRead: return "folder"
            case .localService: return "point.3.connected.trianglepath.dotted"
            case .network: return "network"
            case .shell: return "terminal"
            case .audio: return "waveform"
            case .clipboard: return "doc.on.clipboard"
            case .ui: return "macwindow"
            @unknown default: return "questionmark.diamond"
            }
        }
    }
}
