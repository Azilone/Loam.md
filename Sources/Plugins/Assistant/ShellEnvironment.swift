import Foundation

/// The user's shell environment, as a terminal has it. A Mac app gets a bare PATH (`/usr/bin:/bin:…`), while the
/// agents live in `~/.local/bin`, `~/.bun/bin` or npm's folder and need node or bun next to them. Read once from the
/// login shell, then cached.
public final class ShellEnvironment: @unchecked Sendable {
    public static let shared = ShellEnvironment()

    private let lock = StateLock()
    private var cached: [String: String]?

    public init() {}

    /// The process environment with the login shell's PATH, without the `DYLD_*` variables a test runner sets.
    public var variables: [String: String] {
        lock.lock()
        if let cached {
            lock.unlock()
            return cached
        }
        lock.unlock()
        var environment = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("DYLD_") }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var folders = Self.loginPath()?.split(separator: ":").map(String.init) ?? []
        folders += (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        folders += ["\(home)/.local/bin", "\(home)/.bun/bin", "\(home)/.npm-global/bin", "\(home)/.opencode/bin",
                    "\(home)/.homebrew/bin", "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]
        var seen = Set<String>()
        environment["PATH"] = folders.filter { !$0.isEmpty && seen.insert($0).inserted }.joined(separator: ":")
        lock.lock()
        cached = environment
        lock.unlock()
        return environment
    }

    /// The program named `name` on that PATH: a real file, never a shell alias (`claude` may be an alias adding
    /// flags of the user's).
    public func find(_ name: String) -> URL? {
        let fileManager = FileManager.default
        for folder in (variables["PATH"] ?? "").split(separator: ":") {
            let path = "\(folder)/\(name)"
            if fileManager.isExecutableFile(atPath: path) { return URL(fileURLWithPath: path) }
        }
        return nil
    }

    /// `$SHELL -lic 'echo $PATH'`, with a time limit: a slow or broken shell profile must not hang the app.
    static func loginPath() -> String? {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        guard FileManager.default.isExecutableFile(atPath: shell) else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-lic", "printf '__LOAM_PATH__%s__LOAM_PATH__' \"$PATH\""]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let done = DispatchSemaphore(value: 0)
        var data = Data()
        DispatchQueue.global().async {
            data = output.fileHandleForReading.readDataToEndOfFile()
            done.signal()
        }
        if done.wait(timeout: .now() + 5) == .timedOut {
            process.terminate()
            return nil
        }
        let text = String(decoding: data, as: UTF8.self)
        let parts = text.components(separatedBy: "__LOAM_PATH__")
        return parts.count >= 3 ? parts[1] : nil
    }
}

/// Runs a short command and returns what it printed, for status checks (`claude auth status --json`).
enum QuickCommand {
    static func run(_ executable: URL, _ arguments: [String], environment: [String: String], timeout: TimeInterval = 10)
        -> (status: Int32, output: String)
    {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return (-1, "\(error)") }
        let done = DispatchSemaphore(value: 0)
        var data = Data()
        DispatchQueue.global().async {
            data = output.fileHandleForReading.readDataToEndOfFile()
            done.signal()
        }
        if done.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            return (124, "")
        }
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}
