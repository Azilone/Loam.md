import AppKit
import ObsidianImportPlugin
import PluginKitUI
import SwiftUI

/// The first launch, on the intro's welcome window: the welcome card, then one card a choice, all at night: where the
/// vault lives, the user's coding agent, a prompt that has that agent move their notes in from any app (Obsidian's
/// vault named when there is one), the plugins and the look; then the welcome note. Return takes the main choice, Escape goes back.
@MainActor
@Observable
final class IntroOnboarding {
    enum Phase: Equatable {
        case welcome
        case step(IntroSetup.Step)
    }

    /// Where the vault lives: the folder Loam made, iCloud Drive (on every Mac signed in), or one the user picks.
    enum Folder: Hashable {
        case documents, iCloud
        case custom(String)
    }

    private(set) var phase: Phase {
        didSet { changed = .now }
    }
    /// Whether the last change went forward: the card's content slides in from that side.
    private(set) var forward = true
    /// When the card last changed: a Return that comes right after belongs to the card before, not to this one.
    @ObservationIgnored private var changed = ContinuousClock.now - .seconds(10)
    let vaults: [ObsidianVault]
    /// The Obsidian vault the migration prompt names (the first one found).
    var chosenVault: ObsidianVault?
    /// Where the vault is now (`~/Documents/Loam`).
    let vaultPlace: String
    /// The folder card's choice, on the vault's place until the user picks another.
    var folder: Folder
    /// Where Documents and iCloud Drive would put the vault: `Loam`, or `Loam 2`… when a `Loam` there or in the other place has notes.
    let documentsPlace: String
    let iCloudPlace: String
    /// Whether iCloud Drive is on, so the folder card offers it.
    let hasICloud: Bool
    /// The user's coding agent ("Claude Code"); nil without the Assistant.
    let agentName: String?
    /// What the cards chose, and what they do.
    let setup: IntroSetup

    /// What the user pastes into their agent so it moves their notes in (`IntroSetup.migrationPrompt`), and whether
    /// they copied it.
    let migrationPrompt: String
    private(set) var promptCopied = false

    /// Puts the vault in another folder: the app opens it and the onboarding comes back on the agent's card.
    @ObservationIgnored private let onMoveVault: (String) -> Void
    /// Puts the prompt on the pasteboard.
    @ObservationIgnored private let onCopyPrompt: (String) -> Void
    /// Asks the user for a folder, then tells its place; nil when they cancel.
    @ObservationIgnored var chooseFolder: (@escaping (String?) -> Void) -> Void = { $0(nil) }
    /// Closes the intro.
    @ObservationIgnored var finish: () -> Void = {}
    /// Tells the anonymous usage statistics how far the cards got (`UsageEvent`): which card, done, skipped or left
    /// by going back, and the plain choice it made (a plugin set, a look). Never a folder's name.
    @ObservationIgnored var onUsage: (String, [String: String]) -> Void = { _, _ in }

    init(
        vaults: [ObsidianVault], vaultPlace: String, agentName: String? = nil, hasICloud: Bool = false,
        documentsPlace: String = IntroOnboarding.documentsPlace, iCloudPlace: String = IntroOnboarding.iCloudPlace,
        startAt step: IntroSetup.Step? = nil,
        migrationPrompt: String = "",
        onMoveVault: @escaping (String) -> Void = { _ in }, onCopyPrompt: @escaping (String) -> Void = { _ in },
        setup: IntroSetup = IntroSetup()
    ) {
        self.setup = setup
        self.vaults = vaults
        chosenVault = vaults.first
        self.vaultPlace = vaultPlace
        self.agentName = agentName
        self.hasICloud = hasICloud
        self.onMoveVault = onMoveVault
        self.onCopyPrompt = onCopyPrompt
        self.migrationPrompt = migrationPrompt
        self.documentsPlace = documentsPlace
        self.iCloudPlace = iCloudPlace
        folder = vaultPlace == documentsPlace ? .documents : vaultPlace == iCloudPlace ? .iCloud : .custom(vaultPlace)
        phase = step.map { .step($0) } ?? .welcome
    }

    // MARK: Folders

    static let documentsPlace = "~/Documents/Loam"
    static let iCloudPlace = "~/Library/Mobile Documents/com~apple~CloudDocs/Loam"

    /// Where `folder` is, `~` for the home folder.
    func place(of folder: Folder) -> String {
        switch folder {
        case .documents: documentsPlace
        case .iCloud: iCloudPlace
        case .custom(let place): place
        }
    }

    /// The folders the card offers, in order.
    var folders: [Folder] {
        var folders: [Folder] = [.documents]
        if hasICloud { folders.append(.iCloud) }
        if case .custom = folder { folders.append(folder) } else { folders.append(.custom("")) }
        return folders
    }

    /// The last choice: another folder, through the open panel.
    func pickFolder() {
        chooseFolder { [weak self] place in
            guard let self, let place else { return }
            folder = place == documentsPlace ? .documents : place == iCloudPlace ? .iCloud : .custom(place)
        }
    }

    // MARK: Steps

    /// The cards, in order.
    var steps: [IntroSetup.Step] { IntroSetup.Step.allCases }

    /// The capsules: the welcome is the first, then one a card.
    var stepCount: Int { steps.count + 1 }

    var stepIndex: Int {
        guard case .step(let step) = phase else { return 0 }
        return (steps.firstIndex(of: step) ?? 0) + 1
    }

    private func step(after step: IntroSetup.Step) -> IntroSetup.Step? {
        guard let index = steps.firstIndex(of: step), steps.indices.contains(index + 1) else { return nil }
        return steps[index + 1]
    }

    private func step(before step: IntroSetup.Step) -> IntroSetup.Step? {
        guard let index = steps.firstIndex(of: step), index > 0 else { return nil }
        return steps[index - 1]
    }

    /// Whether Escape has somewhere to go: every card goes back, the first one to the welcome.
    var canGoBack: Bool { phase != .welcome }

    // MARK: Actions

    /// Return: the card's main choice.
    func primary() {
        guard ContinuousClock.now - changed > .milliseconds(400) else { return }
        switch phase {
        case .welcome: go(.step(steps[0]))
        case .step(.folder):
            if place(of: folder) == vaultPlace {
                report(.folder, "done")
                next(after: .folder)
            } else {
                report(.folder, "moved")
                onMoveVault(place(of: folder))
            }
        case .step(.migrate):
            report(.migrate, "done")
            next(after: .migrate)
        case .step(let step):
            setup.apply(step)
            report(step, "done")
            next(after: step)
        }
    }

    /// The plain words beside the main button: Skip, Not now.
    func secondary() {
        guard case .step(let step) = phase else { return }
        report(step, "skipped")
        next(after: step)
    }

    /// Skips the card on screen, leaving its choice undone.
    func skip() {
        secondary()
    }

    /// Escape: back one card.
    func back() {
        guard case .step(let step) = phase else { return }
        report(step, "back")
        if let previous = self.step(before: step) { go(.step(previous), forward: false) } else { go(.welcome, forward: false) }
    }

    /// The arrow keys: through the folders and the plugin sets, lists; through the looks, a grid of two columns.
    func arrow(dx: Int, dy: Int) {
        func step<T: Equatable>(_ items: [T], from current: T, by offset: Int) -> T {
            guard let index = items.firstIndex(of: current), items.indices.contains(index + offset) else { return current }
            return items[index + offset]
        }
        switch phase {
        case .step(.folder):
            let next = step(folders, from: folder, by: dx + dy)
            if case .custom(let place) = next, place.isEmpty { pickFolder() } else { folder = next }
        case .step(.plugins): setup.preset = step(IntroSetup.presets.map(\.id), from: setup.preset, by: dx + dy)
        case .step(.look): setup.look = step(IntroSetup.looks.map(\.id), from: setup.look, by: dx + dy * 2)
        case .step(.agent): if dx != 0 { setup.agentTools = dx > 0 }
        default: break
        }
    }

    private func next(after step: IntroSetup.Step) {
        if let next = self.step(after: step) { go(.step(next)) } else { end() }
    }

    /// One card's outcome for the statistics, with what a card that was done chose.
    private func report(_ step: IntroSetup.Step, _ action: String) {
        var properties = ["step": step.rawValue, "action": action]
        if action == "done" || action == "moved" {
            switch step {
            case .folder: properties["folder"] = folder == .documents ? "documents" : folder == .iCloud ? "icloud" : "custom"
            case .plugins: properties["preset"] = setup.preset
            case .look: properties["look"] = setup.look
            case .agent: properties["tools"] = setup.agentTools ? "true" : "false"
            case .migrate:
                properties["prompt_copied"] = promptCopied ? "true" : "false"
                properties["obsidian"] = vaults.isEmpty ? "false" : "true"
            }
        }
        onUsage("onboarding_step", properties)
    }

    // MARK: Migration

    /// Copy: the prompt on the pasteboard, for the user's agent.
    func copyPrompt() {
        onCopyPrompt(migrationPrompt)
        promptCopied = true
    }

    /// The last card done: the welcome note, then Loam.
    private func end() {
        onUsage("onboarding_finished", ["prompt_copied": promptCopied ? "true" : "false"])
        setup.welcome(promptCopied ? chosenVault : nil, nil)
        finish()
    }

    /// Shows `next`: the cards slide their words; the welcome's night gives way to the first card.
    private func go(_ next: Phase, forward: Bool = true) {
        self.forward = forward
        let animation: Animation = (phase == .welcome || next == .welcome) ? .easeInOut(duration: 0.7) : .smooth(duration: 0.5)
        withAnimation(Motion.resolved(animation)) { phase = next }
    }
}

/// What the welcome window shows during onboarding, in its 928 × 544 points: the welcome card, then the cards over it.
struct IntroOnboardingView: View {
    let model: IntroOnboarding

    var body: some View {
        ZStack(alignment: .topLeading) {
            WelcomePanel(model: model)
                .allowsHitTesting(model.phase == .welcome)
            if model.phase != .welcome {
                OnboardingStage(model: model)
                    .motionTransition(.paperWipe)
                    .zIndex(1)
            }
        }
        .frame(width: IntroScene.cardSize.width, height: IntroScene.cardSize.height, alignment: .topLeading)
        .clipped()
    }
}

// MARK: Welcome

/// The welcome card: the brand bar, the title, a line and the tagline, Get started. On the right, the night art with
/// Loam's window resting on it.
private struct WelcomePanel: View {
    let model: IntroOnboarding

    var body: some View {
        ZStack(alignment: .topLeading) {
            Onb.night
            OnbNightArt()
            OnbAppShot(name: "plugins-everything").place(OnbGrid.window.minX, OnbGrid.window.minY)
            column.place(OnbGrid.edge, OnbGrid.markerY)
        }
        .frame(width: IntroScene.cardSize.width, height: IntroScene.cardSize.height, alignment: .topLeading)
        .environment(\.colorScheme, .dark)
    }

    private var column: some View {
        VStack(alignment: .leading, spacing: 0) {
            OnbSteps(count: model.stepCount, current: 0)
            Text("Welcome to Loam")
                .font(OnbType.title(30))
                .tracking(-0.3)
                .foregroundStyle(Onb.ink)
                .frame(height: 36, alignment: .leading)
                .padding(.top, OnbGrid.titleY - OnbGrid.markerY - 8)
            Text("Your notes stay plain Markdown, on your Mac.")
                .font(OnbType.text(14))
                .foregroundStyle(Onb.soft)
                .frame(height: 21, alignment: .leading)
                .padding(.top, 12)
            Text("The second brain that becomes whatever you need.")
                .font(OnbType.italic(17))
                .foregroundStyle(Onb.leaf)
                .frame(height: 24, alignment: .leading)
                .padding(.top, 14)
            OnbMainButton(title: String(localized: "Get started"), action: model.primary)
                .padding(.top, 44)
        }
        .frame(width: 400, alignment: .leading)
    }
}

/// An app's own icon, as the Dock draws it.
struct IntroAppIcon: View {
    let image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().interpolation(.high)
            } else {
                RoundedRectangle(cornerRadius: Corners.r(22), style: .continuous).fill(Color(white: 0.5))
            }
        }
        .aspectRatio(1, contentMode: .fit)
    }
}

