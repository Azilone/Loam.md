import CoreServices
import Foundation
import XCTest
@testable import NotebookApp

@MainActor
final class AppAndWatcherTests: ShellTestCase {
    func testOpeningAMissingFolderReportsAnError() {
        let model = AppModel(configuration: ShellConfiguration(logicPlugins: [], uiPlugins: []))
        model.openVault(root.appendingPathComponent("nope"))
        XCTAssertNil(model.session)
        XCTAssertNotNil(model.errorMessage)
    }

    func testTheMachineIDIsStable() throws {
        let suite = "NotebookAppTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let id = MachineID.current(defaults: defaults)
        XCTAssertFalse(id.isEmpty)
        XCTAssertEqual(MachineID.current(defaults: defaults), id)
    }

    func testAWatcherThatGoesAwayStopsCallingBack() async throws {
        try write("First.md", "first")
        var calls = 0
        var watcher: FileWatcher? = FileWatcher(url: root, latency: 0.05) { calls += 1 }
        XCTAssertNotNil(watcher)
        watcher = nil
        try write("First.md", "changed")
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(calls, 0)
    }

    func testAWatcherReportsChanges() async throws {
        try write("First.md", "first")
        var calls = 0
        let watcher = FileWatcher(url: root, latency: 0.05) { calls += 1 }
        try await Task.sleep(for: .milliseconds(100))
        try write("First.md", "changed")
        try await Task.sleep(for: .milliseconds(500))
        watcher.stop()
        XCTAssertGreaterThan(calls, 0)
    }

    func testAWatcherIgnoresChangesInsideGit() async throws {
        try write("First.md", "first")
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".git/objects"),
                                                withIntermediateDirectories: true)
        var calls = 0
        let watcher = FileWatcher(url: root, latency: 0.05) { calls += 1 }
        // FSEvents may still report the setup above; only what follows counts.
        try await Task.sleep(for: .milliseconds(400))
        calls = 0
        try Data("x".utf8).write(to: root.appendingPathComponent(".git/objects/abc"))
        try Data("y".utf8).write(to: root.appendingPathComponent(".git/index"))
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(calls, 0)
        try write("First.md", "changed")
        try await Task.sleep(for: .milliseconds(500))
        watcher.stop()
        XCTAssertGreaterThan(calls, 0)
    }

    func testOnlyBatchesEntirelyInsideGitAreSkipped() {
        let plain = FSEventStreamEventFlags(kFSEventStreamEventFlagItemModified)
        let note = "/vault/Ideas/Note.md"
        let git = "/vault/.git/objects/ab/cdef"
        XCTAssertFalse(FileWatcher.shouldNotify(paths: [git, "/vault/.git"], flags: [plain, plain]))
        XCTAssertTrue(FileWatcher.shouldNotify(paths: [git, note], flags: [plain, plain]))
        XCTAssertTrue(FileWatcher.shouldNotify(paths: ["/vault/.github/x.md"], flags: [plain]))
        XCTAssertTrue(FileWatcher.shouldNotify(
            paths: [git], flags: [FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs)]
        ))
        XCTAssertTrue(FileWatcher.shouldNotify(paths: [], flags: []))
    }
}
