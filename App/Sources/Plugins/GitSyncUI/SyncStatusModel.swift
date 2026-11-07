import Foundation
import GitSyncPlugin
import Observation
import PluginKitUI
import SwiftUI

/// The status bar item's state, and what a click on it offers.
@MainActor
@Observable
final class SyncStatusModel {
    private(set) var status = SyncStatus.off
    /// What the last syncs that brought changes in brought, by device, newest first: kept after quieter syncs.
    private(set) var recent: [SyncStatus.DeviceChanges] = []
    @ObservationIgnored private let service: GitSyncService
    @ObservationIgnored private let panels: () -> (any PanelRegistry)?
    @ObservationIgnored private let workspace: () -> (any Workspace)?
    @ObservationIgnored private let quickPick: () -> (any QuickPick)?
    @ObservationIgnored private let openSettings: () -> Void
    @ObservationIgnored private var removeRegisteredPanel: (@MainActor () -> Void)?

    init(service: GitSyncService, panels: @escaping () -> (any PanelRegistry)?,
         workspace: @escaping () -> (any Workspace)?, quickPick: @escaping () -> (any QuickPick)?,
         openSettings: @escaping () -> Void = {}) {
        self.service = service
        self.panels = panels
        self.workspace = workspace
        self.quickPick = quickPick
        self.openSettings = openSettings
    }

    var isShowingPanel: Bool { removeRegisteredPanel != nil }

    /// The item always shows: "Sync off" is how someone who never set sync up finds it.
    func update(_ status: SyncStatus) {
        self.status = status
        if !status.incoming.isEmpty {
            let devices = Set(status.incoming.map(\.device))
            recent = status.incoming + recent.filter { !devices.contains($0.device) }
        }
        if removeRegisteredPanel == nil, let registry = panels() {
            removeRegisteredPanel = registry.register(Panel(
                id: GitSyncUIPlugin.panelID, title: "Sync", symbol: "arrow.triangle.2.circlepath", slot: .statusBar,
                order: 100
            ) { [weak self] in
                guard let self else { return AnyView(EmptyView()) }
                return AnyView(SyncStatusItem(model: self))
            })
        }
    }

    func removePanel() {
        removeRegisteredPanel?()
        removeRegisteredPanel = nil
    }

    func setForeground(_ isForeground: Bool) {
        service.setForeground(isForeground)
    }

    func syncNow() {
        service.requestSync()
    }

    /// A click on the item: Settings while sync is off; else sync now, open a conflict copy to merge it by hand, or
    /// open Settings.
    func showMenu() {
        if status.state == .off { return openSettings() }
        let sync = QuickPickItem(id: "sync", title: "Sync now", subtitle: status.message ?? details,
                                 symbol: "arrow.triangle.2.circlepath")
        let copies = status.conflicts.map { path in
            QuickPickItem(id: "open:" + path, title: "Open " + (path.split(separator: "/").last.map(String.init) ?? path),
                          subtitle: "Conflict copy: the other version of a note changed on two devices",
                          symbol: "doc.on.doc")
        }
        let changes = recent.map { change in
            QuickPickItem(id: "device:" + change.device, title: change.summary,
                          subtitle: change.files.prefix(3).map { String($0.split(separator: "/").last ?? "") }
                              .joined(separator: ", ") + (change.files.count > 3 ? "…" : ""),
                          symbol: "person.crop.circle")
        }
        let settings = QuickPickItem(id: "settings", title: "Sync settings…", subtitle: "Repository, encryption, "
                                     + "automatic sync", symbol: "gearshape")
        quickPick()?.show(placeholder: "Sync", items: { query in
            let all = [sync] + copies + changes + [settings]
            return query.isEmpty ? all : all.filter { $0.title.localizedCaseInsensitiveContains(query) }
        }, choose: { [weak self] item in
            guard let self else { return }
            if item.id == "sync" { return syncNow() }
            if item.id == "settings" { return openSettings() }
            if item.id.hasPrefix("device:") { return showChanges(of: String(item.id.dropFirst("device:".count))) }
            if item.id.hasPrefix("open:") {
                workspace()?.open(.file(String(item.id.dropFirst("open:".count))), placement: .newTab)
            }
        })
    }

    /// The files one device changed, to open one.
    func showChanges(of device: String) {
        guard let change = recent.first(where: { $0.device == device }) else { return }
        let items = change.files.map { path in
            QuickPickItem(id: path, title: String(path.split(separator: "/").last ?? ""), subtitle: path,
                          symbol: "doc.text")
        }
        quickPick()?.show(placeholder: change.summary, items: { query in
            query.isEmpty ? items : items.filter { $0.subtitle?.localizedCaseInsensitiveContains(query) == true }
        }, choose: { [weak self] item in
            self?.workspace()?.open(.file(item.id), placement: .newTab)
        })
    }

    var symbol: String {
        switch status.state {
        case .off: return "arrow.triangle.2.circlepath"
        case .syncing: return "arrow.triangle.2.circlepath"
        case .offline: return "wifi.slash"
        case .attention: return "exclamationmark.triangle"
        case .synced: return status.conflicts.isEmpty ? "checkmark.circle" : "doc.on.doc"
        }
    }

    /// The tooltip: what is wrong if anything, then where things stand.
    var details: String {
        var lines: [String] = []
        if let message = status.message { lines.append(message) }
        if let remote = status.remoteURL ?? status.remote { lines.append("Remote: \(remote)") }
        if let lastSync = status.lastSync {
            lines.append("Last sync: " + lastSync.formatted(.relative(presentation: .named)))
        }
        if let ahead = status.ahead, ahead > 0 { lines.append("\(ahead) commit\(ahead == 1 ? "" : "s") to push") }
        lines += recent.prefix(3).map(\.summary)
        lines += status.warnings
        return lines.joined(separator: "\n")
    }
}

/// The status bar item: one icon, sized as the sidebar footer's others, its state in the symbol and its colour (orange
/// when it needs attention) and in the tooltip; a click offers "Sync now" and the conflict copies.
struct SyncStatusItem: View {
    let model: SyncStatusModel
    @Environment(\.themeTokens) private var theme
    @Environment(\.statusStyle) private var style

    var body: some View {
        switch style {
        case .item: item
        case .dot: dot(ring: true)
        case .detail:
            HStack(spacing: 6) {
                dot(ring: false)
                Text(detailText).font(.ui(size: 11.5)).foregroundStyle(theme.secondaryText)
            }
        }
    }

    /// The menu's few words: when the last sync was while all is well, else the state.
    private var detailText: String {
        if model.status.state == .synced, model.status.conflicts.isEmpty, let lastSync = model.status.lastSync {
            return lastSync.formatted(.relative(presentation: .named))
        }
        return model.status.label
    }

    /// The state as a dot: green when synced, amber while syncing, orange when it needs the user, grey when offline;
    /// nothing while sync is off.
    private var dotColor: Color? {
        switch model.status.state {
        case .off: nil
        case .synced: model.status.conflicts.isEmpty ? Color(red: 0.30, green: 0.76, blue: 0.54) : .orange
        case .syncing: Color(red: 0.90, green: 0.77, blue: 0.35)
        case .offline: theme.secondaryText
        case .attention: .orange
        }
    }

    /// `ring`: a ring in the sidebar's colour cuts the dot out of the icon it sits on.
    @ViewBuilder private func dot(ring: Bool) -> some View {
        if let dotColor {
            Circle().fill(dotColor)
                .frame(width: 8, height: 8)
                .padding(ring ? 2.5 : 0)
                .background(Circle().fill(ring ? theme.sidebarGround(selected: false) : .clear))
                .accessibilityLabel(model.status.label)
        }
    }

    private var item: some View {
        Button(action: model.showMenu) {
            Image(symbol: model.symbol)
                .symbolEffect(.rotate, options: .repeating, isActive: model.status.state == .syncing)
                .font(.ui(size: 15))
                .foregroundStyle(model.status.state == .attention ? AnyShapeStyle(.orange) : AnyShapeStyle(theme.secondaryText))
                .frame(width: 24, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(model.details.isEmpty ? model.status.label : model.details)
        .accessibilityLabel(model.status.label)
    }
}
