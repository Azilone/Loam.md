import Foundation

/// What one paste gives a new Mac or an agent: the vault's repository, how to reach it, and the vault's key. Agents
/// get a deploy key of their own (this repository only, removed from GitHub to take access away); a Mac signs in to
/// GitHub instead. A secret: whoever has it can read and change the vault.
public struct ConnectCode: Codable, Equatable, Sendable {
    public static let prefix = "loam-connect:"

    public var version = 1
    /// `owner/name` on GitHub.
    public var repository: String
    /// The address git uses: SSH for an agent (its deploy key), HTTPS for a Mac (its GitHub sign-in).
    public var url: String
    /// The agent's private SSH key (OpenSSH format); nil for a Mac.
    public var sshKey: String?
    /// The vault's key (`loam-key:…`); nil for a vault that is not encrypted.
    public var vaultKey: String?
    /// The name the new device syncs as.
    public var device: String

    public var encoded: String {
        let data = (try? JSONEncoder().encode(self)) ?? Data()
        return Self.prefix + data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    public init(repository: String, url: String, sshKey: String?, vaultKey: String?, device: String) {
        self.repository = repository
        self.url = url
        self.sshKey = sshKey
        self.vaultKey = vaultKey
        self.device = device
    }

    /// Reads `encoded`, ignoring spaces, line breaks and quotes around it (a pasted code).
    public init?(encoded text: String) {
        let trimmed = text.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"'")))
        guard trimmed.hasPrefix(Self.prefix) else { return nil }
        var base64 = String(trimmed.dropFirst(Self.prefix.count)).filter { !$0.isWhitespace }
            .replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64 += "=" }
        guard let data = Data(base64Encoded: base64),
              let code = try? JSONDecoder().decode(ConnectCode.self, from: data) else { return nil }
        self = code
    }

    /// `github.com/owner/name(.git)` in any form git takes: `https://…`, `git@github.com:…`, `ssh://…`.
    static func gitHubRepository(in url: String) -> String? {
        guard let range = url.range(of: #"github\.com[:/]([^/\s]+)/([^/\s]+?)(\.git)?/?$"#, options: .regularExpression)
        else { return nil }
        let path = url[range].dropFirst("github.com".count + 1)
        var name = String(path)
        if name.hasSuffix("/") { name.removeLast() }
        if name.hasSuffix(".git") { name.removeLast(4) }
        return name
    }

    /// `owner/name` for a GitHub address, as Settings shows it; nil for another host.
    public static func repositoryName(_ url: String) -> String? { gitHubRepository(in: url) }

    /// A name for a device or an agent that fits in a deploy key's title and a conflict copy's name.
    public static func deviceName(_ name: String) -> String {
        let cleaned = ConflictPlan.clean(name.trimmingCharacters(in: .whitespacesAndNewlines))
        return cleaned.isEmpty ? "agent" : cleaned
    }
}

/// GitHub's host keys (docs.github.com, "GitHub's SSH key fingerprints"): an agent's ssh checks the server against
/// them instead of trusting whatever answers first.
enum GitHubHostKeys {
    static let knownHosts = """
        github.com ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl
        github.com ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBEmKSENjQEezOmxkZMy7opKgwFB9nkt5YRrYMjNuG5N87uRgg6CLrbo5wAdT/y6v0mKV0U2w0WZ2YB/++Tpockg=
        github.com ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQCj7ndNxQowgcQnjshcLrqPEiiphnt+VTTvDP6mHBL9j1aNUkY4Ue1gvwnGLVlOhGeYrnZaMgRK6+PKCUXaDbC7qtbW8gIkhL7aGCsOr/C56SJMy/BCZfxd1nWzAOxSDPgVsmerOBYfNqltV9/hWCqBywINIR+5dIg6JTJ72pcEpEjcYgXkE2YEFXV1JHnsKgbLWNlhScqb2UmyRkQyytRLtL+38TGxkxCflmO+5Z8CSSNY7GidjMIZ7Q4zMjA2n1nGrlTDkzwDCsw+wqFPGQA179cnfGWOWRVruj16z6XyvxvjJwbz0wQZ75XK5tKSb7FNyeIEs4TT4jk+S4dhPeAUC5y+bDYirYgM4GC7uEnztnZyaVWQ7B381AK4Qdrwt51ZqExKbQpTUNn+EjqoTwvqNj4kqx5QUCI0ThS/YkOxJCXmPUWZbhjpCg56i+2aB6CmK2JGhn57K5mj0MNdBXA4/WnwH6XoPWJzK5Nyu2zB3nAZp+S5hpQs+p1vN1/wsjk=
        """

    /// The ssh command a clone uses with the agent's deploy key: that key only, GitHub's host keys only.
    static func sshCommand(key: String, knownHosts: String) -> String {
        "ssh -i \(GitCrypt.quote(key)) -o IdentitiesOnly=yes -o StrictHostKeyChecking=yes "
            + "-o UserKnownHostsFile=\(GitCrypt.quote(knownHosts))"
    }
}

/// What connecting an agent gives: what to run where it works, and, when Loam could not add the agent's deploy key
/// itself (not signed in to GitHub), the public key to add on the repository's Deploy keys page with write access.
public struct AgentAccess: Equatable, Sendable {
    public let agent: String
    public let setup: String
    /// Everything to paste into the agent: the context, `setup`, and how to work in the vault (`AgentBrief`).
    public let brief: String
    public let publicKey: String?
    public let deployKeysURL: String?
}

/// An agent or device that cannot join as asked, in one sentence.
public struct ConnectError: Error, LocalizedError, Equatable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

extension SyncController {
    var tokenStore: GitHubTokenStore { GitHubTokenStore() }

    func gitHub() -> GitHub { GitHub(token: tokenStore.load(), transport: transport) }

    // MARK: - GitHub sign-in (a Mac)

    func gitHubAccount() async -> String? {
        guard tokenStore.load() != nil else { return nil }
        return try? await gitHub().login()
    }

    func startGitHubSignIn() async throws -> GitHubDeviceCode {
        try await GitHub(token: nil, transport: transport).startSignIn()
    }

    func finishGitHubSignIn(_ code: GitHubDeviceCode) async throws {
        let token = try await GitHub(token: nil, transport: transport).finishSignIn(code)
        try tokenStore.save(token)
    }

    func signOutOfGitHub() throws {
        try tokenStore.save(nil)
    }

    /// The vault's repository name on GitHub: `loam-` and the vault's folder name.
    var repositoryName: String {
        let folder = engine.root.lastPathComponent
        let allowed = folder.map { $0.isLetter || $0.isNumber || "-_.".contains($0) ? $0 : "-" }
        return "loam-" + String(allowed).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    /// One click: the vault syncs with its own private repository on the user's GitHub, made if needed, encrypted
    /// when new. A repository encrypted already needs its key: `ConnectError` asks for a code from a device that has
    /// it (`connectCode(for:)` there).
    func setUpWithGitHub(encrypt: Bool) async throws -> SyncStatus {
        let gitHub = gitHub()
        let (repository, created) = try await gitHub.vaultRepository(named: repositoryName)
        // Made before and left empty (a first push that failed): as new, so `encrypt` still holds.
        if !created, await !gitHub.isEmpty(repository.fullName) {
            // An existing vault repository: this Mac joins it. Encrypted, it needs the key from another device.
            let attributes = try? await gitHub.fileContent(repository.fullName, path: ".gitattributes")
            if let attributes, let keyID = CryptAttributes.declaredKey(in: attributes), !keyID.isEmpty,
               (try? engine.loadKey(keyID)) == nil {
                throw ConnectError("\(repository.fullName) is encrypted. On a Mac that syncs it, open Settings > Sync > "
                                   + "Connect a device, and paste the code here.")
            }
            return try await setUp(SetupRequest(url: repository.cloneURL, device: Self.defaultDevice())).status
        }
        return try await setUp(SetupRequest(url: repository.cloneURL, device: Self.defaultDevice(),
                                            encrypt: encrypt)).status
    }

    static func defaultDevice() -> String { SyncEngine.computerName() }

    // MARK: - Codes

    /// The code a new Mac or an agent pastes. An agent gets a deploy key of its own, added to the repository now.
    func connectCode(for device: String, agent: Bool) async throws -> String {
        let device = ConnectCode.deviceName(device)
        let remote = await engine.git(["remote", "get-url", await settings().remote])
        guard remote.succeeded, let repository = ConnectCode.gitHubRepository(in: remote.text) else {
            throw ConnectError("This vault does not sync with GitHub yet: set it up first.")
        }
        guard agent else {
            let vaultKey = (try? await engine.exportKey())?.exported
            return ConnectCode(repository: repository, url: "https://github.com/\(repository).git", sshKey: nil,
                               vaultKey: vaultKey, device: device).encoded
        }
        return try await agentAccess(for: device).setup
    }

    /// What an agent needs: its own SSH deploy key on the vault's repository, and what to run where it works. Signed
    /// in to GitHub, Loam adds the key itself; otherwise `publicKey` is for the user to add on the repository's
    /// Deploy keys page (`deployKeysURL`), with write access.
    func agentAccess(for name: String) async throws -> AgentAccess {
        let device = ConnectCode.deviceName(name)
        let remote = await engine.git(["remote", "get-url", await settings().remote])
        guard remote.succeeded, let repository = ConnectCode.gitHubRepository(in: remote.text) else {
            throw ConnectError("This vault does not sync with GitHub yet: set it up first.")
        }
        let vaultKey = (try? await engine.exportKey())?.exported
        let (privateKey, publicKey) = try SSHKeys.generate(comment: "loam-agent-\(device)")
        var added = false
        if tokenStore.load() != nil {
            let gitHub = gitHub()
            let title = GitHub.agentKeyPrefix + device
            if try await gitHub.deployKeys(repository).contains(where: { $0.title == title }) {
                throw ConnectError("An agent named \(device) is connected already: remove it first, or pick another name.")
            }
            _ = try await gitHub.addDeployKey(repository, title: title, publicKey: publicKey)
            added = true
        }
        // A plain vault needs nothing but git: the agent gets its key and the commands.
        let setup = vaultKey == nil
            ? Self.gitOnlySetup(repository: repository, agent: device, privateKey: privateKey)
            : GitSyncPlugin.installLine(ConnectCode(repository: repository, url: "git@github.com:\(repository).git",
                                                    sshKey: privateKey, vaultKey: vaultKey, device: device).encoded)
        let brief = AgentBrief.text(repository: repository, agent: device, encrypted: vaultKey != nil, setup: setup)
        return AgentAccess(agent: device, setup: setup, brief: brief, publicKey: added ? nil : publicKey,
                           deployKeysURL: added ? nil : "https://github.com/\(repository)/settings/keys/new")
    }

    /// The shell an agent runs once to work on a plain vault with git alone: its deploy key in `~/.ssh`, GitHub's
    /// host keys pinned, a clone in `~/vault` that commits under the agent's name (the Mac shows "<name> changed …").
    static func gitOnlySetup(repository: String, agent: String, privateKey: String) -> String {
        let slug = agent.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" }
        let file = "loam-" + String(slug)
        let key = privateKey.hasSuffix("\n") ? privateKey : privateKey + "\n"
        return """
            # Loam vault \(repository) for the agent "\(agent)": git only. Run once where the agent works.
            mkdir -p ~/.ssh && chmod 700 ~/.ssh
            cat > ~/.ssh/\(file) <<'KEY'
            \(key)KEY
            chmod 600 ~/.ssh/\(file)
            cat > ~/.ssh/loam_github_hosts <<'HOSTS'
            \(GitHubHostKeys.knownHosts)
            HOSTS
            git clone -c core.sshCommand="ssh -i $HOME/.ssh/\(file) -o IdentitiesOnly=yes -o StrictHostKeyChecking=yes -o UserKnownHostsFile=$HOME/.ssh/loam_github_hosts" \\
              -c user.name="\(agent)" -c user.email="\(String(slug))@agent.loam" git@github.com:\(repository).git ~/vault
            # After each task: cd ~/vault && git add -A && git commit -m "\(agent): <what changed>" && git pull --rebase && git push
            """
    }

    /// The agents connected to this vault's repository: its deploy keys made by Loam.
    func connectedAgents() async throws -> [String] {
        guard let repository = await gitHubRepository() else { return [] }
        return try await gitHub().deployKeys(repository).compactMap { key in
            key.title.hasPrefix(GitHub.agentKeyPrefix) ? String(key.title.dropFirst(GitHub.agentKeyPrefix.count)) : nil
        }
    }

    /// Takes an agent's access away: its deploy key goes, so it can no longer fetch or push. The vault key stays: the
    /// other agents and devices go on as they were. What the agent already pulled stays with it; `sync.key.rotate`
    /// is there for a key that leaked some other way.
    func removeAgent(_ name: String) async throws -> SyncStatus {
        guard let repository = await gitHubRepository() else { throw ConnectError("This vault does not sync with GitHub.") }
        let gitHub = gitHub()
        let keys = try await gitHub.deployKeys(repository).filter { $0.title == GitHub.agentKeyPrefix + name }
        guard !keys.isEmpty else { throw ConnectError("No agent named \(name) is connected.") }
        for key in keys { try await gitHub.deleteDeployKey(repository, id: key.id) }
        return status
    }

    func gitHubRepository() async -> String? {
        let remote = await engine.git(["remote", "get-url", await settings().remote])
        return remote.succeeded ? ConnectCode.gitHubRepository(in: remote.text) : nil
    }

    // MARK: - Joining

    /// A new Mac or agent pastes a code: the vault syncs with that repository, decrypted here. An agent's deploy key
    /// is kept in `~/.config/loam/ssh` (only the user can read it) and used for this vault only.
    func join(_ text: String, maxChanges: Int? = nil) async throws -> SyncStatus {
        guard let code = ConnectCode(encoded: text) else {
            throw ConnectError("This is not a Loam connect code: one starts with \(ConnectCode.prefix)")
        }
        if let vaultKey = code.vaultKey { _ = try await engine.importKey(vaultKey) }
        // A vault syncing with that repository already (it lacked the key): the key was all it needed.
        if await gitHubRepository() == code.repository {
            return await syncNow()
        }
        var request = SetupRequest(url: code.url, device: code.device)
        if let sshKey = code.sshKey {
            request.sshCommand = try Self.saveSSHKey(sshKey, for: code)
            request.maxChanges = maxChanges ?? 50
        } else {
            request.maxChanges = maxChanges
        }
        return try await setUp(request).status
    }

    static func saveSSHKey(_ key: String, for code: ConnectCode) throws -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let config = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"].map { URL(fileURLWithPath: $0) }
            ?? home.appendingPathComponent(".config")
        let folder = config.appendingPathComponent("loam/ssh")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let name = code.repository.replacingOccurrences(of: "/", with: "-") + "-" + code.device.replacingOccurrences(of: " ", with: "-")
        let keyFile = folder.appendingPathComponent(name)
        let hostsFile = folder.appendingPathComponent("known_hosts")
        let text = key.hasSuffix("\n") ? key : key + "\n"
        guard FileManager.default.createFile(atPath: keyFile.path, contents: Data(text.utf8),
                                             attributes: [.posixPermissions: 0o600]),
              FileManager.default.createFile(atPath: hostsFile.path, contents: Data((GitHubHostKeys.knownHosts + "\n").utf8),
                                             attributes: [.posixPermissions: 0o644]) else {
            throw ConnectError("Could not save the agent's key in \(folder.path).")
        }
        return GitHubHostKeys.sshCommand(key: keyFile.path, knownHosts: hostsFile.path)
    }
}

/// An SSH key pair for an agent's deploy key, made by `ssh-keygen` (on every Mac and almost every Linux).
enum SSHKeys {
    static func generate(comment: String) throws -> (privateKey: String, publicKey: String) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("loam-ssh-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("key")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
        process.arguments = ["-q", "-t", "ed25519", "-N", "", "-C", comment, "-f", file.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let privateKey = try? String(contentsOf: file, encoding: .utf8),
              let publicKey = try? String(contentsOf: folder.appendingPathComponent("key.pub"), encoding: .utf8) else {
            throw ConnectError("Could not make an SSH key for the agent (ssh-keygen).")
        }
        return (privateKey, publicKey.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
