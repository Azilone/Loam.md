import Foundation
import Observation

/// Anonymous usage statistics, sent to Loam's own Umami server (no third party, no cookie, no identifier).
///
/// One event, `app_launch`, a couple of minutes after the app starts: Loam's version and build, the macOS version and
/// the system language. Never a note, a file name, a vault path or anything that identifies the user. The server
/// derives a country from the request's IP address and does not store the address.
///
/// On by default, and off with Settings > About > Send anonymous analytics. Like the updates, only a release build
/// reports (`LoamAnalyticsURL` and `LoamAnalyticsWebsiteID` in Info.plist, written by scripts/build-app.sh): a
/// development build or a test run sends nothing.
@MainActor
@Observable
public final class AppAnalytics {
    public var isEnabled: Bool {
        didSet { defaults.set(isEnabled, forKey: Self.enabledKey) }
    }

    @ObservationIgnored private let bundle: Bundle
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let delay: Duration
    @ObservationIgnored private let transport: @Sendable (URLRequest) async -> Void
    @ObservationIgnored private var launchReported = false

    static let enabledKey = "sendAnonymousAnalytics"
    /// What the server shows as the site's hostname: one label for the whole app.
    static let hostname = "app.loam.md"
    /// The wait before the launch report, long enough to turn analytics off first (the first launch plays an intro).
    public static let launchDelay: Duration = .seconds(120)

    public init(
        bundle: Bundle = .main,
        defaults: UserDefaults = .standard,
        delay: Duration = AppAnalytics.launchDelay,
        transport: @escaping @Sendable (URLRequest) async -> Void = { _ = try? await URLSession.shared.data(for: $0) }
    ) {
        self.bundle = bundle
        self.defaults = defaults
        self.delay = delay
        self.transport = transport
        isEnabled = defaults.object(forKey: Self.enabledKey) as? Bool ?? true
    }

    /// Where the events go, nil in a development build.
    var endpoint: URL? {
        (bundle.infoDictionary?["LoamAnalyticsURL"] as? String).flatMap(URL.init(string:))
    }

    var websiteID: String? { bundle.infoDictionary?["LoamAnalyticsWebsiteID"] as? String }

    /// Whether this build reports at all, whatever the setting says.
    public var isAvailable: Bool {
        endpoint != nil && websiteID != nil && bundle.bundleURL.pathExtension == "app"
    }

    /// Reports the launch once per run, after `delay`, if analytics are still on then.
    public func reportLaunch() {
        guard isAvailable, !launchReported else { return }
        launchReported = true
        Task { @MainActor [weak self, delay] in
            try? await Task.sleep(for: delay)
            guard let self, self.isEnabled, let request = self.launchRequest() else { return }
            await self.transport(request)
        }
    }

    /// The `app_launch` event as Umami's collect endpoint takes it.
    func launchRequest(locale: Locale = .current) -> URLRequest? {
        guard let endpoint, let websiteID else { return nil }
        let info = bundle.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "dev"
        let build = info["CFBundleVersion"] as? String ?? ""
        let system = ProcessInfo.processInfo.operatingSystemVersion
        let body = Event(payload: .init(
            website: websiteID,
            hostname: Self.hostname,
            language: Locale.preferredLanguages.first ?? locale.identifier,
            url: "/launch",
            title: "Loam",
            name: "app_launch",
            data: ["version": version, "build": build, "macos": "\(system.majorVersion).\(system.minorVersion)"]
        ))
        var request = URLRequest(url: endpoint, timeoutInterval: 15)
        request.httpMethod = "POST"
        request.httpBody = try? JSONEncoder().encode(body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // The server drops what looks like a bot: a browser-shaped agent with Loam's version passes.
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Loam/\(version)",
            forHTTPHeaderField: "User-Agent"
        )
        return request
    }

    struct Event: Encodable {
        var type = "event"
        var payload: Payload

        struct Payload: Encodable {
            var website: String
            var hostname: String
            var language: String
            var url: String
            var title: String
            var name: String
            var data: [String: String]
        }
    }
}
