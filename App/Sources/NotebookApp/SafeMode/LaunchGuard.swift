import Foundation

/// Decides when a vault opens in safe mode: when Option is held at launch, or when the last two launches on that
/// vault never reached `didLaunchSuccessfully` (they crashed or hung while starting).
///
/// Every launch counts as pending until it is confirmed. The counters live in `UserDefaults`, per vault path, so a
/// vault that crashes the app does not put the other vaults in safe mode.
public struct LaunchGuard {
    /// Unconfirmed launches in a row that put the next launch in safe mode.
    public static let failureThreshold = 2

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Records a launch on `vault` and returns true when it must start in safe mode.
    public mutating func willLaunch(vault: String, optionHeld: Bool) -> Bool {
        let pending = pendingLaunches(vault: vault)
        defaults.set(pending + 1, forKey: Self.key(vault))
        return optionHeld || pending >= Self.failureThreshold
    }

    /// The launch on `vault` got far enough (the window has been up for a few seconds): forgets the pending ones.
    public mutating func didLaunchSuccessfully(vault: String) {
        defaults.removeObject(forKey: Self.key(vault))
    }

    /// Launches on `vault` that were recorded and never confirmed.
    public func pendingLaunches(vault: String) -> Int {
        defaults.integer(forKey: Self.key(vault))
    }

    static func key(_ vault: String) -> String {
        "launchGuard.pending.\(vault)"
    }
}
