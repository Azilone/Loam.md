import Foundation

/// `loam crypt …`: what git runs for an encrypted vault (`.gitattributes`: `filter=loam-crypt diff=loam-crypt
/// merge=loam-crypt`), set up in each clone's own git config by the sync.
///
///     loam crypt filter                      the long-running clean (encrypt) and smudge (decrypt) filter
///     loam crypt merge %O %A %B %L %P        the merge driver: decrypt, `git merge-file`, encrypt
///     loam crypt textconv <file>             the plaintext of a file, for `git diff` and `git log -p`
///
/// The key comes from `LOAM_CRYPT_KEY` when the sync runs git, else from this device's key store (git in a
/// terminal).
public enum GitCrypt {
    /// The environment variable through which the sync hands the key to the git commands it runs (base64).
    static let keyVariable = "LOAM_CRYPT_KEY"
    /// The git config entry naming this clone's key (`loam.cryptkey`): set once a clone knows its vault is encrypted.
    static let keyConfig = "loam.cryptkey"

    /// Runs `loam crypt <arguments>` (a leading `crypt` is skipped) and returns its exit status.
    public static func main(_ arguments: [String],
                            environment: [String: String] = ProcessInfo.processInfo.environment) -> Int32 {
        var arguments = arguments
        if arguments.first == "crypt" { arguments.removeFirst() }
        let keys = ToolKeys(environment: environment)
        switch arguments.first {
        case "filter": return filter(keys: keys)
        case "merge": return merge(Array(arguments.dropFirst()), keys: keys)
        case "textconv": return textconv(Array(arguments.dropFirst()), keys: keys)
        default:
            log("usage: loam crypt filter | merge %O %A %B %L %P | textconv <file> (run by git for an encrypted vault)")
            return 2
        }
    }

    // MARK: - Commands for git

    /// The shell command git runs for `loam crypt` on this machine, quoted for git's shell: `LOAM_CRYPT_TOOL` when
    /// set, `loam` itself in the command line, the one in the app bundle (`Contents/Helpers/loam`) in the app, else
    /// one on the usual PATH. nil when none is found.
    public static func locateTool(environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        if let tool = environment["LOAM_CRYPT_TOOL"], !tool.isEmpty { return tool }
        var candidates: [URL] = []
        if let executable = Bundle.main.executableURL, executable.lastPathComponent == "loam" {
            candidates.append(executable)
        }
        candidates.append(Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/loam"))
        candidates += ["/opt/homebrew/bin/loam", "/usr/local/bin/loam"].map { URL(fileURLWithPath: $0) }
        guard let found = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) else {
            return nil
        }
        return quote(found.path) + " crypt"
    }

    /// `path` as one word for a POSIX shell.
    static func quote(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// This clone's git config for an encrypted vault, from the tool's command (`locateTool`).
    static func config(tool: String) -> [(key: String, value: String)] {
        [
            ("filter.loam-crypt.process", "\(tool) filter"),
            ("filter.loam-crypt.required", "true"),
            ("merge.loam-crypt.name", "Loam: decrypt, merge, encrypt"),
            ("merge.loam-crypt.driver", "\(tool) merge %O %A %B %L %P"),
            ("diff.loam-crypt.textconv", "\(tool) textconv"),
        ]
    }

    // MARK: - filter

    private static func filter(keys: ToolKeys) -> Int32 {
        let input = FileHandle.standardInput
        let output = FileHandle.standardOutput
        let reader = PacketReader { input.availableData }
        let writer = PacketWriter { try output.write(contentsOf: $0) }
        do {
            try FilterProcess.serve(
                reader: reader, writer: writer,
                clean: { content, _ in
                    // Already encrypted (a file checked out without the filter): kept as it is, never twice.
                    if CryptCodec.isEncrypted(content) { return content }
                    return try CryptCodec.encrypt(content, with: keys.key(id: nil))
                },
                smudge: { content, _ in try decrypt(content, keys: keys) },
                log: log)
            return 0
        } catch {
            log(error.localizedDescription)
            return 1
        }
    }

    private static func decrypt(_ data: Data, keys: ToolKeys) throws -> Data {
        guard let id = CryptCodec.keyID(of: data) else { return data }
        return try CryptCodec.decrypt(data, with: keys.key(id: id))
    }

    // MARK: - merge

    /// git's `%O %A %B %L %P`: the base, ours (where the result goes) and theirs as encrypted blobs, the conflict
    /// marker size and the path. Exits 0 for a clean merge, 1 for conflicts (git then records the paths as
    /// conflicted and the sync makes its conflict copies, as for any file), 129 when it cannot decrypt.
    private static func merge(_ arguments: [String], keys: ToolKeys) -> Int32 {
        guard arguments.count >= 3 else {
            log("usage: loam crypt merge <base> <ours> <theirs> [<marker size>] [<path>]")
            return 129
        }
        let ours = URL(fileURLWithPath: arguments[1])
        let markerSize = arguments.count > 3 ? Int(arguments[3]) ?? 7 : 7
        let path = arguments.count > 4 ? arguments[4] : arguments[1]
        do {
            let sides = try [arguments[0], arguments[1], arguments[2]].map { file in
                try decrypt(Data(contentsOf: URL(fileURLWithPath: file)), keys: keys)
            }
            // As git does for a binary file: ours stays, and the path is in conflict.
            if sides.contains(where: isBinary) { return 1 }
            let merged = try mergeFile(base: sides[0], ours: sides[1], theirs: sides[2], markerSize: markerSize)
            try CryptCodec.encrypt(merged.text, with: keys.key(id: nil)).write(to: ours)
            return merged.conflicts == 0 ? 0 : 1
        } catch {
            log("\(path): \(error.localizedDescription)")
            return 129
        }
    }

    /// git's own test: a NUL in the first 8000 bytes.
    static func isBinary(_ data: Data) -> Bool {
        data.prefix(8000).contains(0)
    }

    /// `git merge-file` on the plaintexts, in a folder only the user can read, removed right after.
    private static func mergeFile(base: Data, ours: Data, theirs: Data, markerSize: Int) throws
        -> (text: Data, conflicts: Int32) {
        let manager = FileManager.default
        let folder = manager.temporaryDirectory.appendingPathComponent("loam-merge-\(UUID().uuidString)")
        try manager.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? manager.removeItem(at: folder) }
        var files: [String] = []
        for (name, data) in [("ours", ours), ("base", base), ("theirs", theirs)] {
            let url = folder.appendingPathComponent(name)
            guard manager.createFile(atPath: url.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
                throw KeyStoreError(message: "Could not write a temporary file in \(folder.path).")
            }
            files.append(url.path)
        }
        let result = runGit(["merge-file", "-p", "--marker-size=\(markerSize)", "-L", "ours", "-L", "base",
                             "-L", "theirs"] + files)
        // The number of conflicts, up to 127; more means git failed.
        guard result.status >= 0, result.status <= 127 else {
            throw KeyStoreError(message: "git merge-file failed: \(result.stderr)")
        }
        return (result.stdout, result.status)
    }

    // MARK: - textconv

    private static func textconv(_ arguments: [String], keys: ToolKeys) -> Int32 {
        guard let file = arguments.first else {
            log("usage: loam crypt textconv <file>")
            return 2
        }
        do {
            let plain = try decrypt(Data(contentsOf: URL(fileURLWithPath: file)), keys: keys)
            try FileHandle.standardOutput.write(contentsOf: plain)
            return 0
        } catch {
            log(error.localizedDescription)
            return 1
        }
    }

    // MARK: - Helpers

    static func log(_ message: String) {
        FileHandle.standardError.write(Data("loam crypt: \(message)\n".utf8))
    }

    /// Runs the machine's git and waits for it.
    static func runGit(_ arguments: [String]) -> (status: Int32, stdout: Data, stderr: String) {
        let process = Process()
        process.executableURL = ProcessGitRunner.executable.url
        process.arguments = ProcessGitRunner.executable.prefix + arguments
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return (-1, Data(), "cannot run git: \(error.localizedDescription)")
        }
        let stderr = ReadBack()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            stderr.data = err.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        let stdout = out.fileHandleForReading.readDataToEndOfFile()
        group.wait()
        process.waitUntilExit()
        return (process.terminationStatus, stdout, String(decoding: stderr.data, as: UTF8.self))
    }
}

/// What a reading thread collects, read once it is done.
private final class ReadBack: @unchecked Sendable {
    var data = Data()
}

/// The keys `loam crypt` uses: the one the sync hands over (`LOAM_CRYPT_KEY`), else this device's store, by the id a
/// file names or, to encrypt, the id this clone's git config names.
final class ToolKeys {
    private let environment: [String: String]
    private lazy var store = VaultKeyStores.system(environment: environment)
    private lazy var handed: VaultKey? = environment[GitCrypt.keyVariable]
        .flatMap { Data(base64Encoded: $0) }.flatMap { VaultKey(bytes: $0) }
    private lazy var configured: String? = {
        let read = GitCrypt.runGit(["config", "--get", GitCrypt.keyConfig])
        let id = String(decoding: read.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return read.status == 0 && !id.isEmpty ? id : nil
    }()
    private var loaded: [String: VaultKey] = [:]

    init(environment: [String: String]) {
        self.environment = environment
    }

    /// The key with this id; `nil` for the key this clone encrypts with.
    func key(id: String?) throws -> VaultKey {
        if let handed, id == nil || handed.id == id { return handed }
        guard let wanted = id ?? configured else {
            throw KeyStoreError(message: "This clone has no vault key set up (git config \(GitCrypt.keyConfig)): "
                                + "sync it with Loam once.")
        }
        if let key = loaded[wanted] { return key }
        guard let key = try store.load(id: wanted) else { throw CryptError.missingKey(wanted) }
        loaded[wanted] = key
        return key
    }
}
