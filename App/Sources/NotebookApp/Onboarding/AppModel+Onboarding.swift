import AppKit
import Foundation
import ObsidianImportPlugin
import PluginKitUI

/// The first launch: no vault yet. The user brings their Obsidian notes or starts fresh; either way Loam makes the
/// vault folder itself (`~/Documents/Loam` unless they pick another), so there is nothing to set up first. A new,
/// empty vault starts from the demo vault: a tour of Loam in notes, a journal, a mind map, a meeting and boards.
extension AppModel {
    /// What the first screen offers.
    enum Start: Equatable {
        /// Opens the new vault on the import page.
        case importNotes
        /// Opens the new, empty vault.
        case fresh
    }

    static let importCommand = "import.open"
    static let onboardCommand = "intro.onboard"
    static let onboardedKey = "onboarded"

    /// The very first launch: makes the vault in `~/Documents/Loam` and plays the intro, whose welcome window holds
    /// the choices. Later launches without a vault show `OnboardingView` instead.
    func startFirstRun(defaults: UserDefaults = .standard) {
        guard !defaults.bool(forKey: Self.onboardedKey) else { return }
        defaults.set(true, forKey: Self.onboardedKey)
        begin(.fresh, in: Self.defaultVaultFolder)
        onboard(at: nil)
    }

    /// Moves the vault when the onboarding asks to (`VaultMoveRequested`), whether it is the first launch's or one
    /// replayed from the palette or Settings, and takes the demo's notes out before the user's move in
    /// (`DemoVaultRemovalRequested`). Called each time a vault opens.
    func listenForVaultMoves() {
        onboardingListener?()
        let events = session?.runtime.kernel.events
        let move = events?.on(VaultMoveRequested.self) { @Sendable [weak self] event in
            Task { @MainActor in self?.moveFirstVault(to: URL(fileURLWithPath: event.path), resumeAt: event.resumeAt) }
        }
        let demo = events?.on(DemoVaultRemovalRequested.self) { @Sendable [weak self] _ in
            Task { @MainActor in
                guard let folder = self?.session?.rootURL else { return }
                Self.removeDemoIfUntouched(from: folder)
            }
        }
        onboardingListener = { move?(); demo?() }
    }

    /// Plays the onboarding in the open vault: from the intro, or straight on the card `at`.
    private func onboard(at: String?) {
        guard let session else { return }
        // Once the window is up, so the intro puts it away and brings it back.
        Task {
            try? await Task.sleep(for: .seconds(at == nil ? 1 : 0.05))
            if canRun(Self.onboardCommand) {
                _ = try? await session.run(Self.onboardCommand, at.map { ["at": $0] } ?? [:])
            } else if !obsidianVaults().isEmpty {
                run(Self.importCommand)
            }
        }
    }

    /// Opens `folder` in place of the open vault, then throws that one away when nothing was put in it (the one Loam
    /// made for the first launch), and resumes the onboarding on the card `resumeAt`, else on its welcome page.
    func moveFirstVault(to folder: URL, resumeAt: String? = nil) {
        guard let old = session?.rootURL, old.standardizedFileURL != folder.standardizedFileURL else { return }
        begin(.fresh, in: folder)
        guard session != nil else { return }
        Self.discardIfUntouched(old)
        onboard(at: resumeAt ?? "welcome")
    }

    /// Moves the demo vault's top-level folders and notes in `folder` to the Trash, when the folder holds nothing else
    /// (besides `.loam` and the welcome note), so the user's own notes have the vault to themselves.
    static func removeDemoIfUntouched(from folder: URL, template: URL? = demoVaultTemplate) {
        let manager = FileManager.default
        let names = (try? manager.contentsOfDirectory(atPath: folder.path)) ?? []
        let ours = Set((template.flatMap { try? manager.contentsOfDirectory(atPath: $0.path) }) ?? [])
        guard !ours.isEmpty, names.allSatisfy({ $0.hasPrefix(".") || ours.contains($0) }) else { return }
        for name in names where ours.contains(name) {
            try? manager.trashItem(at: folder.appendingPathComponent(name), resultingItemURL: nil)
        }
    }

    /// Moves `folder` to the Trash when it holds nothing but Loam's own `.loam` folder and the demo vault's top-level
    /// folders and notes (the vault of the first launch, before anything was written in it).
    static func discardIfUntouched(_ folder: URL, template: URL? = demoVaultTemplate) {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        let ours = Set((template.flatMap { try? FileManager.default.contentsOfDirectory(atPath: $0.path) }) ?? [])
        guard names.allSatisfy({ $0 == ".loam" || $0 == ".DS_Store" || ours.contains($0) }) else { return }
        try? FileManager.default.trashItem(at: folder, resultingItemURL: nil)
    }

    /// Where a new vault goes when the user picks nothing.
    static var defaultVaultFolder: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents/Loam", isDirectory: true)
    }

    /// The Obsidian vaults on this Mac, for the import card.
    func obsidianVaults() -> [ObsidianVault] {
        ObsidianVaults.find()
    }

    /// Makes `folder` if it is missing, opens it as the vault, then shows the import page for `.importNotes`.
    func begin(_ start: Start, in folder: URL) {
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            errorMessage = String(localized: "Could not create the vault: \(error.localizedDescription)")
            return
        }
        if start == .fresh { Self.seedDemoVault(into: folder) }
        openVault(folder)
        if start == .importNotes { run(Self.importCommand) }
    }

    /// The demo vault shipped in the app (`Contents/Resources/DemoVault`, from `App/Resources/DemoVault`); nil when
    /// the build has none, as under `swift test`.
    static var demoVaultTemplate: URL? {
        let url = Bundle.main.resourceURL?.appendingPathComponent("DemoVault", isDirectory: true)
        return url.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
    }

    /// Copies the demo vault into `folder` when it holds nothing yet (a vault with notes is never touched).
    static func seedDemoVault(into folder: URL, template: URL? = demoVaultTemplate) {
        guard let template else { return }
        let manager = FileManager.default
        let present = (try? manager.contentsOfDirectory(atPath: folder.path)) ?? []
        guard present.allSatisfy({ $0 == ".DS_Store" }) else { return }
        for name in (try? manager.contentsOfDirectory(atPath: template.path)) ?? [] where name != ".DS_Store" {
            try? manager.copyItem(at: template.appendingPathComponent(name), to: folder.appendingPathComponent(name))
        }
    }

    /// Lets the user pick the folder of the new vault; nil when they cancel.
    func chooseNewVaultFolder() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = String(localized: "Choose")
        panel.message = String(localized: "Choose where your notes live.")
        return panel.runModal() == .OK ? panel.url : nil
    }
}
