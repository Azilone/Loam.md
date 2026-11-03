import AppKit
import Foundation
import GitSyncPlugin
import PluginKitUI
import SwiftUI

/// The sync's place in the window: a status bar item (synced, syncing, offline, conflicts; "Sync off" opens Settings
/// to set it up), a section on the Git sync page in Settings, the app's focus passed to the sync (it checks the remote when the app comes to the front), and the
/// editor's state, so a pull never fights unsaved typing. The sync itself is the `git-sync` logic plugin.
public final class GitSyncUIPlugin: UIPlugin {
    public static let manifest = PluginManifest(
        id: "git-sync-ui",
        name: "Git sync status",
        version: "0.1.0",
        description: "Shows the sync status and runs a sync on demand.",
        icon: "arrow.triangle.2.circlepath.circle",
        requires: ["git-sync"],
        optionalRequires: ["editor"],
        permissions: ["ui", "vault.read", "vault.write"]
    )

    static let panelID = "git-sync.status"
    /// The Settings page the sync's section is on: the logic plugin's, where its settings are.
    static let settingsPageID = "git-sync"
    /// Internal: lets the tests reach the model. Not a contract.
    static var modelKey: ServiceKey<SyncStatusModel> { ServiceKey("git-sync-ui.model") }

    public init() {}

    @MainActor public func activateUI(context: PluginContext) throws {
        guard let service = context.service(.gitSync) else { throw GitSyncUIError.serviceMissing }
        let model = SyncStatusModel(
            service: service,
            panels: { [weak context] in context?.service(.panels) },
            workspace: { [weak context] in context?.workspace },
            quickPick: { [weak context] in context?.quickPick },
            openSettings: { [weak context] in context?.openSettings(pluginID: Self.settingsPageID) }
        )
        try context.provide(Self.modelKey, model)

        let settings = SyncSettingsModel(service: service, root: context.vault.rootURL)
        try context.addSettingsSection(SettingsSection(
            id: "git-sync.setup", pluginID: Self.settingsPageID, title: "Sync",
            subtitle: "Keep this vault the same on all your computers.", order: -1
        ) { AnyView(SyncSettingsView(model: settings)) })

        let bridge = EditorSyncBridge(root: context.vault.rootURL, pluginID: Self.manifest.id,
                                      editor: { [weak context] in context?.editor },
                                      emit: { [weak context] in context?.emit($0) })
        service.setEditorBridge(bridge)
        context.on(DocumentTextChanged.self) { [weak bridge] event in
            let path = event.path
            onMainThread { bridge?.typed(path) }
        }

        let stopObserving = service.observe { [weak model, weak settings] status in
            onMainThread {
                model?.update(status)
                settings?.update(status)
            }
        }
        let center = NotificationCenter.default
        let observers = [
            center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak model] _ in
                MainActor.assumeIsolated { model?.setForeground(true) }
            },
            center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak model] _ in
                MainActor.assumeIsolated { model?.setForeground(false) }
            },
        ]
        context.effect {
            stopObserving()
            for observer in observers { center.removeObserver(observer) }
            MainActor.assumeIsolated {
                service.setEditorBridge(nil)
                model.removePanel()
            }
        }

        model.update(service.status)
        model.setForeground(NSApplication.shared.isActive)
    }
}

enum GitSyncUIError: Error, Equatable {
    /// The host activates this plugin after `git-sync` (it is in `requires`), so this means a broken host.
    case serviceMissing
}

/// Runs main-actor code from an event listener, which Swift cannot prove runs on the main thread.
func onMainThread(_ body: @MainActor @Sendable () -> Void) {
    if Thread.isMainThread {
        MainActor.assumeIsolated { body() }
    } else {
        DispatchQueue.main.sync { MainActor.assumeIsolated { body() } }
    }
}
