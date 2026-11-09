import Foundation
import SwiftUI

/// The native macOS installer wizard: it copies Loam.app into place, links the `loam` command line and opens the
/// app. What the install script does, natively, with a window the user can read.
///
/// `--version` prints the version and leaves, so the build workflow can check the bundle it made.
if CommandLine.arguments.contains("--version") {
    let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    print("Loam Installer \(version)")
    exit(0)
}

struct LoamInstallerApp: App {
    @State private var wizard: WizardModel = {
        WizardModel()
    }()

    var body: some Scene {
        Window("Install Loam", id: "installer") {
            WizardView()
                .environment(wizard)
        }
        .windowResizability(.contentSize)
    }
}

LoamInstallerApp.main()
