import AppKit
import CryptoKit
import Foundation
import Observation

/// One release in a channel's feed (docs/UPDATES.md), `stable.json` or `beta.json` next to the release archives:
///
///     { "version": "0.2.0", "build": 12, "url": "https://…/Loam-0.2.0.zip", "size": 48213456,
///       "sha256": "…", "signature": "<Ed25519 of the zip, base64>", "minimumSystemVersion": "26.0",
///       "notes": "What changed.", "date": "2026-10-28" }
public struct AppRelease: Codable, Equatable, Sendable {
    public var version: String
    public var build: Int
    public var url: URL
    public var size: Int?
    public var sha256: String
    public var signature: String
    public var minimumSystemVersion: String?
    public var notes: String?
    public var date: String?

    /// Newer than the running build: a higher build number wins, so a beta and its release compare in order.
    public func isNewer(thanBuild build: Int) -> Bool { self.build > build }

    /// Whether this Mac runs the macOS the release needs.
    public func runsOnThisMac() -> Bool {
        guard let minimum = minimumSystemVersion else { return true }
        let parts = minimum.split(separator: ".").compactMap { Int($0) }
        return ProcessInfo.processInfo.isOperatingSystemAtLeast(OperatingSystemVersion(
            majorVersion: parts.first ?? 0, minorVersion: parts.count > 1 ? parts[1] : 0, patchVersion: parts.count > 2 ? parts[2] : 0
        ))
    }
}

public enum AppUpdateError: Error, LocalizedError, Equatable {
    case badSignature
    case badChecksum
    case badArchive(String)
    case notWritable(String)
    case server(Int)

    public var errorDescription: String? {
        switch self {
        case .badSignature: return String(localized: "The update is not signed by Loam: it was not installed.")
        case .badChecksum: return String(localized: "The update was damaged while downloading.")
        case .badArchive(let reason): return String(localized: "The update cannot be opened: \(reason)")
        case .notWritable(let path):
            return String(localized: "Loam cannot replace itself in \(path). Move Loam to your Applications folder.")
        case .server(let status): return String(localized: "The update server answered \(status).")
        }
    }
}

/// Keeps the app up to date without a store or a server of our own: a signed JSON feed per channel, the release as a
/// zip, both static files (scripts/release.sh writes them). Every archive is checked against the Ed25519 public key
/// built into the app (`LoamUpdatePublicKey`), so only a release signed with the project's private key installs.
///
/// A release is downloaded in the background, unpacked next to the caches and swapped in when the user restarts:
/// a small shell script waits for the app to quit, replaces the bundle, and opens the new one on the same vault.
@MainActor
@Observable
public final class AppUpdater {
    public enum Channel: String, CaseIterable, Sendable {
        case stable
        case beta
    }

    public enum State: Equatable {
        case idle
        case checking
        case upToDate
        case downloading(AppRelease)
        /// Downloaded, verified and unpacked: restarting installs it.
        case ready(AppRelease)
        case failed(String)
    }

    public private(set) var state: State = .idle
    public private(set) var lastCheck: Date?

    public var channel: Channel {
        didSet { defaults.set(channel.rawValue, forKey: Self.channelKey) }
    }

    public var checksAutomatically: Bool {
        didSet { defaults.set(checksAutomatically, forKey: Self.automaticKey) }
    }

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let bundle: Bundle
    @ObservationIgnored private var schedule: Task<Void, Never>?
    /// The unpacked bundle of a `ready` release.
    @ObservationIgnored private var stagedApp: URL?
    /// Told when an update is ready or failed, for the anonymous statistics (Analytics/AppAnalytics.swift).
    @ObservationIgnored public var onEvent: (@MainActor (String, [String: String]) -> Void)?

    static let channelKey = "updateChannel"
    static let automaticKey = "updateChecksAutomatically"
    static let interval: Duration = .seconds(24 * 60 * 60)

    public init(bundle: Bundle = .main, defaults: UserDefaults = .standard) {
        self.bundle = bundle
        self.defaults = defaults
        channel = Channel(rawValue: defaults.string(forKey: Self.channelKey) ?? "") ?? .stable
        checksAutomatically = defaults.object(forKey: Self.automaticKey) as? Bool ?? true
    }

    // MARK: What this build is

    public var currentVersion: String { bundle.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev" }
    public var currentBuild: Int { Int(bundle.infoDictionary?["CFBundleVersion"] as? String ?? "") ?? 0 }

    /// The feed of the chosen channel: `LOAM_UPDATE_FEED` (a folder URL, for tests) or `LoamUpdateFeed` in Info.plist.
    public var feedURL: URL? {
        let base = ProcessInfo.processInfo.environment["LOAM_UPDATE_FEED"].flatMap { $0.isEmpty ? nil : $0 }
            ?? bundle.infoDictionary?["LoamUpdateFeed"] as? String
        guard let base, let url = URL(string: base) else { return nil }
        return url.appendingPathComponent("\(channel.rawValue).json")
    }

    var publicKey: Curve25519.Signing.PublicKey? {
        guard let text = bundle.infoDictionary?["LoamUpdatePublicKey"] as? String,
              let data = Data(base64Encoded: text) else { return nil }
        return try? Curve25519.Signing.PublicKey(rawRepresentation: data)
    }

    /// Why this build does not update itself, nil when it does: a development build has no feed or key.
    public var unavailableReason: String? {
        if feedURL == nil || publicKey == nil {
            return String(localized: "This is a development build: it does not update itself.")
        }
        if bundle.bundleURL.pathExtension != "app" { return String(localized: "Not running from an app bundle.") }
        return nil
    }

    // MARK: Checking

    /// Checks a little after launch, then once a day, while automatic checks are on.
    public func start() {
        guard schedule == nil, unavailableReason == nil else { return }
        schedule = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(30))
            while !Task.isCancelled {
                if self?.checksAutomatically == true { await self?.check() }
                try? await Task.sleep(for: Self.interval)
            }
        }
    }

    /// Reads the feed; a newer release this Mac can run is downloaded and verified at once.
    public func check() async {
        guard unavailableReason == nil, let feedURL else { return }
        switch state {
        case .checking, .downloading, .ready: return
        default: break
        }
        state = .checking
        do {
            let release = try await Self.fetchRelease(feedURL)
            lastCheck = Date()
            guard release.isNewer(thanBuild: currentBuild), release.runsOnThisMac() else {
                state = .upToDate
                return
            }
            state = .downloading(release)
            stagedApp = try await download(release)
            state = .ready(release)
            onEvent?("update_ready", ["version": release.version])
        } catch {
            state = .failed(error.localizedDescription)
            onEvent?("update_failed", [:])
        }
    }

    static func fetchRelease(_ url: URL) async throws -> AppRelease {
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 20
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 { throw AppUpdateError.server(http.statusCode) }
        return try JSONDecoder().decode(AppRelease.self, from: data)
    }

    // MARK: Downloading

    private var updatesFolder: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Loam/Updates", isDirectory: true)
    }

    private func download(_ release: AppRelease) async throws -> URL {
        guard let publicKey else { throw AppUpdateError.badSignature }
        let (file, response) = try await URLSession.shared.download(from: release.url)
        defer { try? FileManager.default.removeItem(at: file) }
        if let http = response as? HTTPURLResponse, http.statusCode != 200 { throw AppUpdateError.server(http.statusCode) }
        let data = try Data(contentsOf: file, options: .mappedIfSafe)
        try Self.verify(data, release: release, publicKey: publicKey)
        return try await Self.unpack(data, version: release.version, into: updatesFolder,
                                     bundleID: bundle.bundleIdentifier ?? "com.azilone.loam")
    }

    /// Throws unless `data` is the archive the release describes, signed with the project's key.
    static func verify(_ data: Data, release: AppRelease, publicKey: Curve25519.Signing.PublicKey) throws {
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard digest == release.sha256.lowercased() else { throw AppUpdateError.badChecksum }
        guard let signature = Data(base64Encoded: release.signature),
              publicKey.isValidSignature(signature, for: data) else { throw AppUpdateError.badSignature }
    }

    /// Unzips `data` into a fresh folder of `folder` and returns the Loam.app inside, checked to be this app.
    static func unpack(_ data: Data, version: String, into folder: URL, bundleID: String) async throws -> URL {
        let files = FileManager.default
        try? files.removeItem(at: folder)
        let target = folder.appendingPathComponent(version, isDirectory: true)
        try files.createDirectory(at: target, withIntermediateDirectories: true)
        let archive = folder.appendingPathComponent("Loam-\(version).zip")
        try data.write(to: archive)
        defer { try? files.removeItem(at: archive) }
        let status = try await run("/usr/bin/ditto", ["-x", "-k", archive.path, target.path])
        guard status == 0 else { throw AppUpdateError.badArchive("ditto exited with \(status)") }
        let app = target.appendingPathComponent("Loam.app")
        // The plist itself, not Bundle(url:), which caches the bundle of a path for the life of the process.
        let plist = app.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: plist),
              let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              info["CFBundleIdentifier"] as? String == bundleID else {
            throw AppUpdateError.badArchive(String(localized: "no Loam.app inside"))
        }
        return app
    }

    // MARK: Installing

    /// Quits, swaps the new bundle in, and opens it on `vault`. Throws before quitting when it cannot.
    public func installAndRelaunch(vault: URL?) throws {
        guard case .ready = state, let stagedApp else { return }
        let current = bundle.bundleURL
        let parent = current.deletingLastPathComponent()
        guard FileManager.default.isWritableFile(atPath: parent.path),
              FileManager.default.isWritableFile(atPath: current.path) else {
            throw AppUpdateError.notWritable(parent.path)
        }
        let script = """
        while kill -0 "$1" 2>/dev/null; do sleep 0.2; done
        backup="$3.previous-$$"
        if mv "$3" "$backup" && mv "$2" "$3"; then
          rm -rf "$backup"
        else
          [ -e "$3" ] || mv "$backup" "$3"
        fi
        xattr -dr com.apple.quarantine "$3" 2>/dev/null
        if [ -n "$4" ]; then open -n "$3" --args --vault "$4"; else open -n "$3"; fi
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script, "loam-update", String(ProcessInfo.processInfo.processIdentifier),
                             stagedApp.path, current.path, vault?.path ?? ""]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        NSApp.terminate(nil)
    }

    private static func run(_ tool: String, _ arguments: [String]) async throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        return try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                continuation.resume(throwing: error)
            }
        }
    }
}
