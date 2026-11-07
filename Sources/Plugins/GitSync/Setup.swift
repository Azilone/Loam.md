import Foundation

/// Why `sync.setup` stopped, in one sentence.
struct SetupError: Error, LocalizedError, Equatable {
    let message: String
    var errorDescription: String? { message }
}

/// What `sync.setup` was given.
struct SetupRequest: Equatable {
    /// The remote repository's address; needed only when the remote does not exist yet.
    var url: String?
    var remote = "origin"
    /// The branch for a new repository, and the one to sync when given.
    var branch: String?
    /// Where a new repository keeps its data, outside the vault (`git init --separate-git-dir`): advised in iCloud.
    var gitDir: String?
    /// This device's name in commit messages and conflict copies.
    var device: String?
    /// Encrypt what goes to the remote from now on (`SyncEngine.setUpEncryption`).
    var encrypt = false
    /// The most files one sync may commit on this clone (`loam.maxchanges`): for an agent.
    var maxChanges: Int?
    /// How git reaches the remote over SSH here (`core.sshCommand`): an agent's deploy key.
    var sshCommand: String?
    /// Join a remote that does not look like a vault (`confirm=foreign-remote`).
    var allowForeignRemote = false

    init(url: String? = nil, remote: String = "origin", branch: String? = nil, gitDir: String? = nil,
         device: String? = nil, encrypt: Bool = false) {
        self.url = url
        self.remote = remote
        self.branch = branch
        self.gitDir = gitDir
        self.device = device
        self.encrypt = encrypt
    }

    init(arguments: [String: String]) {
        func value(_ key: String) -> String? { arguments[key].flatMap { $0.isEmpty ? nil : $0 } }
        self.init(url: value("url"), remote: value("remote") ?? "origin", branch: value("branch"),
                  gitDir: value("gitDir"), device: value("device"),
                  encrypt: ["true", "yes", "1"].contains(value("encrypt")?.lowercased() ?? ""))
        maxChanges = value("maxChanges").flatMap(Int.init)
        allowForeignRemote = value("confirm") == "foreign-remote"
    }
}

extension SyncEngine {
    /// Lines `.gitignore` gets so per-machine and deleted files never sync.
    static let ignoredByDefault = [".loam/cache/", ".DS_Store", ".trash/"]

    /// Makes the vault a repository that syncs with `request`'s remote and turns automatic sync on. Adds to what is
    /// there and never replaces it: an existing remote with another address stops it. Returns what it did, one
    /// line each. The first sync is the caller's to run.
    func setUp(_ request: SetupRequest) async throws -> [String] {
        var report: [String] = []
        let dotGit = root.appendingPathComponent(".git").path
        if FileManager.default.fileExists(atPath: dotGit) {
            let top = await git(["rev-parse", "--show-toplevel"])
            guard top.succeeded else { throw SetupError(message: Git.summary(top.stderr)) }
            guard Self.samePath(top.text, root.path) else {
                throw SetupError(message: "The vault is inside the git repository \(top.text): sync needs one of its own.")
            }
        } else {
            let outer = await git(["rev-parse", "--show-toplevel"])
            if outer.succeeded {
                throw SetupError(message: "The vault is inside the git repository \(outer.text): sync needs one of its own.")
            }
            var arguments = ["init", "--quiet", "-b", request.branch ?? "main"]
            if let gitDir = request.gitDir {
                let path = (gitDir as NSString).expandingTildeInPath
                try? FileManager.default.createDirectory(at: URL(fileURLWithPath: path).deletingLastPathComponent(),
                                                         withIntermediateDirectories: true)
                arguments += ["--separate-git-dir", path]
            }
            let created = await git(arguments)
            guard created.succeeded else { throw SetupError(message: Git.summary(created.stderr)) }
            report.append(request.gitDir.map { "Created a git repository, its data in \($0)." } ?? "Created a git repository.")
        }

        let ignoreURL = root.appendingPathComponent(".gitignore")
        let ignore = (try? String(contentsOf: ignoreURL, encoding: .utf8)) ?? ""
        let present = Set(ignore.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) })
        let missing = Self.ignoredByDefault.filter { !present.contains($0) && !present.contains("/" + $0) }
        if !missing.isEmpty {
            let separator = ignore.isEmpty || ignore.hasSuffix("\n") ? "" : "\n"
            try await host.write(".gitignore", Data((ignore + separator + missing.joined(separator: "\n") + "\n").utf8))
            report.append("Added to .gitignore: \(missing.joined(separator: " ")).")
        }

        if !(await git(["config", "user.name"])).succeeded {
            let name = NSFullUserName().isEmpty ? NSUserName() : NSFullUserName()
            _ = await git(["config", "--local", "user.name", name])
            report.append("Commits are signed \(name) (git config user.name).")
        }
        if !(await git(["config", "user.email"])).succeeded {
            let email = "\(NSUserName())@\(Self.computerName()).local"
            _ = await git(["config", "--local", "user.email", email])
            report.append("Commits use the address \(email) (git config user.email).")
        }

        let existing = await git(["remote", "get-url", request.remote])
        if let url = request.url {
            if existing.succeeded {
                guard existing.text == url else {
                    throw SetupError(message: "The remote \"\(request.remote)\" already points to "
                                     + "\(Git.redact(existing.text)): remove it with git, or pass remote=<another name>.")
                }
            } else {
                let added = await git(["remote", "add", request.remote, url])
                guard added.succeeded else { throw SetupError(message: Git.summary(added.stderr)) }
                report.append("Syncs with \(Git.redact(url)).")
            }
        } else if !existing.succeeded {
            throw SetupError(message: "Pass the repository's address: sync.setup url=https://github.com/<you>/<vault>.git")
        }

        if let device = request.device {
            _ = await git(["config", "--local", "loam.device", device])
        }
        if let sshCommand = request.sshCommand {
            _ = await git(["config", "--local", "core.sshCommand", sshCommand])
        }
        if let maxChanges = request.maxChanges {
            _ = await git(["config", "--local", "loam.maxchanges", String(maxChanges)])
            report.append("One sync commits at most \(maxChanges) files here; more wait for sync.now confirm=changes.")
        }
        if request.encrypt {
            report += try await setUpEncryption(remote: request.remote, branch: request.branch)
        }
        var settings = await host.settings()
        settings.auto = true
        settings.remote = request.remote
        if let branch = request.branch { settings.branch = branch }
        try await host.updateSettings(settings)
        report.append("Automatic sync is on, as \(await deviceName()).")
        return report
    }

    /// Stops syncing with `remote` and forgets it, to sync with another repository (`sync.setup`). The vault's files and
    /// its history stay, and so does the repository itself: nothing is deleted anywhere. Returns what it did.
    func disconnect(remote: String) async throws -> [String] {
        let url = await git(["remote", "get-url", remote])
        guard url.succeeded else { throw SetupError(message: "This vault is not syncing with a repository.") }
        let removed = await git(["remote", "remove", remote])
        guard removed.succeeded else { throw SetupError(message: Git.summary(removed.stderr)) }
        var report = ["No longer syncs with \(Git.redact(url.text)); its files and history stay here and there."]
        if await localConfig().keyID != nil {
            report.append("The vault stays encrypted with the same key: so will the next repository.")
        }
        return report
    }
}
