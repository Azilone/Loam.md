import Foundation
import PluginKit

/// The shared state of a running app: the vault and the registries plugins register into.
public final class Kernel {
    public let vault: VaultAccess
    public let commands: CommandCenter
    public let services: ServiceRegistry
    public let events: EventBus
    /// The programs plugins run (`git`, `ffmpeg`), found on this Mac. The host checks `requiresTools` with it, and
    /// plugins get it as the `tools` service.
    public let tools: ToolLocator
    /// `.loam/config.json`, where plugin settings are stored. Nil keeps settings in memory, so a kernel built
    /// for a test or a one-off tool never writes the vault's config.
    public let config: ConfigStore?
    let settingsBackend: SettingsBackend
    /// The defaults plugins read their settings with (`settingsDefault(for:)`).
    let settingsDefaults = SettingsDefaults()
    private var knownStamps: [String: FileStamp]?

    public init(
        vault: VaultAccess,
        config: ConfigStore? = nil,
        commands: CommandCenter = CommandCenter(),
        services: ServiceRegistry = ServiceRegistry(),
        events: EventBus = EventBus(),
        tools: ToolLocator = ToolLocator()
    ) {
        self.vault = vault
        self.config = config
        settingsBackend = config ?? InMemorySettings()
        self.commands = commands
        self.services = services
        self.events = events
        self.tools = tools
        // A registry that already has a locator keeps its own; the host still checks with `tools`.
        _ = try? services.provide(ServiceKey<ToolLocating>.tools, tools)
    }
}

extension Kernel {
    /// The default a plugin reads its settings with, as JSON, once it has read them (usually when it activates); nil
    /// before. The plugin manager shows these keys with the stored values over them, so every setting can be changed.
    public func settingsDefault(for id: String) -> JSONValue? {
        settingsDefaults.value(for: id)
    }

    /// Compares the files on disk (notes and any other non-hidden file) with the previous call and sends a `VaultChanged` event if anything
    /// changed. The first call only records the starting point. The app calls this when the file system
    /// reports a change (FSEvents), or on a timer where that is not available.
    @discardableResult
    public func refreshVault() throws -> [VaultChange] {
        refreshVault(applying: try vault.stamps())
    }

    /// `refreshVault` for stamps already read, so the app can walk the folder off the main thread and apply the result
    /// here.
    @discardableResult
    public func refreshVault(applying current: [String: FileStamp]) -> [VaultChange] {
        defer { knownStamps = current }
        guard let known = knownStamps else { return [] }

        var changes: [VaultChange] = []
        for (path, stamp) in current {
            if let old = known[path] {
                if old != stamp { changes.append(VaultChange(kind: .modified, path: path)) }
            } else {
                changes.append(VaultChange(kind: .added, path: path))
            }
        }
        for path in known.keys where current[path] == nil { changes.append(VaultChange(kind: .removed, path: path)) }
        changes.sort { $0.path < $1.path }
        if !changes.isEmpty { events.emit(VaultChanged(changes: changes)) }
        return changes
    }
}

/// The context one plugin sees. Its `scope` undoes everything it registered.
final class ScopedContext: PluginContext {
    let pluginID: String
    let scope = Scope()
    private let kernel: Kernel

    init(pluginID: String, kernel: Kernel) {
        self.pluginID = pluginID
        self.kernel = kernel
    }

    /// The kernel's vault, announcing this plugin's reads and writes (`NotifyingVault`).
    var vault: VaultAccess { NotifyingVault(base: kernel.vault, pluginID: pluginID, events: kernel.events) }

    private(set) lazy var settings: PluginSettingsAccess = ScopedSettings(
        pluginID: pluginID,
        backend: kernel.settingsBackend,
        events: kernel.events,
        defaults: kernel.settingsDefaults
    )

    func registerCommand(_ command: Command) throws {
        try kernel.commands.register(command, owner: pluginID)
        let id = command.id
        scope.add { [kernel] in kernel.commands.unregister(id: id) }
    }

    func provide<S>(_ key: ServiceKey<S>, _ service: S) throws {
        scope.add(try kernel.services.provide(key, service))
    }

    func service<S>(_ key: ServiceKey<S>) -> S? {
        kernel.services.service(key)
    }

    func emit<E: PluginEvent>(_ event: E) {
        kernel.events.emit(event)
    }

    func on<E: PluginEvent>(_ type: E.Type, _ handler: @escaping (E) -> Void) {
        scope.add(kernel.events.on(type, handler))
    }

    func waterfall<E: PluginEvent>(_ initial: E) -> E {
        kernel.events.waterfall(initial)
    }

    func intercept<E: PluginEvent>(_ type: E.Type, _ handler: @escaping Interceptor<E>) {
        scope.add(kernel.events.intercept(type, handler))
    }

    func effect(_ dispose: @escaping () -> Void) {
        scope.add(dispose)
    }
}
