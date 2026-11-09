import Foundation
import Observation

/// The wizard's state: where Loam goes, what it does, and what went wrong.
@MainActor
@Observable
final class WizardModel {
    /// The steps the wizard walks through.
    enum Step: Int, CaseIterable {
        case welcome
        case destination
        case vault
        case installing
        case done

        var title: String {
            switch self {
            case .welcome: return "Welcome"
            case .destination: return "Where to install"
            case .vault: return "Your vault"
            case .installing: return "Installing"
            case .done: return "Ready"
            }
        }
    }

    var step: Step = .welcome
    var destination: InstallDestination = Installer.preferredDestination()
    var linkCommandLine = true
    var createVault = true
    var vaultPath: String = WizardModel.defaultVaultPath()
    var problem: String?
    var detail = ""
    var isWorking = false

    /// What this Mac must have. A wizard that cannot install says so before anything else.
    var requirementProblem: String? { Installer.requirementProblem() }

    /// The app the wizard installs.
    var installedApp: URL {
        destination.folder.appendingPathComponent(Installer.appName, isDirectory: true)
    }

    /// The vault the wizard creates, when it creates one.
    var vaultURL: URL {
        URL(fileURLWithPath: (vaultPath as NSString).expandingTildeInPath)
    }

    /// The vault folder the wizard offers: Documents, where a Mac keeps what the user made.
    static func defaultVaultPath() -> String {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Documents", isDirectory: true)
            .appendingPathComponent("Loam Vault", isDirectory: true)
            .path
    }

    /// One step back, when there is one.
    func goBack() {
        switch step {
        case .destination: step = .welcome
        case .vault: step = .destination
        default: break
        }
    }

    /// Runs the installation. Everything that touches the disk happens off the main thread.
    func install() async {
        isWorking = true
        problem = nil
        step = .installing
        let destination = self.destination
        let linkCommandLine = self.linkCommandLine
        let createVault = self.createVault
        let vaultURL = self.vaultURL
        do {
            try await Task.detached(priority: .userInitiated) {
                Installer.quitRunningApp()
                try Installer.installApp(to: destination)
                if linkCommandLine {
                    _ = try Installer.linkCommandLine(
                        to: destination.folder.appendingPathComponent(Installer.appName, isDirectory: true)
                    )
                }
                if createVault {
                    try Installer.createVault(at: vaultURL)
                }
            }.value
            detail = summary()
            step = .done
        } catch {
            problem = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            step = .installing
        }
        isWorking = false
    }

    /// Opens Loam, on the vault when the wizard made one.
    func launch() {
        do {
            try Installer.launch(app: installedApp, vault: createVault ? vaultURL : nil)
        } catch {
            problem = error.localizedDescription
        }
    }

    /// What the wizard did, in one line.
    private func summary() -> String {
        var lines = ["Loam is in \(installedApp.path)."]
        if linkCommandLine {
            lines.append("The command line is ~/.local/bin/\(Installer.commandName).")
        }
        if createVault {
            lines.append("Your vault is \(vaultURL.path).")
        }
        return lines.joined(separator: "\n")
    }
}
