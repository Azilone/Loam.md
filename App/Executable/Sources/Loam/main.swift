import AppKit
import BuiltinPlugins
import BuiltinUIPlugins
import NotebookApp
import PluginKitUI
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // A frozen main thread leaves its stack in ~/Library/Logs/Loam/Hangs.
        HangWatchdog.start()
        // Lets `swift run` show a normal app with a Dock icon and a menu bar, not only the bundled .app.
        // An agent's instance (debug builds) stays out of the Dock and in the background: it must not take the focus.
        NSApp.setActivationPolicy(AgentInstance.startsInBackground ? .accessory : .regular)
        if !AgentInstance.startsInBackground { NSApp.activate() }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if let window = sender.windows.first(where: { AppModel.isNotebookWindow($0) }) {
            if window.isMiniaturized { window.deminiaturize(nil) }
            if !window.isVisible { window.makeKeyAndOrderFront(nil) }
        }
        return true
    }

    /// Resident mode (Settings > Appearance): closing the window keeps the vault open, so the capture shortcut and the
    /// menu-bar icon keep working; Dock, menu-bar "Open Loam" or a capture's Open bring the window back.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { !ResidentMode.keepsRunning }
}

struct LoamApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model: AppModel = {
        // Safe mode keeps the editor and the file explorer (the runtime adds what they require). The vault's own
        // plugins load once enabled in its config, never in safe mode.
        let configuration = ShellConfiguration(
            logicPlugins: builtinPlugins,
            uiPlugins: builtinUIPlugins,
            safeModePlugins: ["markdown-editor", "file-explorer", "files"],
            thirdPartyPlugins: true
        )
        let model = AppModel(configuration: configuration)
        model.openInitialVault()
        return model
    }()

    var body: some Scene {
        NotebookScene(model: model)
    }
}

LoamApp.main()
