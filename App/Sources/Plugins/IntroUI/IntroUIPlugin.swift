import AssistantPlugin
import AppKit
import Foundation
import ObsidianImportPlugin
import PluginKitUI

/// The intro: Loam coming to life over the desktop before the welcome page. Its pictures and music
/// are not bundled yet (`IntroAssets`): it draws plain stand-ins.
/// Settings > About replays it through `intro.play`. On the first launch, `intro.onboard` plays it and keeps the
/// welcome window up for the onboarding (`IntroOnboarding`; the palette and Settings > About replay it too): the
/// vault's folder (`VaultMoveRequested`), the coding agent, a prompt that has it move the user's notes in, the plugins
/// and the look, then the welcome note.
public final class IntroUIPlugin: UIPlugin {
    public static let manifest = PluginManifest(
        id: "intro-ui",
        name: "Intro",
        version: "0.1.0",
        description: "Plays the intro over the desktop.",
        icon: "sparkles",
        optionalRequires: ["obsidian-import", "assistant"],
        permissions: ["ui", "vault.read"]
    )

    public static let playCommand = "intro.play"
    public static let onboardCommand = "intro.onboard"

    public init() {}

    @MainActor public func activateUI(context: PluginContext) throws {
        let launcher = OnboardingLauncher(context: context)
        try context.registerCommand(Command(
            id: Self.playCommand,
            title: "Play Intro",
            summary: "Plays the intro over the whole screen: other apps are hidden until it ends. Returns what it did."
        ) { _ in
            await MainActor.run { IntroPlayer.shared.play() }
            return "Playing the intro."
        })

        try context.registerCommand(Command(
            id: Self.onboardCommand,
            title: "Replay Onboarding",
            summary: "Plays the intro, then keeps its welcome window up with the first launch's choices: the vault's "
                + "folder, the coding agent, the Obsidian notes found on this Mac, the plugins and the look. Optional "
                + "argument: at=welcome to skip to the welcome page, or at=<card> (folder, agent, migrate, plugins, "
                + "look) to open on that card. Returns what it did.",
            isInPalette: true
        ) { arguments in
            // `at=agent`: straight to that card, as after the vault moved.
            let at = arguments["at"]
            await MainActor.run { launcher.play(at: at) }
            return "Playing the onboarding."
        })
    }
}

/// Starts the onboarding with what it needs from the vault: Obsidian's vaults, the vault's place, the agent, the
/// migration prompt, and the way to move the vault.
@MainActor
private final class OnboardingLauncher {
    private weak var context: PluginContext?

    init(context: PluginContext) {
        self.context = context
    }

    /// `at`: "welcome", or a card's name; nil plays the intro first.
    func play(at: String? = nil) {
        guard let context else { return }
        let vaults = context.service(.obsidianImport)?.vaults() ?? []
        let place = context.vault.rootURL.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
        let assistant = context.service(.assistant)
        let iCloud = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
        let home = FileManager.default.homeDirectoryForCurrentUser
        let onboarding = IntroOnboarding(
            vaults: vaults, vaultPlace: place, agentName: assistant?.settings().agentKind.name,
            hasICloud: FileManager.default.fileExists(atPath: iCloud.path),
            documentsPlace: Self.freePlace(in: home.appendingPathComponent("Documents"), current: context.vault.rootURL),
            iCloudPlace: Self.freePlace(in: iCloud, current: context.vault.rootURL),
            startAt: at.flatMap(IntroSetup.Step.init(rawValue:)),
            migrationPrompt: IntroSetup.migrationPrompt(
                cli: AssistantInstructions.cliPath() ?? "/Applications/Loam.app/Contents/Helpers/loam",
                vault: context.vault.rootURL.path, obsidian: vaults.first
            ),
            onMoveVault: { [weak self] place in self?.moveVault(to: place) },
            onCopyPrompt: { [weak context] prompt in
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(prompt, forType: .string)
                // The user's notes are coming: the demo's leave, so they do not land among the tour's.
                context?.emit(DemoVaultRemovalRequested())
            }
        )
        onboarding.chooseFolder = Self.chooseFolder
        let commands = context.service(.commands)
        onboarding.setup.run = { id, arguments in
            Task { _ = try? await commands?.run(id, arguments: arguments) }
        }
        onboarding.setup.installAgentTools = { Task.detached { IntroSetup.installLoamTools() } }
        onboarding.setup.welcome = { [weak context] imported, report in
            guard let context else { return }
            let note = IntroSetup.welcomeNote(
                vaultPath: place, imported: imported, reportPath: report, shortcut: { commands?.shortcut(for: $0) }
            )
            let path = IntroSetup.welcomePath
            if !context.vault.exists(path) { try? context.vault.write(path, note) }
            context.workspace?.open(.file(path), placement: .replace, from: nil)
            // Once the intro has faded, over the first real page.
            Task { @MainActor [weak context] in
                try? await Task.sleep(for: .milliseconds(700))
                context?.toasts?.show(String(localized: "Everything is saved on this Mac."), kind: .success)
            }
        }
        let start = at == nil ? 0 : IntroScene.welcomeStart
        IntroPlayer.shared.play(onboarding: onboarding, at: start)
    }

    /// The vault goes to `place`: the app opens it there behind the welcome window, whose onboarding the new vault's
    /// takes over on the agent's card.
    private func moveVault(to place: String) {
        let path = (place as NSString).expandingTildeInPath
        context?.emit(VaultMoveRequested(path: path, resumeAt: IntroSetup.Step.agent.rawValue))
    }

    /// `Loam` in `parent`, or `Loam 2`, `Loam 3`… when one there already holds something: a new vault never lands among
    /// notes that are there. The open vault's own folder counts as free.
    private static func freePlace(in parent: URL, current: URL) -> String {
        var index = 1
        while true {
            let url = parent.appendingPathComponent(index == 1 ? "Loam" : "Loam \(index)", isDirectory: true)
            let names = ((try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []).filter { !$0.hasPrefix(".") }
            if url.standardizedFileURL == current.standardizedFileURL || names.isEmpty {
                return url.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
            }
            index += 1
        }
    }

    /// Asks for a folder in a sheet coming down from the intro's window, which is above everything else.
    private static func chooseFolder(_ done: @escaping (String?) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = String(localized: "Choose")
        panel.message = String(localized: "Choose where your notes live.")
        let answer: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return done(nil) }
            done(url.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
        }
        if let window = IntroPlayer.shared.sheetWindow {
            panel.beginSheetModal(for: window, completionHandler: answer)
        } else {
            answer(panel.runModal())
        }
    }
}
