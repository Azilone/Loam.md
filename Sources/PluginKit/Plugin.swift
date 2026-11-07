import Foundation

/// What the core hands to one plugin. Everything registered through it (commands, services,
/// listeners, effects) is undone when the plugin unloads, so a plugin never cleans up by hand.
public protocol PluginContext: AnyObject {
    /// The id from the plugin's manifest.
    var pluginID: String { get }
    var vault: VaultAccess { get }
    /// This plugin's settings, kept in `.loam/config.json` so they travel with the vault.
    var settings: PluginSettingsAccess { get }

    func registerCommand(_ command: Command) throws

    func provide<S>(_ key: ServiceKey<S>, _ service: S) throws
    func service<S>(_ key: ServiceKey<S>) -> S?

    /// Notifies every `on` listener, in registration order.
    func emit<E: PluginEvent>(_ event: E)
    func on<E: PluginEvent>(_ type: E.Type, _ handler: @escaping (E) -> Void)
    /// Passes `initial` through every `intercept` listener, in registration order.
    func waterfall<E: PluginEvent>(_ initial: E) -> E
    func intercept<E: PluginEvent>(_ type: E.Type, _ handler: @escaping Interceptor<E>)

    /// Runs `dispose` when the plugin unloads, after later effects (last in, first out).
    func effect(_ dispose: @escaping () -> Void)
}

/// Everything in the app, the editor included, is a plugin.
public protocol Plugin: AnyObject {
    static var manifest: PluginManifest { get }
    /// Programs the plugin cannot run without (`git`, `ffmpeg`), by name. While one is missing the host does not start
    /// the plugin: the plugin manager says which, and how to install it (`ToolLocating`).
    static var requiresTools: [String] { get }
    /// Programs the plugin uses when they are installed. Without one, the features that need it say so.
    static var optionalTools: [String] { get }
    init()
    func activate(context: PluginContext) throws
    func deactivate()
}

public extension Plugin {
    static var requiresTools: [String] { [] }
    static var optionalTools: [String] { [] }

    func deactivate() {}
}
