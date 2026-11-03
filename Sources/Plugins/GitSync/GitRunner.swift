import Foundation

/// What one git command printed and how it ended.
public struct GitOutput: Sendable, Equatable {
    /// The exit status; -1 when git could not start, 124 when it was stopped for taking too long.
    public let status: Int32
    public let stdout: Data
    public let stderr: String

    public init(status: Int32, stdout: Data = Data(), stderr: String = "") {
        self.status = status
        self.stdout = stdout
        self.stderr = stderr
    }

    public var succeeded: Bool { status == 0 }
    /// Stdout as text, without the trailing newline.
    public var text: String {
        String(decoding: stdout, as: UTF8.self).trimmingCharacters(in: .newlines)
    }
}

/// Runs git in the vault. The sync engine only talks to git through this, so tests can script it.
public protocol GitRunner: Sendable {
    /// Runs `git <arguments>` in the vault folder. `input` goes to stdin. A command still running after `timeout`
    /// seconds is stopped (the sync gives local commands a long one: a stopped one may leave `index.lock`, which the
    /// next cycle reports).
    /// `environment` is added for this command only (the key of an encrypted vault, for its filter).
    func run(_ arguments: [String], input: Data?, timeout: TimeInterval?, environment: [String: String]) async -> GitOutput
}

public extension GitRunner {
    func run(_ arguments: [String], input: Data? = nil, timeout: TimeInterval? = nil) async -> GitOutput {
        await run(arguments, input: input, timeout: timeout, environment: [:])
    }
}

/// The real runner: the git installed on the machine, never prompting (no terminal, no password dialog), so a
/// missing credential fails at once instead of hanging the sync.
public struct ProcessGitRunner: GitRunner {
    public let directory: URL
    /// Added to the environment, after the defaults: tests use it to isolate git from the user's own config.
    public let environment: [String: String]
    /// The git to run: the one the host located (`ToolLocating`), else `env git` on the PATH.
    let invocation: (url: URL, prefix: [String])

    public init(directory: URL, environment: [String: String] = [:], git: URL? = nil) {
        self.directory = directory
        self.environment = environment
        invocation = git.map { ($0, []) } ?? Self.executable
    }

    /// `env git`: the git on the PATH, for a run outside the app (the `loam` command line, tests).
    static let executable: (url: URL, prefix: [String]) = (URL(fileURLWithPath: "/usr/bin/env"), ["git"])

    /// The process environment without the `DYLD_*` variables a test runner sets, with prompts turned off and the
    /// usual tool folders on the PATH so credential helpers (`gh`, `git-lfs`) are found from the app too.
    func processEnvironment(_ command: [String: String] = [:]) -> [String: String] {
        var values = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("DYLD_") }
        let path = values["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        let extra = ["/opt/homebrew/bin", "/usr/local/bin"].filter { !path.split(separator: ":").contains(Substring($0)) }
        values["PATH"] = ([path] + extra).joined(separator: ":")
        values["GIT_TERMINAL_PROMPT"] = "0"
        values["GCM_INTERACTIVE"] = "never"
        values["LC_ALL"] = "C"
        values.merge(environment) { _, new in new }
        values.merge(command) { _, new in new }
        return values
    }

    public func run(_ arguments: [String], input: Data?, timeout: TimeInterval?,
                    environment command: [String: String]) async -> GitOutput {
        let process = Process()
        process.executableURL = invocation.url
        process.arguments = invocation.prefix
            + ["-C", directory.path, "-c", "core.quotepath=off", "-c", "color.ui=never"] + arguments
        process.environment = processEnvironment(command)
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        let stdin = input.map { _ in Pipe() }
        process.standardInput = stdin ?? FileHandle.nullDevice

        // The read ends are closed by hand once read: swift-corelibs-foundation does not close them when the pipes go
        // away, so every git call leaked two descriptors on Linux. After about a thousand of them `Process.run`
        // crashed while scanning /proc/self/fd to find which descriptors to close in the child.
        return await withCheckedContinuation { continuation in
            let group = DispatchGroup()
            let collected = Collected()
            group.enter()
            DispatchQueue.global().async {
                collected.stdout = out.fileHandleForReading.readDataToEndOfFile()
                try? out.fileHandleForReading.close()
                group.leave()
            }
            group.enter()
            DispatchQueue.global().async {
                collected.stderr = err.fileHandleForReading.readDataToEndOfFile()
                try? err.fileHandleForReading.close()
                group.leave()
            }
            group.enter()
            process.terminationHandler = { _ in group.leave() }
            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                try? out.fileHandleForWriting.close()
                try? err.fileHandleForWriting.close()
                group.leave()
                group.notify(queue: .global()) {
                    continuation.resume(returning: GitOutput(status: -1, stderr: "cannot run git: \(error.localizedDescription)"))
                }
                return
            }
            if let stdin, let input {
                DispatchQueue.global().async {
                    try? stdin.fileHandleForWriting.write(contentsOf: input)
                    try? stdin.fileHandleForWriting.close()
                }
            }
            if let timeout {
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                    guard process.isRunning else { return }
                    collected.timedOut = true
                    process.terminate()
                }
            }
            group.notify(queue: .global()) {
                let stderr = String(decoding: collected.stderr, as: UTF8.self)
                if collected.timedOut {
                    continuation.resume(returning: GitOutput(status: 124, stdout: collected.stdout,
                                                             stderr: stderr + "\ngit timed out after \(Int(timeout ?? 0)) s"))
                } else {
                    continuation.resume(returning: GitOutput(status: process.terminationStatus, stdout: collected.stdout,
                                                             stderr: stderr))
                }
            }
        }
    }
}

/// What the reading threads collect. Each field is written by one thread before the group finishes.
private final class Collected: @unchecked Sendable {
    var stdout = Data()
    var stderr = Data()
    var timedOut = false
}
