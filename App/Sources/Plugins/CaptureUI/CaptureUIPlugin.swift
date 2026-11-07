import AppKit
import CapturePlugin
import PluginKit
import PluginKitUI
import SwiftUI

/// Quick capture in the app: a shortcut that works from any app (⌃⌥Space by default) opens a small window already
/// holding what was copied; Enter saves it into the capture collection, then the user's agent titles, summarizes
/// and tags it while one line says what happened, with Open and Undo. Also a menu-bar icon (Loam keeps running
/// without its window) and a status-bar button. docs/design/CAPTURE-PLUGIN-PLAN.md.
public final class CaptureUIPlugin: UIPlugin {
    public static let manifest = PluginManifest(
        id: "capture-ui",
        name: "Quick capture in the app",
        version: "0.1.0",
        description: "A shortcut from any app saves what you copied, in one keystroke.",
        icon: "tray.and.arrow.down",
        requires: ["capture"],
        optionalRequires: ["assistant"],
        permissions: ["ui", "clipboard", "vault.read", "vault.write", "network"]
    )

    static let defaultShortcut = KeyShortcut("space", [.control, .option])
    static let introducedKey = "capture.introduced"

    /// Internal: lets the tests reach the model. Not a contract.
    static var modelKey: ServiceKey<CaptureModel> { ServiceKey("capture-ui.model") }

    private var hotkey: GlobalHotkey?
    private var windows: CaptureWindows?
    private var menuBar: MenuBarItem?

    public init() {}

    @MainActor public func activateUI(context: PluginContext) throws {
        guard let store = context.service(.capture) else { return }
        let model = CaptureModel(store: store)
        let windows = CaptureWindows(model: model)
        let hotkey = GlobalHotkey()
        self.windows = windows
        self.hotkey = hotkey
        try context.provide(Self.modelKey, model)

        model.settings = { store.currentSettings }
        model.run = { [weak context] id, arguments in
            guard let launcher = context?.service(.commands) else { return "" }
            return try await launcher.run(id, arguments: arguments)
        }
        model.isAvailable = { [weak context] id in context?.service(.commands)?.isAvailable(id) ?? false }
        model.readVault = { [weak context] path in try? context?.vault.read(path) }
        model.openNote = { [weak context] path in
            context?.workspace?.open(.file(path), placement: .newTab)
            Self.bringLoamForward()
        }
        model.openSettings = { [weak context] plugin in context?.openSettings(pluginID: plugin) }
        model.showWindow = { [weak windows] in windows?.show() }
        model.hideWindow = { [weak windows] in windows?.hide() }
        model.showLine = { [weak windows] in windows?.showLine() }
        model.shortcutText = { [weak context] in
            context?.service(.commands)?.shortcut(for: "capture.open") ?? "⌃⌥Space"
        }
        context.effect {
            MainActor.assumeIsolated {
                hotkey.tearDown()
                windows.tearDown()
            }
        }

        try context.registerCommand(Command(
            id: "capture.open",
            title: "Capture clipboard…",
            summary: "Opens the capture window holding what the clipboard has (a link, an image, a PDF, text or files); "
                + "Enter saves it into the capture collection. Opens a window, so it is for the palette and the "
                + "shortcut; from the command line or an agent use capture.add.",
            shortcut: Self.defaultShortcut
        ) { _ in
            await MainActor.run { model.open() }
            return ""
        })

        let actions = CaptureActions(context: context, store: store)
        try context.registerCommand(Command(
            id: "capture.show-recent",
            title: "Recent captures",
            summary: "Lists this session's captures in a popup; picking one opens its note. For the palette; from the "
                + "command line or an agent use capture.recent."
        ) { _ in
            await actions.showRecent()
            return ""
        })

        try context.registerCommand(Command(
            id: "capture.choose-collection",
            title: "Choose the capture collection…",
            summary: "Lists the vault's folders in a popup, plus a new one; captures then go into the one "
                + "picked. For the palette; from the command line or an agent use capture.set-collection."
        ) { _ in
            await actions.chooseCollection()
            return ""
        })

        // A status bar button, so the feature is visible and clickable in the window.
        try context.registerPanel(Panel(id: "capture.status", title: "Capture", symbol: "tray.and.arrow.down", slot: .statusBar, order: 5) {
            AnyView(CaptureStatusButton(shortcut: { model.shortcutText() }) { model.open() })
        })

        // The shortcut from any app: the command's own, so Settings > Shortcuts changes it.
        let register = { [weak context, weak hotkey] in
            guard let hotkey else { return }
            let text = context?.service(.commands)?.shortcut(for: "capture.open")
            let shortcut = text.flatMap(GlobalHotkey.shortcut(display:)) ?? (text == nil ? Self.defaultShortcut : nil)
            hotkey.register(shortcut) { model.open() }
        }
        // The commands are in place once every plugin has activated.
        DispatchQueue.main.async { register() }
        context.on(PluginSettingsChanged.self) { _ in DispatchQueue.main.async { register() } }

        let menuBar = MenuBarItem(model: model)
        self.menuBar = menuBar
        context.effect { MainActor.assumeIsolated { menuBar.remove() } }

        Self.introduceOnce(context)
    }

    // MARK: Helpers

    /// Brings the window back (resident mode may have closed it) and Loam to the front: what a Dock click does.
    @MainActor static func bringLoamForward() {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration)
        NSApp.activate()
    }

    /// One toast, the first time: the shortcut is the whole interface.
    @MainActor static func introduceOnce(_ context: PluginContext) {
        guard !UserDefaults.standard.bool(forKey: introducedKey) else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak context] in
            guard let context, let toasts = context.toasts else { return }
            UserDefaults.standard.set(true, forKey: introducedKey)
            let key = context.service(.commands)?.shortcut(for: "capture.open") ?? "⌃⌥Space"
            toasts.show("Press \(key) in any app to save what you copied.", kind: .info)
        }
    }

    static func symbol(_ kind: CaptureKind) -> String {
        switch kind {
        case .link: "link"
        case .image: "photo"
        case .pdf: "doc.richtext"
        case .text: "text.alignleft"
        case .file: "doc"
        }
    }
}

/// The two palette popups. Main-actor, so the commands (which must be `Sendable`) can hold it while the plugin
/// context, which is not, stays on the main actor.
@MainActor
final class CaptureActions {
    private weak var context: PluginContext?
    private let store: CaptureStore

    init(context: PluginContext, store: CaptureStore) {
        self.context = context
        self.store = store
    }

    func showRecent() {
        guard let context, let quickPick = context.quickPick else { return }
        let items = store.recent().map {
            QuickPickItem(id: $0.path, title: $0.title, subtitle: VaultPath.directory(of: $0.path), symbol: CaptureUIPlugin.symbol($0.kind))
        }
        quickPick.show(
            placeholder: items.isEmpty ? "No captures yet" : "Recent captures",
            items: { query in Fuzzy.rank(items, query: query) { $0.title } },
            choose: { [weak context] item in context?.workspace?.open(.file(item.id), placement: .newTab) }
        )
    }

    func chooseCollection() {
        guard let context, let quickPick = context.quickPick else { return }
        let current = store.folder
        let folders = Self.folders(in: context.vault)
        var items = folders.map {
            QuickPickItem(id: $0, title: $0, subtitle: $0 == current ? "Captures go here" : nil, symbol: "folder")
        }
        if !folders.contains(current) {
            items.insert(QuickPickItem(id: current, title: current, subtitle: "Captures go here (created at the next capture)", symbol: "folder"), at: 0)
        }
        quickPick.show(
            placeholder: "Choose a folder, or type a new name",
            items: { query in
                let ranked = Fuzzy.rank(items, query: query) { $0.title }
                let typed = query.trimmingCharacters(in: .whitespaces)
                guard !typed.isEmpty, !folders.contains(typed) else { return ranked }
                return ranked + [QuickPickItem(id: typed, title: "New collection “\(typed)”", symbol: "plus")]
            },
            choose: { [weak self] item in self?.setCollection(item.id) }
        )
    }

    /// Every folder of the vault, depth first, a few levels deep: a collection can sit in a subfolder.
    private static func folders(in vault: VaultAccess, under folder: String = "", depth: Int = 0) -> [String] {
        guard depth < 5, let entries = try? vault.list(folder) else { return [] }
        return entries.filter(\.isFolder).flatMap { [$0.path] + folders(in: vault, under: $0.path, depth: depth + 1) }
    }

    private func setCollection(_ folder: String) {
        guard let context, let launcher = context.service(.commands) else { return }
        Task { @MainActor [weak context] in
            let answer = (try? await launcher.run("capture.set-collection", arguments: ["path": folder])) ?? ""
            context?.toasts?.show(answer, kind: .success)
        }
    }
}

/// The status bar's capture button: the icon, the shortcut in its tooltip.
private struct CaptureStatusButton: View {
    let shortcut: () -> String
    let action: () -> Void
    @Environment(\.statusStyle) private var style

    /// Only as its own icon: capture has no state to show as the dot on the vault's icon or in its menu.
    var body: some View {
        if style == .item {
            Button(action: action) {
                Image(systemName: "tray.and.arrow.down")
            }
            .buttonStyle(.plain)
            .help("Capture clipboard (\(shortcut()))")
            .accessibilityLabel("Capture clipboard")
        }
    }
}

/// Loam's icon in the menu bar while it runs, with or without its window: capture, open the window, quit.
@MainActor
final class MenuBarItem: NSObject {
    private var item: NSStatusItem?
    private let model: CaptureModel

    init(model: CaptureModel) {
        self.model = model
        super.init()
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "tray.and.arrow.down", accessibilityDescription: "Loam")
        item.button?.toolTip = "Loam"
        let menu = NSMenu()
        menu.addItem(withTitle: "Capture Clipboard", action: #selector(capture), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Recent Captures", action: #selector(recent), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Open Loam", action: #selector(openLoam), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Quit Loam", action: #selector(quit), keyEquivalent: "q").target = self
        menu.delegate = self
        item.menu = menu
        self.item = item
    }

    func remove() {
        if let item { NSStatusBar.system.removeStatusItem(item) }
        item = nil
    }

    @objc private func capture() { model.open() }
    @objc private func openLoam() { CaptureUIPlugin.bringLoamForward() }
    @objc private func quit() { NSApp.terminate(nil) }
    @objc private func recent() {
        CaptureUIPlugin.bringLoamForward()
        Task { _ = try? await model.run("capture.show-recent", [:]) }
    }
}

extension MenuBarItem: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.items.first?.title = "Capture Clipboard  \(model.shortcutText())"
    }
}
