import AppKit
import BuiltinPlugins
import BuiltinUIPlugins
import NotebookApp
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
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

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
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
