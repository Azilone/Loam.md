import Foundation

/// A note an agent added, changed or deleted during one turn.
public struct ChangedFile: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable { case added, modified, deleted }
    public let path: String
    public let kind: Kind

    public init(path: String, kind: Kind) {
        self.path = path
        self.kind = kind
    }
}

/// The vault's state before and after each turn, in a git repository of its own beside the vault
/// (`.loam/cache/ai/checkpoints`, never the vault's own `.git`): what a turn changed, and its undo. An agent writes
/// files from outside the app, which clears the editor's undo; this is the way back.
public final class Checkpoints: @unchecked Sendable {
    private let folder: URL
    private let gitDir: URL
    /// Finds git, at the first snapshot rather than at launch: the host's lookup can start a login shell.
    /// Nil when git is not installed, and then there are no snapshots.
    private let locateGit: @Sendable () -> URL?
    private let lock = StateLock()

    public convenience init(folder: URL, git: URL?) {
        self.init(folder: folder, locateGit: { git })
    }

    public init(folder: URL, locateGit: @escaping @Sendable () -> URL?) {
        self.folder = folder
        self.locateGit = locateGit
        gitDir = folder.appendingPathComponent(".loam/cache/ai/checkpoints")
    }

    /// Records the vault as it is now; returns the snapshot's id, or nil when git is missing.
    public func snapshot(_ label: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        guard prepare() else { return nil }
        guard git(["add", "-A", "."]).status == 0 else { return nil }
        _ = git(["-c", "user.name=Loam", "-c", "user.email=assistant@loam.local", "commit", "-q", "--allow-empty",
                 "--no-verify", "-m", label])
        let head = git(["rev-parse", "HEAD"])
        return head.status == 0 ? head.output.trimmingCharacters(in: .whitespacesAndNewlines) : nil
    }

    /// What differs between two snapshots.
    public func changes(from before: String, to after: String) -> [ChangedFile] {
        lock.lock()
        defer { lock.unlock() }
        let result = git(["diff", "--name-status", "--no-renames", before, after])
        guard result.status == 0 else { return [] }
        return result.output.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: "\t", maxSplits: 1)
            guard parts.count == 2 else { return nil }
            let kind: ChangedFile.Kind = switch parts[0].first {
            case "A": .added
            case "D": .deleted
            default: .modified
            }
            return ChangedFile(path: String(parts[1]), kind: kind)
        }
    }

    /// Puts `files` back as they were in `snapshot`: changed and deleted ones restored, added ones removed.
    public func restore(_ files: [ChangedFile], to snapshot: String) throws {
        lock.lock()
        defer { lock.unlock() }
        for file in files {
            let url = folder.appendingPathComponent(file.path)
            switch file.kind {
            case .added:
                try? FileManager.default.removeItem(at: url)
            case .modified, .deleted:
                let result = git(["show", "\(snapshot):\(file.path)"], raw: true)
                guard result.status == 0 else { throw AgentError("Could not restore \(file.path).") }
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                        withIntermediateDirectories: true)
                try result.data.write(to: url, options: .atomic)
            }
        }
    }

    private func prepare() -> Bool {
        if FileManager.default.fileExists(atPath: gitDir.appendingPathComponent("HEAD").path) { return true }
        try? FileManager.default.createDirectory(at: gitDir, withIntermediateDirectories: true)
        guard git(["init", "-q"]).status == 0 else { return false }
        let exclude = gitDir.appendingPathComponent("info/exclude")
        try? FileManager.default.createDirectory(at: exclude.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? "/.loam/cache/\n/.git/\n/.trash/\n.DS_Store\n".write(to: exclude, atomically: true, encoding: .utf8)
        return true
    }

    private func git(_ arguments: [String], raw: Bool = false) -> (status: Int32, output: String, data: Data) {
        guard let executable = locateGit() else { return (-1, "", Data()) }
        let process = Process()
        process.executableURL = executable
        // Accented names stay as they are ("Compiègne.canvas", not "Compi\303\250gne.canvas").
        process.arguments = ["--git-dir", gitDir.path, "--work-tree", folder.path, "-c", "core.quotepath=off"] + arguments
        process.currentDirectoryURL = folder
        var environment = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("DYLD_") && !$0.key.hasPrefix("GIT_") }
        environment["GIT_TERMINAL_PROMPT"] = "0"
        environment["GIT_CONFIG_NOSYSTEM"] = "1"
        process.environment = environment
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return (-1, "", Data()) }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, raw ? "" : String(decoding: data, as: UTF8.self), data)
    }
}
