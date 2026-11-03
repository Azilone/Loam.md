import Foundation

/// Installs missing programs as far as the app can without the user's password: the developer tools with Apple's own
/// installer, Homebrew formulas with `brew install`. Homebrew itself asks for the password, so it is the one step left
/// to the Terminal (the app's `install-dependencies.command`).
public enum ToolInstaller {
    /// What installing the missing programs takes next.
    public enum Step: Equatable, Sendable {
        case nothing
        /// The developer tools (git, swift): Apple's installer, opened with `xcode-select --install`.
        case developerTools
        /// Homebrew is missing: it installs in the Terminal, then the formulas.
        case homebrew
        /// `brew install` these formulas.
        case brew([String])

        public var name: String {
            switch self {
            case .nothing: "nothing"
            case .developerTools: "developer-tools"
            case .homebrew: "homebrew"
            case .brew: "brew"
            }
        }
    }

    /// The programs Apple's developer tools provide: without them `/usr/bin/git` is only a stub.
    static let developerToolPrograms = ToolCatalog.developerToolPrograms.union(["git"])

    /// The next step for `missing`. The developer tools come first: Homebrew needs them, and they bring git and
    /// swift without a password.
    public static func plan(missing: [String], hasDeveloperTools: Bool, hasHomebrew: Bool) -> Step {
        if !hasDeveloperTools, missing.contains(where: developerToolPrograms.contains) { return .developerTools }
        let formulas = ToolCatalog.formulas(for: missing)
        if formulas.isEmpty { return .nothing }
        return hasHomebrew ? .brew(formulas) : .homebrew
    }

    /// Opens Apple's installer for the developer tools and returns at once; it reports nothing back, so the caller
    /// looks for the tools again later.
    static func openDeveloperToolsInstaller() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcode-select")
        process.arguments = ["--install"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
    }

    /// Runs `brew install` without prompts. Throws with the end of its output when it fails.
    static func brewInstall(_ formulas: [String], brew: URL) async throws {
        let log = FileManager.default.temporaryDirectory.appendingPathComponent("loam-brew-\(UUID().uuidString).log")
        defer { try? FileManager.default.removeItem(at: log) }
        let path = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        let status = try await Subprocess.run(brew.path, ["install"] + formulas, environment: [
            "PATH": brew.deletingLastPathComponent().path + ":" + path,
            "NONINTERACTIVE": "1",
            "HOMEBREW_NO_ENV_HINTS": "1",
        ], log: log)
        guard status == 0 else {
            let text = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
            throw Subprocess.Failure(message: "brew install \(formulas.joined(separator: " ")) failed (\(status)): "
                + Subprocess.lastLines(text, 8))
        }
    }
}
