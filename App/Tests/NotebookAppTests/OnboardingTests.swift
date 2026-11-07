import AppKit
import SwiftUI
import PluginKitUI
import XCTest
@testable import NotebookApp

@MainActor
final class OnboardingTests: ShellTestCase {
    func testStartingFreshMakesTheFolderAndOpensIt() throws {
        let model = AppModel(configuration: ShellConfiguration(logicPlugins: [], uiPlugins: []))
        let folder = root.appendingPathComponent("New/Loam")
        model.begin(.fresh, in: folder)
        defer { model.closeVault() }
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.session?.rootURL.standardizedFileURL.path, folder.standardizedFileURL.path)
    }

    func testAFolderThatCannotBeMadeIsReported() throws {
        let model = AppModel(configuration: ShellConfiguration(logicPlugins: [], uiPlugins: []))
        let file = root.appendingPathComponent("file")
        try "x".write(to: file, atomically: true, encoding: .utf8)
        model.begin(.fresh, in: file.appendingPathComponent("Loam"))
        XCTAssertNil(model.session)
        XCTAssertNotNil(model.errorMessage)
    }

    func testAReplayedOnboardingCanMoveAVaultThatHasNotes() throws {
        let model = AppModel(configuration: ShellConfiguration(logicPlugins: [], uiPlugins: []))
        let used = root.appendingPathComponent("Used")
        try FileManager.default.createDirectory(at: used, withIntermediateDirectories: true)
        try "x".write(to: used.appendingPathComponent("Note.md"), atomically: true, encoding: .utf8)
        let other = root.appendingPathComponent("Other")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        model.openVault(used)
        defer { model.closeVault() }
        model.session?.runtime.kernel.events.emit(VaultMoveRequested(path: other.path))
        let moved = expectation(description: "moved")
        Task { @MainActor in
            while model.session?.rootURL.standardizedFileURL.path != other.standardizedFileURL.path {
                try? await Task.sleep(for: .milliseconds(20))
            }
            moved.fulfill()
        }
        wait(for: [moved], timeout: 5)
        XCTAssertTrue(FileManager.default.fileExists(atPath: used.appendingPathComponent("Note.md").path))
    }

    func testOnlyAnUntouchedVaultIsThrownAway() throws {
        let untouched = root.appendingPathComponent("Untouched")
        try FileManager.default.createDirectory(at: untouched.appendingPathComponent(".loam"), withIntermediateDirectories: true)
        let used = root.appendingPathComponent("Used")
        try FileManager.default.createDirectory(at: used, withIntermediateDirectories: true)
        try "x".write(to: used.appendingPathComponent("Note.md"), atomically: true, encoding: .utf8)
        AppModel.discardIfUntouched(untouched)
        AppModel.discardIfUntouched(used)
        XCTAssertFalse(FileManager.default.fileExists(atPath: untouched.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: used.appendingPathComponent("Note.md").path))
    }

    func testANewEmptyVaultStartsFromTheDemoAndANonEmptyOneIsLeftAlone() throws {
        let template = root.appendingPathComponent("Template")
        try FileManager.default.createDirectory(at: template.appendingPathComponent(".loam"), withIntermediateDirectories: true)
        try "# Home".write(to: template.appendingPathComponent("Home.md"), atomically: true, encoding: .utf8)
        let empty = root.appendingPathComponent("Empty")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        AppModel.seedDemoVault(into: empty, template: template)
        XCTAssertTrue(FileManager.default.fileExists(atPath: empty.appendingPathComponent("Home.md").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: empty.appendingPathComponent(".loam").path))

        let used = root.appendingPathComponent("UsedNotes")
        try FileManager.default.createDirectory(at: used, withIntermediateDirectories: true)
        try "x".write(to: used.appendingPathComponent("Mine.md"), atomically: true, encoding: .utf8)
        AppModel.seedDemoVault(into: used, template: template)
        XCTAssertFalse(FileManager.default.fileExists(atPath: used.appendingPathComponent("Home.md").path))

        // The seeded vault is still "untouched" until the user adds something of their own.
        AppModel.discardIfUntouched(empty, template: template)
        XCTAssertFalse(FileManager.default.fileExists(atPath: empty.path))
    }

    func testTheFirstScreenDraws() throws {
        let model = AppModel(configuration: ShellConfiguration(logicPlugins: [], uiPlugins: []))
        let size = CGSize(width: 1100, height: 760)
        let hosting = NSHostingView(rootView: OnboardingView(model: model).frame(width: size.width, height: size.height))
        hosting.frame = CGRect(origin: .zero, size: size)
        // In a window, so the cascade runs; then time for it to settle and for the task to find Obsidian's vaults.
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = hosting
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        RunLoop.main.run(until: Date().addingTimeInterval(2))
        hosting.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        XCTAssertGreaterThan(bitmap.pixelsWide, 0)
        if let dir = ProcessInfo.processInfo.environment["LOAM_SNAPSHOT_DIR"] {
            try bitmap.representation(using: .png, properties: [:])?
                .write(to: URL(fileURLWithPath: dir).appendingPathComponent("onboarding.png"))
        }
    }
}
