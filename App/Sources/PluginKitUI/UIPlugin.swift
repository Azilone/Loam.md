/// A plugin with an interface. It activates on the main actor, where SwiftUI and the UI registries live.
///
/// The plugin host is not actor-aware (it is Foundation-only and builds on Linux), so `Plugin.activate` is
/// nonisolated. The app and the UI test harness always drive the host from the main thread, so the default
/// `activate` asserts that with `MainActor.assumeIsolated` instead of hopping: a UI plugin activated anywhere
/// else is a bug, and trapping says so at once.
///
/// The conforming class itself stays nonisolated, because the host calls `init()` from a nonisolated context.
public protocol UIPlugin: Plugin {
    @MainActor func activateUI(context: PluginContext) throws
    /// Optional; everything registered through the context is undone without it.
    @MainActor func deactivateUI()
}

public extension UIPlugin {
    @MainActor func deactivateUI() {}

    func activate(context: PluginContext) throws {
        // The host and the context are main-thread objects that Swift 6 cannot prove are on the main actor;
        // `assumeIsolated` checks it at run time, so moving them into the closure is safe.
        nonisolated(unsafe) let plugin = self
        nonisolated(unsafe) let context = context
        try MainActor.assumeIsolated { try plugin.activateUI(context: context) }
    }

    func deactivate() {
        nonisolated(unsafe) let plugin = self
        MainActor.assumeIsolated { plugin.deactivateUI() }
    }
}
