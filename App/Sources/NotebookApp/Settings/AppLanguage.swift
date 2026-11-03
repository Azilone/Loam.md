import AppKit
import Foundation

/// The language of the app's interface, chosen in Settings > Appearance. macOS reads `AppleLanguages` from the app's
/// own preferences when the app starts, so a choice applies on the next launch; none follows the system's languages.
enum AppLanguage {
    static let key = "AppleLanguages"

    /// The languages Loam is translated into (`App/Resources/*.lproj`, and `CFBundleLocalizations` in the bundle).
    static let codes = ["ar", "de", "en", "es", "fr", "hi", "it", "ja", "ko", "nl", "zh-Hans"]

    /// The language chosen in Settings, nil to follow the system.
    static func chosen(in defaults: UserDefaults = .standard, domain: String? = Bundle.main.bundleIdentifier) -> String? {
        guard let domain, let languages = defaults.persistentDomain(forName: domain)?[key] as? [String] else { return nil }
        return languages.first.flatMap { codes.contains($0) ? $0 : nil }
    }

    /// Writes the choice to the app's preferences (nil: the system's languages), for the next launch.
    static func choose(_ code: String?, in defaults: UserDefaults = .standard) {
        if let code {
            defaults.set([code], forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }

    /// The language the interface is in now.
    static var current: String? { Bundle.main.preferredLocalizations.first }

    /// A language's name in that language ("Français", "日本語"), as macOS lists them.
    static func name(of code: String) -> String {
        let locale = Locale(identifier: code)
        return locale.localizedString(forIdentifier: code)?.capitalized(with: locale) ?? code
    }

    /// Quits and opens the app again, so a new language applies.
    @MainActor
    static func relaunch() {
        let url = Bundle.main.bundleURL
        // The new instance waits for this one to quit, so the vault is never open twice.
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "while kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do sleep 0.1; done; open \"$0\"", url.path]
        try? task.run()
        NSApp.terminate(nil)
    }
}
