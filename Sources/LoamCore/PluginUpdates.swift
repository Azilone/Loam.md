import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import PluginKit

/// Where a vault plugin came from, so it can be updated: `.loam/plugins/<id>/.loam-origin.json`, written by
/// `plugins.install` and `plugins.update` (docs/UPDATES.md).
///
///     { "source": "https://github.com/someone/share", "ref": "v1.2.0", "commit": "3f2a…", "catalog": false }
///
/// `ref` is the release tag that was installed, nil when the plugin follows its default branch; `commit` is what was
/// checked out (nil for a copied folder); `catalog` says the versions come from the plugin catalog, pinned to commits.
public struct PluginOrigin: Codable, Equatable, Sendable {
    public static let fileName = ".loam-origin.json"

    public var source: String
    public var ref: String?
    public var commit: String?
    public var catalog: Bool
    /// Updates that ask for no new permission are applied by the app's daily check without asking.
    public var autoUpdate: Bool

    public init(source: String, ref: String? = nil, commit: String? = nil, catalog: Bool = false, autoUpdate: Bool = false) {
        self.source = source
        self.ref = ref
        self.commit = commit
        self.catalog = catalog
        self.autoUpdate = autoUpdate
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        source = try container.decode(String.self, forKey: .source)
        ref = try container.decodeIfPresent(String.self, forKey: .ref)
        commit = try container.decodeIfPresent(String.self, forKey: .commit)
        catalog = try container.decodeIfPresent(Bool.self, forKey: .catalog) ?? false
        autoUpdate = try container.decodeIfPresent(Bool.self, forKey: .autoUpdate) ?? false
    }

    /// A git URL (or path to a repository), not a folder that was copied.
    public var isGit: Bool { commit != nil }

    public static func read(in folder: URL) -> PluginOrigin? {
        guard let data = FileManager.default.contents(atPath: folder.appendingPathComponent(fileName).path) else { return nil }
        return try? JSONDecoder().decode(PluginOrigin.self, from: data)
    }

    public func write(in folder: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: folder.appendingPathComponent(Self.fileName), options: .atomic)
    }
}

/// A release version, `1.2.0` or `v1.2.0`: numbers compared one by one, a missing one counts as 0. Anything after a
/// `-` or `+` is ignored, so a pre-release tag (`1.3.0-beta`) never counts as newer than its release.
public struct ReleaseVersion: Comparable, Hashable, Sendable, CustomStringConvertible {
    public let numbers: [Int]
    public let isPrerelease: Bool

    public init?(_ text: String) {
        var core = Substring(text.trimmingCharacters(in: .whitespaces))
        if core.first == "v" || core.first == "V" { core = core.dropFirst() }
        let cut = core.firstIndex { $0 == "-" || $0 == "+" }
        isPrerelease = cut.map { core[$0] == "-" } ?? false
        if let cut { core = core[..<cut] }
        let parts = core.split(separator: ".", omittingEmptySubsequences: false)
        guard !parts.isEmpty, parts.count <= 4 else { return nil }
        var numbers: [Int] = []
        for part in parts {
            guard let number = Int(part), number >= 0 else { return nil }
            numbers.append(number)
        }
        self.numbers = numbers
    }

    public static func < (lhs: ReleaseVersion, rhs: ReleaseVersion) -> Bool {
        let count = max(lhs.numbers.count, rhs.numbers.count)
        for index in 0..<count {
            let left = index < lhs.numbers.count ? lhs.numbers[index] : 0
            let right = index < rhs.numbers.count ? rhs.numbers[index] : 0
            if left != right { return left < right }
        }
        return lhs.isPrerelease && !rhs.isPrerelease
    }

    public static func == (lhs: ReleaseVersion, rhs: ReleaseVersion) -> Bool { !(lhs < rhs) && !(rhs < lhs) }

    public func hash(into hasher: inout Hasher) {
        var trimmed = numbers
        while trimmed.last == 0 { trimmed.removeLast() }
        hasher.combine(trimmed)
        hasher.combine(isPrerelease)
    }

    public var description: String { numbers.map(String.init).joined(separator: ".") }
}

extension PluginSDKVersion {
    /// `"1.12"` → 1.12; nil for anything else.
    static func parse(_ text: String) -> PluginSDKVersion? {
        let parts = text.trimmingCharacters(in: .whitespaces).split(separator: ".")
        guard parts.count == 2, let major = Int(parts[0]), let minor = Int(parts[1]) else { return nil }
        return PluginSDKVersion(major: major, minor: minor)
    }
}

/// The public list of plugins anyone can install by id (docs/UPDATES.md): one JSON file in a git repository, changed by
/// pull request. Every version is pinned to a commit, so a moved tag or a taken-over repository is refused.
///
///     { "plugins": [ { "id": "share", "name": "Share", "description": "…", "repo": "https://github.com/x/share",
///       "versions": [ { "version": "1.2.0", "tag": "v1.2.0", "commit": "3f2a…", "minSDK": "1.12",
///                       "permissions": ["network"] } ] } ] }
public struct PluginCatalog: Codable, Equatable, Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        public var id: String
        public var name: String
        public var description: String?
        public var author: String?
        public var repo: String
        public var versions: [Version]

        /// The newest version this app can build: its `minSDK` is not above `sdk`.
        public func latest(for sdk: PluginSDKVersion = .current) -> Version? {
            versions.filter { $0.buildable(with: sdk) }.max { $0.release < $1.release }
        }

        /// The newest version of all, buildable or not.
        public var newest: Version? { versions.max { $0.release < $1.release } }
    }

    public struct Version: Codable, Equatable, Sendable {
        public var version: String
        public var tag: String
        public var commit: String
        public var minSDK: String?
        public var permissions: [String]?

        var release: ReleaseVersion { ReleaseVersion(version) ?? ReleaseVersion("0")! }

        func buildable(with sdk: PluginSDKVersion) -> Bool {
            guard let required = minSDK.flatMap(PluginSDKVersion.parse) else { return true }
            return required.major == sdk.major && required <= sdk
        }
    }

    public var plugins: [Entry]

    public func entry(_ id: String) -> Entry? { plugins.first { $0.id == id } }

    /// The catalog's address: `LOAM_PLUGIN_CATALOG` when set (a URL or a path), else the public one.
    public static var defaultURL: URL {
        if let value = ProcessInfo.processInfo.environment["LOAM_PLUGIN_CATALOG"], !value.isEmpty {
            return value.contains("://") ? URL(string: value)! : URL(fileURLWithPath: value)
        }
        return URL(string: "https://raw.githubusercontent.com/Azilone/loam-community/main/index.json")!
    }

    /// Reads the catalog at `url` (https or a file).
    public static func fetch(_ url: URL = defaultURL) async throws -> PluginCatalog {
        let data: Data
        if url.isFileURL {
            data = try Data(contentsOf: url)
        } else {
            var request = URLRequest(url: url)
            request.cachePolicy = .reloadIgnoringLocalCacheData
            request.timeoutInterval = 20
            let (body, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                throw PluginPackageError.badSource("the plugin catalog \(url.absoluteString) answered \(http.statusCode)")
            }
            data = body
        }
        do {
            return try JSONDecoder().decode(PluginCatalog.self, from: data)
        } catch {
            throw PluginPackageError.badSource("the plugin catalog \(url.absoluteString) cannot be read: \(error)")
        }
    }
}

/// What `git ls-remote` says about a repository, without downloading it.
enum GitRemote {
    /// The highest release tag (`v1.2.0`, `1.2.0`; pre-releases left out), nil when the repository has none.
    static func latestTag(_ source: String) async throws -> (tag: String, version: ReleaseVersion)? {
        let output = try await Subprocess.output("git", ["ls-remote", "--tags", "--refs", "--", source])
        return latestTag(inListing: output)
    }

    static func latestTag(inListing output: String) -> (tag: String, version: ReleaseVersion)? {
        output.split(separator: "\n").compactMap { line -> (String, ReleaseVersion)? in
            guard let ref = line.split(separator: "\t").last, ref.hasPrefix("refs/tags/") else { return nil }
            let tag = String(ref.dropFirst("refs/tags/".count))
            guard let version = ReleaseVersion(tag), !version.isPrerelease else { return nil }
            return (tag, version)
        }.max { $0.1 < $1.1 }
    }

    /// The commit the repository's default branch points to.
    static func headCommit(_ source: String) async throws -> String? {
        let output = try await Subprocess.output("git", ["ls-remote", "--", source, "HEAD"])
        return output.split(separator: "\n").first?.split(separator: "\t").first.map(String.init)
    }
}
