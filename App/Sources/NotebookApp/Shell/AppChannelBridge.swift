import AppKit
import Foundation
import LoamCLI
import PluginKit
import PluginKitUI

/// The open vault's `loam app` channel (`AppChannel`): what lets an outside agent see and steer the window it works
/// for. It opens a note, runs a command in the app (UI commands included), takes a picture of the window, switches to
/// another vault (a migration's new one) and relaunches the app to load rebuilt plugins. Nothing that types, clicks or reads what the user did not ask about.
@MainActor
enum AppChannelBridge {
    private static var server: AppChannelServer?

    static func start(_ model: AppModel) {
        stop()
        guard let session = model.session else { return }
        let vault = session.rootURL
        let server = AppChannelServer(vault: vault) { [weak model] request in
            await Task { @MainActor in await handle(request, model: model) }.value
        }
        do {
            try server.start()
            // An agent's test instance (`LOAM_INSTANCE`) is not the user's app: `loam app` without a vault keeps
            // going to theirs.
            if ProcessInfo.processInfo.environment["LOAM_INSTANCE"] == nil, !CommandLine.arguments.contains("--instance") {
                try? vault.standardizedFileURL.path.write(toFile: AppChannel.lastVaultFile, atomically: true, encoding: .utf8)
            }
            Self.server = server
        } catch {
            FileHandle.standardError.write(Data("loam app channel: \(error)\n".utf8))
        }
    }

    static func stop() {
        server?.stop()
        server = nil
    }

    private static func handle(_ request: AppChannel.Request, model: AppModel?) async -> AppChannel.Response {
        guard let model, let session = model.session else { return .failure("No vault is open.") }
        switch request.action {
        case "info":
            let info = Info(
                vault: session.rootURL.path,
                note: session.workspace.activeResource.map { $0.kind == .file ? $0.path : $0.name },
                plugins: session.runtime.host.manifests.map(\.id).sorted(),
                safeMode: session.isSafeMode
            )
            return respond { try JSON.string(info) }
        case "list":
            // The window's commands: the plugins' (UI ones included) and the shell's own.
            let commands = session.runtime.kernel.commands.all.map { Listed(id: $0.id, title: $0.title, summary: $0.summary) }
            return respond { try JSON.string(commands) }
        case "open":
            guard let path = request.target, session.runtime.kernel.vault.exists(path) else {
                return .failure("No such note: \(request.target ?? "")")
            }
            session.workspace.open(.file(path), placement: .replace)
            NSApp.activate()
            return AppChannel.Response(ok: true, output: "Opened \(path).")
        case "run":
            guard let id = request.target else { return .failure("Which command?") }
            do {
                return AppChannel.Response(ok: true, output: try await session.run(id, request.arguments))
            } catch ShellError.unknownCommand(let id) {
                return .failure("Unknown command \(id); `loam app run` takes the ids of `loam list`.")
            } catch {
                return .failure(String(describing: error))
            }
        case "shot":
            guard let path = request.target else { return .failure("Where to write the picture?") }
            guard let window = NSApplication.shared.windows.first(where: { AppModel.isNotebookWindow($0) && $0.contentView != nil })
            else { return .failure("The window is not up.") }
            try? FileManager.default.createDirectory(
                at: URL(fileURLWithPath: path).deletingLastPathComponent(), withIntermediateDirectories: true
            )
            // What the agent just did (open a note, toggle a panel) is still animating: let it settle.
            try? await Task.sleep(for: .milliseconds(700))
            ScriptDriver.snapshot(window, to: path)
            guard FileManager.default.fileExists(atPath: path) else { return .failure("Cannot draw the window.") }
            return AppChannel.Response(ok: true, output: path)
        case "switch":
            guard let path = request.target else { return .failure("Which vault?") }
            let url = URL(fileURLWithPath: path, isDirectory: true)
            // Answer first: opening replaces the session, and this channel with it.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                model.openVault(url)
                NSApp.activate()
            }
            return AppChannel.Response(ok: true, output: "Opening \(url.path).")
        case "relaunch":
            guard model.canRelaunch else { return .failure("This build cannot relaunch itself; quit and open it again.") }
            // Answer first: the process is about to go.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { model.relaunch() }
            return AppChannel.Response(ok: true, output: "Relaunching on \(session.rootURL.path).")
        default:
            return .failure("Unknown action \(request.action).")
        }
    }

    private struct Listed: Encodable {
        let id: String
        let title: String
        let summary: String
    }

    private struct Info: Encodable {
        let vault: String
        let note: String?
        let plugins: [String]
        let safeMode: Bool
    }

    private static func respond(_ body: () throws -> String) -> AppChannel.Response {
        do {
            return AppChannel.Response(ok: true, output: try body())
        } catch {
            return .failure(String(describing: error))
        }
    }
}
