import AppKit
import Foundation
import LoamCore
import Observation
import PluginKitUI

/// Keeps the programs the plugins need installed, with as little for the user to do as possible. One Install takes the
/// next step (`tools.install`): brew in the background, Apple's installer for the developer tools, or the Terminal for
/// Homebrew itself, which asks for the Mac's password. Loam then looks again on its own, when the app comes back to the
/// front and every few seconds while an installer runs, so the plugins that were waiting start by themselves.
@MainActor
@Observable
public final class ToolSetup {
    enum Phase: Equatable {
        case idle
        /// `tools.install` is running for these programs.
        case installing([String])
        /// Apple's installer for the developer tools is open.
        case waitingForDeveloperTools
        /// Homebrew installs in the Terminal.
        case waitingForHomebrew

        var isWaiting: Bool { self == .waitingForDeveloperTools || self == .waitingForHomebrew }
    }

    /// What `plugins.list` says about each plugin, the part this needs.
    struct PluginBrief: Decodable {
        let id: String
        let name: String
        let enabled: Bool
    }

    private struct InstallResult: Decodable {
        let step: String
        let installed: [String]
        let missing: [String]
    }

    private(set) var tools: [ToolStatusRow] = []
    private(set) var phase: Phase = .idle
    /// Bumped after every look, so the pages listing plugins reload.
    private(set) var revision = 0
    /// What one Install does next for the missing programs, worked out on every look.
    private(set) var nextStep: ToolInstaller.Step = .nothing
    /// The enabled plugins' names, by id.
    @ObservationIgnored private var enabledNames: [String: String] = [:]

    @ObservationIgnored private let run: (String, [String: String]) async throws -> String
    @ObservationIgnored private let show: (String, ToastKind) -> Void
    @ObservationIgnored private let locate: (String) -> URL?
    @ObservationIgnored private var watch: Task<Void, Never>?
    @ObservationIgnored nonisolated(unsafe) private var observer: NSObjectProtocol?
    @ObservationIgnored private var lastLook = Date.distantPast

    /// - Parameters:
    ///   - run: runs a command (`ShellSession.run`).
    ///   - show: shows a toast.
    ///   - locate: the kernel's tool locator, for brew.
    init(
        run: @escaping (String, [String: String]) async throws -> String,
        show: @escaping (String, ToastKind) -> Void,
        locate: @escaping (String) -> URL?
    ) {
        self.run = run
        self.show = show
        self.locate = locate
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    /// The missing programs an enabled plugin needs or uses: the ones worth installing.
    var missing: [ToolStatusRow] { tools.filter { !$0.isInstalled && !features(using: $0).isEmpty } }

    /// The enabled plugins that need or use `tool`, by name.
    func features(using tool: ToolStatusRow) -> [String] {
        (tool.requiredBy + tool.optionalFor).compactMap { enabledNames[$0] }
    }


    /// What Install will do, in one sentence, with how long it takes.
    var nextStepText: String {
        switch nextStep {
        case .nothing: ""
        case .developerTools:
            String(localized: "Apple’s installer opens: click Install. About 5 minutes, then Loam continues on its own.")
        case .homebrew:
            String(localized: "The Terminal opens and asks for your Mac password once, to install Homebrew. About 5 minutes, then Loam continues on its own.")
        case .brew:
            String(localized: "Loam installs it in the background. About 2 minutes.")
        }
    }

    /// Looks again when the app comes back to the front (after an install in the Terminal, a permission granted),
    /// and offers to install what is missing when `offer` is true.
    func start(offer: Bool) {
        observer = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.becameActive() }
        }
        Task {
            await reload()
            guard offer else { return }
            // The window comes up first: the offer is a sheet on it.
            try? await Task.sleep(for: .seconds(1))
            offerInstall()
        }
    }

    func stop() {
        watch?.cancel()
        watch = nil
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
    }

    /// Reads the tools and the plugins without looking again.
    func reload() async {
        if let json = try? await run("tools.list", [:]),
           let rows = try? JSONDecoder().decode([ToolStatusRow].self, from: Data(json.utf8)) {
            tools = rows
        }
        if let json = try? await run("plugins.list", [:]),
           let plugins = try? JSONDecoder().decode([PluginBrief].self, from: Data(json.utf8)) {
            enabledNames = Dictionary(plugins.filter(\.enabled).map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
        }
        let names = missing.map(\.name)
        nextStep = names.isEmpty ? .nothing : ToolInstaller.plan(
            missing: names, hasDeveloperTools: ToolLocator.developerToolsInstalled(), hasHomebrew: locate("brew") != nil
        )
        revision += 1
    }

    /// Looks for the programs again; the plugins waiting for one start if it is there now.
    func check() async {
        lastLook = Date()
        _ = try? await run("tools.check", [:])
        await reload()
    }

    /// Installs the missing programs, or takes the step that leads there.
    func install() async {
        if case .installing = phase { return }
        let names = missing.map(\.name)
        guard !names.isEmpty else { return }
        phase = .installing(names)
        do {
            let json = try await run("tools.install", ["names": names.joined(separator: ",")])
            let result = try JSONDecoder().decode(InstallResult.self, from: Data(json.utf8))
            await reload()
            switch result.step {
            case "developer-tools":
                phase = .waitingForDeveloperTools
                watchInstaller(for: names)
            case "homebrew":
                openTerminalInstaller()
                phase = .waitingForHomebrew
                watchInstaller(for: names)
            default:
                phase = .idle
                announce(installed: result.installed)
            }
        } catch {
            phase = .idle
            show(String(localized: "Could not install \(names.joined(separator: ", ")): \(error.localizedDescription)"), .error)
        }
    }

    /// Once per set of missing programs, a sheet on the window offers to install them. "Not Now" is remembered; the
    /// Plugins pane of Settings still offers it.
    private func offerInstall() {
        let missing = missing
        guard !missing.isEmpty, phase == .idle else { return }
        let key = "ToolSetup.declined." + missing.map(\.name).sorted().joined(separator: ",")
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        guard let window = NSApp.mainWindow ?? NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain }) else { return }
        let features = Array(Set(missing.flatMap(features(using:)))).sorted()
        let alert = NSAlert()
        alert.messageText = String(localized: "One step to finish setting up Loam")
        alert.informativeText = String(localized: "\(features.joined(separator: ", ")) need \(missing.map(\.name).joined(separator: ", ")), which is not on this Mac yet.")
            + "\n\n" + nextStepText
        alert.addButton(withTitle: String(localized: "Install"))
        alert.addButton(withTitle: String(localized: "Not Now")).keyEquivalent = "\u{1b}"
        alert.beginSheetModal(for: window) { [weak self] response in
            // A sheet closed another way (the app quit) asks again next time.
            switch response {
            case .alertFirstButtonReturn: Task { await self?.install() }
            case .alertSecondButtonReturn: UserDefaults.standard.set(true, forKey: key)
            default: break
            }
        }
    }

    private func becameActive() {
        guard !missing.isEmpty, Date().timeIntervalSince(lastLook) > 2 else { return }
        if case .installing = phase { return }
        Task { await check() }
    }

    /// While an installer of its own runs, looks every 5 seconds, for up to 30 minutes. When the developer tools
    /// arrive and formulas are still missing, it goes on with them.
    private func watchInstaller(for names: [String]) {
        watch?.cancel()
        watch = Task { [weak self] in
            for _ in 0..<360 {
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled, let self else { return }
                guard self.phase.isWaiting else { return }
                await self.check()
                let still = self.missing.map(\.name)
                if still.isEmpty {
                    self.phase = .idle
                    self.announce(installed: names)
                    return
                }
                if self.phase == .waitingForDeveloperTools, !still.contains(where: { $0 == "git" || $0 == "swift" }) {
                    self.phase = .idle
                    await self.install()
                    return
                }
            }
            self?.phase = .idle
        }
    }

    /// Says what works now.
    private func announce(installed: [String]) {
        guard !installed.isEmpty else { return }
        show(String(localized: "Installed \(installed.joined(separator: ", ")). Everything is ready."), .success)
    }

    /// Opens the app's installer in the Terminal: Homebrew (with the user's password), then every formula.
    private func openTerminalInstaller() {
        guard let installer = Bundle.main.url(forResource: "install-dependencies", withExtension: "command") else {
            show(String(localized: "The installer is missing from this build."), .error)
            return
        }
        NSWorkspace.shared.open(installer)
    }
}
