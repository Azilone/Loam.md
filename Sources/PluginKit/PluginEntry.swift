import Foundation

/// What a plugin library loaded at run time hands to the app: its plugin types, and the SDK and runtime it was built
/// against. A third-party plugin exports one C function returning a retained entry:
///
///     @_cdecl("loam_plugin_entry")
///     public func loamPluginEntry() -> UnsafeMutableRawPointer {
///         Unmanaged.passRetained(PluginEntry(plugins: [HelloPlugin.self])).toOpaque()
///     }
///
/// On Apple platforms the app accepts an entry whose `sdkVersion` it supports (`PluginSDKVersion`); on Linux, where
/// Swift has no stable ABI, only an entry whose `buildID` is its own `PluginRuntime.buildID`.
public final class PluginEntry {
    /// The name of the C function every plugin library exports.
    public static let symbol = "loam_plugin_entry"

    public let plugins: [Plugin.Type]
    /// The `PluginRuntime.buildID` the plugin was compiled against.
    public let buildID: String
    /// The `PluginSDKVersion.current` the plugin was compiled against; nil for a plugin built before the SDK had
    /// versions.
    public let sdkVersion: PluginSDKVersion?

    public init(plugins: [Plugin.Type], buildID: String, sdkVersion: PluginSDKVersion?) {
        self.plugins = plugins
        self.buildID = buildID
        self.sdkVersion = sdkVersion
    }

    /// An entry without an SDK version, as plugins built before `PluginSDKVersion` made them.
    public convenience init(plugins: [Plugin.Type], buildID: String) {
        self.init(plugins: plugins, buildID: buildID, sdkVersion: nil)
    }

    /// Records the SDK version and runtime build id the calling plugin is compiled against. Emitted into the plugin,
    /// not called in the runtime, so the values are the ones the plugin saw at compile time (a default argument would
    /// be evaluated by the runtime loaded at run time, which always matches).
    @_alwaysEmitIntoClient
    public convenience init(plugins: [Plugin.Type]) {
        self.init(plugins: plugins, buildID: PluginRuntime.buildID, sdkVersion: PluginSDKVersion.current)
    }
}
