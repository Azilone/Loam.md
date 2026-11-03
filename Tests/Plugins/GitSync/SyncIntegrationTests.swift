import XCTest
@testable import GitSyncPlugin

/// Two devices syncing through a bare repository with real git: what two Macs (or a Mac and Obsidian Git) do.
final class SyncIntegrationTests: XCTestCase {
    private var fixture: GitFixture!
    private var devices: [Device] = []
    private let today = SyncEngine.day(Date())

    override func setUp() async throws {
        fixture = try await GitFixture()
    }

    override func tearDown() async throws {
        for device in devices {
            XCTAssertEqual(device.runner.forbidden, [], "a command that can lose work ran")
            for (path, data) in device.files() where path.hasSuffix(".md") {
                XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("<<<<<<<"), "conflict markers in \(path)")
            }
        }
        devices = []
        fixture = nil
    }

    private func device(_ name: String) throws -> Device {
        let device = try fixture.emptyDevice(name)
        devices.append(device)
        return device
    }

    private func clone(_ name: String) async throws -> Device {
        let device = try await fixture.clonedDevice(name)
        devices.append(device)
        return device
    }

    /// A on the remote with `files`, and B cloned from it.
    private func pair(_ files: [String: String]) async throws -> (Device, Device) {
        let a = try device("A")
        for (path, text) in files { try a.write(path, text) }
        let first = try await a.setUp(fixture.remoteURL, device: "A")
        XCTAssertEqual(first.status.state, .synced, first.status.message ?? "")
        return (a, try await clone("B"))
    }

    private func assertSynced(_ outcome: CycleOutcome, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(outcome.status.state, .synced, outcome.status.message ?? "", file: file, line: line)
    }

    func testTheFirstSyncPushesToAnEmptyRemote() async throws {
        let a = try device("A")
        try a.write("Inbox/First.md", "# First\n")
        try a.write(".loam/cache/workspace/machine.json", "{}")
        try a.write(".loam/config.json", "{}")
        let outcome = try await a.setUp(fixture.remoteURL, device: "A")
        assertSynced(outcome)
        XCTAssertEqual(outcome.status.ahead, 0)
        XCTAssertEqual(outcome.status.device, "A")
        let tree = await fixture.remoteGit(["ls-tree", "-r", "--name-only", "main"])
        XCTAssertEqual(tree.text.split(separator: "\n"), [".gitignore", ".loam/config.json", "Inbox/First.md"])
        XCTAssertEqual(a.read(".gitignore"), ".loam/cache/\n.DS_Store\n.trash/\n")
        let log = await fixture.remoteGit(["log", "-1", "--format=%s", "main"])
        XCTAssertTrue(log.text.hasPrefix("vault backup: "), log.text)
        XCTAssertTrue(log.text.hasSuffix(" (A)"), log.text)
        XCTAssertEqual(a.host.stored.auto, true)
    }

    func testDisconnectingForgetsTheRemoteAndKeepsTheNotesAndHistory() async throws {
        let a = try device("A")
        try a.write("Inbox/Mine.md", "# Mine\n")
        assertSynced(try await a.setUp(fixture.remoteURL, device: "A"))
        let report = try await a.engine.disconnect(remote: "origin")
        XCTAssertTrue(report.first?.contains("No longer syncs") == true)
        let remotes = await a.git(["remote"])
        XCTAssertEqual(remotes.text, "")
        XCTAssertNotNil(a.files()["Inbox/Mine.md"])
        let head = await a.git(["rev-parse", "--verify", "HEAD"])
        XCTAssertTrue(head.succeeded, "the history stays")
        let theirs = await fixture.remoteGit(["ls-tree", "-r", "--name-only", "main"])
        XCTAssertTrue(theirs.text.contains("Inbox/Mine.md"), "nothing deleted on the remote")
        do {
            _ = try await a.engine.disconnect(remote: "origin")
            XCTFail("nothing to disconnect from")
        } catch {}

        // Another repository, then: the same vault joins an empty one.
        let other = try await GitFixture()
        assertSynced(try await a.setUp(other.remoteURL, device: "A"))
        let tree = await other.remoteGit(["ls-tree", "-r", "--name-only", "main"])
        XCTAssertTrue(tree.text.contains("Inbox/Mine.md"))
    }

    // MARK: Joining a remote that is not a vault

    private func codebase() -> [String: Data] {
        ["Package.swift": Data("// swift-tools-version: 6.0\n".utf8), "Sources/App/main.swift": Data("print(1)\n".utf8),
         "README.md": Data("# App\n".utf8)]
    }

    func testACodebaseIsNotJoinedAndNothingMovesEitherWay() async throws {
        try await fixture.pushWithoutLoam(codebase())
        let before = await fixture.remoteGit(["rev-parse", "main"]).text
        let a = try device("A")
        try a.write("Inbox/Mine.md", "# Mine\n")
        let outcome = try await a.setUp(fixture.remoteURL, device: "A")
        XCTAssertEqual(outcome.status.state, .attention)
        XCTAssertTrue(outcome.status.message?.contains("do not look like a vault") == true, outcome.status.message ?? "")
        let afterSetup = await fixture.remoteGit(["rev-parse", "main"]).text
        XCTAssertEqual(afterSetup, before, "nothing was pushed")
        XCTAssertNil(a.files()["Package.swift"], "nothing was merged in")
        // The next automatic syncs do not join it either.
        let later = await a.sync(CycleOptions())
        XCTAssertEqual(later.status.state, .attention)
        let afterLater = await fixture.remoteGit(["rev-parse", "main"]).text
        XCTAssertEqual(afterLater, before)
    }

    func testARepositoryWithOtherBranchesButNotThisOneIsNotJoined() async throws {
        try await fixture.pushWithoutLoam(codebase())
        _ = await fixture.remoteGit(["branch", "-m", "main", "master"])
        _ = await fixture.remoteGit(["symbolic-ref", "HEAD", "refs/heads/master"])
        let a = try device("A")
        try a.write("Inbox/Mine.md", "# Mine\n")
        let outcome = try await a.setUp(fixture.remoteURL, device: "A")
        XCTAssertEqual(outcome.status.state, .attention)
        XCTAssertTrue(outcome.status.message?.contains("master") == true, outcome.status.message ?? "")
        let branches = await fixture.remoteGit(["branch", "--list", "main"]).text
        XCTAssertFalse(branches.contains("main"), "no branch of notes started")
    }

    func testAForeignRemoteIsJoinedOnceConfirmedAndTheStartIsKept() async throws {
        try await fixture.pushWithoutLoam(codebase())
        let a = try device("A")
        try a.write("Inbox/Mine.md", "# Mine\n")
        assertSynced(try await a.setUp(fixture.remoteURL, device: "A", allowForeignRemote: true))
        XCTAssertNotNil(a.files()["Package.swift"])
        let joined = await a.git(["rev-parse", "--verify", "refs/loam/before-join"])
        XCTAssertTrue(joined.succeeded, "the state before the join is kept")
        let tree = await a.git(["ls-tree", "-r", "--name-only", "refs/loam/before-join"])
        XCTAssertTrue(tree.text.contains("Inbox/Mine.md"))
        XCTAssertFalse(tree.text.contains("Package.swift"))
    }

    func testARepositoryOfNotesIsJoinedWithoutAsking() async throws {
        try await fixture.pushWithoutLoam(["Reading/Book.md": Data("# Book\n".utf8), "Ideas.md": Data("# Ideas\n".utf8)])
        let a = try device("A")
        try a.write("Inbox/Mine.md", "# Mine\n")
        assertSynced(try await a.setUp(fixture.remoteURL, device: "A"))
        XCTAssertNotNil(a.files()["Reading/Book.md"])
    }

    func testPerMachineFilesNeverSyncEvenWhenTheGitignoreForgetsThem() async throws {
        let (_, b) = try await pair(["Note.md": "v1\n"])
        try b.write(".gitignore", ".DS_Store\n")
        try b.write(".loam/cache/workspace/b.json", "{}")
        assertSynced(await b.sync())
        let tree = await fixture.remoteGit(["ls-tree", "-r", "--name-only", "main"])
        XCTAssertFalse(tree.text.contains(".loam/cache"), tree.text)
    }

    func testEditsOnDifferentLinesMergeWithoutACopy() async throws {
        let (a, b) = try await pair(["Plan.md": "one\ntwo\nthree\nfour\nfive\n"])
        try a.write("Plan.md", "ONE\ntwo\nthree\nfour\nfive\n")
        try b.write("Plan.md", "one\ntwo\nthree\nfour\nFIVE\n")
        assertSynced(await a.sync())
        assertSynced(await b.sync())
        assertSynced(await a.sync())
        XCTAssertEqual(a.read("Plan.md"), "ONE\ntwo\nthree\nfour\nFIVE\n")
        XCTAssertEqual(b.read("Plan.md"), "ONE\ntwo\nthree\nfour\nFIVE\n")
        XCTAssertEqual(a.files().keys.filter(ConflictPlan.isCopy), [])
        XCTAssertEqual(b.host.flushed, ["Plan.md"], "the incoming note was saved before the merge")
        XCTAssertTrue(b.host.reloaded.contains("Plan.md"), "the editor was told the note changed")
    }

    func testTheSameLineChangedTwiceKeepsThisDevicesVersionAndCopiesTheOther() async throws {
        let (a, b) = try await pair(["Plan.md": "# Plan\nship on friday\n"])
        try a.write("Plan.md", "# Plan\nship on monday\n")
        try b.write("Plan.md", "# Plan\nship on tuesday\n")
        assertSynced(await a.sync())
        let outcome = await b.sync()
        assertSynced(outcome)
        let copy = "Plan (conflict B \(today)).md"
        XCTAssertEqual(b.read("Plan.md"), "# Plan\nship on tuesday\n")
        XCTAssertEqual(b.read(copy), "# Plan\nship on monday\n")
        XCTAssertEqual(outcome.status.conflicts, [copy])
        XCTAssertEqual(outcome.status.label, "1 conflict")
        assertSynced(await a.sync())
        XCTAssertEqual(a.files(), b.files(), "both devices end up with the same vault")
        let subject = await b.git(["log", "-1", "--format=%s"])
        XCTAssertEqual(subject.text, "vault sync: merge origin/main (B), 1 conflict copy")
    }

    func testAFileDeletedOnOneSideAndChangedOnTheOtherIsKept() async throws {
        let (a, b) = try await pair(["Kept.md": "v1\n", "Other.md": "v1\n"])
        try a.delete("Kept.md")
        try b.write("Kept.md", "v2 from B\n")
        try a.write("Other.md", "v2 from A\n")
        try b.delete("Other.md")
        assertSynced(await a.sync())
        assertSynced(await b.sync())
        assertSynced(await a.sync())
        for device in [a, b] {
            XCTAssertEqual(device.read("Kept.md"), "v2 from B\n")
            XCTAssertEqual(device.read("Other.md"), "v2 from A\n")
        }
    }

    func testTheSameNewFileOnBothSides() async throws {
        let (a, b) = try await pair(["Readme.md": "hi\n"])
        try a.write("Inbox/Idea.md", "from A\n")
        try b.write("Inbox/Idea.md", "from B\n")
        try a.write("Inbox/Same.md", "same\n")
        try b.write("Inbox/Same.md", "same\n")
        assertSynced(await a.sync())
        assertSynced(await b.sync())
        XCTAssertEqual(b.read("Inbox/Idea.md"), "from B\n")
        XCTAssertEqual(b.read("Inbox/Idea (conflict B \(today)).md"), "from A\n")
        XCTAssertFalse(b.exists("Inbox/Same (conflict B \(today)).md"), "identical files are no conflict")
    }

    func testABinaryConflictKeepsBothFilesWhole() async throws {
        let (a, b) = try await pair(["Readme.md": "hi\n"])
        let original = Data([0x89, 0x50, 0x4E, 0x47, 0, 1, 2, 3])
        try a.writeData("img/photo.png", original)
        assertSynced(await a.sync())
        assertSynced(await b.sync())
        let fromA = Data([0x89, 0x50, 0x4E, 0x47, 0, 9, 9, 9])
        let fromB = Data([0x89, 0x50, 0x4E, 0x47, 0, 7, 7, 7, 7])
        try a.writeData("img/photo.png", fromA)
        try b.writeData("img/photo.png", fromB)
        assertSynced(await a.sync())
        assertSynced(await b.sync())
        XCTAssertEqual(b.files()["img/photo.png"], fromB)
        XCTAssertEqual(b.files()["img/photo (conflict B \(today)).png"], fromA)
    }

    func testOfflineCommitsHereAndPushesOnceTheRemoteIsBack() async throws {
        let (a, _) = try await pair(["Note.md": "v1\n"])
        let away = fixture.base.appendingPathComponent("away.git")
        try FileManager.default.moveItem(at: fixture.remote, to: away)
        try a.write("Note.md", "v2\n")
        let offline = await a.sync()
        XCTAssertEqual(offline.status.state, .offline)
        XCTAssertEqual(offline.networkFailure, .offline)
        XCTAssertEqual(offline.status.label, "Offline")
        let local = await a.git(["log", "-1", "--format=%s"])
        XCTAssertTrue(local.text.hasPrefix("vault backup: "), "the change is committed here")
        try FileManager.default.moveItem(at: away, to: fixture.remote)
        assertSynced(await a.sync())
        let remote = await fixture.remoteGit(["show", "main:Note.md"])
        XCTAssertEqual(remote.text, "v2")
    }

    func testAGitDirOutsideTheVaultWorks() async throws {
        let a = try device("A")
        try a.write("Note.md", "v1\n")
        let gitDir = fixture.base.appendingPathComponent("outside/a.git").path
        assertSynced(try await a.setUp(fixture.remoteURL, device: "A", gitDir: gitDir))
        var isFolder: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: a.root.appendingPathComponent(".git").path, isDirectory: &isFolder))
        XCTAssertFalse(isFolder.boolValue, ".git is a file pointing outside")
        let b = try await clone("B")
        try b.write("Note.md", "v1\nfrom B\n")
        assertSynced(await b.sync())
        try a.write("Note.md", "from A\nv1\n")
        assertSynced(await a.sync())
        XCTAssertEqual(a.read("Note.md"), "from A\nv1\nfrom B\n")
    }

    func testAMergeLeftByAnotherToolIsLeftAloneUntilAskedToFinish() async throws {
        let (a, b) = try await pair(["Plan.md": "one\n"])
        try a.write("Plan.md", "from A\n")
        assertSynced(await a.sync())
        try b.write("Plan.md", "from B\n")
        _ = await b.byHand(["commit", "--quiet", "-am", "by hand"])
        _ = await b.byHand(["fetch", "--quiet"])
        let manual = await b.byHand(["merge", "origin/main"])
        XCTAssertFalse(manual.succeeded, "the hand-made merge stops on the conflict")
        let refused = await b.sync()
        XCTAssertEqual(refused.status.state, .attention)
        XCTAssertTrue(refused.status.message?.contains("sync.resolve") == true, refused.status.message ?? "")
        XCTAssertTrue(b.read("Plan.md")?.contains("<<<<<<<") == true, "nothing was touched")
        let finished = await b.sync(CycleOptions(forceMerge: true, resolveForeignMerge: true))
        assertSynced(finished)
        XCTAssertEqual(b.read("Plan.md"), "from B\n")
        XCTAssertEqual(b.read("Plan (conflict B \(today)).md"), "from A\n")
    }

    func testDeletingMostOfTheVaultAtOnceWaitsForConfirmation() async throws {
        var files: [String: String] = [:]
        for index in 0..<60 { files["Notes/\(index).md"] = "note \(index)\n" }
        let (a, _) = try await pair(files)
        try FileManager.default.removeItem(at: a.root.appendingPathComponent("Notes"))
        let paused = await a.sync()
        XCTAssertEqual(paused.status.state, .attention)
        XCTAssertTrue(paused.status.message?.contains("confirm=deletions") == true)
        let remote = await fixture.remoteGit(["ls-tree", "-r", "--name-only", "main"])
        XCTAssertEqual(remote.text.split(separator: "\n").count, 61, "nothing was deleted on the remote")
        assertSynced(await a.sync(CycleOptions(allowDeletions: true, forceMerge: true)))
        let after = await fixture.remoteGit(["ls-tree", "-r", "--name-only", "main"])
        XCTAssertEqual(after.text, ".gitignore")
    }

    func testNamesWithAccentsSpacesAndPatternCharacters() async throws {
        let names = ["Idées/Note de Kévin.md", "Why? [draft].md", "*star*.md"]
        let (a, b) = try await pair(Dictionary(uniqueKeysWithValues: names.map { ($0, "v1\n") }))
        for name in names {
            try a.write(name, "A\n")
            try b.write(name, "B\n")
        }
        assertSynced(await a.sync())
        let outcome = await b.sync()
        assertSynced(outcome)
        for name in names {
            XCTAssertEqual(b.read(name), "B\n", name)
            let copy = ConflictPlan.copyPath(for: name, device: "B", day: today) { _ in false }
            XCTAssertEqual(b.read(copy), "A\n", copy)
        }
        XCTAssertEqual(outcome.status.conflicts.count, 3)
    }

    func testANoteBeingTypedInWaitsThenTheMergeGoesAhead() async throws {
        let (a, b) = try await pair(["Plan.md": "one\n"])
        try a.write("Plan.md", "one\ntwo\n")
        assertSynced(await a.sync())
        b.host.busy = ["Plan.md"]
        let waiting = await b.sync(CycleOptions())
        XCTAssertTrue(waiting.mergeDeferred)
        XCTAssertEqual(waiting.status.state, .syncing)
        XCTAssertEqual(b.read("Plan.md"), "one\n")
        assertSynced(await b.sync(CycleOptions(forceMerge: true)))
        XCTAssertEqual(b.read("Plan.md"), "one\ntwo\n")
    }

    func testASyncSaysWhichDeviceChangedWhat() async throws {
        let (a, b) = try await pair(["Plan.md": "one\n"])
        _ = await a.git(["config", "loam.device", "agent-research"])
        try a.write("Plan.md", "one\ntwo\n")
        try a.write("Ideas/New.md", "idea\n")
        assertSynced(await a.sync())
        let outcome = await b.sync()
        assertSynced(outcome)
        XCTAssertEqual(outcome.status.incoming, [SyncStatus.DeviceChanges(device: "agent-research",
                                                                          files: ["Ideas/New.md", "Plan.md"])])
        XCTAssertEqual(outcome.status.sentence, "Synced: agent-research changed 2 notes.")
        let quiet = await b.sync()
        XCTAssertEqual(quiet.status.incoming, [], "only the sync that brought them in says so")
    }

    func testDeviceNamesComeFromLoamCommitSubjects() {
        XCTAssertEqual(SyncEngine.deviceNamed(in: "vault backup: 2026-10-20 10:00:00 (MacBook Pro)"), "MacBook Pro")
        XCTAssertEqual(SyncEngine.deviceNamed(in: "vault sync: merge origin/main (A), 2 conflict copies"), "A")
        XCTAssertNil(SyncEngine.deviceNamed(in: "Fix typo (#12)"))
    }

    func testUndoingAnAgentKeepsEveryoneElsesChanges() async throws {
        let (a, b) = try await pair(["Plan.md": "one\n", "Other.md": "x\n"])
        _ = await a.git(["config", "loam.device", "agent-bad"])
        try a.write("Plan.md", "garbage\n")
        try a.delete("Other.md")
        assertSynced(await a.sync())
        assertSynced(await b.sync())
        try b.write("Mine.md", "kept\n")
        assertSynced(await b.sync())

        let changed = try await b.engine.undo(device: "agent-bad", since: nil)
        XCTAssertEqual(Set(changed), ["Plan.md", "Other.md"])
        XCTAssertEqual(b.read("Plan.md"), "one\n")
        XCTAssertEqual(b.read("Other.md"), "x\n")
        XCTAssertEqual(b.read("Mine.md"), "kept\n")
        assertSynced(await b.sync())
        assertSynced(await a.sync())
        XCTAssertEqual(a.read("Plan.md"), "one\n", "the undo reaches the agent too")
        let history = await b.git(["log", "--format=%s", "-3"])
        XCTAssertTrue(history.text.contains("undo 1 change by agent-bad"), history.text)
    }

    func testUndoStopsWhenTheSameLinesChangedSince() async throws {
        let (a, b) = try await pair(["Plan.md": "one\n"])
        _ = await a.git(["config", "loam.device", "agent-bad"])
        try a.write("Plan.md", "agent\n")
        assertSynced(await a.sync())
        assertSynced(await b.sync())
        try b.write("Plan.md", "user fixed it\n")
        assertSynced(await b.sync())
        do {
            _ = try await b.engine.undo(device: "agent-bad", since: nil)
            XCTFail("undo went ahead over a later change")
        } catch let error as SetupError {
            XCTAssertTrue(error.message.contains("changed again"), error.message)
        }
        XCTAssertEqual(b.read("Plan.md"), "user fixed it\n", "nothing changed")
        let clean = await b.git(["status", "--porcelain"])
        XCTAssertEqual(clean.text, "")
    }

    func testSinceTakesDaysTimesAndSpans() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertEqual(SyncEngine.parseSince("6h", now: now), now.addingTimeInterval(-6 * 3600))
        XCTAssertEqual(SyncEngine.parseSince("2d", now: now), now.addingTimeInterval(-2 * 86400))
        XCTAssertNotNil(SyncEngine.parseSince("2026-10-28", now: now))
        XCTAssertNotNil(SyncEngine.parseSince("2026-10-28T14:00", now: now))
        XCTAssertNil(SyncEngine.parseSince("yesterday", now: now))
    }

    func testADeviceJoiningWithItsOwnSettingsMakesNoConflictCopy() async throws {
        let a = try device("A")
        try a.write(".loam/config.json", #"{"plugins":{"squeeze":{"settings":{"ffmpegPath":"/opt/homebrew/bin/ffmpeg"}}}}"#)
        try a.write("Note.md", "hi\n")
        assertSynced(try await a.setUp(fixture.remoteURL, device: "A"))
        let agent = try device("Agent")
        try agent.write(".loam/config.json", #"{"plugins":{"squeeze":{"settings":{"ffmpegPath":""}},"meetings":{"settings":{"myName":"Me"}}}}"#)
        let joined = try await agent.setUp(fixture.remoteURL, device: "Agent")
        assertSynced(joined)
        XCTAssertEqual(joined.status.conflicts, [], "settings merge, no copy")
        let settings = try XCTUnwrap(agent.read(".loam/config.json"))
        XCTAssertTrue(settings.contains("/opt/homebrew/bin/ffmpeg"), "the vault's values win: \(settings)")
        XCTAssertTrue(settings.contains("myName"), "the joining device's own keys stay")
        assertSynced(await a.sync())
        XCTAssertTrue(a.read(".loam/config.json")?.contains("/opt/homebrew/bin/ffmpeg") == true, "the Mac keeps its paths")
    }

    func testNotesPushedWithConflictMarkersAreFlagged() async throws {
        let (a, b) = try await pair(["Plan.md": "one\n"])
        try a.write("Plan.md", "<<<<<<< HEAD\nmine\n=======\ntheirs\n>>>>>>> abc123\n")
        assertSynced(await a.sync())
        let outcome = await b.sync()
        assertSynced(outcome)
        XCTAssertTrue(outcome.status.warnings.contains { $0.contains("Conflict markers") && $0.contains("Plan.md") },
                      "\(outcome.status.warnings)")
        // The fixture checks every vault for markers at the end: these were on purpose.
        try a.write("Plan.md", "one\n")
        try b.write("Plan.md", "one\n")
    }

    func testAnAgentsLimitStopsARunawayChange() async throws {
        let (_, b) = try await pair(["Plan.md": "one\n"])
        _ = await b.git(["config", "loam.maxchanges", "3"])
        for index in 1...5 { try b.write("Note \(index).md", "x\n") }
        let stopped = await b.sync()
        XCTAssertEqual(stopped.status.state, .attention)
        XCTAssertTrue(stopped.status.message?.contains("limit of 3") == true, stopped.status.message ?? "")
        let waiting = await b.git(["status", "--porcelain"])
        XCTAssertEqual(waiting.text.split(separator: "\n").count, 5, "nothing committed")
        assertSynced(await b.sync(CycleOptions(forceMerge: true, allowManyChanges: true)))
    }

    func testAMergePutOffForTypingDoesNotPushIntoARejection() async throws {
        let (a, b) = try await pair(["Plan.md": "one\n", "Other.md": "x\n"])
        try a.write("Plan.md", "one\ntwo\n")
        assertSynced(await a.sync())
        try b.write("Other.md", "x\ny\n")
        b.host.busy = ["Plan.md"]
        let waiting = await b.sync(CycleOptions())
        XCTAssertTrue(waiting.mergeDeferred)
        XCTAssertEqual(waiting.status.state, .syncing, waiting.status.message ?? "")
        XCTAssertFalse(waiting.retrySoon)
        b.host.busy = []
        assertSynced(await b.sync())
        assertSynced(await a.sync())
        XCTAssertEqual(a.read("Other.md"), "x\ny\n")
    }

    func testAnEditorThatKeptItsOwnTextGetsTheMergedVersionNextToIt() async throws {
        let (a, b) = try await pair(["Plan.md": "one\n"])
        try a.write("Plan.md", "one\nfrom A\n")
        assertSynced(await a.sync())
        b.host.kept = ["Plan.md"]
        assertSynced(await b.sync())
        XCTAssertEqual(b.read("Plan (conflict B \(today)).md"), "one\nfrom A\n")
        let tracked = await b.git(["ls-files", "--", "Plan (conflict B \(today)).md"])
        XCTAssertFalse(tracked.text.isEmpty, "the copy is committed, so the other device gets it")
    }

    func testStatusReportsWithoutChangingAnything() async throws {
        let (a, _) = try await pair(["Note.md": "v1\n"])
        try a.write("Note.md", "v2\n")
        let before = a.runner.commands.count
        let status = await a.engine.inspect()
        XCTAssertEqual(status.uncommitted, 1)
        XCTAssertEqual(status.remoteURL, fixture.remoteURL)
        XCTAssertEqual(status.branch, "main")
        let ran = a.runner.commands.dropFirst(before).compactMap(\.first)
        XCTAssertFalse(ran.contains { ["add", "commit", "fetch", "push", "merge"].contains($0) }, "\(ran)")
    }

    func testANonRepositoryIsOffAndADetachedHeadNeedsAttention() async throws {
        let plain = try device("plain")
        let off = await plain.sync()
        XCTAssertEqual(off.status.state, .off)
        XCTAssertEqual(plain.runner.commands, [], "no git runs in a folder without a repository")

        let (a, _) = try await pair(["Note.md": "v1\n"])
        _ = await a.byHand(["checkout", "--quiet", "--detach"])
        let detached = await a.sync()
        XCTAssertEqual(detached.status.state, .attention)
        _ = await a.byHand(["checkout", "--quiet", "main"])
    }

    func testSetupRefusesARemoteThatPointsElsewhere() async throws {
        let (a, _) = try await pair(["Note.md": "v1\n"])
        do {
            _ = try await a.engine.setUp(SetupRequest(url: "https://example.com/other.git"))
            XCTFail("setup replaced a remote")
        } catch let error as SetupError {
            XCTAssertTrue(error.message.contains("already points to"), error.message)
        }
    }
}
