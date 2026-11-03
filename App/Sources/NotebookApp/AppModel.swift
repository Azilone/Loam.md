import AppKit
import Foundation
import Observation

/// The app around the shell: which vault is open, and the errors to show. Everything inside a vault belongs to its
/// `ShellSession` and the plugins it hosts.
@MainActor
@Observable
public final class AppModel {
    public private(set) var session: ShellSession?
    public var errorMessage: String?
    /// Where the settings window is, kept while the app runs so it opens where it was left.
    @ObservationIgnored public let settingsNavigation = SettingsNavigation()
    /// Keeps the app itself up to date (Updates/AppUpdater.swift).
    @ObservationIgnored public let updater = AppUpdater()
    /// Anonymous launch statistics, off in Settings > About (Analytics/AppAnalytics.swift).
    public let analytics = AppAnalytics()

    /// The vaults opened on this Mac, for the switcher in the sidebar and Settings > Vaults.
    public let library: VaultLibrary

    @ObservationIgnored let configuration: ShellConfiguration
    @ObservationIgnored var launchGuard: LaunchGuard
    /// How long the window must stay up before a launch counts as successful for the launch guard.
    @ObservationIgnored let launchConfirmationDelay: Duration
    @ObservationIgnored private var confirmationTask: Task<Void, Never>?
    /// The vault whose launch waits for the window to appear before its confirmation is scheduled.
    @ObservationIgnored private var launchAwaitingWindow: URL?
    /// Stops listening to the first launch's onboarding (`AppModel+Onboarding`).
    @ObservationIgnored var onboardingListener: (() -> Void)?

    static let lastVaultKey = "lastVaultPath"

    public init(
        configuration: ShellConfiguration,
        launchGuard: LaunchGuard = LaunchGuard(),
        launchConfirmationDelay: Duration = .seconds(5),
        library: VaultLibrary? = nil
    ) {
        self.library = library ?? VaultLibrary()
        self.configuration = configuration
        self.launchGuard = launchGuard
        self.launchConfirmationDelay = launchConfirmationDelay
    }

    /// True when the open vault runs only the safe mode plugins.
    public var isSafeMode: Bool { session?.isSafeMode ?? false }

    // MARK: Vault

    /// Opens the vault given by `--vault <path>`, or else the last one opened. It opens in safe mode when Option is
    /// held, `--safe-mode` is passed, or the last two launches on that vault did not get going (`LaunchGuard`).
    public func openInitialVault(
        arguments: [String] = CommandLine.arguments,
        optionHeld: Bool = NSEvent.modifierFlags.contains(.option)
    ) {
        var url: URL?
        if let index = arguments.firstIndex(of: "--vault"), index + 1 < arguments.count {
            let path = (arguments[index + 1] as NSString).expandingTildeInPath
            url = URL(fileURLWithPath: path, isDirectory: true)
        } else if let path = UserDefaults.standard.string(forKey: Self.lastVaultKey), isFolder(path) {
            url = URL(fileURLWithPath: path, isDirectory: true)
        }
        guard let url else { return startFirstRun() }
        guard isFolder(url.path) else { return openVault(url) }
        let forced = optionHeld || arguments.contains("--safe-mode")
        let safeMode = launchGuard.willLaunch(vault: Self.guardKey(url), optionHeld: forced)
        openVault(url, safeMode: safeMode)
        launchAwaitingWindow = url
    }

    /// Called when the main window appears: the launch counts as successful `launchConfirmationDelay` later.
    public func windowDidAppear() {
        updater.start()
        analytics.reportLaunch()
        guard let url = launchAwaitingWindow else { return }
        launchAwaitingWindow = nil
        scheduleLaunchConfirmation(for: url)
    }

    /// Re-opens the vault with every enabled plugin and forgets the failed launches. The layout is saved and
    /// restored, so the open tabs stay.
    public func restartNormally() {
        guard let url = session?.rootURL else { return }
        launchGuard.didLaunchSuccessfully(vault: Self.guardKey(url))
        // The full set of plugins may be what crashes: this start counts until it is confirmed too.
        _ = launchGuard.willLaunch(vault: Self.guardKey(url), optionHeld: false)
        openVault(url, safeMode: false)
        scheduleLaunchConfirmation(for: url)
    }

    /// True when the app runs from its bundle with a vault open, so `relaunch` can start it again.
    public var canRelaunch: Bool {
        session != nil && Bundle.main.bundleURL.pathExtension == "app"
    }

    /// Installs the downloaded update: the vault is closed first, so the layout is saved, then the app quits and the new
    /// version opens on the same vault.
    public func installUpdate() {
        let vault = session?.rootURL
        do {
            closeVault()
            try updater.installAndRelaunch(vault: vault)
        } catch {
            errorMessage = error.localizedDescription
            if let vault { openVault(vault) }
        }
    }

    /// Opens a new instance of the app on the same vault, then quits: a plugin rebuilt while its old code is loaded
    /// runs only in a new process (code cannot be unloaded). The vault is closed first, so the layout is saved.
    public func relaunch() {
        guard canRelaunch, let url = session?.rootURL else { return }
        closeVault()
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        configuration.arguments = ["--vault", url.path]
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { [weak self] _, error in
            let message = error.map { String(describing: $0) }
            Task { @MainActor in
                guard let message else { return NSApp.terminate(nil) }
                self?.errorMessage = String(localized: "Could not relaunch: \(message)")
                self?.openVault(url)
            }
        }
    }

    /// Marks the launch as successful once the window has been up for `launchConfirmationDelay`.
    func scheduleLaunchConfirmation(for url: URL) {
        confirmationTask?.cancel()
        let delay = launchConfirmationDelay
        confirmationTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            self.launchGuard.didLaunchSuccessfully(vault: Self.guardKey(url))
        }
    }

    static func guardKey(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }

    public func chooseVault() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = String(localized: "Open")
        panel.message = String(localized: "Choose a folder of Markdown notes.")
        if panel.runModal() == .OK, let url = panel.url { openVault(url) }
    }

    /// Asks for a name and a folder to put it in, then makes that empty vault and opens it. A vault made here starts
    /// empty: the demo vault is the first launch's.
    public func createVault() {
        let field = NSTextField(string: String(localized: "Untitled"))
        field.frame = NSRect(x: 0, y: 0, width: 240, height: 22)
        let label = NSTextField(labelWithString: String(localized: "Vault name:"))
        let stack = NSStackView(views: [label, field])
        stack.spacing = 8
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents", isDirectory: true)
        panel.prompt = String(localized: "Create")
        panel.message = String(localized: "Choose where the new vault goes.")
        panel.accessoryView = stack
        panel.isAccessoryViewDisclosed = true
        guard panel.runModal() == .OK, let parent = panel.url else { return }
        createVault(named: field.stringValue, in: parent)
    }

    /// Makes the folder `name` in `parent` (a folder that is already there is opened as it is) and opens it.
    func createVault(named name: String, in parent: URL) {
        guard VaultLibrary.isValidName(name) else {
            errorMessage = String(localized: "A vault name cannot be empty or contain \"/\" or \":\".")
            return
        }
        let folder = parent.appendingPathComponent(name.trimmingCharacters(in: .whitespacesAndNewlines), isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            errorMessage = String(localized: "Could not create the vault: \(error.localizedDescription)")
            return
        }
        openVault(folder)
    }

    public func openVault(_ url: URL, safeMode: Bool = false) {
        guard isFolder(url.path) else {
            errorMessage = String(localized: "Folder not found: \(url.path)")
            return
        }
        closeVault()
        do {
            let session = try ShellSession(rootURL: url, configuration: configuration, safeMode: safeMode)
            session.startWatching()
            session.startPluginUpdateChecks()
            // Offers to install what an enabled plugin is missing, once the window is up.
            session.toolSetup.start(offer: true)
            session.host = self
            self.session = session
            library.remember(url)
            listenForVaultMoves()
            ScriptDriver.startIfAsked(settings: settingsNavigation) { [weak self] in self?.session }
            AppChannelBridge.start(self)
            #if DEBUG || LOAM_AGENT_BRIDGE
            DebugBridge.startIfAsked(settings: settingsNavigation) { [weak self] in self?.session }
            #endif
            UserDefaults.standard.set(url.path, forKey: Self.lastVaultKey)
        } catch {
            errorMessage = String(localized: "Could not open the vault: \(String(describing: error))")
        }
    }

    /// Saves the layout and stops the plugins, which save their pending work. Called on quit too.
    public func closeVault() {
        AppChannelBridge.stop()
        session?.close()
        session = nil
    }

    // MARK: Commands

    /// Runs a registered command for a menu item, showing what went wrong if it fails.
    public func run(_ commandID: String) {
        guard let session else { return }
        Task {
            do {
                _ = try await session.run(commandID)
            } catch ShellError.unknownCommand {
                NSSound.beep()
            } catch {
                errorMessage = String(localized: "\(commandID) failed: \(String(describing: error))")
            }
        }
    }

    /// True when a vault is open and one of its plugins registered `commandID`, for enabling a menu item.
    public func canRun(_ commandID: String) -> Bool {
        session?.runtime.kernel.commands.command(id: commandID) != nil
    }

    /// File > Close Tab: closes the active tab, or the window when no tab is open, as browsers do. In another window
    /// (Settings), Cmd+W closes that window, not a tab of the notebook behind it.
    public func closeTabOrWindow() {
        if let key = NSApp.keyWindow {
            switch Self.closeTarget(for: key) {
            case .window: key.performClose(nil); return
            case .nothing: return
            case .tab: break
            }
        }
        guard let session, session.workspace.layout.activeTab != nil else {
            NSApp.keyWindow?.performClose(nil)
            return
        }
        run("workspace.close-tab")
    }

    enum CloseTarget: Equatable { case window, tab, nothing }

    /// What Cmd+W closes with `key` as the key window: another window (Settings) closes itself; a sheet or alert
    /// (a separate key window that cannot close) closes nothing, whichever window it hangs from; the notebook
    /// window closes its active tab.
    static func closeTarget(for key: NSWindow) -> CloseTarget {
        if key.sheetParent != nil { return .nothing }
        if !isNotebookWindow(key), key.styleMask.contains(.closable) { return .window }
        return .tab
    }

    /// The main window (`Window(id: "main")`), whose tabs Cmd+W closes.
    public static func isNotebookWindow(_ window: NSWindow) -> Bool {
        window.identifier?.rawValue.hasPrefix("main") == true
    }

    private func isFolder(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }
}
