import Foundation

/// What the vault's `.gitattributes` and a clone's `info/attributes` say about encryption.
enum CryptAttributes {
    /// The comment naming the vault's key, so a new device knows which key it needs.
    static let keyLine = "# loam-crypt-key: "
    /// Every file through the filter, except the two git reads itself. `-text`: no line-ending conversion of
    /// ciphertext.
    static let rules = """
        * filter=loam-crypt diff=loam-crypt merge=loam-crypt -text
        .gitattributes !filter !diff !merge !text
        .gitignore !filter !diff !merge !text
        \(githubRule)
        """
    /// Files git reads itself, never encrypted: `.gitattributes` and `.gitignore` anywhere, and `.github/`, which
    /// GitHub reads (the check that the remote holds only ciphertext).
    static func isExempt(_ path: String) -> Bool {
        let name = path.split(separator: "/").last.map(String.init) ?? path
        return name == ".gitattributes" || name == ".gitignore" || path.hasPrefix(".github/")
    }

    /// `.github/` stays plain: GitHub reads its workflows (`RemoteGuard`).
    static let githubRule = ".github/** !filter !diff !merge !text"

    /// The first line of the clone's own block (`info/attributes`, never pushed).
    static let cloneMarker = "# Loam: this clone encrypts what it commits (git sync)."

    /// The block `sync.setup encrypt=true` adds to the vault's `.gitattributes`.
    static func block(keyID: String) -> String {
        """
        # Loam encrypts this vault before it leaves the Mac: files hold ciphertext, their names stay visible.
        # A new device needs the key: sync.key.export on one that syncs, then sync.key.import on the new one.
        \(keyLine)\(keyID)
        \(rules)

        """
    }

    /// This clone's block: it encrypts whatever the vault's `.gitattributes` says (or before it arrives).
    static let clone = "\(cloneMarker)\n\(rules)\n"

    /// The key an attributes file encrypts with: nil when it does not use the filter, "" when it does without naming
    /// its key.
    static func declaredKey(in text: String) -> String? {
        let lines = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        guard lines.contains(where: { !$0.hasPrefix("#") && $0.contains("filter=loam-crypt") }) else { return nil }
        for line in lines where line.hasPrefix(keyLine) {
            let id = line.dropFirst(keyLine.count).trimmingCharacters(in: .whitespaces)
            if id.count == 16, id.allSatisfy(\.isHexDigit) { return id.lowercased() }
        }
        return ""
    }

    /// `text` with the vault's block for `keyID`: added at the end, or its key line replaced.
    static func adding(keyID: String, to text: String) -> String {
        var lines = text.components(separatedBy: "\n")
        if let index = lines.firstIndex(where: { $0.hasPrefix(keyLine) }) {
            lines[index] = keyLine + keyID
            return lines.joined(separator: "\n")
        }
        let separator = text.isEmpty ? "" : text.hasSuffix("\n\n") ? "" : text.hasSuffix("\n") ? "\n" : "\n\n"
        return text + separator + block(keyID: keyID)
    }
}

extension SyncEngine {
    enum CryptCheck {
        /// The vault is not encrypted.
        case plain
        /// Encrypted, the key loaded and handed to git.
        case ready(keyID: String)
        case stop(CycleOutcome)
    }

    /// Run before anything reads or writes the work tree. The vault is encrypted once this clone knows it
    /// (`loam.cryptkey`), once its `.gitattributes` says so, or once `remoteRef`'s does. Then this clone's filter is
    /// set up and the key handed to the git commands; without the key the cycle stops, so a plain file is never
    /// committed and ciphertext never lands in the vault. `adopt` lets it finish a clone's switch to encryption
    /// (`adopt(_:gitDir:)`).
    /// The remote moved to another key (`rotateKey` on another device): this clone follows when it has that key.
    /// False when it does not.
    func followKey(_ keyID: String) async -> Bool {
        guard let key = try? loadKey(keyID) else { return false }
        _ = await git(["config", "--local", GitCrypt.keyConfig, keyID])
        setCrypt(key)
        return true
    }

    func prepareEncryption(gitDir: String, remoteRef: String?, base: SyncStatus, adopt: Bool = true,
                           config known: LocalConfig? = nil) async -> CryptCheck {
        let config: LocalConfig
        if let known { config = known } else { config = await localConfig() }
        var keyID = config.keyID
        if keyID == nil {
            var declared = CryptAttributes.declaredKey(in: worktreeAttributes())
            if declared == nil, let remoteRef { declared = await remoteDeclaredKey(remoteRef) }
            guard let declared else {
                setCrypt(nil)
                return .plain
            }
            guard !declared.isEmpty else {
                return .stop(attention("This vault's .gitattributes encrypts it with loam-crypt but names no key "
                                       + "(\(CryptAttributes.keyLine.trimmingCharacters(in: .whitespaces)) <id>).",
                                       base: base))
            }
            keyID = declared
            _ = await git(["config", "--local", GitCrypt.keyConfig, declared])
        }
        guard let keyID else { return .plain }
        var status = base
        status.encryptionKey = keyID

        // Even without the key or the tool, git refuses to commit a file it cannot encrypt (`required`).
        let tool = cryptTool ?? "loam crypt"
        if config.process != "\(tool) filter" {
            for (key, value) in GitCrypt.config(tool: tool) { _ = await git(["config", "--local", key, value]) }
        }
        guard cryptTool != nil else {
            return .stop(attention("This vault is encrypted, and Loam's command line (loam), which encrypts for git, "
                                   + "was not found next to the app or on the PATH.", base: status))
        }
        let key: VaultKey
        do {
            guard let loaded = try loadKey(keyID) else {
                setCrypt(nil)
                return .stop(attention(CryptError.missingKey(keyID).errorDescription ?? "", base: status))
            }
            key = loaded
        } catch {
            setCrypt(nil)
            return .stop(attention(error.localizedDescription, base: status))
        }
        setCrypt(key)
        updateCloneRules(gitDir: gitDir)
        if adopt, !cloneEncrypts(gitDir: gitDir),
           let failure = await self.adopt(key, gitDir: gitDir, remote: await host.settings().remote, base: status) {
            return .stop(failure)
        }
        return .ready(keyID: keyID)
    }

    /// A clone's switch to encryption, once it has the key: files a plain `git clone` left encrypted are decrypted in
    /// place, the clone's own attributes make it encrypt whatever `.gitattributes` says, and the files committed
    /// plain before are encrypted again (`git add --renormalize`), to go in the next commit. Plain files committed
    /// here and not on `remote` yet wait for the user's word before they are pushed (`plainFilesToPush`).
    func adopt(_ key: VaultKey, gitDir: String, remote: String, base: SyncStatus) async -> CycleOutcome? {
        for path in Git.fields(await git(["ls-files", "-z"]).stdout) where startsEncrypted(path) {
            let url = root.appendingPathComponent(path)
            do {
                try await host.write(path, CryptCodec.decrypt(Data(contentsOf: url), with: key))
            } catch {
                return attention("Could not decrypt \(path): \(error.localizedDescription)", base: base)
            }
        }
        let url = URL(fileURLWithPath: gitDir).appendingPathComponent("info/attributes")
        let current = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        let separator = current.isEmpty || current.hasSuffix("\n") ? "" : "\n"
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data((current + separator + CryptAttributes.clone).utf8).write(to: url, options: .atomic)
        } catch {
            return attention("Could not write \(url.path): \(error.localizedDescription)", base: base)
        }
        if await git(["rev-parse", "-q", "--verify", "HEAD^{commit}"]).succeeded {
            let renormalized = await git(["add", "--renormalize", "--", "."])
            guard renormalized.succeeded else {
                return attention("Could not encrypt the vault's files: \(Git.summary(renormalized.stderr))", base: base)
            }
            // Everything committed from now on is encrypted; what was committed here before and never pushed is not.
            let plain = await plainFilesToPush(remote: remote)
            if plain > 0 {
                _ = await git(["config", "--local", "loam.cryptplain", String(plain)])
                plainFilesWaiting = plain
            }
        }
        return nil
    }

    /// Files in plain text a push would send: blobs this clone has and the remote does not (as last fetched),
    /// other than `.gitattributes`, `.gitignore` and empty files.
    func plainFilesToPush(remote: String) async -> Int {
        let listed = await git(["rev-list", "--objects", "HEAD", "--not", "--remotes=\(remote)"])
        guard listed.succeeded else { return 0 }
        var objects: [String] = []
        for line in listed.text.split(separator: "\n") {
            // Commits and the root tree have no path.
            let parts = line.split(separator: " ", maxSplits: 1)
            guard parts.count == 2 else { continue }
            if !CryptAttributes.isExempt(String(parts[1])) { objects.append(String(parts[0])) }
        }
        return await blobs(objects).filter { blob in
            guard let blob, !blob.isEmpty else { return false }
            return !blob.starts(with: CryptCodec.magic)
        }.count
    }

    /// The raw content (no filter) of each object, in order: nil for one that is missing or not a blob.
    func blobs(_ objects: [String]) async -> [Data?] {
        guard !objects.isEmpty else { return [] }
        let batch = await git(["cat-file", "--batch"], input: Data((objects.joined(separator: "\n") + "\n").utf8))
        // "<oid> <type> <size>\n<content>\n" or "<name> missing\n", one after the other.
        let data = batch.stdout
        var found: [Data?] = []
        var index = data.startIndex
        while index < data.endIndex, let newline = data[index...].firstIndex(of: 0x0A) {
            let header = String(decoding: data[index..<newline], as: UTF8.self).split(separator: " ")
            guard header.count == 3, let size = Int(header[2]), newline + 1 + size <= data.endIndex else {
                found.append(nil)
                index = newline + 1
                continue
            }
            let content = newline + 1
            found.append(header[1] == "blob" ? Data(data[content..<content + size]) : nil)
            index = content + size + 1
        }
        while found.count < objects.count { found.append(nil) }
        return found
    }

    /// What an encrypted vault cannot take from the remote as it is: files in plain text (pushed by a clone without
    /// the filter, such as an agent without Loam) and ciphertext this device cannot open (another key, or bytes
    /// changed by a tool that does not know them).
    struct IncomingCheck: Equatable {
        var plain: [String] = []
        var unreadable: [String] = []
    }

    func checkIncoming(_ paths: [String], remoteRef: String) async -> IncomingCheck {
        guard let key = currentKey else { return IncomingCheck() }
        // `cat-file --batch` reads one name per line.
        let checked = paths.filter { !CryptAttributes.isExempt($0) && !$0.contains("\n") }
        let contents = await blobs(checked.map { "\(remoteRef):\($0)" })
        var check = IncomingCheck()
        for (path, content) in zip(checked, contents) {
            guard let content, !content.isEmpty else { continue }
            if !CryptCodec.isEncrypted(content) {
                check.plain.append(path)
            } else if (try? CryptCodec.decrypt(content, with: key)) == nil {
                check.unreadable.append(path)
            }
        }
        return check
    }

    static func plainIncomingMessage(_ paths: [String]) -> String {
        let files = paths.count == 1 ? "1 file" : "\(paths.count) files"
        return "\(files) came from the remote unencrypted (pushed by a tool without Loam's encryption, such as an "
            + "agent): \(Self.list(paths)). They are readable on the remote. Run sync.now confirm=plain-incoming to "
            + "take them (they are encrypted again in the next commit), then see sync.leak.report."
    }

    static func unreadableIncomingMessage(_ paths: [String]) -> String {
        let files = paths.count == 1 ? "1 file" : "\(paths.count) files"
        return "\(files) from the remote cannot be opened with this vault's key (changed by a tool without the key, "
            + "or encrypted with another one): \(Self.list(paths)). Nothing was merged. Revert the commit that changed "
            + "them (git revert on any clone), then sync again."
    }

    static func list(_ paths: [String]) -> String {
        paths.count <= 5 ? paths.joined(separator: ", ") : paths.prefix(5).joined(separator: ", ")
            + " and \(paths.count - 5) more"
    }

    /// The plain files `plainFilesToPush` found went up, by the user's choice (`sync.now confirm=plain`).
    func forgetPlainHistory() async {
        _ = await git(["config", "--local", "--unset", "loam.cryptplain"])
        plainFilesWaiting = 0
    }

    static func plainHistoryMessage(_ count: Int) -> String {
        let files = count == 1 ? "1 file" : "\(count) files"
        return "\(files) committed here before the vault was encrypted would go to the remote in plain text. Run "
            + "sync.now confirm=plain to push them anyway; for a remote with nothing readable, move this vault's .git "
            + "folder aside and run sync.setup encrypt=true with a new, empty repository."
    }

    /// `sync.setup encrypt=true`: encrypts what goes to the remote from now on, with the key the remote already
    /// uses (it must be on this device) or a new one kept on this device. Returns what it did, one line each.
    func setUpEncryption(remote: String, branch requested: String?) async throws -> [String] {
        guard let tool = cryptTool else {
            throw SetupError(message: "Encryption needs Loam's command line (loam), which was not found next to the "
                             + "app or on the PATH.")
        }
        let located = await git(["rev-parse", "--absolute-git-dir"])
        guard located.succeeded else { throw SetupError(message: Git.summary(located.stderr)) }
        let head = await git(["symbolic-ref", "-q", "--short", "HEAD"])
        let branch = requested ?? (head.succeeded ? head.text : "main")
        let remoteRef = "refs/remotes/\(remote)/\(branch)"

        // Another device may have encrypted the remote already: its key, then.
        let fetch = await git(["fetch", "--quiet", "--no-tags", "--no-recurse-submodules", remote, branch],
                              timeout: Self.networkTimeout)
        if !fetch.succeeded, Git.classify(fetch.stderr) != .missingRemoteBranch {
            throw SetupError(message: "Turning encryption on needs the remote, to see whether it is encrypted "
                             + "already: \(Git.summary(fetch.stderr))")
        }
        let remoteHasHistory = await git(["rev-parse", "-q", "--verify", remoteRef + "^{commit}"]).succeeded
        let remoteKey = remoteHasHistory ? await remoteDeclaredKey(remoteRef) : nil
        let localKey = await localConfig().keyID ?? CryptAttributes.declaredKey(in: worktreeAttributes())

        var report: [String] = []
        let key: VaultKey
        if let remoteKey, !remoteKey.isEmpty {
            guard let found = try loadKey(remoteKey) else {
                throw SetupError(message: "The remote is encrypted already, with the key \(remoteKey). Bring it to "
                                 + "this device first: sync.key.export on one that syncs, then sync.key.import here.")
            }
            key = found
        } else if let localKey, !localKey.isEmpty, let found = try loadKey(localKey) {
            key = found
        } else {
            key = VaultKey.generate()
            try keyStore.save(key)
            remember(key)
            report.append("Created the vault's key (\(key.id)), kept on this device only.")
        }

        let attributes = worktreeAttributes()
        if CryptAttributes.declaredKey(in: attributes) != key.id {
            try await host.write(".gitattributes", Data(CryptAttributes.adding(keyID: key.id, to: attributes).utf8))
        }
        _ = await git(["config", "--local", GitCrypt.keyConfig, key.id])
        for (name, value) in GitCrypt.config(tool: tool) { _ = await git(["config", "--local", name, value]) }
        setCrypt(key)
        if !cloneEncrypts(gitDir: located.text),
           let failure = await adopt(key, gitDir: located.text, remote: remote, base: SyncStatus(state: .attention)) {
            throw SetupError(message: failure.status.message ?? "Could not encrypt the vault's files.")
        }
        report.append("What goes to the remote is encrypted; the vault stays plain Markdown here. File names stay "
                      + "visible.")
        report.append("Another device needs the key: sync.key.export here, then sync.key.import there.")
        report += try await installRemoteGuard()
        if remoteHasHistory, remoteKey == nil {
            report.append("Commits already on the remote stay readable: for a remote with no plain copy, sync to a "
                          + "new, empty repository.")
        }
        return report
    }

    /// The vault's key, for `sync.key.export`.
    /// `sync.key.rotate`: a new key for what is committed from now on. Every file is encrypted again with it in one
    /// commit and `.gitattributes` names it; devices without it stop at their next sync until they import it, which
    /// is how a machine (an agent) loses access. History keeps the old key's ciphertext: the old key still opens it.
    func rotateKey() async throws -> (old: String, new: VaultKey) {
        guard let old = await localConfig().keyID else {
            throw SetupError(message: "This vault is not encrypted: there is no key to change.")
        }
        guard currentKey?.id == old else {
            throw SetupError(message: "This device does not have the vault's key (\(old)) loaded: sync first.")
        }
        let listed = await git(["status", "--porcelain=v1", "-z", "--untracked-files=all"])
        guard listed.succeeded, Git.parseStatus(listed.stdout).isEmpty else {
            throw SetupError(message: "Some changes here are not committed yet: sync first (sync.now).")
        }
        let key = VaultKey.generate()
        try keyStore.save(key)
        remember(key)
        try await host.write(".gitattributes", Data(CryptAttributes.adding(keyID: key.id, to: worktreeAttributes()).utf8))
        _ = await git(["config", "--local", GitCrypt.keyConfig, key.id])
        setCrypt(key)
        let renormalized = await git(["add", "--renormalize", "--", "."])
        let attributes = await git(["add", "--", ".gitattributes"])
        guard renormalized.succeeded, attributes.succeeded else {
            throw SetupError(message: "Could not encrypt the files again: "
                             + Git.summary(renormalized.stderr + attributes.stderr))
        }
        let commit = await git(["commit", "--quiet", "-m", "vault sync: change the vault key (\(await deviceName()))"])
        guard commit.succeeded else { throw SetupError(message: Git.summary(commit.stderr)) }
        return (old, key)
    }

    func exportKey() async throws -> VaultKey {
        guard let id = await knownKeyID(), !id.isEmpty else {
            throw SetupError(message: "This vault is not encrypted: sync.setup encrypt=true turns encryption on.")
        }
        guard let key = try loadKey(id) else {
            throw SetupError(message: CryptError.missingKey(id).errorDescription ?? "")
        }
        return key
    }

    /// Keeps an exported key on this device, for `sync.key.import`. Refuses a key that is not the vault's.
    func importKey(_ text: String) async throws -> VaultKey {
        guard let key = VaultKey(exported: text) else {
            throw SetupError(message: "This is not a Loam vault key: one starts with loam-key: (sync.key.export "
                             + "gives it).")
        }
        // The remote may have moved to a new key (`rotateKey`): that one is the vault's too.
        if let id = await knownKeyID(), !id.isEmpty, id != key.id, await remoteKeyID() != key.id {
            throw SetupError(message: "This key (\(key.id)) is not this vault's: the vault is encrypted with \(id).")
        }
        try keyStore.save(key)
        remember(key)
        return key
    }

    /// How to sync right after `sync.key.import`: as `sync.setup`'s first sync when that one stopped for want of the
    /// key (the branch has no upstream yet), else as `sync.now`.
    func optionsAfterImport() async -> CycleOptions {
        let upstream = await git(["rev-parse", "-q", "--verify", "@{upstream}"])
        return upstream.succeeded
            ? CycleOptions(forceMerge: true)
            : CycleOptions(allowUnrelatedHistories: true, setUpstream: true, forceMerge: true)
    }

    // MARK: - Helpers

    /// The key the vault uses, as far as this device can tell without the network: this clone's config, the
    /// vault's `.gitattributes`, the last fetched remote branch's.
    /// The key the remote's `.gitattributes` names, as last fetched.
    func remoteKeyID() async -> String? {
        let settings = await host.settings()
        var branch = settings.branch
        if branch.isEmpty {
            let head = await git(["symbolic-ref", "-q", "--short", "HEAD"])
            guard head.succeeded else { return nil }
            branch = head.text
        }
        return await remoteDeclaredKey("refs/remotes/\(settings.remote)/\(branch)")
    }

    func knownKeyID() async -> String? {
        if let id = await localConfig().keyID { return id }
        if let declared = CryptAttributes.declaredKey(in: worktreeAttributes()) { return declared }
        let settings = await host.settings()
        var branch = settings.branch
        if branch.isEmpty {
            let head = await git(["symbolic-ref", "-q", "--short", "HEAD"])
            guard head.succeeded else { return nil }
            branch = head.text
        }
        return await remoteDeclaredKey("refs/remotes/\(settings.remote)/\(branch)")
    }

    /// What a cycle needs from this clone's own git config.
    struct LocalConfig {
        /// `loam.device`.
        var device: String?
        /// `loam.cryptkey`: the vault is encrypted with this key.
        var keyID: String?
        /// `filter.loam-crypt.process`: how git runs the filter here.
        var process: String?
        /// `loam.cryptplain`: files in plain text waiting to be pushed (`adopt`).
        var plainToPush = 0
        /// `loam.maxchanges`: the most files one sync commits on this clone (an agent's); nil for no limit.
        var maxChanges: Int?
    }

    /// This clone's device name, key id and filter command, in one git call.
    func localConfig() async -> LocalConfig {
        let names = #"^(loam\.device|loam\.cryptkey|loam\.cryptplain|loam\.maxchanges|filter\.loam-crypt\.process)$"#
        let read = await git(["config", "--local", "--get-regexp", names])
        var config = LocalConfig()
        for line in read.text.split(separator: "\n") {
            guard let space = line.firstIndex(of: " ") else { continue }
            let value = String(line[line.index(after: space)...])
            guard !value.isEmpty else { continue }
            switch line[..<space] {
            case "loam.device": config.device = value
            case "loam.cryptkey": config.keyID = value
            case "loam.cryptplain": config.plainToPush = Int(value) ?? 0
            case "loam.maxchanges": config.maxChanges = Int(value).flatMap { $0 > 0 ? $0 : nil }
            case "filter.loam-crypt.process": config.process = value
            default: break
            }
        }
        return config
    }

    func remoteDeclaredKey(_ remoteRef: String) async -> String? {
        let attributes = await git(["cat-file", "blob", "\(remoteRef):.gitattributes"])
        guard attributes.succeeded else { return nil }
        return CryptAttributes.declaredKey(in: String(decoding: attributes.stdout, as: UTF8.self))
    }

    private func worktreeAttributes() -> String {
        (try? String(contentsOf: root.appendingPathComponent(".gitattributes"), encoding: .utf8)) ?? ""
    }

    private func cloneEncrypts(gitDir: String) -> Bool {
        let url = URL(fileURLWithPath: gitDir).appendingPathComponent("info/attributes")
        return ((try? String(contentsOf: url, encoding: .utf8)) ?? "").contains(CryptAttributes.cloneMarker)
    }

    private func startsEncrypted(_ path: String) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: root.appendingPathComponent(path)) else { return false }
        defer { try? handle.close() }
        let start = (try? handle.read(upToCount: CryptCodec.magic.count)) ?? Data()
        return start == CryptCodec.magic
    }
}
