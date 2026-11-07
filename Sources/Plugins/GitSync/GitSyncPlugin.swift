import Foundation
import PluginKit

/// Keeps the vault in sync with a git remote (GitHub or any other), on its own: changes are committed shortly after
/// they stop, other devices' changes come in when the app is in front, and a note changed on two devices at once
/// keeps this device's version with the other one saved next to it. Provides the `git-sync` service (used by the
/// status bar item, `GitSyncUI`) and the `sync.*` commands. Uses the git installed on the machine and its
/// credentials; stores no secret.
public final class GitSyncPlugin: Plugin {
    public static var manifest: PluginManifest {
        PluginManifest(id: "git-sync", name: "Git sync", version: "0.1.0", description: "Keeps the vault in sync with a Git remote on its own, encrypted.", icon: "arrow.triangle.2.circlepath", provides: ["git-sync"],
                       permissions: ["vault.read", "vault.write", "shell", "network", "disk.read"])
    }

    public static var requiresTools: [String] { ["git"] }

    public required init() {}

    public func activate(context: PluginContext) throws {
        let git = context.service(ServiceKey<ToolLocating>.tools)?.locate("git")
        let controller = SyncController(context: context, runner: ProcessGitRunner(directory: context.vault.rootURL, git: git))
        try context.provide(.gitSync, controller)
        let ownID = Self.manifest.id

        try context.registerCommand(Command(
            id: "sync.now",
            title: "Sync now",
            summary: "Commits this vault's changes, brings in the other devices' changes and pushes. A note changed on "
                + "both sides keeps this device's version and gets a conflict copy next to it. Writes to the vault. "
                + "Optional: confirm=deletions to commit a deletion of many files at once; confirm=plain-incoming to take notes that came unencrypted; confirm=changes to go over this device's limit (loam.maxchanges); confirm=plain to push "
                + "commits made before the vault was encrypted."
        ) { arguments in
            var options = CycleOptions(forceMerge: true)
            options.allowDeletions = arguments["confirm"] == "deletions"
            options.allowPlainHistory = arguments["confirm"] == "plain"
            options.allowPlainIncoming = arguments["confirm"] == "plain-incoming"
            options.allowManyChanges = arguments["confirm"] == "changes"
            return await controller.sync(options).status.sentence
        })

        try context.registerCommand(Command(
            id: "sync.status",
            title: "Sync status",
            summary: "Where the sync stands, without changing anything: state, branch, remote, commits ahead and "
                + "behind, uncommitted changes, conflict copies, last sync."
        ) { _ in try JSON.string(await controller.report()) })

        try context.registerCommand(Command(
            id: "sync.setup",
            title: "Set up sync",
            summary: "Makes the vault a git repository that syncs with a remote, then syncs once. Writes to the vault "
                + "(.gitignore). Optional: url (needed if the remote does not exist), remote (origin), branch, "
                + "gitDir (keep git's data outside the vault, advised in iCloud Drive), device (name in commits), "
                + "encrypt=true (the remote only gets ciphertext; the key stays in this device's Keychain), "
                + "key=loam-key:… or keyFile=<path> (an encrypted remote's key, from sync.key.export: a new machine, "
                + "an agent), maxChanges=<n> (the most files one sync may commit here: for an agent), confirm=foreign-remote (join a repository that is not a vault: a codebase, or one with other branches but not this one; refused otherwise). On a server, mkdir the folder and run it there: loam --vault <folder> sync.setup url=….",
            isInPalette: false
        ) { arguments in
            var imported: [String] = []
            if let text = try Self.keyArgument(arguments) {
                let key = try await controller.engine.importKey(text)
                imported.append("Key \(key.id) saved on this device.")
            }
            let (report, first) = try await controller.setUp(SetupRequest(arguments: arguments))
            return (imported + report + [first.sentence]).joined(separator: "\n")
        })

        try context.registerCommand(Command(
            id: "sync.enable",
            title: "Turn on automatic sync",
            summary: "Syncs on its own while the app is open. The vault must be set up (sync.setup)."
        ) { _ in
            try await controller.setAuto(true)
            return "Automatic sync is on."
        })

        try context.registerCommand(Command(
            id: "sync.disconnect",
            title: "Stop syncing with this repository",
            summary: "Turns automatic sync off and forgets the vault's remote, to set up another repository with "
                + "sync.setup. The vault's files and history stay, and the repository is left as it is.",
            isInPalette: false
        ) { _ in
            try await controller.disconnect().report.joined(separator: " ")
        })

        try context.registerCommand(Command(
            id: "sync.disable",
            title: "Turn off automatic sync",
            summary: "Stops syncing on its own; sync.now still works."
        ) { _ in
            try await controller.setAuto(false)
            return "Automatic sync is off."
        })

        try context.registerCommand(Command(
            id: "sync.resolve",
            title: "Finish a merge with conflict copies",
            summary: "Finishes a merge left in progress by another tool (Obsidian Git, a terminal): each file changed on "
                + "both sides keeps this device's version, with the other one saved next to it. Writes to the vault.",
            isInPalette: false
        ) { _ in
            await controller.sync(CycleOptions(forceMerge: true, resolveForeignMerge: true)).status.sentence
        })

        try context.registerCommand(Command(
            id: "sync.github",
            title: "Sync with GitHub",
            summary: "Settings > Sync > Connect GitHub from the command line: the vault syncs with its private repository "
                + "(loam-<folder>) on the GitHub account this device is signed in to (the app's sign-in, or "
                + "LOAM_GITHUB_TOKEN), made if new. encrypt=true encrypts it (agents then need Loam to read it).",
            isInPalette: false
        ) { arguments in
            try await controller.setUpWithGitHub(encrypt: ["true", "yes", "1"].contains(arguments["encrypt"] ?? "")).sentence
        })

        try context.registerCommand(Command(
            id: "sync.join",
            title: "Join a vault with a connect code",
            summary: "For a new Mac or an agent: code=loam-connect:… (or the LOAM_CONNECT environment variable), from "
                + "Settings > Sync on a Mac that syncs (Connect an agent, Connect a device). Sets this folder up as that "
                + "vault, decrypted here, and syncs once. An agent then runs sync.watch, or sync.now after each task. "
                + "Optional: maxChanges=<n> (50 for an agent).",
            isInPalette: false
        ) { arguments in
            guard let code = arguments["code"].flatMap({ $0.isEmpty ? nil : $0 })
                ?? ProcessInfo.processInfo.environment["LOAM_CONNECT"] else {
                throw ConnectError("Pass the code: code=loam-connect:… or LOAM_CONNECT.")
            }
            return try await controller.join(code, maxChanges: arguments["maxChanges"].flatMap(Int.init)).sentence
        })

        try context.registerCommand(Command(
            id: "sync.connect",
            title: "Make a connect code",
            summary: "The code an agent (agent=<name>) or another Mac (device=<name>) pastes to join this vault "
                + "(sync.join there). An agent gets a deploy key of its own on GitHub. A secret: it opens the vault.",
            isInPalette: false
        ) { arguments in
            if let agent = arguments["agent"], !agent.isEmpty {
                return try await controller.connectCode(for: agent, agent: true)
            }
            return try await controller.connectCode(for: arguments["device"] ?? "Mac", agent: false)
        })

        try context.registerCommand(Command(
            id: "sync.agents",
            title: "List connected agents",
            summary: "The agents with access to the vault's GitHub repository, one per line. agent=<name> remove=true "
                + "takes one's access away (its deploy key on GitHub goes).",
            isInPalette: false
        ) { arguments in
            if let agent = arguments["agent"], !agent.isEmpty, arguments["remove"] == "true" {
                return try await controller.removeAgent(agent).sentence
            }
            let agents = try await controller.connectedAgents()
            return agents.isEmpty ? "No agent is connected." : agents.joined(separator: "\n")
        })

        try context.registerCommand(Command(
            id: "sync.watch",
            title: "Keep the vault synced from a terminal",
            summary: "For a server or an agent's machine: syncs every `every` seconds (default 60) until stopped "
                + "(Ctrl-C, or the service stops), with the same guards as the app. Prints a line when a sync changed "
                + "something or needs attention. Optional: count=<n> stops after n syncs. Not for the app, which "
                + "syncs on its own.",
            isInPalette: false
        ) { arguments in
            let every = max(5, Double(arguments["every"] ?? "") ?? 60)
            let count = Int(arguments["count"] ?? "")
            var last: String?
            var runs = 0
            while count.map({ runs < $0 }) ?? true, !Task.isCancelled {
                let outcome = await controller.sync(CycleOptions(forceMerge: true))
                runs += 1
                let line = outcome.status.sentence
                if line != last || outcome.status.state == .attention {
                    let stamp = SyncEngine.timestamp(Date())
                    FileHandle.standardOutput.write(Data("\(stamp) \(line)\n".utf8))
                    last = line
                }
                if count.map({ runs >= $0 }) ?? false { break }
                try? await Task.sleep(nanoseconds: UInt64(every * 1_000_000_000))
            }
            return "Stopped after \(runs) sync\(runs == 1 ? "" : "s")."
        })

        try context.registerCommand(Command(
            id: "sync.undo",
            title: "Undo what a device or agent changed",
            summary: "Takes back the changes one device or agent committed (device=<name>, as in its commits), with new "
                + "commits: history keeps both. Optional: since=<2026-10-28 | 2026-10-28T14:00 | 6h | 2d>. Syncs "
                + "before and after. Stops, changing nothing, when someone changed the same lines since.",
            isInPalette: false
        ) { arguments in
            let device = try arguments.require("device")
            var since: Date?
            if let text = arguments["since"], !text.isEmpty {
                guard let parsed = SyncEngine.parseSince(text, now: Date()) else {
                    throw SetupError(message: "since= takes 2026-10-28, 2026-10-28T14:00, 6h or 2d.")
                }
                since = parsed
            }
            let first = await controller.syncNow()
            guard first.state != .attention else { return first.sentence }
            let changed = try await controller.engine.undo(device: device, since: since)
            guard !changed.isEmpty else { return "\(device)'s changes were already undone." }
            let files = changed.count == 1 ? "1 file" : "\(changed.count) files"
            return "Undid \(device)'s changes to \(files): \(SyncEngine.list(changed)).\n"
                + (await controller.syncNow()).sentence
        })

        try context.registerCommand(Command(
            id: "sync.protect",
            title: "Check that the remote stays encrypted",
            summary: "For an encrypted vault: adds a GitHub check (.github/workflows/loam-encrypted.yml) that fails "
                + "when a file on the remote is not encrypted, such as one pushed by an agent without Loam. Writes to "
                + "the vault; the next sync pushes it. sync.setup encrypt=true does it already.",
            isInPalette: false
        ) { _ in
            let report = try await controller.engine.installRemoteGuard()
            guard !report.isEmpty else { return "The remote check is already there." }
            return (report + [await controller.syncNow().sentence]).joined(separator: "\n")
        })

        try context.registerCommand(Command(
            id: "sync.leak.report",
            title: "List notes that reached the remote unencrypted",
            summary: "For an encrypted vault: the commits on the remote that hold a file in plain text since the vault "
                + "was encrypted (pushed by a tool without Loam's encryption), and how to remove them. Changes nothing.",
            isInPalette: false
        ) { _ in SyncEngine.leakReport(await controller.engine.leaks()) })

        try context.registerCommand(Command(
            id: "sync.key.rotate",
            title: "Change the vault key",
            summary: "For an encrypted vault: encrypts every file again with a new key, in one commit, and pushes it. "
                + "Devices and agents without the new key stop at their next sync until it is imported there "
                + "(sync.key.export here, sync.key.import there): the way to take access away from one. History "
                + "stays encrypted with the old key, which still opens it.",
            isInPalette: false
        ) { _ in
            let first = await controller.syncNow()
            guard first.state == .synced || first.state == .off else { return first.sentence }
            let (old, key) = try await controller.engine.rotateKey()
            let pushed = await controller.syncNow()
            return "The vault key is now \(key.id) (was \(old)). Give it to each device and agent you still trust: "
                + "sync.key.export here, sync.key.import there (agents: LOAM_VAULT_KEY). The others stop syncing.\n"
                + pushed.sentence
        })

        try context.registerCommand(Command(
            id: "sync.key.export",
            title: "Export the vault key",
            summary: "Gives the key an encrypted vault syncs with, for another device (sync.key.import there). A "
                + "secret: with it and access to the remote, anyone can read the vault. Optional: file=<path> writes it "
                + "to a file only you can read instead of printing it.",
            isInPalette: false
        ) { arguments in
            let key = try await controller.engine.exportKey()
            guard let file = arguments["file"], !file.isEmpty else { return key.exported }
            let path = (file as NSString).expandingTildeInPath
            guard FileManager.default.createFile(atPath: path, contents: Data((key.exported + "\n").utf8),
                                                 attributes: [.posixPermissions: 0o600]) else {
                throw SetupError(message: "Could not write \(path).")
            }
            return "Key \(key.id) written to \(path). On the other device: sync.key.import file=<that file>, then "
                + "delete it."
        })

        try context.registerCommand(Command(
            id: "sync.key.import",
            title: "Import the vault key",
            summary: "Keeps an encrypted vault's key on this device (the Keychain), so it can sync: key=loam-key:… or "
                + "file=<path>, from sync.key.export on a device that syncs. Refuses another vault's key.",
            isInPalette: false
        ) { arguments in
            let text: String
            if let key = arguments["key"], !key.isEmpty {
                text = key
            } else if let file = arguments["file"], !file.isEmpty {
                text = try String(contentsOfFile: (file as NSString).expandingTildeInPath, encoding: .utf8)
            } else {
                throw SetupError(message: "Pass the key: key=loam-key:… or file=<path>.")
            }
            let key = try await controller.engine.importKey(text)
            var lines = ["Key \(key.id) saved on this device."]
            if await controller.settings().auto {
                lines.append(await controller.sync(await controller.engine.optionsAfterImport()).status.sentence)
            }
            return lines.joined(separator: "\n")
        })

        context.on(VaultChanged.self) { [weak controller] _ in controller?.noteWritten(fromWatcher: true) }
        context.on(NoteDidChange.self) { [weak controller] event in
            guard event.pluginID != ownID else { return }
            controller?.noteWritten(fromWatcher: false)
        }
        context.on(PluginSettingsChanged.self) { [weak controller] event in
            guard event.pluginID == ownID else { return }
            controller?.applySettings()
        }
        context.effect { controller.stop() }
    }
}

extension GitSyncPlugin {
    /// What an encrypted vault's agent runs: installs Loam, joins with its code (`LOAM_CONNECT`).
    public static func installLine(_ code: String) -> String {
        "curl -fsSL https://github.com/Azilone/loam-releases/releases/download/cli/install.sh | LOAM_CONNECT=\(code) sh"
    }

    /// A key passed as `key=loam-key:…` or `keyFile=<path>`; nil when neither is.
    static func keyArgument(_ arguments: [String: String]) throws -> String? {
        if let key = arguments["key"], !key.isEmpty { return key }
        guard let file = arguments["keyFile"], !file.isEmpty else { return nil }
        return try String(contentsOfFile: (file as NSString).expandingTildeInPath, encoding: .utf8)
    }
}

extension SyncController {
    /// Sets the vault up (`SyncEngine.setUp`), then syncs once. Returns what setting up did and where the sync left
    /// things.
    func setUp(_ request: SetupRequest) async throws -> (report: [String], status: SyncStatus) {
        var request = request
        if request.gitDir == nil { request.gitDir = Self.gitDirOutsideICloud(for: engine.root) }
        let report = try await engine.setUp(request)
        await MainActor.run { applySettings() }
        let first = await sync(CycleOptions(allowUnrelatedHistories: true, allowForeignRemote: request.allowForeignRemote,
                                            setUpstream: true, forceMerge: true))
        return (report, first.status)
    }

    func setUp(url: String, device: String?, encrypt: Bool) async throws -> SyncStatus {
        let device = device.flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
        let request = SetupRequest(url: url.trimmingCharacters(in: .whitespacesAndNewlines), device: device,
                                   encrypt: encrypt)
        return try await setUp(request).status
    }

    func setAutomatic(_ on: Bool) async throws {
        try await setAuto(on)
    }

    /// Where a new repository keeps git's data for a vault in iCloud Drive, which can damage a `.git` folder:
    /// `~/.vault-git/<vault>.git`. nil outside iCloud Drive, or when the vault is already a repository.
    static func gitDirOutsideICloud(for root: URL) -> String? {
        guard root.path.contains("/Library/Mobile Documents/"),
              !FileManager.default.fileExists(atPath: root.appendingPathComponent(".git").path) else { return nil }
        let name = root.lastPathComponent.replacingOccurrences(of: " ", with: "-")
        return "~/.vault-git/\(name).git"
    }

    /// `sync.disconnect`: automatic sync off and the remote forgotten, to set up another repository.
    func disconnect() async throws -> (report: [String], status: SyncStatus) {
        try await setAuto(false)
        let remote = await settings().remote
        let report = try await engine.disconnect(remote: remote)
        return (report, await self.report())
    }

    /// Turns automatic sync on or off, keeping the other settings.
    func setAuto(_ auto: Bool) async throws {
        var settings = await settings()
        settings.auto = auto
        try await updateSettings(settings)
        await MainActor.run { applySettings() }
    }
}
