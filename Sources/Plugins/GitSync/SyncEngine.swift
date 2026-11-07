import Foundation
#if canImport(Glibc)
import Glibc
#endif

/// What the engine needs from the plugin around it: settings, the editor, and writes that go through the vault.
/// Every call hops to the main thread, where the event bus lives.
protocol SyncHost: AnyObject, Sendable {
    func settings() async -> GitSyncSettings
    func busyPaths(_ paths: [String], quiet: TimeInterval) async -> [String]
    func flush(_ paths: [String]) async
    func reload(_ paths: [String]) async -> [String]
    func write(_ path: String, _ data: Data) async throws
    func updateSettings(_ settings: GitSyncSettings) async throws
}

/// How one sync cycle may behave.
struct CycleOptions: Equatable {
    /// Fetch and push. Off while the remote is known to be unreachable: local commits still happen.
    var network = true
    /// Commit even when many files were deleted at once (`sync.now confirm=deletions`).
    var allowDeletions = false
    /// Push commits made before the vault was encrypted, with files in plain text (`sync.now confirm=plain`).
    var allowPlainHistory = false
    /// Join a remote with a history of its own (`sync.setup` only).
    var allowUnrelatedHistories = false
    /// Join a remote that is not a vault, or has other branches but not this one (`sync.setup confirm=foreign-remote`).
    var allowForeignRemote = false
    /// Record the remote branch as the upstream on push (`sync.setup`).
    var setUpstream = false
    /// Merge even when an incoming note is being typed in (`sync.now`, or a merge put off too long).
    var forceMerge = false
    /// Settle a merge another tool left in progress (`sync.resolve`).
    var resolveForeignMerge = false
    /// Take files that came from the remote unencrypted into an encrypted vault (`sync.now confirm=plain-incoming`).
    var allowPlainIncoming = false
    /// Commit more files at once than this clone's limit (`loam.maxchanges`; `sync.now confirm=changes`).
    var allowManyChanges = false
}

/// Where a cycle left things, for the scheduler.
struct CycleOutcome: Equatable {
    var status: SyncStatus
    /// The remote was reached.
    var reachedRemote = false
    /// The remote could not be reached for this reason (`offline`, `authentication`).
    var networkFailure: Git.Failure?
    /// The merge waits for the user to stop typing in a note it changes.
    var mergeDeferred = false
    /// Something passing (a lock, a save racing the merge): try again shortly.
    var retrySoon = false
}

/// One sync, start to end: commit what changed here, merge what changed elsewhere (conflict copies, never conflict
/// markers), push. Never rewrites history and never runs a command that can lose work (`reset`, `clean`, `stash`,
/// `rebase`, a forced push).
final class SyncEngine: @unchecked Sendable {
    let root: URL
    let runner: GitRunner
    let host: SyncHost
    let now: @Sendable () -> Date
    /// Where this device keeps vault keys (the Keychain).
    let keyStore: VaultKeyStore
    /// The shell command git runs for `loam crypt` (`GitCrypt.locateTool`); nil when it was not found.
    let cryptTool: String?
    /// This device's GitHub sign-in, for git over HTTPS to github.com (`GitHub.gitEnvironment`); nil when signed out.
    var gitHubToken: @Sendable () -> String? = { nil }

    /// Files over this size are left out of commits: hosts refuse them, and they would slow every sync.
    static let largeFileLimit = 50 * 1024 * 1024
    /// Network commands give up after this long.
    static let networkTimeout: TimeInterval = 120
    /// Other commands give up after this long: a filter waiting on the Keychain must not hang the sync forever.
    static let localTimeout: TimeInterval = 600
    /// A lock held this long by another git process needs the user.
    static let lockPatience: TimeInterval = 600

    /// Only touched inside a cycle, and cycles never overlap.
    private var lockSeenSince: Date?
    /// This clone's `loam.maxchanges`, read at the start of each cycle.
    private var maxChanges: Int?
    /// The key of an encrypted vault, handed to git's filter; and the keys read from the store once (each read of
    /// the Keychain may ask the user). Behind `cryptLock`: `sync.status` may run during a cycle.
    private var cryptKey: VaultKey?
    private var loadedKeys: [String: VaultKey] = [:]
    /// Files in plain text that pushing would send, found when this clone switched to encryption (`loam.cryptplain`).
    private var plainToPush = 0
    private let cryptLock = NSLock()

    init(root: URL, runner: GitRunner, host: SyncHost, now: @escaping @Sendable () -> Date = { Date() },
         keyStore: VaultKeyStore = VaultKeyStores.system(), cryptTool: String? = GitCrypt.locateTool()) {
        self.root = root
        self.runner = runner
        self.host = host
        self.now = now
        self.keyStore = keyStore
        self.cryptTool = cryptTool
    }

    /// Commands that talk to the remote (and run credential helpers) never get the key.
    private static let networkCommands: Set<String> = ["fetch", "push", "ls-remote", "clone", "pull"]

    func git(_ arguments: [String], input: Data? = nil, timeout: TimeInterval? = nil) async -> GitOutput {
        var environment: [String: String] = [:]
        var arguments = arguments
        if Self.networkCommands.contains(arguments.first ?? ""), let token = gitHubToken() {
            environment.merge(GitHub.gitEnvironment(token: token)) { _, new in new }
        }
        if !Self.networkCommands.contains(arguments.first ?? ""), let key = crypt({ cryptKey }) {
            environment[GitCrypt.keyVariable] = key.bytes.base64EncodedString()
            // Hooks would inherit the key: none run while git holds it.
            arguments = ["-c", "core.hooksPath=/dev/null"] + arguments
        }
        return await runner.run(arguments, input: input, timeout: timeout ?? Self.localTimeout, environment: environment)
    }

    private func crypt<T>(_ body: () -> T) -> T {
        cryptLock.lock()
        defer { cryptLock.unlock() }
        return body()
    }

    /// The key git's filter gets from now on; nil for a plain vault.
    func setCrypt(_ key: VaultKey?) {
        crypt { cryptKey = key }
    }

    /// The key git's filter has now; nil for a plain vault, or before the cycle loaded it.
    var currentKey: VaultKey? { crypt { cryptKey } }

    /// Files in plain text waiting to be pushed (`adopt`); 0 once pushed or when there are none.
    var plainFilesWaiting: Int {
        get { crypt { plainToPush } }
        set { crypt { plainToPush = newValue } }
    }

    /// The key with this id from this device's store, read once per run of the app.
    func loadKey(_ id: String) throws -> VaultKey? {
        if let key = crypt({ loadedKeys[id] }) { return key }
        guard let key = try keyStore.load(id: id) else { return nil }
        remember(key)
        return key
    }

    func remember(_ key: VaultKey) {
        crypt { loadedKeys[key.id] = key }
    }

    // MARK: - The cycle

    /// The repository the vault is, checked: its git dir and the branch to sync.
    private struct Repository {
        let gitDir: String
        let branch: String
        var base: SyncStatus

        func has(_ name: String) -> Bool { FileManager.default.fileExists(atPath: gitDir + "/" + name) }
    }

    private enum Located {
        case found(Repository)
        case stop(CycleOutcome)
    }

    private func locate(_ settings: GitSyncSettings) async -> Located {
        guard FileManager.default.fileExists(atPath: root.appendingPathComponent(".git").path) else {
            return .stop(CycleOutcome(status: SyncStatus(
                state: .off, message: "This vault is not a git repository yet: run sync.setup.")))
        }
        let found = await git(["rev-parse", "--show-toplevel", "--absolute-git-dir"])
        let lines = found.text.split(separator: "\n").map(String.init)
        guard found.succeeded, lines.count == 2 else { return .stop(attention(Git.summary(found.stderr))) }
        guard Self.samePath(lines[0], root.path) else {
            return .stop(attention("The vault is inside a larger git repository (\(lines[0])): sync needs a "
                                      + "repository of its own."))
        }
        let head = await git(["symbolic-ref", "-q", "--short", "HEAD"])
        guard head.succeeded else {
            return .stop(attention("No branch is checked out (detached HEAD): check one out to sync."))
        }
        let branch = settings.branch.isEmpty ? head.text : settings.branch
        guard branch == head.text else {
            return .stop(attention("The branch checked out is \(head.text), but sync is set to \(branch)."))
        }
        let base = SyncStatus(state: .synced, branch: branch, remote: settings.remote, warnings: warnings())
        return .found(Repository(gitDir: lines[1], branch: branch, base: base))
    }

    /// Where things stand, without changing anything or using the network (`sync.status`).
    func inspect() async -> SyncStatus {
        let settings = await host.settings()
        let repository: Repository
        switch await locate(settings) {
        case .stop(let outcome): return outcome.status
        case .found(let found): repository = found
        }
        var status = repository.base
        status.state = settings.auto ? .synced : .off
        status.device = await deviceName()
        switch await prepareEncryption(gitDir: repository.gitDir, remoteRef: nil, base: status, adopt: false) {
        case .stop(let outcome):
            status = outcome.status
        case .ready(let keyID):
            status.encryptionKey = keyID
        case .plain:
            break
        }
        let url = await git(["remote", "get-url", settings.remote])
        status.remoteURL = url.succeeded ? Git.redact(url.text) : nil
        if !url.succeeded { status.message = "No git remote named \"\(settings.remote)\": run sync.setup url=<address>." }
        let listed = await git(["status", "--porcelain=v1", "-z", "--no-renames", "--untracked-files=all"])
        status.uncommitted = Git.parseStatus(listed.stdout).count
        if repository.has("MERGE_HEAD") { status.message = "A merge is in progress." }
        if repository.has("index.lock") { status.message = "Another git process is working in this repository." }
        return await finish(CycleOutcome(status: status), remote: settings.remote, branch: repository.branch,
                            gitDir: repository.gitDir, keepState: true).status
    }

    func cycle(_ options: CycleOptions) async -> CycleOutcome {
        let settings = await host.settings()
        let remote = settings.remote
        let repository: Repository
        switch await locate(settings) {
        case .stop(let outcome): return outcome
        case .found(let found): repository = found
        }
        let gitDir = repository.gitDir
        let branch = repository.branch
        let inGitDir = repository.has
        var base = repository.base

        if inGitDir("index.lock") {
            let since = lockSeenSince ?? now()
            lockSeenSince = since
            if now().timeIntervalSince(since) > Self.lockPatience {
                return attention("Another git process has held \(gitDir)/index.lock for over 10 minutes. If no git is "
                                 + "running, remove that file.", base: base)
            }
            base.state = .syncing
            base.message = "Waiting for another git process to finish."
            return CycleOutcome(status: base, retrySoon: true)
        }
        lockSeenSince = nil
        excludeMachineFiles(gitDir: gitDir)
        let config = await localConfig()
        plainFilesWaiting = config.plainToPush
        maxChanges = config.maxChanges
        switch await prepareEncryption(gitDir: gitDir, remoteRef: nil, base: base, config: config) {
        case .stop(let outcome): return outcome
        case .ready(let keyID): base.encryptionKey = keyID
        case .plain: break
        }
        for (name, what) in [("rebase-merge", "A rebase"), ("rebase-apply", "A rebase"), ("CHERRY_PICK_HEAD", "A cherry-pick"),
                             ("REVERT_HEAD", "A revert"), ("BISECT_LOG", "A bisect")] where inGitDir(name) {
            return attention("\(what) started outside Loam is in progress: finish or abort it with git, then sync again.",
                             base: base)
        }

        let device = config.device ?? Self.computerName()
        base.device = device

        if inGitDir("MERGE_HEAD") {
            let message = (try? String(contentsOfFile: gitDir + "/MERGE_MSG", encoding: .utf8)) ?? ""
            guard message.hasPrefix("vault sync: merge") || options.resolveForeignMerge else {
                return attention("A merge started outside Loam is waiting. Run sync.resolve to finish it with conflict "
                                 + "copies, or finish it with git.", base: base)
            }
            if let failure = await settleMerge(device: device, subject: "vault sync: finish merge", base: base) {
                return failure
            }
        } else if !Git.parseUnmerged(await git(["ls-files", "-u", "-z"]).stdout).isEmpty {
            return attention("Some files are in conflict, but no merge is in progress: fix them with git.", base: base)
        }

        let url = await git(["remote", "get-url", remote])
        guard url.succeeded else {
            return attention("This vault has no git remote named \"\(remote)\": run sync.setup url=<address>.", base: base)
        }
        base.remoteURL = Git.redact(url.text)

        var outcome = CycleOutcome(status: base)
        for attempt in 0..<3 {
            switch await pass(options: options, remote: remote, branch: branch, device: device, gitDir: gitDir,
                              outcome: &outcome) {
            case .done:
                return await finish(outcome, remote: remote, branch: branch, gitDir: gitDir)
            case .stopped:
                return outcome
            case .pushRejected where attempt < 2:
                continue
            case .pushRejected:
                outcome.status.state = .attention
                outcome.status.message = "The remote keeps getting new commits while pushing: try again in a moment."
                outcome.retrySoon = true
                return outcome
            }
        }
        return outcome
    }

    private enum PassResult { case done, stopped, pushRejected }

    /// Fetch, commit, merge, push. `.pushRejected` means the remote moved meanwhile: run it again.
    private func pass(options: CycleOptions, remote: String, branch: String, device: String, gitDir: String,
                      outcome: inout CycleOutcome) async -> PassResult {
        let remoteRef = "refs/remotes/\(remote)/\(branch)"
        var network = options.network
        var plainIncoming: [String] = []

        if network {
            let fetch = await git(["fetch", "--quiet", "--no-tags", "--no-recurse-submodules", remote, branch],
                                  timeout: Self.networkTimeout)
            if fetch.succeeded {
                outcome.reachedRemote = true
            } else {
                switch Git.classify(fetch.stderr) {
                case .missingRemoteBranch:
                    outcome.reachedRemote = true
                case .authentication:
                    // Access removed (an agent whose deploy key was deleted) or a sign-in gone: nothing to do
                    // until it is back. Local changes stay as they are.
                    outcome = attention("The repository refused this device's access (removed, or the sign-in "
                                        + "expired): \(Git.summary(fetch.stderr))", base: outcome.status)
                    outcome.networkFailure = .authentication
                    return .stopped
                case .offline:
                    outcome.networkFailure = .offline
                    outcome.status.message = Git.summary(fetch.stderr)
                    network = false
                case .locked:
                    outcome.status.state = .syncing
                    outcome.retrySoon = true
                    return .stopped
                default:
                    outcome = attention("Fetching failed: \(Git.summary(fetch.stderr))", base: outcome.status)
                    return .stopped
                }
            }
        }

        let hasRemoteRef = await git(["rev-parse", "-q", "--verify", remoteRef + "^{commit}"]).succeeded
        var hasHead = await git(["rev-parse", "-q", "--verify", "HEAD^{commit}"]).succeeded
        // The first sync joins a remote: only one that is a vault (or empty), before anything is merged or pushed.
        if options.allowUnrelatedHistories, network, !options.allowForeignRemote,
           let reason = await foreignRemoteReason(remote: remote, remoteRef: remoteRef, branch: branch,
                                                  hasRemoteRef: hasRemoteRef, hasHead: hasHead) {
            outcome = attention(reason, base: outcome.status)
            return .stopped
        }
        var behind = 0
        if hasRemoteRef {
            if hasHead {
                let counts = await git(["rev-list", "--left-right", "--count", "HEAD...\(remoteRef)"])
                behind = Git.parseAheadBehind(counts.text)?.behind ?? 0
            } else {
                behind = 1
            }
        }

        if behind > 0 {
            let listed = hasHead
                ? await git(["diff", "--name-only", "-z", "--no-renames", "HEAD...\(remoteRef)"])
                : await git(["ls-tree", "-r", "--name-only", "-z", remoteRef])
            let incoming = Git.fields(listed.stdout)
            // The remote may have turned encryption on, or moved to another key: settled before anything is
            // committed. Only `.gitattributes` says so (unrelated histories have no diff: read it, then).
            if !listed.succeeded || incoming.contains(".gitattributes"),
               let stop = await encryptionOfIncoming(remoteRef: remoteRef, gitDir: gitDir, status: &outcome.status) {
                outcome = stop
                return .stopped
            }

            // An encrypted vault takes only ciphertext of its own key: plain text pushed by a clone without the filter
            // stops here (it would be merged silently), and so does ciphertext this device cannot open.
            if hasHead, outcome.status.encryptionKey != nil {
                let check = await checkIncoming(incoming, remoteRef: remoteRef)
                if !check.unreadable.isEmpty {
                    outcome = attention(Self.unreadableIncomingMessage(check.unreadable), base: outcome.status)
                    return .stopped
                }
                if !check.plain.isEmpty, !options.allowPlainIncoming {
                    outcome = attention(Self.plainIncomingMessage(check.plain), base: outcome.status)
                    return .stopped
                }
                plainIncoming = check.plain
            }

            // Notes the merge will change: their unsaved typing goes to disk first, so it is part of the merge.
            let notes = incoming.filter { $0.hasSuffix(".md") }
            if !options.forceMerge, !(await host.busyPaths(notes, quiet: 5)).isEmpty {
                outcome.mergeDeferred = true
            } else {
                await host.flush(notes)
            }
        }

        switch await commitLocalChanges(device: device, allowDeletions: options.allowDeletions,
                                        allowMany: options.allowManyChanges, status: &outcome.status) {
        case .blocked(let blocked):
            outcome = blocked
            return .stopped
        case .committed:
            hasHead = true
        case .nothing:
            break
        }

        if behind > 0, !outcome.mergeDeferred {
            let before = hasHead ? await git(["rev-parse", "HEAD"]).text : ""
            let arriving = hasHead ? await incomingChanges(from: before, to: remoteRef) : []
            if hasHead { await markBeforeMerge(joining: options.allowUnrelatedHistories) }
            var arguments = ["merge", "--ff", "--no-stat", "--quiet", "-m", "vault sync: merge \(remote)/\(branch) (\(device))"]
            if options.allowUnrelatedHistories { arguments.append("--allow-unrelated-histories") }
            let merge = await git(arguments + [remoteRef])
            if !merge.succeeded {
                if FileManager.default.fileExists(atPath: gitDir + "/MERGE_HEAD") {
                    let subject = "vault sync: merge \(remote)/\(branch)"
                    if let failure = await settleMerge(device: device, subject: subject, base: outcome.status) {
                        outcome = failure
                        return .stopped
                    }
                } else if merge.stderr.contains("unrelated histories") {
                    outcome = attention("This vault and the remote have separate histories: run sync.setup to join them.",
                                        base: outcome.status)
                    return .stopped
                } else if merge.stderr.contains("would be overwritten") || Git.classify(merge.stderr) == .locked {
                    // A save landed between the commit and the merge; git touched nothing. Next cycle commits it.
                    outcome.status.state = .syncing
                    outcome.retrySoon = true
                    return .stopped
                } else {
                    outcome = attention("Merging failed: \(Git.summary(merge.stderr))", base: outcome.status)
                    return .stopped
                }
            }
            // Plain files taken from the remote go back up encrypted: the clean filter runs on them again.
            if !plainIncoming.isEmpty {
                if let failure = await literal(["add", "--renormalize", "--"] + plainIncoming, base: outcome.status) {
                    outcome = failure
                    return .stopped
                }
                if !(await git(["diff", "--cached", "--quiet", "--no-textconv"]).succeeded) {
                    let commit = await git(["commit", "--quiet", "-m",
                                            "vault sync: encrypt notes that came unencrypted (\(device))"])
                    guard commit.succeeded else {
                        outcome = attention(Git.summary(commit.stderr), base: outcome.status)
                        return .stopped
                    }
                }
            }
            let changed = before.isEmpty
                ? Git.fields(await git(["ls-files", "-z"]).stdout)
                : Git.fields(await git(["diff", "--name-only", "-z", "--no-renames", before, "HEAD"]).stdout)
            outcome.status.incoming = arriving
            // A tool merging with plain git (an agent) may push a note with conflict markers: both versions are in
            // it, so nothing is lost, but the user should look.
            let marked = changed.filter { $0.hasSuffix(".md") && Self.hasConflictMarkers(root.appendingPathComponent($0)) }
            if !marked.isEmpty {
                outcome.status.warnings.append("Conflict markers (<<<<<<< … >>>>>>>) came in \(Self.list(marked)): both "
                                               + "versions are in the note; keep the right one.")
            }
            let kept = await host.reload(changed.filter { $0.hasSuffix(".md") })
            if !kept.isEmpty, let failure = await keepMergedVersions(of: kept, device: device, base: outcome.status) {
                outcome = failure
                return .stopped
            }
        }

        // Behind with the merge put off: the remote would refuse the push, so it waits for the merge.
        if network, !(behind > 0 && outcome.mergeDeferred) {
            let ahead: Int
            if hasRemoteRef {
                ahead = Int(await git(["rev-list", "--count", "\(remoteRef)..HEAD"]).text) ?? 0
            } else {
                ahead = await git(["rev-parse", "-q", "--verify", "HEAD^{commit}"]).succeeded ? 1 : 0
            }
            if ahead > 0 {
                let plain = plainFilesWaiting
                if plain > 0, !options.allowPlainHistory {
                    outcome = attention(Self.plainHistoryMessage(plain), base: outcome.status)
                    return .stopped
                }
                var arguments = ["push", "--quiet", "--porcelain"]
                if options.setUpstream { arguments.append("--set-upstream") }
                let push = await git(arguments + [remote, "HEAD:refs/heads/\(branch)"], timeout: Self.networkTimeout)
                if push.succeeded, plain > 0 { await forgetPlainHistory() }
                if !push.succeeded {
                    let text = push.stderr + "\n" + push.text
                    switch Git.classify(text) {
                    case .rejected:
                        return .pushRejected
                    case .offline, .authentication:
                        outcome.networkFailure = Git.classify(text)
                        outcome.status.message = Git.summary(push.stderr)
                    case .tooLarge:
                        outcome = attention("The remote refused a file that is too large: \(Git.summary(push.stderr))",
                                            base: outcome.status)
                        return .stopped
                    default:
                        outcome = attention("Pushing failed: \(Git.summary(text))", base: outcome.status)
                        return .stopped
                    }
                }
            }
        }
        return .done
    }

    /// Who changed what in the commits `remoteRef` has and `base` does not: the device a Loam commit names at the
    /// end of its subject ("vault backup: … (agent-research)"), else the commit's author. Merges are left out.
    func incomingChanges(from base: String, to remoteRef: String) async -> [SyncStatus.DeviceChanges] {
        let log = await git(["log", "--no-merges", "--format=%x01%an%x02%s", "--name-only", "--no-renames",
                             "\(base)..\(remoteRef)"])
        guard log.succeeded else { return [] }
        var order: [String] = []
        var files: [String: [String]] = [:]
        var device = ""
        for line in log.text.split(separator: "\n").map(String.init) where !line.isEmpty {
            if line.hasPrefix("\u{1}") {
                let parts = line.dropFirst().split(separator: "\u{2}", maxSplits: 1, omittingEmptySubsequences: false)
                    .map(String.init)
                device = Self.deviceNamed(in: parts.count > 1 ? parts[1] : "") ?? parts[0]
                if files[device] == nil { order.append(device) }
                files[device, default: []] += []
            } else if !files[device, default: []].contains(line) {
                files[device, default: []].append(line)
            }
        }
        return order.compactMap { name in
            let changed = files[name] ?? []
            return changed.isEmpty ? nil : SyncStatus.DeviceChanges(device: name, files: changed)
        }
    }

    /// Whether a note holds git's conflict markers: a line starting `<<<<<<< ` and one starting `>>>>>>> `.
    static func hasConflictMarkers(_ url: URL) -> Bool {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return false }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        return lines.contains { $0.hasPrefix("<<<<<<< ") } && lines.contains { $0.hasPrefix(">>>>>>> ") }
    }

    /// The device a Loam commit subject ends with: "vault backup: 2026-10-20 10:00:00 (MacBook)" → MacBook.
    static func deviceNamed(in subject: String) -> String? {
        guard subject.hasPrefix("vault "),
              let range = subject.range(of: #"\(([^()]+)\)(, [^()]*)?$"#, options: .regularExpression) else { return nil }
        let inside = subject[range].dropFirst()
        return inside.prefix { $0 != ")" }.trimmingCharacters(in: .whitespaces)
    }

    // MARK: - Commit

    private enum CommitResult { case nothing, committed, blocked(CycleOutcome) }

    /// Stages and commits everything that changed here, except per-machine files and files too large to sync.
    private func commitLocalChanges(device: String, allowDeletions: Bool, allowMany: Bool,
                                    status: inout SyncStatus) async -> CommitResult {
        let scope = ["--", "."]
        let listed = await git(["status", "--porcelain=v1", "-z", "--no-renames", "--untracked-files=all"] + scope)
        guard listed.succeeded else { return .blocked(blockedOutcome(listed.stderr, base: status)) }
        let entries = Git.parseStatus(listed.stdout)
        guard !entries.isEmpty else { return .nothing }

        // An agent's clone may have a limit: a runaway agent (a bad prompt, a prompt injection) stops here.
        if let maxChanges, entries.count > maxChanges, !allowMany {
            return .blocked(attention(
                "\(entries.count) files changed at once, over this device's limit of \(maxChanges) (git config "
                    + "loam.maxchanges), so sync paused before committing them. If that was intended, run sync.now "
                    + "confirm=changes.", base: status))
        }

        let deletions = entries.filter(\.isDeletion).count
        if deletions >= 50, !allowDeletions {
            let tracked = Git.fields(await git(["ls-files", "-z"]).stdout).count
            if deletions * 4 >= tracked {
                return .blocked(attention(
                    "\(deletions) files were deleted at once, so sync paused to make sure nothing is lost by mistake. "
                        + "If that was you, run sync.now confirm=deletions.", base: status))
            }
        }

        let large = entries.filter { !$0.isDeletion && fileSize($0.path) > Self.largeFileLimit }.map(\.path)
        if !large.isEmpty {
            status.warnings.append("Not synced, over 50 MB: " + large.joined(separator: ", "))
        }
        let add = await git(["add", "--all"] + scope + large.map { ":(exclude,literal)\($0)" })
        guard add.succeeded else { return .blocked(blockedOutcome(add.stderr, base: status)) }
        // No textconv: an encrypted vault's would decrypt every staged file in a process of its own.
        if await git(["diff", "--cached", "--quiet", "--no-textconv"]).succeeded { return .nothing }

        let commit = await git(["commit", "--quiet", "-m", "vault backup: \(Self.timestamp(now())) (\(device))"])
        guard commit.succeeded else {
            if commit.stderr.contains("tell me who you are") || commit.stderr.contains("user.email") {
                return .blocked(attention("git does not know who you are: run sync.setup, or set user.name and "
                                          + "user.email.", base: status))
            }
            return .blocked(blockedOutcome(commit.stderr, base: status))
        }
        return .committed
    }

    private func blockedOutcome(_ stderr: String, base: SyncStatus) -> CycleOutcome {
        if Git.classify(stderr) == .locked {
            var status = base
            status.state = .syncing
            return CycleOutcome(status: status, retrySoon: true)
        }
        return attention(Git.summary(stderr), base: base)
    }

    // MARK: - Conflicts

    /// Settles every path in conflict (`ConflictPlan`) and commits the merge. Returns an outcome only on failure.
    private func settleMerge(device: String, subject: String, base: SyncStatus) async -> CycleOutcome? {
        var entries = Git.parseUnmerged(await git(["ls-files", "-u", "-z"]).stdout)
        // Loam's settings merge key by key: no conflict copy of them.
        for path in Set(entries.map(\.path)) where ConflictPlan.isSettings(path) {
            let stages = Dictionary(entries.filter { $0.path == path }.map { ($0.stage, $0.oid) }) { a, _ in a }
            guard let ours = stages[2], let theirs = stages[3] else { continue }
            func content(_ oid: String) async -> Data? {
                let read = await git(["cat-file", "--filters", "--path=\(path)", oid])
                return read.succeeded ? read.stdout : nil
            }
            var original: Data?
            if let oid = stages[1] { original = await content(oid) }
            guard let mine = await content(ours), let other = await content(theirs),
                  let merged = ConflictPlan.mergeJSON(base: original, ours: mine, theirs: other) else { continue }
            do {
                try await host.write(path, merged)
            } catch {
                return attention("Could not save the merged settings \(path): \(error)", base: base)
            }
            if let failure = await literal(["add", "--", path], base: base) { return failure }
            entries.removeAll { $0.path == path }
        }
        let steps = ConflictPlan.steps(for: entries, device: device, day: Self.day(now())) { path in
            FileManager.default.fileExists(atPath: root.appendingPathComponent(path).path)
        }
        var copies = 0
        for step in steps {
            switch step {
            case .keepOursWithCopy(let path, let oid, let copy):
                let theirs = await git(["cat-file", "--filters", "--path=\(path)", oid])
                guard theirs.succeeded else { return attention(Git.summary(theirs.stderr), base: base) }
                do {
                    try await host.write(copy, theirs.stdout)
                } catch {
                    return attention("Could not save the other version of \(path): \(error)", base: base)
                }
                copies += 1
                if let failure = await literal(["checkout", "--ours", "--", path], base: base) { return failure }
                if let failure = await literal(["add", "--", path, copy], base: base) { return failure }
            case .keepOurs(let path):
                if let failure = await literal(["checkout", "--ours", "--", path], base: base) { return failure }
                if let failure = await literal(["add", "--", path], base: base) { return failure }
            case .keepTheirs(let path):
                if let failure = await literal(["checkout", "--theirs", "--", path], base: base) { return failure }
                if let failure = await literal(["add", "--", path], base: base) { return failure }
            case .remove(let path):
                if let failure = await literal(["rm", "--cached", "--quiet", "--", path], base: base) { return failure }
            }
        }
        guard Git.parseUnmerged(await git(["ls-files", "-u", "-z"]).stdout).isEmpty else {
            return attention("Some conflicts could not be settled: finish the merge with git.", base: base)
        }
        let suffix = copies == 0 ? "" : copies == 1 ? ", 1 conflict copy" : ", \(copies) conflict copies"
        let commit = await git(["commit", "--quiet", "-m", "\(subject) (\(device))\(suffix)"])
        guard commit.succeeded else { return attention(Git.summary(commit.stderr), base: base) }
        return nil
    }

    /// Runs a command whose paths are file names, not patterns (a note may be called `Why? [draft].md`).
    private func literal(_ arguments: [String], base: SyncStatus) async -> CycleOutcome? {
        let output = await git(["--literal-pathspecs"] + arguments)
        return output.succeeded ? nil : attention(Git.summary(output.stderr), base: base)
    }

    /// Notes open with unsaved typing that differs from the merge: the editor's next save will put the user's text
    /// back, so the merged version is kept next to it as a conflict copy, as for any conflict.
    private func keepMergedVersions(of paths: [String], device: String, base: SyncStatus) async -> CycleOutcome? {
        var copies: [String] = []
        for path in paths {
            let merged = await git(["cat-file", "--filters", "HEAD:\(path)"])
            guard merged.succeeded else { continue }
            let copy = ConflictPlan.copyPath(for: path, device: device, day: Self.day(now())) { candidate in
                FileManager.default.fileExists(atPath: root.appendingPathComponent(candidate).path)
            }
            do {
                try await host.write(copy, merged.stdout)
            } catch {
                return attention("Could not save the merged version of \(path): \(error)", base: base)
            }
            copies.append(copy)
        }
        guard !copies.isEmpty else { return nil }
        if let failure = await literal(["add", "--"] + copies, base: base) { return failure }
        let commit = await git(["commit", "--quiet", "-m", "vault sync: keep both versions of notes being edited (\(device))"])
        return commit.succeeded ? nil : attention(Git.summary(commit.stderr), base: base)
    }

    // MARK: - Status

    /// Fills in the conflict copies, the counts and the last sync, and the state from how the cycle went (unless
    /// `keepState`).
    private func finish(_ outcome: CycleOutcome, remote: String, branch: String, gitDir: String,
                        keepState: Bool = false) async -> CycleOutcome {
        var outcome = outcome
        var status = outcome.status
        let tracked = Git.fields(await git(["ls-files", "-z"]).stdout)
        status.conflicts = ConflictPlan.copies(in: tracked)
        let remoteRef = "refs/remotes/\(remote)/\(branch)"
        if await git(["rev-parse", "-q", "--verify", remoteRef + "^{commit}"]).succeeded,
           let counts = Git.parseAheadBehind(await git(["rev-list", "--left-right", "--count", "HEAD...\(remoteRef)"]).text) {
            status.ahead = counts.ahead
            status.behind = counts.behind
        }
        status.lastSync = modified(gitDir + "/FETCH_HEAD")
        if keepState {
            outcome.status = status
            return outcome
        }
        switch outcome.networkFailure {
        case .authentication?:
            status.state = .attention
            status.message = "The remote refused the credentials: \(status.message ?? "")"
                + " Check you can push with git from a terminal, then sync again."
        case .offline?:
            status.state = .offline
            if let last = status.lastSync, now().timeIntervalSince(last) > 24 * 3600 {
                status.state = .attention
                status.message = "Not synced for over a day: \(status.message ?? "the remote cannot be reached")."
            }
        default:
            status.state = outcome.mergeDeferred ? .syncing : .synced
            status.message = outcome.mergeDeferred ? "Waiting for you to stop typing to bring in other changes." : nil
        }
        outcome.status = status
        return outcome
    }

    /// What the incoming commits mean for encryption: a plain clone whose remote is now encrypted switches
    /// (`prepareEncryption`); an encrypted one whose remote names another key stops.
    private func encryptionOfIncoming(remoteRef: String, gitDir: String, status: inout SyncStatus) async
        -> CycleOutcome? {
        guard let keyID = status.encryptionKey else {
            guard await remoteDeclaredKey(remoteRef) != nil else { return nil }
            switch await prepareEncryption(gitDir: gitDir, remoteRef: remoteRef, base: status) {
            case .stop(let outcome): return outcome
            case .ready(let keyID): status.encryptionKey = keyID
            case .plain: break
            }
            return nil
        }
        if let remoteKey = await remoteDeclaredKey(remoteRef), !remoteKey.isEmpty, remoteKey != keyID {
            if await followKey(remoteKey) {
                status.encryptionKey = remoteKey
                return nil
            }
            return attention("The remote is encrypted with another key (\(remoteKey)) than this device's (\(keyID)): "
                             + "bring that key here with sync.key.import.", base: status)
        }
        return nil
    }

    func attention(_ message: String, base: SyncStatus = SyncStatus(state: .attention)) -> CycleOutcome {
        var status = base
        status.state = .attention
        status.message = message
        return CycleOutcome(status: status)
    }

    /// Per-machine files (`.loam/cache/`) never sync, even when the vault's `.gitignore` does not list them: this
    /// clone's own ignore file (`info/exclude`, never pushed) lists them.
    private func excludeMachineFiles(gitDir: String) {
        let url = URL(fileURLWithPath: gitDir).appendingPathComponent("info/exclude")
        let current = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        let line = "/.loam/cache/"
        guard !current.split(separator: "\n").contains(Substring(line)) else { return }
        let separator = current.isEmpty || current.hasSuffix("\n") ? "" : "\n"
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data((current + separator + "# Loam: per-machine files\n" + line + "\n").utf8).write(to: url, options: .atomic)
    }

    private func warnings() -> [String] {
        var isFolder: ObjCBool = false
        let dotGit = root.appendingPathComponent(".git").path
        if root.path.contains("/Library/Mobile Documents/"),
           FileManager.default.fileExists(atPath: dotGit, isDirectory: &isFolder), isFolder.boolValue {
            return ["The .git folder is inside iCloud Drive, which can damage it. Move it out with "
                    + "git init --separate-git-dir ~/.vault-git/<name>.git"]
        }
        return []
    }

    // MARK: - Helpers

    /// `git config loam.device`, kept in this clone only, else the computer's name.
    func deviceName() async -> String {
        let configured = await git(["config", "--local", "--get", "loam.device"])
        if configured.succeeded, !configured.text.isEmpty { return configured.text }
        return Self.computerName()
    }

    static func computerName() -> String {
        var buffer = [CChar](repeating: 0, count: 256)
        guard gethostname(&buffer, 255) == 0 else { return "device" }
        var name = String(cString: buffer)
        if name.hasSuffix(".local") { name.removeLast(".local".count) }
        return name.isEmpty ? "device" : name
    }

    private func fileSize(_ path: String) -> Int {
        let attributes = try? FileManager.default.attributesOfItem(atPath: root.appendingPathComponent(path).path)
        return (attributes?[.size] as? NSNumber)?.intValue ?? 0
    }

    private func modified(_ path: String) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
    }

    static func samePath(_ a: String, _ b: String) -> Bool {
        func canonical(_ path: String) -> String {
            URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path.precomposedStringWithCanonicalMapping
        }
        return canonical(a) == canonical(b)
    }

    private static func formatter(_ format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = format
        return formatter
    }

    /// The commit date, as Obsidian Git writes it (`YYYY-MM-DD HH:mm:ss`).
    static func timestamp(_ date: Date) -> String { formatter("yyyy-MM-dd HH:mm:ss").string(from: date) }
    static func day(_ date: Date) -> String { formatter("yyyy-MM-dd").string(from: date) }
}
