import Foundation
import PluginKit

/// The "loam" skill for outside agents (Claude Code, Codex, OpenCode, Pi, Antigravity), as Aside does for its
/// browser: a short `SKILL.md` that says when to use Loam and to read `loam guide`, which holds the knowledge and
/// ships with the app. `loam skill install` writes it where the agents look.
public enum AgentSkill {
    /// Where agents read skills: one folder each, `<folder>/loam/SKILL.md`.
    public struct Target: Equatable, Sendable {
        public let name: String
        /// The agents that read this folder.
        public let agents: String
        public let folder: URL
    }

    public static func targets(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [Target] {
        [
            Target(name: "claude", agents: "Claude Code, OpenCode", folder: home.appendingPathComponent(".claude/skills")),
            Target(name: "codex", agents: "Codex", folder: home.appendingPathComponent(".codex/skills")),
            Target(name: "agents", agents: "Antigravity, Pi, OpenCode, Codex",
                   folder: home.appendingPathComponent(".agents/skills")),
        ]
    }

    /// Bumped when the text below changes, so `loam skill status` can say a copy is old.
    public static let version = 2

    public static var text: String {
        """
        ---
        name: loam
        description: Use Loam, the user's Markdown notebook app, from the terminal - read, write, search and organize their notes, tasks, daily notes and collections, run any of the app's commands, and build, test and install Loam plugins (new features for the app). Use whenever the user mentions Loam, their Loam vault or notes in it, or asks for a Loam plugin or feature.
        metadata:
          version: \(version)
        ---

        # Loam

        Loam is a local-first Markdown notebook for the Mac: a vault is a plain folder of Markdown notes, and every
        feature is a plugin whose actions are commands. The `loam` command line does everything the app does.

        Before anything else, run:

        ```bash
        loam guide
        ```

        It explains the rules (the notes are the user's) and lists the topics; read the one you need, for example
        `loam guide recipes` to make a project and its Kanban, a meeting, a habit, a mind map, a board or a drawing,
        `loam guide plugins` before building a plugin, `loam guide app` to check your work in the open app. The guide
        comes from the installed app, so it is always right for its version; trust it over what you remember.

        If `loam` is not found, it is in the app: `/Applications/Loam.app/Contents/Helpers/loam`, and Settings >
        Developers puts it on the PATH.
        """
    }

    public struct Status: Encodable, Equatable {
        public let target: String
        public let agents: String
        public let path: String
        public let installed: Bool
        /// The installed copy's version, when there is one.
        public let version: Int?
        public let current: Bool
    }

    public static func status(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [Status] {
        targets(home: home).map { target in
            let file = target.folder.appendingPathComponent("loam/SKILL.md")
            let text = try? String(contentsOf: file, encoding: .utf8)
            let version = text.flatMap { body -> Int? in
                guard let line = body.split(separator: "\n").first(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("version:") })
                else { return nil }
                return Int(line.split(separator: ":").last?.trimmingCharacters(in: .whitespaces) ?? "")
            }
            return Status(target: target.name, agents: target.agents, path: file.path, installed: text != nil,
                          version: version, current: version == Self.version)
        }
    }

    /// Writes the skill for `names` (every target when empty). Returns the files written.
    @discardableResult
    public static func install(_ names: [String] = [], home: URL = FileManager.default.homeDirectoryForCurrentUser) throws
        -> [String]
    {
        let chosen = targets(home: home).filter { names.isEmpty || names.contains($0.name) }
        guard !chosen.isEmpty else {
            throw CLIError.usage("unknown agent; use \(targets(home: home).map(\.name).joined(separator: ", "))")
        }
        return try chosen.map { target in
            let folder = target.folder.appendingPathComponent("loam")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let file = folder.appendingPathComponent("SKILL.md")
            try text.write(to: file, atomically: true, encoding: .utf8)
            return file.path
        }
    }

    /// Removes the skill from `names` (every target when empty).
    public static func uninstall(_ names: [String] = [], home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        for target in targets(home: home) where names.isEmpty || names.contains(target.name) {
            try? FileManager.default.removeItem(at: target.folder.appendingPathComponent("loam"))
        }
    }
}

/// Puts the app's `loam` on the PATH: a link in `~/.local/bin`, a folder most agents and shells already search.
public enum CommandLineInstall {
    public static func linkURL(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appendingPathComponent(".local/bin/loam")
    }

    /// Where the link points, or nil when there is none.
    public static func installed(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> String? {
        try? FileManager.default.destinationOfSymbolicLink(atPath: linkURL(home: home).path)
    }

    /// Links `~/.local/bin/loam` to `executable`, replacing an older link (never a real file someone put there).
    public static func install(executable: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser) throws {
        // A throwaway copy (an agent's test instance in /tmp) would leave the link dangling once it is cleaned up.
        if ["/tmp/", "/private/tmp/", "/private/var/folders/"].contains(where: executable.standardizedFileURL.path.hasPrefix) {
            throw CLIError.usage("\(executable.path) is a temporary copy of Loam; link the installed app instead")
        }
        let link = linkURL(home: home)
        let files = FileManager.default
        try files.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        if (try? files.destinationOfSymbolicLink(atPath: link.path)) != nil {
            try files.removeItem(at: link)
        } else if files.fileExists(atPath: link.path) {
            throw CLIError.usage("\(link.path) exists and is not a link to Loam; remove it first")
        }
        try files.createSymbolicLink(atPath: link.path, withDestinationPath: executable.path)
    }

    public static func uninstall(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        let link = linkURL(home: home)
        if (try? FileManager.default.destinationOfSymbolicLink(atPath: link.path)) != nil {
            try? FileManager.default.removeItem(at: link)
        }
    }

    /// Whether `~/.local/bin` is on the login shell's PATH (`$SHELL -lc 'echo $PATH'`).
    public static func folderIsOnPath(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Bool {
        let folder = linkURL(home: home).deletingLastPathComponent().path
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh")
        process.arguments = ["-lc", "echo $PATH"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return false }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self).split(separator: ":").contains { $0.trimmingCharacters(in: .whitespacesAndNewlines) == folder }
    }
}
