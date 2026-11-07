import XCTest
@testable import GitSyncPlugin

/// Devices syncing an encrypted vault through a bare repository, with real git running the real filter and merge
/// driver (`GitCryptTool`, the code of `loam crypt`): the remote only ever holds ciphertext, the vaults stay plain.
final class EncryptedSyncTests: XCTestCase {
    private var fixture: GitFixture!
    private var devices: [Device] = []
    private let today = SyncEngine.day(Date())

    override func setUp() async throws {
        fixture = try await GitFixture()
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: GitFixture.cryptToolPath), "GitCryptTool is not built")
    }

    override func tearDown() async throws {
        for device in devices {
            XCTAssertEqual(device.runner.forbidden, [], "a command that can lose work ran")
            for (path, data) in device.files() where path.hasSuffix(".md") {
                XCTAssertFalse(CryptCodec.isEncrypted(data), "ciphertext in the vault: \(path)")
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

    private func assertSynced(_ outcome: CycleOutcome, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(outcome.status.state, .synced, outcome.status.message ?? "", file: file, line: line)
    }

    /// A on an encrypted remote with `files`, and B cloned from it with the key.
    private func pair(_ files: [String: String]) async throws -> (Device, Device) {
        let a = try device("A")
        for (path, text) in files { try a.write(path, text) }
        assertSynced(try await a.setUp(fixture.remoteURL, device: "A", encrypt: true))
        let b = try await clone("B")
        try await b.importKey(from: a)
        assertSynced(await b.sync())
        for (path, text) in files { XCTAssertEqual(b.read(path), text, path) }
        return (a, b)
    }

    /// Every blob ever pushed, by object id, with the paths it was seen at.
    private func remoteBlobs() async -> [(oid: String, path: String, data: Data)] {
        let listed = await fixture.remoteGit(["rev-list", "--objects", "--all"])
        var blobs: [(String, String, Data)] = []
        for line in listed.text.split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            guard (await fixture.remoteGit(["cat-file", "-t", parts[0]])).text == "blob" else { continue }
            blobs.append((parts[0], parts[1], (await fixture.remoteGit(["cat-file", "blob", parts[0]])).stdout))
        }
        return blobs
    }

    // MARK: - What the remote holds

    func testTheRemoteHoldsOnlyCiphertext() async throws {
        let a = try device("A")
        try a.write("Inbox/Secret.md", "# Secret\nThe launch code is 1234.\n")
        try a.write("Daily/2026-10-20.md", "- met Bob about the launch\n")
        try a.write(".loam/config.json", #"{"plugins":{"git-sync":{"settings":{"auto":true}}}}"#)
        try a.writeData("Attachments/photo.png", Data([0x89, 0x50, 0x4E, 0x47, 0x00, 0x01, 0x02, 0x03]) + Data("launch".utf8))
        let outcome = try await a.setUp(fixture.remoteURL, device: "A", encrypt: true)
        assertSynced(outcome)
        let keyID = try XCTUnwrap(outcome.status.encryptionKey)

        let blobs = await remoteBlobs()
        XCTAssertEqual(Set(blobs.map(\.path)), [".gitattributes", ".gitignore", "Inbox/Secret.md", "Daily/2026-10-20.md",
                                               ".loam/config.json", "Attachments/photo.png", RemoteGuard.workflowPath],
                       "file names stay visible")
        for blob in blobs where !CryptAttributes.isExempt(blob.path) {
            XCTAssertTrue(CryptCodec.isEncrypted(blob.data), "\(blob.path) is not encrypted")
            XCTAssertEqual(CryptCodec.keyID(of: blob.data), keyID)
            for secret in ["launch", "Secret", "Bob", "plugins", "PNG"] {
                XCTAssertNil(blob.data.range(of: Data(secret.utf8)), "\"\(secret)\" readable in \(blob.path)")
            }
        }
        let attributes = await fixture.remoteGit(["show", "main:.gitattributes"])
        XCTAssertEqual(CryptAttributes.declaredKey(in: attributes.text), keyID)
        let log = await fixture.remoteGit(["log", "-p", "--all"])
        XCTAssertFalse(log.text.contains("launch code"), "a diff shows plaintext")

        XCTAssertEqual(a.read("Inbox/Secret.md"), "# Secret\nThe launch code is 1234.\n", "the vault stays plain")
        XCTAssertEqual(a.files()["Attachments/photo.png"]?.prefix(4), Data([0x89, 0x50, 0x4E, 0x47]))
        let configured = await a.git(["config", "--local", "--get", GitCrypt.keyConfig])
        XCTAssertEqual(configured.text, keyID)
        XCTAssertNotNil(try a.keys.load(id: keyID), "the key is in the device's store")
        XCTAssertFalse(a.read(".loam/config.json")?.contains(keyID) ?? true, "the settings never hold the key")
    }

    // MARK: - Agents without Loam

    func testPlainTextFromAToolWithoutTheFilterStopsTheSync() async throws {
        let (_, b) = try await pair(["Note.md": "mine\n"])
        try await fixture.pushWithoutLoam(["Agent.md": Data("from the agent\n".utf8)])
        let stopped = await b.sync()
        XCTAssertEqual(stopped.status.state, .attention)
        XCTAssertTrue(stopped.status.message?.contains("unencrypted") == true, stopped.status.message ?? "")
        XCTAssertTrue(stopped.status.message?.contains("Agent.md") == true)
        XCTAssertFalse(b.exists("Agent.md"), "nothing merged before the user says so")

        assertSynced(await b.sync(CycleOptions(forceMerge: true, allowPlainIncoming: true)))
        XCTAssertEqual(b.read("Agent.md"), "from the agent\n")
        let leaks = await b.engine.leaks()
        XCTAssertEqual(leaks.map(\.path), ["Agent.md"], "the leak stays in history and is reported")
        XCTAssertEqual(leaks.first?.subject, "agent edit")
        let tip = await fixture.remoteGit(["cat-file", "blob", "main:Agent.md"])
        XCTAssertTrue(CryptCodec.isEncrypted(tip.stdout), "the note goes back up encrypted")
    }

    func testTheRemoteCheckFailsOnAPlainFile() async throws {
        let (_, _) = try await pair(["Note.md": "mine\n"])
        let workflow = await fixture.remoteGit(["cat-file", "blob", "main:\(RemoteGuard.workflowPath)"])
        XCTAssertTrue(workflow.text.contains("Loam encrypted"), "the workflow is pushed, readable")
        let passing = try await runCheck()
        XCTAssertEqual(passing, 0, "an encrypted remote passes")
        try await fixture.pushWithoutLoam(["Leak.md": Data("plain\n".utf8)])
        let failing = try await runCheck()
        XCTAssertEqual(failing, 1, "a plain file fails it")
    }

    /// The workflow's script, in a checkout without the filter, as GitHub's runner makes it.
    private func runCheck() async throws -> Int32 {
        let checkout = fixture.base.appendingPathComponent("runner-\(UUID().uuidString.prefix(6))")
        let cloned = await ProcessGitRunner(directory: fixture.base, environment: fixture.environment)
            .run(["clone", "--quiet", fixture.remoteURL, checkout.path])
        XCTAssertTrue(cloned.succeeded, cloned.stderr)
        let bash = Process()
        bash.executableURL = URL(fileURLWithPath: "/bin/bash")
        bash.arguments = ["-c", RemoteGuard.checkScript]
        bash.currentDirectoryURL = checkout
        bash.environment = fixture.environment.merging(["PATH": "/usr/bin:/bin"]) { _, new in new }
        bash.standardOutput = FileHandle.nullDevice
        try bash.run()
        bash.waitUntilExit()
        return bash.terminationStatus
    }

    func testChangingTheKeyLocksOutADeviceWithoutIt() async throws {
        let (a, b) = try await pair(["Plan.md": "one\n"])
        let agent = try await clone("Agent")
        try await agent.importKey(from: a)
        assertSynced(await agent.sync())

        let (old, key) = try await a.engine.rotateKey()
        XCTAssertNotEqual(old, key.id)
        assertSynced(await a.sync())
        let tip = await fixture.remoteGit(["cat-file", "blob", "main:Plan.md"])
        XCTAssertEqual(CryptCodec.keyID(of: tip.stdout), key.id, "every file is encrypted with the new key")

        let asking = await b.sync()
        XCTAssertEqual(asking.status.state, .attention, "B learns of the new key first")
        try await b.importKey(from: a)
        assertSynced(await b.sync())
        try b.write("Plan.md", "one\nfrom B\n")
        assertSynced(await b.sync())
        assertSynced(await a.sync())
        XCTAssertEqual(a.read("Plan.md"), "one\nfrom B\n", "a device with the new key follows it")

        let locked = await agent.sync()
        XCTAssertEqual(locked.status.state, .attention, "the agent without the new key stops")
        XCTAssertTrue(locked.status.message?.contains(key.id) == true, locked.status.message ?? "")
        XCTAssertEqual(agent.read("Plan.md"), "one\n", "and changes nothing")
    }

    func testUndoingAnAgentWorksEncrypted() async throws {
        let (a, b) = try await pair(["Plan.md": "one\ntwo\n"])
        _ = await a.git(["config", "loam.device", "agent-bad"])
        try a.write("Plan.md", "one\nagent\n")
        assertSynced(await a.sync())
        assertSynced(await b.sync())
        let changed = try await b.engine.undo(device: "agent-bad", since: nil)
        XCTAssertEqual(changed, ["Plan.md"])
        XCTAssertEqual(b.read("Plan.md"), "one\ntwo\n")
        assertSynced(await b.sync())
        let tip = await fixture.remoteGit(["cat-file", "blob", "main:Plan.md"])
        XCTAssertTrue(CryptCodec.isEncrypted(tip.stdout))
    }

    func testCiphertextChangedByAToolWithoutTheKeyStopsTheSync() async throws {
        let (_, b) = try await pair(["Note.md": "mine\n"])
        let damaged = CryptCodec.magic + Data(repeating: 7, count: 8) + Data("the agent typed over the noise".utf8)
        try await fixture.pushWithoutLoam(["Note.md": damaged])
        let stopped = await b.sync()
        XCTAssertEqual(stopped.status.state, .attention)
        XCTAssertTrue(stopped.status.message?.contains("cannot be opened") == true, stopped.status.message ?? "")
        XCTAssertEqual(b.read("Note.md"), "mine\n", "our note is untouched")
    }

    func testAnUnchangedFileGivesTheSameBlob() async throws {
        let (a, b) = try await pair(["Note.md": "# Note\nsame text\n"])
        let before = await a.git(["rev-parse", "HEAD", "HEAD:Note.md"])
        try a.write("Note.md", "# Note\nsame text\n")
        assertSynced(await a.sync())
        let after = await a.git(["rev-parse", "HEAD", "HEAD:Note.md"])
        XCTAssertEqual(before.text, after.text, "rewriting a file with the same text makes no commit")

        // B encrypts the same text to the same bytes, so its copy of the file is not a change.
        try b.write("Other.md", "new\n")
        try b.write("Note.md", "# Note\nsame text\n")
        assertSynced(await b.sync())
        let fromB = await fixture.remoteGit(["rev-parse", "main:Note.md"])
        XCTAssertEqual(fromB.text, after.text.split(separator: "\n").last.map(String.init))
    }

    // MARK: - Merges and conflicts, as without encryption

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
        let merged = await fixture.remoteGit(["cat-file", "blob", "main:Plan.md"])
        XCTAssertTrue(CryptCodec.isEncrypted(merged.stdout), "the merge driver encrypts its result")
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
        for path in ["Plan.md", copy] {
            let blob = await fixture.remoteGit(["cat-file", "blob", "main:\(path)"])
            XCTAssertTrue(CryptCodec.isEncrypted(blob.stdout), "\(path) is not encrypted on the remote")
        }
    }

    func testABinaryFileChangedOnBothSidesKeepsBothVersions() async throws {
        let (a, b) = try await pair(["Note.md": "v1\n"])
        try a.writeData("photo.png", Data([0x89, 0x50, 0x4E, 0x47, 0, 1]))
        assertSynced(await a.sync())
        assertSynced(await b.sync())
        try a.writeData("photo.png", Data([0x89, 0x50, 0x4E, 0x47, 0, 2]))
        try b.writeData("photo.png", Data([0x89, 0x50, 0x4E, 0x47, 0, 3]))
        assertSynced(await a.sync())
        assertSynced(await b.sync())
        XCTAssertEqual(b.files()["photo.png"], Data([0x89, 0x50, 0x4E, 0x47, 0, 3]))
        XCTAssertEqual(b.files()["photo (conflict B \(today)).png"], Data([0x89, 0x50, 0x4E, 0x47, 0, 2]))
    }

    func testAFileDeletedOnOneSideAndChangedOnTheOtherIsKept() async throws {
        let (a, b) = try await pair(["Kept.md": "v1\n", "Other.md": "v1\n"])
        try a.delete("Kept.md")
        try b.write("Kept.md", "v2 from B\n")
        assertSynced(await a.sync())
        assertSynced(await b.sync())
        assertSynced(await a.sync())
        for device in [a, b] { XCTAssertEqual(device.read("Kept.md"), "v2 from B\n") }
    }

    // MARK: - Devices without the key

    func testADeviceWithoutTheKeyNeedsAttentionAndChangesNothing() async throws {
        let a = try device("A")
        try a.write("Inbox/Secret.md", "secret\n")
        assertSynced(try await a.setUp(fixture.remoteURL, device: "A", encrypt: true))
        let pushed = await fixture.remoteGit(["rev-parse", "main"])

        let c = try device("C")
        try c.write("Mine.md", "written on C\n")
        let outcome = try await c.setUp(fixture.remoteURL, device: "C")
        XCTAssertEqual(outcome.status.state, .attention)
        XCTAssertEqual(outcome.status.label, "Sync needs attention")
        let message = try XCTUnwrap(outcome.status.message)
        XCTAssertTrue(message.contains("does not have the vault's key"), message)
        XCTAssertTrue(message.contains("sync.key.import"), message)
        XCTAssertFalse(c.exists("Inbox/Secret.md"), "no ciphertext lands in the vault")
        XCTAssertEqual(c.read("Mine.md"), "written on C\n")
        let committed = await c.git(["rev-parse", "-q", "--verify", "HEAD"])
        XCTAssertFalse(committed.succeeded, "nothing was committed")
        let remoteHead = await fixture.remoteGit(["rev-parse", "main"])
        XCTAssertEqual(remoteHead.text, pushed.text, "nothing was pushed")

        // The next syncs stop at once, and the status says the same.
        let again = await c.sync()
        XCTAssertEqual(again.status.state, .attention)
        let inspected = await c.engine.inspect()
        XCTAssertEqual(inspected.state, .attention)
        XCTAssertEqual(inspected.encryptionKey, outcome.status.encryptionKey)

        try await c.importKey(from: a)
        assertSynced(await c.sync(await c.engine.optionsAfterImport()))
        XCTAssertEqual(c.read("Inbox/Secret.md"), "secret\n")
        let mine = await fixture.remoteGit(["cat-file", "blob", "main:Mine.md"])
        XCTAssertTrue(CryptCodec.isEncrypted(mine.stdout), "C's note went up encrypted")
        assertSynced(await a.sync())
        XCTAssertEqual(a.read("Mine.md"), "written on C\n")
    }

    func testAVaultWithItsOwnHistoryJoinsAnEncryptedRemoteWithoutLeakingIt() async throws {
        let a = try device("A")
        try a.write("Note.md", "secret\n")
        assertSynced(try await a.setUp(fixture.remoteURL, device: "A", encrypt: true))
        let pushed = await fixture.remoteGit(["rev-parse", "main"])
        // An Obsidian Git vault of its own, never synced with this remote.
        let c = try device("C")
        try c.write("Mine.md", "C's own history\n")
        for command in [["init", "--quiet", "-b", "main"], ["add", "Mine.md"], ["commit", "--quiet", "-m", "mine"]] {
            let done = await c.byHand(command)
            XCTAssertTrue(done.succeeded, done.stderr)
        }

        let withoutKey = try await c.setUp(fixture.remoteURL, device: "C")
        XCTAssertEqual(withoutKey.status.state, .attention)
        XCTAssertTrue(withoutKey.status.message?.contains("sync.key.import") ?? false, withoutKey.status.message ?? "")
        try await c.importKey(from: a)
        let withKey = await c.sync(await c.engine.optionsAfterImport())
        XCTAssertEqual(withKey.status.state, .attention)
        XCTAssertTrue(withKey.status.message?.contains("plain text") ?? false, withKey.status.message ?? "")
        let remoteHead = await fixture.remoteGit(["rev-parse", "main"])
        XCTAssertEqual(remoteHead.text, pushed.text, "C's plain history stayed on C")
        XCTAssertEqual(c.read("Note.md"), "secret\n", "C still brought the vault in")
    }

    func testAGitCloneWithoutTheKeyNeedsAttentionAndCommitsNothing() async throws {
        let a = try device("A")
        try a.write("Note.md", "secret\n")
        assertSynced(try await a.setUp(fixture.remoteURL, device: "A", encrypt: true))
        // A plain `git clone` (or Obsidian Git) gets the ciphertext.
        let d = try await fixture.clonedDevice("D")
        let head = await d.git(["rev-parse", "HEAD"])
        let outcome = await d.sync()
        XCTAssertEqual(outcome.status.state, .attention)
        XCTAssertTrue(outcome.status.message?.contains("sync.key.import") ?? false, outcome.status.message ?? "")
        let unchanged = await d.git(["rev-parse", "HEAD"])
        XCTAssertEqual(unchanged.text, head.text, "nothing was committed")
        try d.write("New.md", "typed on D\n")
        let staged = await d.byHand(["add", "New.md"])
        XCTAssertFalse(staged.succeeded, "git refuses to commit what it cannot encrypt")
        XCTAssertTrue(staged.stderr.contains("loam-crypt"), staged.stderr)
        try d.delete("New.md")

        // With the key, the clone's files are decrypted in place, and nothing changes in git.
        try await d.importKey(from: a)
        assertSynced(await d.sync())
        XCTAssertEqual(d.read("Note.md"), "secret\n")
        let still = await d.git(["rev-parse", "HEAD"])
        XCTAssertEqual(still.text, head.text)
    }

    func testAnotherVaultsKeyIsRefused() async throws {
        let (_, b) = try await pair(["Note.md": "v1\n"])
        do {
            _ = try await b.engine.importKey(VaultKey.generate().exported)
            XCTFail("another key was accepted")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("is not this vault's"), error.localizedDescription)
        }
        do {
            _ = try await b.engine.importKey("not a key")
            XCTFail("a malformed key was accepted")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("loam-key:"), error.localizedDescription)
        }
    }

    // MARK: - Turning encryption on

    func testAPlainVaultTurnsEncryptionOnAndTheOtherDeviceFollows() async throws {
        let a = try device("A")
        try a.write("Note.md", "v1\n")
        try a.write("Other.md", "other\n")
        assertSynced(try await a.setUp(fixture.remoteURL, device: "A"))
        let b = try await clone("B")
        try b.write("Note.md", "v2 from B, before it knew\n")

        let report = try await a.engine.setUp(SetupRequest(encrypt: true))
        XCTAssertTrue(report.contains { $0.contains("Commits already on the remote stay readable") }, "\(report)")
        assertSynced(await a.sync())
        let tree = await fixture.remoteGit(["ls-tree", "-r", "main"])
        for line in tree.text.split(separator: "\n")
        where !CryptAttributes.isExempt(String(line.split(separator: "\t").last ?? "")) {
            let oid = String(line.split(separator: " ")[2].prefix(40))
            let blob = await fixture.remoteGit(["cat-file", "blob", oid])
            XCTAssertTrue(CryptCodec.isEncrypted(blob.stdout), "\(line) is still plain")
        }

        try await b.importKey(from: a)
        assertSynced(await b.sync())
        let note = await fixture.remoteGit(["cat-file", "blob", "main:Note.md"])
        XCTAssertTrue(CryptCodec.isEncrypted(note.stdout), "B's change went up encrypted")
        XCTAssertEqual(b.read("Note.md"), "v2 from B, before it knew\n")
        assertSynced(await a.sync())
        XCTAssertEqual(a.read("Note.md"), "v2 from B, before it knew\n")
        XCTAssertEqual(a.files(), b.files())
    }

    func testCommitsMadeOfflineBeforeTheSwitchWaitForTheUsersWord() async throws {
        let a = try device("A")
        try a.write("Note.md", "v1\n")
        assertSynced(try await a.setUp(fixture.remoteURL, device: "A"))
        let b = try await clone("B")
        try b.write("Offline.md", "written offline\n")
        _ = await b.sync(CycleOptions(network: false, forceMerge: true))
        _ = try await a.engine.setUp(SetupRequest(encrypt: true))
        assertSynced(await a.sync())

        try await b.importKey(from: a)
        let blocked = await b.sync()
        XCTAssertEqual(blocked.status.state, .attention)
        let message = try XCTUnwrap(blocked.status.message)
        XCTAssertTrue(message.hasPrefix("1 file committed here before the vault was encrypted"), message)
        XCTAssertTrue(message.contains("sync.now confirm=plain"), message)
        let absent = await fixture.remoteGit(["cat-file", "-e", "main:Offline.md"])
        XCTAssertFalse(absent.succeeded, "nothing plain was pushed")
        let again = await b.sync()
        XCTAssertEqual(again.status.state, .attention, "it keeps waiting")

        assertSynced(await b.sync(CycleOptions(allowPlainHistory: true, forceMerge: true)))
        let tip = await fixture.remoteGit(["cat-file", "blob", "main:Offline.md"])
        XCTAssertTrue(CryptCodec.isEncrypted(tip.stdout), "the vault as it is now went up encrypted")
        assertSynced(await b.sync())
        assertSynced(await a.sync())
        XCTAssertEqual(a.read("Offline.md"), "written offline\n")
    }

    func testAVaultsHistoryIsNotPushedToANewEncryptedRemote() async throws {
        let a = try device("A")
        try a.write("Old.md", "a secret from before\n")
        assertSynced(try await a.setUp(fixture.remoteURL, device: "A"))
        let secure = fixture.base.appendingPathComponent("secure.git")
        let made = await ProcessGitRunner(directory: fixture.base, environment: fixture.environment)
            .run(["init", "--quiet", "--bare", "-b", "main", secure.path])
        XCTAssertTrue(made.succeeded, made.stderr)
        let first = CycleOptions(allowUnrelatedHistories: true, setUpstream: true, forceMerge: true)

        _ = try await a.engine.setUp(SetupRequest(url: secure.absoluteString, remote: "secure", encrypt: true))
        let blocked = await a.sync(first)
        XCTAssertEqual(blocked.status.state, .attention)
        XCTAssertTrue(blocked.status.message?.contains("plain text") ?? false, blocked.status.message ?? "")
        let empty = await ProcessGitRunner(directory: secure, environment: fixture.environment)
            .run(["rev-parse", "-q", "--verify", "main"])
        XCTAssertFalse(empty.succeeded, "the new remote got nothing")

        // The way out the message gives: a new history, the old one kept aside.
        try FileManager.default.moveItem(at: a.root.appendingPathComponent(".git"),
                                         to: fixture.base.appendingPathComponent("A-history.git"))
        _ = try await a.engine.setUp(SetupRequest(url: secure.absoluteString, remote: "secure", encrypt: true))
        assertSynced(await a.sync(first))
        let objects = await ProcessGitRunner(directory: secure, environment: fixture.environment)
            .run(["rev-list", "--objects", "--all"])
        for line in objects.text.split(separator: "\n") where line.hasSuffix(" Old.md") {
            let blob = await ProcessGitRunner(directory: secure, environment: fixture.environment)
                .run(["cat-file", "blob", String(line.prefix(40))])
            XCTAssertTrue(CryptCodec.isEncrypted(blob.stdout))
        }
        XCTAssertEqual(a.read("Old.md"), "a secret from before\n")
    }

    func testSetupOnAnEncryptedRemoteUsesItsKey() async throws {
        let a = try device("A")
        try a.write("Note.md", "v1\n")
        assertSynced(try await a.setUp(fixture.remoteURL, device: "A", encrypt: true))
        let keyID = try await a.engine.exportKey().id

        let b = try device("B")
        do {
            _ = try await b.engine.setUp(SetupRequest(url: fixture.remoteURL, device: "B", encrypt: true))
            XCTFail("a second key was made for an encrypted remote")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("encrypted already"), error.localizedDescription)
        }
        try await b.importKey(from: a)
        let outcome = try await b.setUp(fixture.remoteURL, device: "B", encrypt: true)
        assertSynced(outcome)
        XCTAssertEqual(outcome.status.encryptionKey, keyID)
        XCTAssertEqual(b.read("Note.md"), "v1\n")
    }
}
