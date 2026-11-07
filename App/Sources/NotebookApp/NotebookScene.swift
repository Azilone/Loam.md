import AppKit
import SwiftUI

/// The app's single window and its menus. The window shows the shell of the open vault; the menu items call
/// registered commands, so they do exactly what the palette and the CLI do.
public struct NotebookScene: Scene {
    let model: AppModel

    public init(model: AppModel) {
        self.model = model
    }

    public var body: some Scene {
        Window(AgentInstance.windowTitle, id: "main") {
            RootView(model: model)
                .frame(minWidth: 640, minHeight: 400)
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
                    model.reportSessionEnd()
                    model.closeVault()
                }
                .onAppear { model.windowDidAppear() }
        }
        // The tabs sit in the title bar row and take their own clicks (Craft's): no title bar behind them.
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1100, height: 760)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") {
                    model.session?.openSettings?(.about, nil)
                    Task { await model.updater.check() }
                }
                .disabled(model.updater.unavailableReason != nil)
            }
            CommandGroup(replacing: .newItem) {
                // The file explorer's command: without that plugin there is no New Note.
                // Cmd+N opens it in a new tab; the sidebar's "New Note" fills the focused tab.
                Button("New Note") { model.run("explorer.new-note-in-tab") }
                    .keyboardShortcut("n")
                    .disabled(!model.canRun("explorer.new-note-in-tab"))
                // Cmd+O is the quick switcher's, so opening a vault moves to Shift-Cmd-O.
                Button("Open Vault…") { model.chooseVault() }
                    .keyboardShortcut("o", modifiers: [.command, .shift])
                Button("New Vault…") { model.createVault() }
                Menu("Open Recent Vault") {
                    ForEach(model.library.entries) { entry in
                        Button(entry.name) { model.openVault(entry.url) }
                            .disabled(entry.id == model.session.map { VaultLibrary.path(of: $0.rootURL) })
                    }
                }
                .disabled(model.library.entries.count < 2)
                Divider()
                Button("New Tab") { model.run("workspace.new-tab") }
                    .keyboardShortcut("t")
                    .disabled(!model.canRun("workspace.new-tab"))
                // In the File menu, before the window's Close, so Cmd+W closes a tab first.
                Button("Close Tab") { model.closeTabOrWindow() }
                    .keyboardShortcut("w")
                Button("Reopen Closed Tab") { model.run("workspace.reopen-closed-tab") }
                    .keyboardShortcut("t", modifiers: [.command, .shift])
                    .disabled(model.session == nil)
            }
            // Cmd+P is the command palette, not Print.
            CommandGroup(replacing: .printItem) {
                Button("Command Palette…") { model.run("palette.open") }
                    .keyboardShortcut("p")
                    .disabled(model.session == nil)
            }
            CommandGroup(before: .sidebar) {
                Button("View Markdown Source") { model.run("editor.toggle-source") }
                    .keyboardShortcut("u", modifiers: [.command, .shift])
                    .disabled(!model.canRun("editor.toggle-source"))
                Divider()
                // Text zoom, a browser's: the board, the mind map and a picture take Cmd-+ and Cmd-- first, for
                // their own zoom, when they have the focus.
                Button("Zoom In") { model.session?.themes.zoomText(by: 1) }
                    .keyboardShortcut("+")
                    .disabled(model.session?.themes.canZoomTextIn != true)
                Button("Zoom Out") { model.session?.themes.zoomText(by: -1) }
                    .keyboardShortcut("-")
                    .disabled(model.session?.themes.canZoomTextOut != true)
                Button("Actual Size") { model.session?.themes.setTextZoom(1) }
                    .keyboardShortcut("0")
                    .disabled(model.session == nil)
                Divider()
                Button("Toggle Left Sidebar") { model.run("sidebar.toggle-leading") }
                    .disabled(model.session == nil)
                Button("Toggle Right Sidebar") { model.run("sidebar.toggle-trailing") }
                    .disabled(model.session == nil)
                Divider()
                Button("Split Right") { model.run("workspace.split-right") }
                    .disabled(model.session == nil)
                Button("Split Down") { model.run("workspace.split-down") }
                    .disabled(model.session == nil)
                Divider()
                // Always enabled with a vault, even with nowhere to go: a menu shortcut lets the focused view have
                // Cmd-[ first (the board's Send to Back), which a disabled item would hand to the shell instead.
                Button("Back") { model.run("workspace.back") }
                    .keyboardShortcut("[")
                    .disabled(model.session == nil)
                Button("Forward") { model.run("workspace.forward") }
                    .keyboardShortcut("]")
                    .disabled(model.session == nil)
                Divider()
            }
        }

        // Cmd+, opens it.
        Settings {
            SettingsView(model: model)
        }
    }
}

struct RootView: View {
    let model: AppModel
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Group {
            if let session = model.session {
                ShellWindow(session: session)
                    .id(ObjectIdentifier(session))
                    .onAppear {
                        let navigation = model.settingsNavigation
                        let open = openSettings
                        session.openSettings = { pane, plugin in
                            if let pane { navigation.open(pane, plugin: plugin) }
                            open()
                        }
                    }
                    .safeAreaInset(edge: .bottom, spacing: 0) {
                        if session.isSafeMode {
                            SafeModeBanner { model.restartNormally() }
                        }
                    }
            } else {
                OnboardingView(model: model)
            }
        }
        .alert(
            "Something went wrong",
            isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } }),
            presenting: model.errorMessage
        ) { _ in
            Button("OK") {}
        } message: { message in
            Text(message.uiLocalized)
        }
    }
}
