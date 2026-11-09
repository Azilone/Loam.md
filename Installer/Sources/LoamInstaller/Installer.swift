import AppKit
import Foundation

/// Where the wizard puts Loam.
enum InstallDestination: String, CaseIterable, Identifiable, Sendable {
    case applications
    case userApplications

    var id: String { rawValue }

    var title: String {
        switch self {
        case .applications: return "/Applications"
        case .userApplications: return "~/Applications"
        }
    }

    var detail: String {
        switch self {
        case .applications: return "For every user of this Mac."
        case .userApplications: return "For this user only."
        }
    }

    /// The folder Loam.app is copied into.
    var folder: URL {
        switch self {
        case .applications:
            return URL(fileURLWithPath: "/Applications", isDirectory: true)
        case .userApplications:
            return URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent("Applications", isDirectory: true)
        }
    }
}

/// What the wizard does, and what can go wrong.
enum InstallerError: Error, LocalizedError {
    case unsupported(String)
    case missingPayload
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .unsupported(let reason): return reason
        case .missingPayload: return "This installer does not carry Loam.app."
        case .failed(let reason): return reason
        }
    }
}

/// What the wizard does to the Mac: it copies the app, links the command line and opens the vault.
///
/// The work happens off the main thread, so nothing here is main-actor isolated.
enum Installer {
    static let appName = "Loam.app"
    static let commandName = "loam"

    /// The Loam.app this installer carries: `Contents/Resources/Payload/Loam.app`.
    static var payload: URL? {
        guard let resources = Bundle.main.resourceURL else { return nil }
        return resources
            .appendingPathComponent("Payload", isDirectory: true)
            .appendingPathComponent(appName, isDirectory: true)
    }

    /// What this Mac must have, checked before anything is written.
    static func requirementProblem() -> String? {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        guard version.majorVersion >= 26 else {
            return "Loam needs macOS 26 or later. This Mac runs macOS \(version.majorVersion)."
        }
        #if !arch(arm64)
        return "Loam needs a Mac with Apple silicon."
        #endif
        return nil
    }

    /// The folder the install script picks: `/Applications` when it is writable, else `~/Applications`.
    static func preferredDestination() -> InstallDestination {
        FileManager.default.isWritableFile(atPath: "/Applications") ? .applications : .userApplications
    }

    /// Copies Loam.app to the destination.
    static func installApp(to destination: InstallDestination) throws {
        guard let payload, FileManager.default.fileExists(atPath: payload.path) else {
            throw InstallerError.missingPayload
        }
        try FileManager.default.createDirectory(at: destination.folder, withIntermediateDirectories: true)
        let target = destination.folder.appendingPathComponent(appName, isDirectory: true)
        // The copy lands beside the old app and only then replaces it: a failure never leaves a half-written Loam.app.
        let staging = destination.folder.appendingPathComponent(".Loam.app.incoming", isDirectory: true)
        try? FileManager.default.removeItem(at: staging)
        try FileManager.default.copyItem(at: payload, to: staging)
        try? FileManager.default.removeItem(at: target)
        try FileManager.default.moveItem(at: staging, to: target)
        // The app comes from a download: without this, Gatekeeper refuses Loam's own first launch.
        clearQuarantine(at: target)
    }

    /// Links the command line into `~/.local/bin`, the folder the install script uses.
    @discardableResult
    static func linkCommandLine(to app: URL) throws -> URL {
        let bin = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".local/bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let link = bin.appendingPathComponent(commandName)
        let helper = app
            .appendingPathComponent("Contents/Helpers", isDirectory: true)
            .appendingPathComponent(commandName)
        try? FileManager.default.removeItem(at: link)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: helper)
        return link
    }

    /// Creates the folder a first vault lives in. Loam fills it when it opens.
    static func createVault(at url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    /// Opens Loam, on the vault when there is one.
    static func launch(app: URL, vault: URL?) throws {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        if let vault { configuration.arguments = ["--vault", vault.path] }
        _ = try NSWorkspace.shared.openApplication(at: app, configuration: configuration)
    }

    /// Asks a running Loam to quit before its bundle is replaced, the way the install script does.
    static func quitRunningApp() {
        guard isRunning() else { return }
        // The app closes its vault on its own when it is asked to quit.
        let script = Process()
        script.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        script.arguments = ["-e", "tell application \"Loam\" to quit"]
        script.standardOutput = FileHandle.nullDevice
        script.standardError = FileHandle.nullDevice
        if (try? script.run()) != nil { script.waitUntilExit() }
        // Ten seconds to close on its own; then it is asked the hard way.
        for _ in 0..<50 {
            if !isRunning() { return }
            Thread.sleep(forTimeInterval: 0.2)
        }
        run("/usr/bin/pkill", ["-x", "Loam"])
    }

    /// Whether a Loam is running.
    static func isRunning() -> Bool {
        run("/usr/bin/pgrep", ["-x", "Loam"]) == 0
    }

    /// Removes the quarantine flag a downloaded file carries, so Gatekeeper lets Loam run.
    static func clearQuarantine(at url: URL) {
        run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", url.path])
    }

    /// Runs a tool quietly and waits for it. Used for the system tools the wizard needs.
    @discardableResult
    static func run(_ tool: String, _ arguments: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return -1 }
        process.waitUntilExit()
        return process.terminationStatus
    }
}
