import AppKit

/// The panes of System Settings › Privacy & Security the recorder needs, and the sheet that takes the user there when
/// macOS said no: one click to the right switch instead of a path to follow.
enum PrivacyPane: String {
    case microphone = "Privacy_Microphone"
    case systemAudio = "Privacy_ScreenCapture"
    case fullDisk = "Privacy_AllFiles"

    var url: URL { URL(string: "x-apple.systempreferences:com.apple.preference.security?\(rawValue)")! }

    private func texts() -> (title: String, detail: String) {
        switch self {
        case .microphone:
            ("Loam can’t use the microphone", "Turn on Loam in Privacy & Security › Microphone, then record again.")
        case .systemAudio:
            ("Loam can’t record the Mac’s sound",
             "The recording goes on with your microphone only. To have the other participants in the transcript, turn on Loam in Privacy & Security › Screen & System Audio Recording.")
        case .fullDisk:
            ("Loam can’t read your Voice Memos", "Turn on Loam in Privacy & Security › Full Disk Access. Loam picks them up by itself afterwards.")
        }
    }

    /// A sheet on the front window that says what macOS refused, with a button to the pane.
    @MainActor
    func ask() {
        let (title, detail) = texts()
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Not Now").keyEquivalent = "\u{1b}"
        let url = url
        let handle: (NSApplication.ModalResponse) -> Void = { response in
            if response == .alertFirstButtonReturn { NSWorkspace.shared.open(url) }
        }
        if let window = NSApp.keyWindow ?? NSApp.mainWindow, window.attachedSheet == nil {
            alert.beginSheetModal(for: window, completionHandler: handle)
        } else {
            handle(alert.runModal())
        }
    }
}
