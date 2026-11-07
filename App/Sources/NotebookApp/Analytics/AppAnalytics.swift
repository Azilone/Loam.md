import Foundation
import Observation

/// Anonymous usage statistics, sent to Loam's own Umami server (no third party, no cookie, no identifier).
///
/// What leaves the Mac is a short list of named events (`allowedEvents`), each with plain properties: Loam's version,
/// the macOS version, a count in a range ("50-199 notes"), the id of a built-in plugin or command. Never a note, a
/// file name, a vault path, a name the user typed or anything that identifies them: `sanitized` drops every property
/// that is not a plain identifier or number. There is no install ID, so two events of one person cannot be tied
/// together except by the server's own daily session (a hash of the address and the agent that is not stored). The
/// server derives a country from the request's IP address and does not store the address.
///
/// On by default, and off with Settings > About > Send anonymous analytics. Nothing leaves in the first
/// `launchDelay` of a run (the first launch plays an intro, where the user can turn it off): what happens meanwhile
/// waits, and is dropped when the user turned analytics off in the meantime. Like the updates, only a release build
/// reports (`LoamAnalyticsURL` and `LoamAnalyticsWebsiteID` in Info.plist, written by scripts/build-app.sh): a
/// development build or a test run sends nothing.
@MainActor
@Observable
public final class AppAnalytics {
    public var isEnabled: Bool {
        didSet { defaults.set(isEnabled, forKey: Self.enabledKey) }
    }

    /// The facts about the app and the open vault that `app_launch` carries, read when it is sent.
    @ObservationIgnored public var context: (@MainActor () async -> [String: String])?

    @ObservationIgnored private let bundle: Bundle
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let delay: Duration
    @ObservationIgnored private let transport: @Sendable (URLRequest) async -> Void
    @ObservationIgnored private var launchReported = false
    /// True once `delay` has passed: from then on events go out at once (when enabled), before they wait.
    @ObservationIgnored private var armed = false
    @ObservationIgnored private var pending: [Queued] = []
    /// What `track(once:)` already counted in this run.
    @ObservationIgnored private var counted: Set<String> = []
    @ObservationIgnored private let startedAt = ContinuousClock.now

    static let enabledKey = "sendAnonymousAnalytics"
    /// The version the last run reported, to say what the app was updated from.
    static let lastVersionKey = "analyticsLastVersion"
    /// What the server shows as the site's hostname: one label for the whole app.
    static let hostname = "app.loam.md"
    /// The wait before the first report, long enough to turn analytics off first (the first launch plays an intro).
    public static let launchDelay: Duration = .seconds(120)
    /// Events kept while waiting for `launchDelay`.
    static let queueLimit = 200

    /// The events that may leave. Anything else, from the app or from a plugin, is dropped.
    static let allowedEvents: Set<String> = [
        "app_launch", "session_end",
        "command_used", "plugin_toggled", "theme_changed",
        "onboarding_step", "onboarding_finished",
        "import_finished",
        "update_ready", "update_failed",
        "safe_mode_entered",
    ]

    private struct Queued {
        let name: String
        let data: [String: String]
    }

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

    // MARK: Events

    /// Reports the launch once per run, after `delay`, if analytics are still on then; the events of that wait follow.
    public func reportLaunch() {
        guard isAvailable, !launchReported else { return }
        launchReported = true
        Task { @MainActor [weak self, delay] in
            try? await Task.sleep(for: delay)
            guard let self else { return }
            self.armed = true
            let queued = self.pending
            self.pending = []
            guard self.isEnabled else { return }
            let extra = await self.context?() ?? [:]
            guard self.isEnabled, let request = self.launchRequest(extra: extra) else { return }
            await self.transport(request)
            self.defaults.set(Self.version(in: self.bundle), forKey: Self.lastVersionKey)
            for event in queued { self.send(event) }
        }
    }

    /// Counts `name` with `properties`. With `once`, only the first time in this run for that key.
    public func track(_ name: String, _ properties: [String: String] = [:], once: String? = nil) {
        guard isAvailable, Self.allowedEvents.contains(name) else { return }
        if let once, !counted.insert("\(name)/\(once)").inserted { return }
        let event = Queued(name: name, data: Self.sanitized(Self.ranged(properties)))
        if armed {
            if isEnabled { send(event) }
        } else if pending.count < Self.queueLimit {
            pending.append(event)
        }
    }

    /// The end of the run: how long it lasted. Sent before the app quits, waiting a second at most, and only when
    /// the run went on past `launchDelay` (so analytics were on when the user had the time to turn them off).
    public func reportSessionEnd(_ properties: [String: String] = [:]) {
        guard isAvailable, armed, isEnabled else { return }
        let minutes = Int(startedAt.duration(to: .now).components.seconds / 60)
        var data = properties
        data["duration"] = Self.bucket(minutes, edges: [5, 15, 30, 60, 120, 240])
        guard let request = request(name: "session_end", url: "/session-end", data: Self.sanitized(data)) else { return }
        let transport = transport
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            await transport(request)
            done.signal()
        }
        _ = done.wait(timeout: .now() + 1)
    }

    private func send(_ event: Queued) {
        guard let request = request(name: event.name, url: "/\(event.name.replacingOccurrences(of: "_", with: "-"))", data: event.data) else { return }
        let transport = transport
        Task.detached { await transport(request) }
    }

    // MARK: Requests

    /// The `app_launch` event as Umami's collect endpoint takes it, with `extra` (the vault's facts) after the app's.
    func launchRequest(locale: Locale = .current, extra: [String: String] = [:]) -> URLRequest? {
        let info = bundle.infoDictionary ?? [:]
        var data = [
            "version": Self.version(in: bundle), "build": info["CFBundleVersion"] as? String ?? "",
            "macos": Self.macOSVersion, "arch": Self.architecture,
        ]
        if let previous = defaults.string(forKey: Self.lastVersionKey), previous != data["version"] {
            data["previous_version"] = previous
        }
        data.merge(extra) { _, new in new }
        return request(name: "app_launch", url: "/launch", data: Self.sanitized(data), locale: locale)
    }

    private func request(name: String, url: String, data: [String: String], locale: Locale = .current) -> URLRequest? {
        guard let endpoint, let websiteID else { return nil }
        let version = Self.version(in: bundle)
        let body = Event(payload: .init(
            website: websiteID,
            hostname: Self.hostname,
            language: Locale.preferredLanguages.first ?? locale.identifier,
            url: url,
            title: "Loam",
            name: name,
            data: data
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

    // MARK: Anonymity

    /// The properties that may leave: keys of lowercase letters, digits and underscores, values of letters, digits and
    /// `. _ - + , :` only, short. Whatever else (a path, a name with spaces, an address) is dropped, not trimmed, so a
    /// slip in a caller loses a property instead of leaking one.
    static func sanitized(_ properties: [String: String]) -> [String: String] {
        properties.filter { key, value in
            let limit = key.hasPrefix("plugins_") ? 480 : 64
            return !key.isEmpty && key.count <= 32 && key.allSatisfy { $0.isASCII && ($0.isLowercase || $0.isNumber || $0 == "_") }
                && !value.isEmpty && value.count <= limit
                && value.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || ".-_+,:".contains($0)) }
        }
    }

    /// A property named `<something>_count` holds a number, and leaves as the range it falls in ("50-199").
    static func ranged(_ properties: [String: String]) -> [String: String] {
        properties.reduce(into: [:]) { result, pair in
            result[pair.key] = pair.key.hasSuffix("_count") ? Int(pair.value).map { bucket($0, edges: sizeEdges) } : pair.value
        }
    }

    /// `count` as a range ("50-199") so the exact figure never leaves: `edges` are the lower bounds after the first.
    static func bucket(_ count: Int, edges: [Int]) -> String {
        guard let first = edges.first else { return String(count) }
        if count < first { return edges.first == 1 ? "0" : "0-\(first - 1)" }
        for (index, edge) in edges.enumerated() {
            if index + 1 < edges.count {
                if count < edges[index + 1] { return "\(edge)-\(edges[index + 1] - 1)" }
            } else {
                return "\(edge)+"
            }
        }
        return String(count)
    }

    /// The note counts, folder counts and the like: 0, 1-9, 10-49, 50-199, 200-999, 1000-4999, 5000+.
    static let sizeEdges = [1, 10, 50, 200, 1000, 5000]

    static func version(in bundle: Bundle) -> String {
        bundle.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
    }

    static var macOSVersion: String {
        let system = ProcessInfo.processInfo.operatingSystemVersion
        return "\(system.majorVersion).\(system.minorVersion)"
    }

    static var architecture: String {
        #if arch(arm64)
        "arm64"
        #else
        "x86_64"
        #endif
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
