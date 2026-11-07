/// The version of the plugin SDK, `PluginKit` and `PluginKitUI`: the API a plugin is compiled against.
///
/// On Apple platforms both modules are built with library evolution, so a compiled plugin keeps running on later
/// releases of the app as long as the SDK only gains API. The app loads a plugin built for its own major version and
/// a minor version up to its own (docs/PLUGIN-LOADING.md, "Plugin SDK version"):
///
/// - **Minor**: bump it when `PluginKit` or `PluginKitUI` gains public API. `scripts/check-plugin-api.sh` (in
///   `make test`) asks for it.
/// - **Major**: bump it only when a change breaks plugins (an API removed or renamed, a protocol requirement without a
///   default implementation). Every plugin then needs a rebuild, so add the new API next to the old one instead.
///
/// Linux has no stable ABI: there a plugin must still match the runtime's `PluginRuntime.buildID`.
public struct PluginSDKVersion: Hashable, Sendable, Comparable, CustomStringConvertible {
    public let major: Int
    public let minor: Int

    public init(major: Int, minor: Int) {
        self.major = major
        self.minor = minor
    }

    /// This SDK. Emitted into every module that reads it, so a plugin carries the version it was compiled against.
    /// `scripts/check-plugin-api.sh` reads the two numbers from this line.
    @_alwaysEmitIntoClient
    public static var current: PluginSDKVersion { PluginSDKVersion(major: 2, minor: 11) }

    public static func < (lhs: PluginSDKVersion, rhs: PluginSDKVersion) -> Bool {
        (lhs.major, lhs.minor) < (rhs.major, rhs.minor)
    }

    public var description: String { "\(major).\(minor)" }
}
