import Foundation
import PluginKit
import LoamCore

public enum CLIError: Error, Equatable {
    case usage(String)
    case unknownCommand(String)
}

/// `loam [--vault <path>] <command-id> [key=value ...]`, `loam list`, `loam help`.
/// Every command a plugin registers is available here, with its text or JSON output on stdout.
public struct Invocation: Equatable {
    public var vault: String?
    public var command: String?
    public var arguments: [String: String] = [:]
    /// The words after `guide`, `skill` and `app` (`loam app run tasks.list`: `run`, `tasks.list`).
    public var operands: [String] = []
    public var wantsHelp = false

    public init() {}
}

public struct CLIResult: Equatable {
    public let exitCode: Int32
    public let stdout: String
    public let stderr: String
}

public enum CLI {
    public static let usage = """
        Usage: loam [--vault <path>] <command> [key=value ...]

        The vault is --vault, then $LOAM_VAULT, then the current folder.

          loam list [word ...]          the commands (JSON: id, title, summary); words keep the matching ones
          loam list --brief             one line per command: id and title
          loam help                     show this text
          loam <command> key=value ...  run a command, e.g. loam daily.append text="Met Bob"

        For agents (Claude Code, Codex, Pi…):

          loam guide [topic]            how to use Loam and build plugins; start here
          loam skill install [--claude|--codex|--agents]   the "loam" skill, so agents know to read the guide
          loam skill status             where the skill is installed

        The open app (the window with this vault):

          loam app info                 the open vault and note
          loam app list                 the window's commands (UI ones included), as JSON
          loam app open <path>          open a note in the window
          loam app run <command> [key=value ...]   run a command inside the app, UI commands included
          loam app shot <file.png>      a picture of the window
          loam app switch <folder>      make the app open another vault
          loam app relaunch             restart the app on the vault (loads rebuilt plugins)

        The vault's own plugins (.loam/plugins/), built with the app's SDK and the swift on the PATH:

          loam plugin new <id> [--ui]   create a plugin package to edit (--ui: with a panel)
          loam plugin build <id>|--all  compile it into .loam/cache/plugins/ (minutes)
          loam plugin test <id>         run its tests against the app's SDK
          loam plugin install <url>     clone a git URL (or copy a folder) and build it; never enables it
          loam plugin install --catalog <id>   install a plugin of the public catalog, pinned to its commit
          loam plugin catalog [query]   list the plugins of the public catalog
          loam plugin outdated          list the plugins with a newer version (network)
          loam plugin update <id>|--all update and rebuild; new permissions disable it until re-enabled
          loam plugin rollback <id>     go back to the version the last update replaced
          loam plugin list              list every plugin (JSON)
          loam plugin enable <id>       enable it (also: disable)
          loam plugin remove <id>       move it to .trash/plugins/ and disable it
        """

    public static func parse(_ arguments: [String]) throws -> Invocation {
        var invocation = Invocation()
        var positionals: [String] = []
        var flags: [String] = []
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            index += 1
            if argument == "-h" || argument == "--help" {
                invocation.wantsHelp = true
            } else if argument == "--vault" {
                guard index < arguments.count else { throw CLIError.usage("--vault needs a path") }
                invocation.vault = arguments[index]
                index += 1
            } else if argument.hasPrefix("--vault=") {
                invocation.vault = String(argument.dropFirst("--vault=".count))
            } else if argument.hasPrefix("-"), argument.count > 1, !argument.contains("=") {
                flags.append(argument)
            } else if invocation.command == nil {
                invocation.command = argument
            } else if invocation.command == "plugin", !argument.contains("=") || positionals.count == 1 && isURL(argument) {
                positionals.append(argument)
            } else if ["guide", "skill", "app", "list"].contains(invocation.command ?? ""), !argument.contains("=") {
                invocation.operands.append(argument)
            } else if let equals = argument.firstIndex(of: "=") {
                let key = String(argument[..<equals])
                guard !key.isEmpty else { throw CLIError.usage("argument \"\(argument)\" has no name") }
                invocation.arguments[key] = String(argument[argument.index(after: equals)...])
            } else {
                throw CLIError.usage("argument \"\(argument)\" must be written key=value")
            }
        }
        if invocation.command == "plugin" {
            try expandPluginAlias(&invocation, positionals: positionals, flags: flags)
        } else if invocation.command == "skill" {
            invocation.operands += flags
        } else if invocation.command == "list", flags.allSatisfy({ $0 == "--brief" }) {
            invocation.operands += flags
        } else if let flag = flags.first {
            throw CLIError.usage("unknown option \(flag)")
        }
        return invocation
    }

    /// `loam plugin <verb> ...`: friendly spellings of the `plugins.*` commands.
    ///
    ///     loam plugin new <id> [--ui]      plugins.new id=<id> [ui=true]
    ///     loam plugin build <id> | --all   plugins.build id=<id> | all=true
    ///     loam plugin install <url>        plugins.install url=<url>
    ///     loam plugin install --catalog <id>   plugins.install id=<id>
    ///     loam plugin catalog [query]      plugins.catalog [query=<query>]
    ///     loam plugin outdated [id]        plugins.outdated [id=<id>]
    ///     loam plugin update <id> | --all  plugins.update id=<id> | all=true
    ///     loam plugin rollback <id>        plugins.rollback id=<id>
    ///     loam plugin list                 plugins.list
    ///     loam plugin remove <id>          plugins.remove id=<id>
    ///     loam plugin enable|disable <id>  plugins.enable|disable id=<id>
    private static func expandPluginAlias(_ invocation: inout Invocation, positionals: [String], flags: [String]) throws {
        guard let verb = positionals.first else {
            if invocation.wantsHelp { return }
            throw CLIError.usage("loam plugin needs a verb: new, build, test, install, list, remove, enable or disable")
        }
        let allowed: [String: Set<String>] = ["new": ["--ui"], "build": ["--all"], "update": ["--all"],
                                              "install": ["--catalog"]]
        if let flag = flags.first(where: { !(allowed[verb] ?? []).contains($0) }) {
            throw CLIError.usage("unknown option \(flag) for loam plugin \(verb)")
        }
        let operand = positionals.dropFirst().first
        if positionals.count > 2 { throw CLIError.usage("loam plugin \(verb) takes one operand") }
        let key: String?
        switch verb {
        case "new", "remove", "enable", "disable", "test", "rollback", "outdated": key = "id"
        case "build", "update": key = flags.contains("--all") ? nil : "id"
        case "install": key = flags.contains("--catalog") ? "id" : "url"
        case "catalog": key = "query"
        case "list": key = nil
        default: throw CLIError.usage("unknown verb \"\(verb)\" for loam plugin; use new, build, test, install, list, catalog, outdated, update, rollback, remove, enable or disable")
        }
        if let key, let operand { invocation.arguments[key] = operand }
        if key == nil, operand != nil { throw CLIError.usage("loam plugin \(verb) takes no operand") }
        if flags.contains("--ui") { invocation.arguments["ui"] = "true" }
        if flags.contains("--all") { invocation.arguments["all"] = "true" }
        invocation.command = verb == "list" ? "plugins.list" : "plugins.\(verb)"
    }

    /// A git URL contains `=` sometimes (query strings); one after `install` is the operand, not key=value.
    private static func isURL(_ argument: String) -> Bool {
        argument.contains("://") || argument.hasPrefix("git@")
    }

    public static func execute(_ invocation: Invocation, kernel: Kernel) async -> CLIResult {
        guard let name = invocation.command, !invocation.wantsHelp, name != "help" else {
            return CLIResult(exitCode: 0, stdout: usage + "\n", stderr: "")
        }
        if name == "list" {
            let words = invocation.operands.filter { $0 != "--brief" }.map { $0.lowercased() }
            let commands = kernel.commands.all.filter { command in
                words.isEmpty || words.contains { command.id.lowercased().contains($0) || command.title.lowercased().contains($0) }
            }
            if invocation.operands.contains("--brief") {
                return CLIResult(exitCode: 0, stdout: commands.map { "\($0.id)  \($0.title)\n" }.joined(), stderr: "")
            }
            let entries = commands.map { ListEntry(id: $0.id, title: $0.title, summary: $0.summary) }
            return finish { try JSON.string(entries) }
        }
        guard let command = kernel.commands.command(id: name) else {
            return failure(CLIError.unknownCommand(name), exitCode: 2)
        }
        do {
            let output = try await command.handler(invocation.arguments)
            return CLIResult(exitCode: 0, stdout: output.hasSuffix("\n") || output.isEmpty ? output : output + "\n", stderr: "")
        } catch {
            return failure(error, exitCode: 1)
        }
    }

    /// `guide` and `skill`, which need no vault. Nil for anything else.
    public static func executeLocal(_ invocation: Invocation) -> CLIResult? {
        guard !invocation.wantsHelp else { return nil }
        switch invocation.command {
        case "guide":
            guard let text = Guide.text(invocation.operands.first) else {
                return failure(CLIError.usage("no guide topic \"\(invocation.operands.first ?? "")\"; topics: "
                    + Guide.topics.map(\.name).joined(separator: ", ")), exitCode: 2)
            }
            return CLIResult(exitCode: 0, stdout: text, stderr: "")
        case "skill":
            let verb = invocation.operands.first ?? "status"
            let names = invocation.operands.dropFirst().map { $0.hasPrefix("--") ? String($0.dropFirst(2)) : $0 }
            switch verb {
            case "install":
                return finish { try JSON.string(["installed": try AgentSkill.install(Array(names))]) }
            case "uninstall", "remove":
                AgentSkill.uninstall(Array(names))
                return finish { try JSON.string(AgentSkill.status()) }
            case "status":
                return finish { try JSON.string(AgentSkill.status()) }
            case "print", "show":
                return CLIResult(exitCode: 0, stdout: AgentSkill.text + "\n", stderr: "")
            default:
                return failure(CLIError.usage("loam skill takes install, uninstall, status or print"), exitCode: 2)
            }
        default:
            return nil
        }
    }

    /// `loam app …`: one request to the app with `vault` open.
    public static func executeApp(_ invocation: Invocation, vault: URL) -> CLIResult {
        let verb = invocation.operands.first ?? "info"
        let target = invocation.operands.dropFirst().first
        var request = AppChannel.Request(action: verb, target: target, arguments: invocation.arguments)
        switch verb {
        case "info", "relaunch", "list":
            break
        case "open", "run":
            guard target != nil else {
                return failure(CLIError.usage("loam app \(verb) needs \(verb == "open" ? "a note's path" : "a command id")"), exitCode: 2)
            }
        case "switch":
            guard let target else { return failure(CLIError.usage("loam app switch needs a vault folder"), exitCode: 2) }
            let folder = URL(fileURLWithPath: (target as NSString).expandingTildeInPath).standardizedFileURL
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                return failure(CLIError.usage("vault folder not found: \(folder.path)"), exitCode: 2)
            }
            request.target = folder.path
        case "shot":
            let path = target ?? FileManager.default.temporaryDirectory.appendingPathComponent("loam-shot.png").path
            request.target = URL(fileURLWithPath: path).standardizedFileURL.path
        default:
            return failure(CLIError.usage("loam app takes info, list, open, run, shot, switch or relaunch"), exitCode: 2)
        }
        do {
            let response = try AppChannel.send(request, vault: vault, timeout: verb == "run" ? 600 : 30)
            guard response.ok else { return failure(CLIError.usage(response.error ?? "The app refused."), exitCode: 1) }
            let output = response.output
            return CLIResult(exitCode: 0, stdout: output.hasSuffix("\n") || output.isEmpty ? output : output + "\n", stderr: "")
        } catch {
            return failure(error, exitCode: 1)
        }
    }

    /// Plugins the config enables that could not start, as a warning for stderr; empty when all started.
    /// The command still runs: a broken plugin must not lock the user out of the others.
    public static func activationWarnings(_ report: ActivationReport) -> String {
        let problems = report.failed.merging(report.skipped) { failed, _ in failed }
        guard !problems.isEmpty else { return "" }
        return problems.keys.sorted()
            .map { "warning: plugin \($0) did not start: \(problems[$0]!)\n" }
            .joined()
    }

    /// The same result with its JSON on one line: what an agent reads, a third fewer tokens than the pretty form a
    /// person reads in a terminal. Text output is left as it is.
    public static func compacted(_ result: CLIResult) -> CLIResult {
        CLIResult(exitCode: result.exitCode, stdout: compactJSON(result.stdout), stderr: compactJSON(result.stderr))
    }

    static func compactJSON(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("{") || trimmed.hasPrefix("["),
              let value = try? JSONSerialization.jsonObject(with: Data(trimmed.utf8), options: [.fragmentsAllowed]),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes])
        else { return text }
        return String(decoding: data, as: UTF8.self) + "\n"
    }

    public static func failure(_ error: Error, exitCode: Int32) -> CLIResult {
        let message = (try? JSON.string(["error": describe(error)])) ?? "{\"error\": \"unknown\"}"
        return CLIResult(exitCode: exitCode, stdout: "", stderr: message + "\n")
    }

    private struct ListEntry: Encodable {
        let id: String
        let title: String
        let summary: String
    }

    private static func finish(_ body: () throws -> String) -> CLIResult {
        do {
            return CLIResult(exitCode: 0, stdout: try body() + "\n", stderr: "")
        } catch {
            return failure(error, exitCode: 1)
        }
    }

    private static func describe(_ error: Error) -> String {
        switch error {
        case CLIError.usage(let message): return message
        case CLIError.unknownCommand(let name): return "unknown command \"\(name)\"; run `loam list`"
        case CommandError.missingArgument(let name): return "missing argument \"\(name)\""
        case CommandError.duplicate(let id): return "duplicate command \"\(id)\""
        case VaultError.notFound(let path): return "not found: \(path)"
        case VaultError.alreadyExists(let path): return "already exists: \(path)"
        case VaultError.outsideVault(let path): return "path outside the vault: \(path)"
        case let error as LocalizedError where error.errorDescription != nil: return error.errorDescription!
        default: return "\(error)"
        }
    }
}
