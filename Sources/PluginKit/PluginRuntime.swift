/// The identity of this build of the runtime libraries. A plugin records the id it was compiled against
/// (`PluginEntry(plugins:)`). On Linux the app refuses it when the id differs from its own; on Apple platforms the
/// SDK is built with library evolution and `PluginSDKVersion` decides instead.
///
/// `scripts/stamp-build-id.sh` writes the id into `PluginRuntimeBuildID.swift` for the app bundle, `make release`
/// and the example plugin, then puts the committed value, `dev`, back. A plain `swift build` or `swift test` builds
/// with `dev`: two dev builds of different sources share it, so only stamped builds are protected
/// (docs/PLUGIN-LOADING.md).
public enum PluginRuntime {
    /// Emitted into every module that reads it, so a plugin carries the value of the sources it was built from.
    @_alwaysEmitIntoClient
    public static var buildID: String { _pluginRuntimeBuildID }
}
