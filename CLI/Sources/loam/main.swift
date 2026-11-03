import BuiltinPlugins
import Foundation
import GitSyncPlugin
import PluginKit
import LoamCLI
import LoamCore

// `loam crypt …` is run by git for an encrypted vault (git sync), once per git command: it loads no vault.
if CommandLine.arguments.dropFirst().first == "crypt" {
    exit(GitCrypt.main(Array(CommandLine.arguments.dropFirst(2))))
}

func finish(_ result: CLIResult) -> Never {
    // Piped (an agent, a script): JSON on one line. In a terminal: the pretty form.
    let result = isatty(STDOUT_FILENO) == 0 ? CLI.compacted(result) : result
    FileHandle.standardOutput.write(Data(result.stdout.utf8))
    FileHandle.standardError.write(Data(result.stderr.utf8))
    exit(result.exitCode)
}

let invocation: Invocation
do {
    invocation = try CLI.parse(Array(CommandLine.arguments.dropFirst()))
} catch {
    finish(CLI.failure(error, exitCode: 2))
}

// The guide and the agent skill need no vault.
if let local = CLI.executeLocal(invocation) { finish(local) }

// `loam app …` talks to the open app: the vault given, the one around the current folder, else the app's last one.
// `switch` skips the current folder, which is often the vault it names, not open yet.
if invocation.command == "app", !invocation.wantsHelp {
    let switching = invocation.operands.first == "switch"
    let given = invocation.vault ?? ProcessInfo.processInfo.environment["LOAM_VAULT"]
    var vault = given.map { URL(fileURLWithPath: $0) } ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    if given == nil {
        var folder = switching ? URL(fileURLWithPath: "/") : vault
        while folder.path != "/", !FileManager.default.fileExists(atPath: folder.appendingPathComponent(".loam").path) {
            folder.deleteLastPathComponent()
        }
        if folder.path != "/" {
            vault = folder
        } else if let last = try? String(contentsOfFile: AppChannel.lastVaultFile, encoding: .utf8) {
            vault = URL(fileURLWithPath: last.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }
    finish(CLI.executeApp(invocation, vault: vault))
}

let vaultPath = invocation.vault ?? ProcessInfo.processInfo.environment["LOAM_VAULT"] ?? FileManager.default.currentDirectoryPath
var isDirectory: ObjCBool = false
guard FileManager.default.fileExists(atPath: vaultPath, isDirectory: &isDirectory), isDirectory.boolValue else {
    finish(CLI.failure(CLIError.usage("vault folder not found: \(vaultPath)"), exitCode: 2))
}

// The runtime reads `.loam/config.json`, so disabled plugins and their commands stay off here too. The vault's own
// plugins (`.loam/plugins/`) load when the config enables them, as in the app.
let runtime: Runtime
do {
    runtime = try Runtime(rootURL: URL(fileURLWithPath: vaultPath), plugins: builtinPlugins, thirdPartyPlugins: true)
} catch {
    finish(CLI.failure(error, exitCode: 1))
}
FileHandle.standardError.write(Data(CLI.activationWarnings(runtime.lastReport).utf8))

finish(await CLI.execute(invocation, kernel: runtime.kernel))
