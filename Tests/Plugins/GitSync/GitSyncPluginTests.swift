@testable import LoamCore
import PluginKit
import PluginKitTesting
import XCTest
@testable import GitSyncPlugin

final class GitSyncPluginTests: XCTestCase {
    func testAVaultWithoutGitIsOffAndActivatingRunsNothing() async throws {
        let harness = try PluginTestHarness([GitSyncPlugin.self], files: ["Note.md": "hello\n"])
        let service = try XCTUnwrap(harness.kernel.services.service(.gitSync))
        XCTAssertEqual(service.status, .off)
        let status = try JSONDecoder().decode(SyncStatus.self, from: Data(try await harness.run("sync.status").utf8))
        XCTAssertEqual(status.state, .off)
        XCTAssertTrue(status.message?.contains("sync.setup") == true)
        XCTAssertFalse(harness.vault.exists(".git"))
    }

    func testTurningAutomaticSyncOnAndOffKeepsTheOtherSettings() async throws {
        let harness = try PluginTestHarness([GitSyncPlugin.self])
        _ = try await harness.run("sync.enable")
        let stored = try XCTUnwrap(harness.kernel.settingsBackend.settings(for: "git-sync"))
        let json = String(decoding: try JSONEncoder().encode(stored), as: UTF8.self)
        XCTAssertTrue(json.contains("\"auto\":true"), json)
        XCTAssertTrue(json.contains("\"remote\":\"origin\""), "the whole settings value is stored, for the form")
        let off = try await harness.run("sync.disable")
        XCTAssertEqual(off, "Automatic sync is off.")
    }

    func testSetupWithoutAnAddressSaysWhatToPass() async throws {
        try XCTSkipUnless(GitFixture.gitIsInstalled)
        let harness = try PluginTestHarness([GitSyncPlugin.self])
        do {
            _ = try await harness.run("sync.setup")
            XCTFail("setup without a remote went ahead")
        } catch let error as SetupError {
            XCTAssertTrue(error.message.contains("url="), error.message)
        }
    }

    func testSetupFromSettingsSyncsAndReportsTheRepository() async throws {
        try XCTSkipUnless(GitFixture.gitIsInstalled)
        let remote = FileManager.default.temporaryDirectory.appendingPathComponent("remote-\(UUID().uuidString).git")
        defer { try? FileManager.default.removeItem(at: remote) }
        let made = Process()
        made.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        made.arguments = ["git", "init", "--quiet", "--bare", "-b", "main", remote.path]
        try made.run()
        made.waitUntilExit()
        let harness = try PluginTestHarness([GitSyncPlugin.self], files: ["Note.md": "hello\n"])
        let service = try XCTUnwrap(harness.kernel.services.service(.gitSync))
        let first = try await service.setUp(url: remote.absoluteString, device: "Test Mac", encrypt: false)
        XCTAssertEqual(first.state, .synced, first.message ?? "")
        let report = await service.report()
        XCTAssertEqual(report.remoteURL, remote.absoluteString)
        XCTAssertEqual(report.device, "Test Mac")
        try await service.setAutomatic(false)
        let off = await service.report()
        XCTAssertEqual(off.state, .off)
    }

    func testAVaultInICloudKeepsGitOutsideIt() {
        let iCloud = URL(fileURLWithPath: "/Users/me/Library/Mobile Documents/com~apple~CloudDocs/My Notes")
        XCTAssertEqual(SyncController.gitDirOutsideICloud(for: iCloud), "~/.vault-git/My-Notes.git")
        XCTAssertNil(SyncController.gitDirOutsideICloud(for: URL(fileURLWithPath: "/Users/me/Notes")))
    }

    func testStatusLabels() {
        XCTAssertEqual(SyncStatus(state: .synced).label, "Synced")
        XCTAssertEqual(SyncStatus(state: .synced, conflicts: ["a", "b"]).label, "2 conflicts")
        XCTAssertEqual(SyncStatus(state: .offline).label, "Offline")
        XCTAssertEqual(SyncStatus(state: .syncing).label, "Syncing…")
    }
}
