import LoamCore
import PluginKit

/// Which plugins the shell hosts. The executable builds it, so the shell itself never names a plugin and tests can
/// host a test plugin instead of the real ones.
public struct ShellConfiguration {
    /// Plugins from the root package (`builtinPlugins`): data, services, commands.
    public var logicPlugins: [Plugin.Type]
    /// Plugins with an interface (`builtinUIPlugins`).
    public var uiPlugins: [Plugin.Type]
    /// The plugins safe mode keeps; the runtime adds the providers they require.
    public var safeModePlugins: Set<String>
    /// Lists the vault's own plugins (`.loam/plugins/`) and loads those `.loam/config.json` enables; never in safe mode.
    public var thirdPartyPlugins: Bool
    /// Where turning on one of the vault's own plugins is remembered; its config alone never runs its code.
    public var pluginTrust: PluginTrust

    public init(
        logicPlugins: [Plugin.Type],
        uiPlugins: [Plugin.Type],
        safeModePlugins: Set<String> = [],
        thirdPartyPlugins: Bool = false,
        pluginTrust: PluginTrust = .onThisMachine
    ) {
        self.logicPlugins = logicPlugins
        self.uiPlugins = uiPlugins
        self.safeModePlugins = safeModePlugins
        self.thirdPartyPlugins = thirdPartyPlugins
        self.pluginTrust = pluginTrust
    }
}
