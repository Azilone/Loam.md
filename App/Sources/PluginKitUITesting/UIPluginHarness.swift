import AppKit
import PluginKitTesting
import PluginKitUI
import LoamCore
import SwiftUI

public enum UIPluginHarnessError: Error, Equatable {
    case unknownCommand(id: String)
}

/// A kernel and plugin host on a `TemporaryVault`, with the shell's host services in place: what a UI plugin
/// test needs, without the app.
///
/// The host services (`ui.views`, `ui.panels`, `ui.note-headers`, `ui.workspace`, `ui.quick-pick`) go into the kernel before any
/// plugin activates, as the shell does: the real registries (`ViewRegistryStore`, `PanelRegistryStore`) and
/// recording fakes for the rest. Plugins are started with the lenient `apply(enabled: nil)`, so a plugin that
/// cannot start shows up in `report` instead of failing the whole harness. Plugin settings live in the temporary
/// vault's `.loam/config.json`; `setSettings` changes them as Settings does. Call `close()` at the end.
@MainActor
public final class UIPluginHarness {
    public let vault: TemporaryVault
    public let kernel: Kernel
    public let host: PluginHost
    public let views = ViewRegistryStore()
    public let panels = PanelRegistryStore()
    public let noteHeaders = NoteHeaderStore()
    public let windowOverlays = WindowOverlayStore()
    public let settingsSections = SettingsSectionStore()
    public let inspector = InspectorStore()
    public let resourceActions = ResourceActionStore()
    public let workspace = RecordingWorkspace()
    public let quickPick = RecordingQuickPick()
    public let toasts = RecordingToasts()
    public let commands = RecordingCommands()
    /// What starting the plugins did; `failed` and `skipped` say why a plugin is not active.
    public private(set) var report = ActivationReport()

    private var removeHostServices: [() -> Void] = []
    private var windows: [NSWindow] = []

    /// - Parameters:
    ///   - logicPlugins: plugins from the root package, such as `builtinPlugins`.
    ///   - uiPlugins: the plugins under test.
    ///   - files: vault-relative path to text, written before the plugins activate.
    ///   - editor: installed as the `editor` service when given. In the app a plugin provides it, so it is not
    ///     a host service by default.
    /// A vault config keeping daily notes flat in `Daily/` (`Daily/2026-10-02.md`), for tests written with that
    /// layout; the defaults sort them by month in `Journal/`.
    public static let flatDailyNotes = [
        ".loam/config.json": #"{"plugins":{"daily-notes":{"settings":{"folder":"Daily","subfolders":"none"}}}}"#,
    ]

    public init(
        logicPlugins: [Plugin.Type] = [],
        uiPlugins: [Plugin.Type],
        files: [String: String] = [:],
        editor: (any EditorService)? = nil
    ) throws {
        vault = try TemporaryVault()
        for (path, text) in files { try vault.write(path, text) }
        kernel = Kernel(vault: vault, config: try ConfigStore(vault: vault))
        host = PluginHost(kernel: kernel)

        let services = kernel.services
        removeHostServices = [
            try services.provide(.views, views as any ViewRegistry),
            try services.provide(.panels, panels as any PanelRegistry),
            try services.provide(.noteHeaders, noteHeaders as any NoteHeaderRegistry),
            try services.provide(.windowOverlays, windowOverlays as any WindowOverlayRegistry),
            try services.provide(.settingsSections, settingsSections as any SettingsSectionRegistry),
            try services.provide(.inspector, inspector as any InspectorRegistry),
            try services.provide(.resourceActions, resourceActions as any ResourceActionRegistry),
            try services.provide(.workspace, workspace as any Workspace),
            try services.provide(.quickPick, quickPick as any QuickPick),
            try services.provide(.toasts, toasts as any Toasts),
            try services.provide(.commands, commands as any CommandLauncher),
        ]
        if let editor { removeHostServices.append(try services.provide(.editor, editor)) }

        for plugin in logicPlugins + uiPlugins { try host.register(plugin) }
        report = host.apply(enabled: nil)
        settleLaunch()
    }

    /// Waits for what the plugins moved off the launch (the note graph's first read, `LaunchWork`), then lets the
    /// main queue run what they sent it, so a test sees the state the window shows a moment after launch. Inside a
    /// main-actor task the main queue cannot run here: those blocks run at the test's next `await`.
    public func settleLaunch() {
        let deadline = Date().addingTimeInterval(10)
        let graph = kernel.services.service(.noteGraph) as? NoteGraphLoading
        while graph?.isLoaded == false || LaunchWork.running > 0, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.002)
        }
        var flushed = false
        DispatchQueue.main.async { flushed = true }
        let flushDeadline = Date().addingTimeInterval(0.5)
        while !flushed, Date() < flushDeadline { RunLoop.main.run(until: Date().addingTimeInterval(0.005)) }
    }

    /// Stores a plugin's settings and sends `PluginSettingsChanged`, as its page in Settings does.
    public func setSettings(_ value: JSONValue, for id: String) throws {
        try kernel.config?.mutate { $0.setSettings(value, for: id) }
        kernel.events.emit(PluginSettingsChanged(pluginID: id))
    }

    /// Runs a registered command, as the palette or the CLI would.
    public func run(_ command: String, _ args: [String: String] = [:]) async throws -> String {
        guard let found = kernel.commands.command(id: command) else {
            throw UIPluginHarnessError.unknownCommand(id: command)
        }
        return try await found.handler(args)
    }

    /// Lays out `view` in a borderless offscreen window and returns its hosting view, so a test can check it
    /// builds and inspect its size. A window is used rather than `ImageRenderer`, which cannot draw AppKit
    /// views wrapped in SwiftUI (the editor is one). The window stays alive until `close()`.
    public func render(_ view: AnyView, size: CGSize = CGSize(width: 400, height: 300)) -> NSView {
        let hosting = NSHostingView(rootView: view)
        hosting.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(
            contentRect: CGRect(origin: CGPoint(x: -10_000, y: -10_000), size: size),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        windows.append(window)
        return hosting
    }

    /// Deactivates every plugin, then removes the host services, in the order the shell does.
    public func close() {
        host.deactivateAll()
        for remove in removeHostServices.reversed() { remove() }
        removeHostServices = []
        for window in windows { window.close() }
        windows = []
    }
}
