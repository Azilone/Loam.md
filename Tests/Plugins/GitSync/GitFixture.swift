import Foundation
import XCTest
@testable import GitSyncPlugin

/// A bare repository standing in for GitHub, and "devices" cloning it, with git isolated from the user's own
/// config (no identity, hooks or helpers leak in) and a `file://` remote, so nothing goes over the network.
final class GitFixture {
    let base: URL
    let remote: URL
    let environment: [String: String]

    static var gitIsInstalled: Bool {
        ["/usr/bin/git", "/opt/homebrew/bin/git", "/usr/local/bin/git"].contains {
            FileManager.default.isExecutableFile(atPath: $0)
        }
    }

    init() async throws {
        try XCTSkipUnless(Self.gitIsInstalled, "git is not installed")
        base = FileManager.default.temporaryDirectory.appendingPathComponent("loam-git-\(UUID().uuidString)")
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let config = base.appendingPathComponent("gitconfig")
        try """
        [user]
        \tname = Test
        \temail = test@example.com
        [init]
        \tdefaultBranch = main
        [advice]
        \tdetachedHead = false
        """.write(to: config, atomically: true, encoding: .utf8)
        environment = ["HOME": base.path, "GIT_CONFIG_GLOBAL": config.path, "GIT_CONFIG_NOSYSTEM": "1"]
        remote = base.appendingPathComponent("remote.git")
        let made = await ProcessGitRunner(directory: base, environment: environment)
            .run(["init", "--quiet", "--bare", "-b", "main", remote.path])
        XCTAssertTrue(made.succeeded, made.stderr)
    }

    deinit {
        try? FileManager.default.removeItem(at: base)
    }

    var remoteURL: String { remote.absoluteString }

    /// The tests' build of `loam crypt` (`GitCryptTool`), in the build folder: next to the test bundle on a Mac, the
    /// folder Linux reports as the bundle.
    static var cryptToolPath: String {
        let bundle = Bundle(for: GitFixture.self).bundleURL
        let candidates = [bundle.deletingLastPathComponent(), bundle].map { $0.appendingPathComponent("GitCryptTool").path }
        return candidates.first(where: FileManager.default.isExecutableFile(atPath:)) ?? candidates[0]
    }

    /// `loam crypt` as git runs it.
    static var cryptTool: String { GitCrypt.quote(cryptToolPath) + " crypt" }

    /// Each device keeps its keys in a folder of its own, its "Keychain": never the user's real one.
    func keyFolder(_ name: String) -> URL {
        base.appendingPathComponent("keys/\(name)")
    }

    /// An empty folder, as a vault that has never synced.
    func emptyDevice(_ name: String, now: @escaping @Sendable () -> Date = { Date() },
                     cryptTool: String = GitFixture.cryptTool) throws -> Device {
        let root = base.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return Device(root: root, environment: environment, keys: keyFolder(name), now: now, cryptTool: cryptTool)
    }

    /// A clone of the remote, as a second Mac or Obsidian Git would have.
    func clonedDevice(_ name: String, now: @escaping @Sendable () -> Date = { Date() },
                      cryptTool: String = GitFixture.cryptTool) async throws -> Device {
        let root = base.appendingPathComponent(name)
        let cloned = await ProcessGitRunner(directory: base, environment: environment)
            .run(["clone", "--quiet", remoteURL, root.path])
        XCTAssertTrue(cloned.succeeded, cloned.stderr)
        let device = Device(root: root, environment: environment, keys: keyFolder(name), now: now, cryptTool: cryptTool)
        _ = await device.git(["config", "loam.device", name])
        return device
    }

    /// An agent with plain git and no Loam: clones, writes `files` as they are, commits and pushes. Its clone has no
    /// `loam-crypt` filter, so git commits what it is given.
    func pushWithoutLoam(_ files: [String: Data], as name: String = "agent") async throws {
        let root = base.appendingPathComponent("\(name)-\(UUID().uuidString.prefix(6))")
        let git = ProcessGitRunner(directory: base, environment: environment)
        let cloned = await git.run(["clone", "--quiet", remoteURL, root.path])
        XCTAssertTrue(cloned.succeeded, cloned.stderr)
        for (path, data) in files {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
        }
        let inClone = ProcessGitRunner(directory: root, environment: environment)
        for arguments in [["add", "--all"], ["commit", "--quiet", "-m", "\(name) edit"], ["push", "--quiet", "origin", "main"]] {
            let ran = await inClone.run(arguments)
            XCTAssertTrue(ran.succeeded, "\(arguments): \(ran.stderr)")
        }
    }

    /// Runs git on the bare remote.
    func remoteGit(_ arguments: [String]) async -> GitOutput {
        await ProcessGitRunner(directory: remote, environment: environment).run(arguments)
    }
}

/// One vault syncing with the fixture's remote: a real engine on real git, with a host that writes plain files.
final class Device {
    let root: URL
    let host: TestHost
    let runner: RecordingRunner
    let engine: SyncEngine
    let keys: FileKeyStore

    init(root: URL, environment: [String: String], keys folder: URL, now: @escaping @Sendable () -> Date,
         cryptTool: String) {
        self.root = root
        host = TestHost(root: root)
        // git in a terminal finds the device's keys there too.
        let environment = environment.merging(["LOAM_KEY_DIR": folder.path]) { _, new in new }
        runner = RecordingRunner(ProcessGitRunner(directory: root, environment: environment))
        keys = FileKeyStore(directory: folder)
        engine = SyncEngine(root: root, runner: runner, host: host, now: now, keyStore: keys,
                            cryptTool: cryptTool)
    }

    func write(_ path: String, _ text: String) throws {
        try writeData(path, Data(text.utf8))
    }

    func writeData(_ path: String, _ data: Data) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
    }

    func read(_ path: String) -> String? {
        try? String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    func exists(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: root.appendingPathComponent(path).path)
    }

    func delete(_ path: String) throws {
        try FileManager.default.removeItem(at: root.appendingPathComponent(path))
    }

    /// A sync as `sync.now` runs it.
    @discardableResult
    func sync(_ options: CycleOptions = CycleOptions(forceMerge: true)) async -> CycleOutcome {
        await engine.cycle(options)
    }

    /// Sets up sync with the remote and runs the first sync, as `sync.setup url=…` does.
    @discardableResult
    func setUp(_ url: String, device: String, gitDir: String? = nil, encrypt: Bool = false,
               allowForeignRemote: Bool = false) async throws -> CycleOutcome {
        _ = try await engine.setUp(SetupRequest(url: url, gitDir: gitDir, device: device, encrypt: encrypt))
        return await sync(CycleOptions(allowUnrelatedHistories: true, allowForeignRemote: allowForeignRemote,
                                       setUpstream: true, forceMerge: true))
    }

    /// The vault key brought over from `other`, as `sync.key.export` there and `sync.key.import` here do.
    func importKey(from other: Device) async throws {
        _ = try await engine.importKey(try await other.engine.exportKey().exported)
    }

    func git(_ arguments: [String]) async -> GitOutput {
        await runner.run(arguments)
    }

    /// Git run by the test itself, as a person in a terminal would: not checked against the engine's rules.
    func byHand(_ arguments: [String]) async -> GitOutput {
        await runner.inner.run(arguments)
    }

    /// Every file in the work tree, by path, outside `.git`.
    func files() -> [String: Data] {
        var result: [String: Data] = [:]
        let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey])
        while let url = enumerator?.nextObject() as? URL {
            let path = String(url.resolvingSymlinksInPath().path.dropFirst(root.resolvingSymlinksInPath().path.count + 1))
            if path == ".git" || path.hasPrefix(".git/") {
                enumerator?.skipDescendants()
                continue
            }
            if (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true {
                result[path] = try? Data(contentsOf: url)
            }
        }
        return result
    }
}

/// The engine's host for tests: plain file writes, settings in memory, and an editor that can be told which notes
/// are busy or keep their own text.
final class TestHost: SyncHost, @unchecked Sendable {
    let root: URL
    var stored = GitSyncSettings()
    var busy: [String] = []
    var kept: [String] = []
    private(set) var flushed: [String] = []
    private(set) var reloaded: [String] = []
    private(set) var written: [String] = []

    init(root: URL) {
        self.root = root
    }

    func settings() async -> GitSyncSettings { stored }
    func updateSettings(_ settings: GitSyncSettings) async throws { stored = settings }
    func busyPaths(_ paths: [String], quiet: TimeInterval) async -> [String] { paths.filter(busy.contains) }
    func flush(_ paths: [String]) async { flushed += paths }

    func reload(_ paths: [String]) async -> [String] {
        reloaded += paths
        return paths.filter(kept.contains)
    }

    func write(_ path: String, _ data: Data) async throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        written.append(path)
    }
}

/// Runs the real git and records every command, so tests can check the engine never runs one that can lose work.
final class RecordingRunner: GitRunner, @unchecked Sendable {
    let inner: GitRunner
    private let lock = NSLock()
    private var recorded: [[String]] = []
    private var durations: [(command: [String], seconds: Double)] = []

    init(_ inner: GitRunner) {
        self.inner = inner
    }

    var commands: [[String]] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    private func record(_ arguments: [String]) {
        lock.lock()
        defer { lock.unlock() }
        recorded.append(arguments)
    }

    private func time(_ arguments: [String], _ seconds: Double) {
        lock.lock()
        defer { lock.unlock() }
        durations.append((arguments, seconds))
    }

    /// How long each command took, in order.
    var timings: [(command: [String], seconds: Double)] {
        lock.lock()
        defer { lock.unlock() }
        return durations
    }

    func run(_ arguments: [String], input: Data?, timeout: TimeInterval?,
             environment: [String: String]) async -> GitOutput {
        record(arguments)
        let start = Date()
        let output = await inner.run(arguments, input: input, timeout: timeout, environment: environment)
        time(arguments, Date().timeIntervalSince(start))
        return output
    }

    /// Commands that can drop commits or files, which the engine must never run.
    var forbidden: [[String]] {
        commands.filter { command in
            var words = command.filter { $0 != "--literal-pathspecs" }
            while words.first == "-c" { words.removeFirst(min(2, words.count)) }
            guard let verb = words.first else { return false }
            if ["reset", "clean", "rebase", "stash", "filter-branch", "gc", "prune"].contains(verb) { return true }
            if verb == "push", words.contains(where: { $0.hasPrefix("--force") || $0 == "-f" || $0.hasPrefix("+") }) {
                return true
            }
            if verb == "branch", words.contains(where: { ["-D", "-d", "--delete"].contains($0) }) { return true }
            if verb == "checkout", !words.contains("--ours"), !words.contains("--theirs") { return true }
            return false
        }
    }
}
