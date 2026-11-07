#if DEBUG || LOAM_AGENT_BRIDGE
import AppKit
import DebugProtocol
import Foundation

/// The agent debug channel of one instance: a Unix socket the instance listens on (`DebugInstance.socketPath`),
/// speaking `DebugProtocol`'s JSON lines. Started when the first vault opens, only for a process launched with
/// `LOAM_INSTANCE`/`--instance`, only in a debug build.
@MainActor
enum DebugBridge {
    private static var server: DebugSocketServer?
    private static var driver: DebugDriver?
    private static var terminationObserver: Any?

    static func startIfAsked(settings: SettingsNavigation, session: @escaping @MainActor () -> ShellSession?) {
        guard server == nil, let instance = AgentInstance.current else { return }
        let driver = DebugDriver(instance: instance, settings: settings, session: session)
        let server = DebugSocketServer(path: instance.socketPath) { request in
            await Task { @MainActor in await driver.handle(request) }.value
        }
        do {
            try server.start()
        } catch {
            FileHandle.standardError.write(Data("loam debug channel: \(error)\n".utf8))
            return
        }
        Self.server = server
        Self.driver = driver
        driver.writeState()
        DebugAccessibility.enableTree()
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { stop() }
        }
    }

    static func stop() {
        server?.stop()
        server = nil
        try? FileManager.default.removeItem(atPath: driver?.instance.statePath ?? "")
        driver = nil
    }
}
#endif
