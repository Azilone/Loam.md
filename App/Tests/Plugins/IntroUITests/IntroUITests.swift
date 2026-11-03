import AppKit
import PluginKit
import PluginKitUI
import PluginKitUITesting
import SwiftUI
import XCTest
import ObsidianImportPlugin
@testable import IntroUI

@MainActor
final class IntroUITests: XCTestCase {
    func testRegistersThePlayCommandAndUndoesIt() throws {
        let harness = try UIPluginHarness(uiPlugins: [IntroUIPlugin.self])
        XCTAssertTrue(harness.host.isActive("intro-ui"), "\(harness.report)")
        XCTAssertNotNil(harness.kernel.commands.command(id: IntroUIPlugin.playCommand))
        harness.close()
        XCTAssertNil(harness.kernel.commands.command(id: IntroUIPlugin.playCommand))
    }

    /// Frames of the scene drawn offscreen at a screen's size, one per half second (LOAM_SNAPSHOT_DIR keeps the PNGs).
    func testEveryMomentDraws() throws {
        let size = CGSize(width: 1662, height: 1080)
        for step in 0...40 {
            let time = Double(step) / 2
            let renderer = ImageRenderer(content: IntroScene(time: time, assets: .shared).frame(width: size.width, height: size.height))
            let image = try XCTUnwrap(renderer.cgImage)
            XCTAssertEqual(image.width, Int(size.width))
            let bitmap = NSBitmapImageRep(cgImage: image)
            if let dir = ProcessInfo.processInfo.environment["LOAM_SNAPSHOT_DIR"] {
                try bitmap.representation(using: .png, properties: [:])?
                    .write(to: URL(fileURLWithPath: dir).appendingPathComponent(String(format: "intro-%05.1f.png", time)))
            }
        }
    }
}

@MainActor
final class IntroOnboardingTests: XCTestCase {
    private let vault = ObsidianVault(name: "Brain", path: NSTemporaryDirectory(), notes: 546, opened: nil)

    /// Lets a card settle, as a person would, before the next Return.
    private func pause() async throws { try await Task.sleep(for: .milliseconds(450)) }

    /// The welcome window at the card's size (LOAM_SNAPSHOT_DIR keeps the PNGs).
    private func draw(_ onboarding: IntroOnboarding, name: String) throws {
        let size = IntroScene.cardSize
        let renderer = ImageRenderer(content: IntroOnboardingView(model: onboarding).frame(width: size.width, height: size.height)
            .environment(\.introStill, true))
        renderer.scale = 2
        // The apps' icons would make it a linear 16-bit picture, which PNG viewers show washed out.
        renderer.colorMode = .nonLinear
        let image = try XCTUnwrap(renderer.cgImage)
        XCTAssertEqual(image.width, Int(size.width * 2))
        if let dir = ProcessInfo.processInfo.environment["LOAM_SNAPSHOT_DIR"] {
            try NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?
                .write(to: URL(fileURLWithPath: dir).appendingPathComponent("onboarding-\(name).png"))
        }
    }

    /// Return through every card; the migration card copies the prompt for the user's agent. Each card drawn.
    func testReturnGoesThroughEveryCardAndCopiesTheMigrationPrompt() async throws {
        var copied: [String] = []
        var welcomed: (ObsidianVault?, String?)?
        let prompt = IntroSetup.migrationPrompt(cli: "/Applications/Loam.app/Contents/Helpers/loam", vault: "/Users/me/Documents/Loam", obsidian: vault)
        let onboarding = IntroOnboarding(
            vaults: [vault], vaultPlace: IntroOnboarding.documentsPlace, agentName: "Claude Code", hasICloud: true,
            migrationPrompt: prompt, onCopyPrompt: { copied.append($0) }
        )
        var ran: [String] = []
        onboarding.setup.run = { id, arguments in ran.append(id + (arguments["name"].map { " " + $0 } ?? "")) }
        onboarding.setup.welcome = { welcomed = ($0, $1) }
        var finished = false
        onboarding.finish = { finished = true }
        XCTAssertEqual(onboarding.steps, [.folder, .agent, .migrate, .plugins, .look])
        try draw(onboarding, name: "01-welcome")

        try await pause()
        onboarding.primary()
        XCTAssertEqual(onboarding.phase, .step(.folder))
        try await Task.sleep(for: .seconds(1))
        try draw(onboarding, name: "02-folder")

        try await pause()
        onboarding.primary()
        XCTAssertEqual(onboarding.phase, .step(.agent), "the folder Loam made stays: nothing to move")
        try await Task.sleep(for: .seconds(1))
        try draw(onboarding, name: "03-agent")

        try await pause()
        onboarding.primary()
        XCTAssertEqual(onboarding.phase, .step(.migrate))
        try await Task.sleep(for: .seconds(1))
        try draw(onboarding, name: "04-migrate")

        onboarding.copyPrompt()
        XCTAssertEqual(copied, [prompt], "the button puts the prompt on the pasteboard")
        try await pause()
        onboarding.primary()
        XCTAssertEqual(onboarding.phase, .step(.plugins))
        onboarding.setup.preset = "writing"
        try await Task.sleep(for: .seconds(1))
        try draw(onboarding, name: "05-plugins")

        try await pause()
        onboarding.primary()
        XCTAssertEqual(onboarding.phase, .step(.look))
        for look in IntroSetup.looks.map(\.id) {
            onboarding.setup.look = look
            try await Task.sleep(for: .milliseconds(300))
            try draw(onboarding, name: "06-look-\(look)")
        }
        try await pause()
        onboarding.primary()
        XCTAssertTrue(finished)
        XCTAssertEqual(welcomed?.0?.path, vault.path, "the welcome note says where the prompt goes")
        XCTAssertTrue(ran.contains("themes.use dracula"))
    }

    func testTheMigrationPromptPointsTheGuideAtTheChosenVault() {
        let prompt = IntroSetup.migrationPrompt(cli: "/x/loam", vault: "/Users/me/Loam", obsidian: vault)
        XCTAssertTrue(prompt.contains("\"/x/loam\" guide migrate"))
        XCTAssertTrue(prompt.contains("my vault \"/Users/me/Loam\" (--vault)"))
        XCTAssertTrue(prompt.contains("My notes are in Obsidian: \""))
        XCTAssertFalse(IntroSetup.migrationPrompt(cli: "/x/loam", vault: "/v", obsidian: nil).contains("Obsidian"))
    }

    func testAnotherFolderMovesTheVault() async throws {
        var moved: [String] = []
        let onboarding = IntroOnboarding(vaults: [], vaultPlace: IntroOnboarding.documentsPlace, hasICloud: true,
                                         startAt: .folder, onMoveVault: { moved.append($0) })
        onboarding.arrow(dx: 0, dy: 1)
        XCTAssertEqual(onboarding.folder, .iCloud)
        try await pause()
        onboarding.primary()
        XCTAssertEqual(moved, [IntroOnboarding.iCloudPlace])
        XCTAssertEqual(onboarding.phase, .step(.folder), "the app opens the vault there, and the onboarding comes back")

        onboarding.chooseFolder = { $0("~/Notes") }
        onboarding.arrow(dx: 0, dy: 1)
        XCTAssertEqual(onboarding.folder, .custom("~/Notes"))
    }

    func testContinueWithoutCopyingSaysNothingOfIt() async throws {
        var copied = 0
        var welcomed: ObsidianVault??
        let onboarding = IntroOnboarding(vaults: [], vaultPlace: "~", startAt: .migrate, onCopyPrompt: { _ in copied += 1 })
        onboarding.setup.welcome = { imported, _ in welcomed = imported }
        try await pause()
        onboarding.primary()
        XCTAssertEqual(onboarding.phase, .step(.plugins))
        XCTAssertEqual(copied, 0)
        onboarding.secondary()
        onboarding.secondary()
        XCTAssertEqual(welcomed, .some(nil), "no prompt copied, no word of it in the welcome note")
    }

    func testArrowsMoveThroughTheChoices() {
        let onboarding = IntroOnboarding(vaults: [], vaultPlace: "~", startAt: .plugins)
        onboarding.arrow(dx: 0, dy: 1)
        XCTAssertEqual(onboarding.setup.preset, "tasks")
        onboarding.arrow(dx: 0, dy: 5)
        XCTAssertEqual(onboarding.setup.preset, "tasks", "past the end, it stays")
        let look = IntroOnboarding(vaults: [], vaultPlace: "~", startAt: .look)
        look.arrow(dx: 0, dy: 1)
        XCTAssertEqual(look.setup.look, "ink")
        look.arrow(dx: 1, dy: 0)
        XCTAssertEqual(look.setup.look, "dracula")
    }

    /// Loam's own night, drawn when the intro has no painting.
    func testTheNightArtDraws() throws {
        let renderer = ImageRenderer(content: NightArt())
        renderer.scale = 2
        let image = try XCTUnwrap(renderer.cgImage)
        if let dir = ProcessInfo.processInfo.environment["LOAM_SNAPSHOT_DIR"] {
            try NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?
                .write(to: URL(fileURLWithPath: dir).appendingPathComponent("onboarding-night-art.png"))
        }
    }

    func testTheWelcomeNoteSaysWhereTheNotesAre() {
        let note = IntroSetup.welcomeNote(vaultPath: "~/Documents/Loam", imported: vault, reportPath: nil,
                                          shortcut: { $0 == "switcher.open" ? "⌘O" : nil })
        XCTAssertTrue(note.hasPrefix("Your notes are plain Markdown files in `~/Documents/Loam`"), "named by its file, no heading")
        XCTAssertEqual(IntroSetup.welcomePath, "Welcome to Loam.md")
        XCTAssertTrue(note.contains("`⌘O` finds any note"))
        XCTAssertTrue(note.contains("it moves the notes of Brain into this vault"))
    }

    func testEscapeGoesBackOneCard() async throws {
        let onboarding = IntroOnboarding(vaults: [vault], vaultPlace: "~")
        onboarding.back()
        XCTAssertEqual(onboarding.phase, .welcome)
        try await pause()
        onboarding.primary()
        XCTAssertEqual(onboarding.phase, .step(.folder))
        onboarding.back()
        XCTAssertEqual(onboarding.phase, .welcome)
    }
}
