import Foundation

/// The sources third-party plugins compile against: the root package (`Package.swift`, `Package.resolved`,
/// `Sources/`) and the app package (`App/`), in a folder named `loam` (the package identity plugins
/// reference). A plugin must be built against the exact sources and compiler of the runtime that loads it
/// (docs/PLUGIN-LOADING.md), so the app ships a snapshot of them, stamped with its build id, in
/// `Contents/Resources/SDK/loam`.
public struct PluginSDK: Equatable, Sendable {
    /// Where the SDK was found, in the order `locate` tries.
    public enum Origin: String, Equatable, Sendable {
        /// `$LOAM_SDK`.
        case environment
        /// The app bundle the running executable belongs to: `Contents/Resources/SDK/loam`.
        case bundle
        /// The source checkout this build was made from (a development build).
        case checkout
    }

    public static let environmentKey = "LOAM_SDK"
    /// The SDK's path inside an app bundle, from `Contents/`.
    public static let bundlePath = "Resources/SDK/loam"

    public let url: URL
    public let origin: Origin

    public init(url: URL, origin: Origin) {
        self.url = url
        self.origin = origin
    }

    /// Same folder (trailing slash or not) and origin.
    public static func == (lhs: PluginSDK, rhs: PluginSDK) -> Bool {
        lhs.url.standardizedFileURL.path == rhs.url.standardizedFileURL.path && lhs.origin == rhs.origin
    }

    /// A checkout carries `scripts/stamp-build-id.sh`; a snapshot (in the bundle) is already stamped.
    public var isCheckout: Bool {
        FileManager.default.fileExists(atPath: url.appendingPathComponent("scripts/stamp-build-id.sh").path)
    }

    /// Whether `url` holds the SDK: the root manifest and PluginKit's entry point.
    public static func isSDK(_ url: URL) -> Bool {
        let files = FileManager.default
        return files.fileExists(atPath: url.appendingPathComponent("Package.swift").path)
            && files.fileExists(atPath: url.appendingPathComponent("Sources/PluginKit/PluginEntry.swift").path)
    }

    /// Finds the SDK, first match wins:
    ///
    /// 1. `$LOAM_SDK`, when it is set (an SDK that is not there is an error, never a silent fallback);
    /// 2. the app bundle of the running executable (`Contents/Helpers/loam` or the app itself, symlinks resolved):
    ///    `Contents/Resources/SDK/loam`;
    /// 3. a source checkout containing the running executable (`CLI/.build/release/loam`), then the checkout this
    ///    file was compiled from, when it still exists (development builds and tests).
    public static func locate(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        executableURL: URL? = Bundle.main.executableURL,
        sourceFile: String = #filePath
    ) -> Result<PluginSDK, PluginSDKError> {
        if let path = environment[environmentKey], !path.isEmpty {
            let url = URL(fileURLWithPath: path).standardizedFileURL
            return isSDK(url) ? .success(PluginSDK(url: url, origin: .environment)) : .failure(.invalidEnvironment(path))
        }
        let executable = executableURL?.resolvingSymlinksInPath()
        if let contents = executable?.deletingLastPathComponent().deletingLastPathComponent(),
           contents.lastPathComponent == "Contents" {
            let url = contents.appendingPathComponent(bundlePath, isDirectory: true)
            if isSDK(url) { return .success(PluginSDK(url: url, origin: .bundle)) }
        }
        var folder = executable?.deletingLastPathComponent()
        while let current = folder, current.path != "/" {
            if isSDK(current) { return .success(PluginSDK(url: current, origin: .checkout)) }
            folder = current.deletingLastPathComponent()
        }
        // Sources/LoamCore/PluginSDK.swift -> the checkout.
        let compiled = URL(fileURLWithPath: sourceFile)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        if isSDK(compiled) { return .success(PluginSDK(url: compiled, origin: .checkout)) }
        return .failure(.notFound)
    }
}

public enum PluginSDKError: Error, Equatable, LocalizedError {
    case invalidEnvironment(String)
    case notFound

    public var errorDescription: String? {
        switch self {
        case .invalidEnvironment(let path):
            return "LOAM_SDK is \(path), which is not a Loam SDK (no Package.swift and Sources/PluginKit)"
        case .notFound:
            return "no Loam SDK found: run the `loam` inside the app (Loam.app/Contents/Helpers/loam), "
                + "or set LOAM_SDK to the app's Contents/Resources/SDK/loam or to a source checkout"
        }
    }
}
