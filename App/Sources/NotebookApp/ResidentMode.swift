import Foundation
import ServiceManagement

/// Loam keeps running when its window is closed, so what works from anywhere (quick capture's shortcut, git sync)
/// keeps working; Quit really quits. Per Mac, in the app's preferences: it is about this machine, not the vault.
public enum ResidentMode {
    static let key = "keepRunningWithoutWindow"

    /// On by default.
    public static var keepsRunning: Bool {
        get { UserDefaults.standard.object(forKey: key) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }

    /// Whether Loam opens when the user logs in (a login item of the system's).
    public static var opensAtLogin: Bool {
        SMAppService.mainApp.status == .enabled
    }

    public static func setOpensAtLogin(_ on: Bool) throws {
        if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
    }
}
