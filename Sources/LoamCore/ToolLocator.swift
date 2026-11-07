import Foundation
import PluginKit

/// Finds the programs plugins run. A Mac app does not get the Terminal's PATH, so the folders searched are the
/// Terminal's own PATH (from the login shell, kept from one launch to the next), then Homebrew's and the system's.
/// Apple's developer-tool stubs in `/usr/bin` (git, swift) open an installer and fail until the developer tools are
/// installed, so they count only then. Answers are kept until `refresh()`.
public final class ToolLocator: ToolLocating, @unchecked Sendable {
    /// The programs `/usr/bin` only offers as stubs for the developer tools.
    static let developerToolNames: Set<String> = ["git", "swift", "clang", "make"]
    /// `~/.homebrew/bin` is Homebrew installed without admin rights: the login shell may not answer (slow profile,
    /// busy machine), and the tools there must still be found.
    static let standardFolders = [FileManager.default.homeDirectoryForCurrentUser.path + "/.homebrew/bin",
                                  "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]

    /// Folders searched in order. Nil: the login shell's PATH, then `standardFolders`. Tests give their own.
    private let folders: [String]?
    private let developerTools: () -> Bool
    private let lock = NSLock()
    private var located: [String: URL?] = [:]
    private var resolvedFolders: [String]?
    private var developerToolsAnswer: Bool?

    public init(folders: [String]? = nil, developerTools: (() -> Bool)? = nil) {
        self.folders = folders
        self.developerTools = developerTools ?? Self.developerToolsInstalled
    }

    public func locate(_ name: String) -> URL? {
        lock.lock()
        defer { lock.unlock() }
        if let answer = located[name] { return answer }
        let answer = search(name)
        located[name] = answer
        return answer
    }

    /// Forgets every answer, so the next `locate` looks again: after the user installed something.
    public func refresh() {
        lock.lock()
        defer { lock.unlock() }
        located = [:]
        resolvedFolders = nil
        developerToolsAnswer = nil
    }

    private func search(_ name: String) -> URL? {
        for folder in searchFolders() {
            let path = folder + "/" + name
            guard FileManager.default.isExecutableFile(atPath: path) else { continue }
            if folder == "/usr/bin", Self.developerToolNames.contains(name), !hasDeveloperTools() { continue }
            return URL(fileURLWithPath: path)
        }
        return nil
    }

    private func searchFolders() -> [String] {
        if let folders { return folders }
        if let resolvedFolders { return resolvedFolders }
        var seen: Set<String> = []
        let all = Self.cachedLoginShellFolders() + Self.standardFolders
        let unique = all.filter { !$0.isEmpty && seen.insert($0).inserted }
        resolvedFolders = unique
        return unique
    }

    private func hasDeveloperTools() -> Bool {
        if let developerToolsAnswer { return developerToolsAnswer }
        let answer = developerTools()
        developerToolsAnswer = answer
        return answer
    }

    static let loginPathKey = "toolLocator.loginShellPath"

    /// The login shell's PATH as the previous launch read it, read again in the background for the next one: starting
    /// the shell held the launch for about half a second. The first launch, with nothing saved, waits for the shell.
    static func cachedLoginShellFolders() -> [String] {
        let defaults = UserDefaults.standard
        guard let saved = defaults.stringArray(forKey: loginPathKey) else {
            let folders = loginShellFolders()
            if !folders.isEmpty { defaults.set(folders, forKey: loginPathKey) }
            return folders
        }
        DispatchQueue.global(qos: .utility).async {
            let folders = loginShellFolders()
            if !folders.isEmpty { UserDefaults.standard.set(folders, forKey: loginPathKey) }
        }
        return saved
    }

    /// The folders of the login shell's PATH (`$SHELL -lic`), empty when the shell does not answer in 5 seconds: a slow
    /// or broken profile must not hang the app.
    static func loginShellFolders() -> [String] {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        guard FileManager.default.isExecutableFile(atPath: shell) else { return [] }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-lic", "printf '__LOAM_PATH__%s__LOAM_PATH__' \"$PATH\""]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return [] }
        let done = DispatchSemaphore(value: 0)
        var data = Data()
        DispatchQueue.global().async {
            data = output.fileHandleForReading.readDataToEndOfFile()
            done.signal()
        }
        if done.wait(timeout: .now() + 5) == .timedOut {
            process.terminate()
            return []
        }
        let parts = String(decoding: data, as: UTF8.self).components(separatedBy: "__LOAM_PATH__")
        guard parts.count >= 3 else { return [] }
        return parts[1].split(separator: ":").map(String.init)
    }

    /// Whether the developer tools are installed: `xcode-select -p` only prints the folder, it opens no installer.
    public static func developerToolsInstalled() -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcode-select")
        process.arguments = ["-p"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }
}
