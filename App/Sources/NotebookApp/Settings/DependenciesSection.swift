import AppKit
import AVFoundation
import SwiftUI

/// A program the plugins run, as `tools.list` reports it: where it is, and which plugins need or use it.
struct ToolStatusRow: Decodable, Identifiable, Equatable, Sendable {
    let name: String
    /// The Homebrew formula that installs it; nil when it comes with the developer tools.
    let formula: String?
    /// Where it is, nil when it is not installed.
    let path: String?
    let requiredBy: [String]
    let optionalFor: [String]

    var id: String { name }
    var isInstalled: Bool { path != nil }
}

/// What macOS says about a permission Loam's features ask for.
enum PermissionState: Equatable {
    case granted, denied, notAsked, notUsed
    /// macOS does not say (system audio): only a recording shows it.
    case unknown

    var text: String {
        switch self {
        case .granted: String(localized: "Allowed")
        case .denied: String(localized: "Not allowed: turn it on in System Settings")
        case .notAsked: String(localized: "Asked the first time a feature needs it")
        case .notUsed: String(localized: "Not used: there is no Voice Memos folder on this Mac")
        case .unknown: String(localized: "macOS does not say: a sound test shows whether it records")
        }
    }

    /// Whether the user has to act in System Settings.
    var needsSettings: Bool { self == .denied || self == .unknown }
}

/// The macOS permissions the features use. Loam reads each one where macOS lets it; the rest is shown, not guessed.
enum SystemPermission: CaseIterable {
    case microphone, systemAudio, fullDisk

    var title: String {
        switch self {
        case .microphone: String(localized: "Microphone")
        case .systemAudio: String(localized: "System audio")
        case .fullDisk: String(localized: "Full Disk Access")
        }
    }

    /// The pane of System Settings > Privacy & Security that grants it.
    var settingsURL: URL {
        let pane: String
        switch self {
        case .microphone: pane = "Privacy_Microphone"
        case .systemAudio: pane = "Privacy_ScreenCapture"
        case .fullDisk: pane = "Privacy_AllFiles"
        }
        return URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")!
    }

    /// The folder Voice Memos syncs from the iPhone into, as `MeetingsSettings` names it: readable only with Full Disk
    /// Access.
    static var voiceMemosFolder: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Group Containers/group.com.apple.VoiceMemos.shared/Recordings")
    }

    func state() -> PermissionState {
        switch self {
        case .microphone:
            switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .authorized: return .granted
            case .notDetermined: return .notAsked
            default: return .denied
            }
        case .systemAudio:
            return .unknown
        case .fullDisk:
            let folder = Self.voiceMemosFolder.path
            guard FileManager.default.fileExists(atPath: folder) else { return .notUsed }
            return (try? FileManager.default.contentsOfDirectory(atPath: folder)) == nil ? .denied : .granted
        }
    }
}

/// Settings > Plugins, first: the programs the plugins run and the permissions the features need. What is missing has
/// one Install; Loam looks again by itself when it comes back to the front, and starts the plugins that waited.
struct DependenciesSection: View {
    @Bindable var model: PluginManagerModel
    @State private var permissions: [SystemPermission: PermissionState] = [:]

    private var setup: ToolSetup { model.toolSetup }

    var body: some View {
        SettingsSection(
            title: String(localized: "Dependencies"),
            subtitle: String(localized: "What the features need on this Mac. Loam installs what is missing and turns the features on by itself.")
        ) {
            let missing = setup.missing
            if missing.isEmpty {
                SettingsRow(title: String(localized: "Everything is installed"), detail: nil)
            } else {
                SettingsRow(
                    title: String(localized: "Missing: \(missing.map(\.name).joined(separator: ", "))"),
                    detail: phaseText
                ) {
                    if setup.phase == .idle {
                        SettingsAction(title: String(localized: "Install")) { Task { await setup.install() } }
                    } else {
                        ProgressView().controlSize(.small)
                    }
                }
            }
            // Only what is missing and used: an installed program needs no row.
            ForEach(missing) { tool in
                SettingsRow(title: tool.name, detail: detail(of: tool), detailColor: tool.isInstalled ? nil : .orange)
            }
            ForEach(SystemPermission.allCases, id: \.self) { permission in
                let state = permissions[permission] ?? .unknown
                // Full Disk Access only serves the Voice Memos import, which is off unless asked: no warning colour.
                let optional = permission == .fullDisk && state == .denied
                SettingsRow(
                    title: permission.title,
                    detail: optional ? String(localized: "Only to import Voice Memos from the iPhone: not allowed yet") : state.text,
                    detailColor: state == .denied && !optional ? .orange : nil
                ) {
                    if state.needsSettings {
                        SettingsAction(title: String(localized: "Open Settings")) { NSWorkspace.shared.open(permission.settingsURL) }
                    }
                }
            }
        }
        .task {
            reloadPermissions()
            await setup.check()
        }
        // Back from System Settings or the Terminal: what changed shows without a click.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            reloadPermissions()
        }
    }

    private var phaseText: String {
        switch setup.phase {
        case .idle: setup.nextStepText
        case .installing(let names):
            String(localized: "Installing \(names.joined(separator: ", "))… About 2 minutes.")
        case .waitingForDeveloperTools:
            String(localized: "Waiting for Apple’s installer. Loam continues on its own.")
        case .waitingForHomebrew:
            String(localized: "Waiting for the Terminal. Loam continues on its own.")
        }
    }

    private func detail(of tool: ToolStatusRow) -> String {
        if let path = tool.path { return path }
        if !tool.requiredBy.isEmpty {
            let names = tool.requiredBy.map { model.name(of: $0) }.joined(separator: ", ")
            return String(localized: "Missing. Needed by \(names)")
        }
        let names = tool.optionalFor.map { model.name(of: $0) }.joined(separator: ", ")
        return names.isEmpty ? String(localized: "Missing") : String(localized: "Missing. Used by \(names) when installed")
    }

    private func reloadPermissions() {
        for permission in SystemPermission.allCases {
            permissions[permission] = permission.state()
        }
    }
}
