import Foundation
import PluginKit

/// The sync as the rest of the app sees it: the `git-sync` service, the engine's way to the main thread, and what
/// feeds the scheduler (changes, the app's focus, settings).
final class SyncController: GitSyncService, SyncHost, @unchecked Sendable {
    private let context: PluginContext
    private let pluginID: String
    private let lock = NSLock()
    private var current = SyncStatus.off
    private var observers: [UUID: @Sendable (SyncStatus) -> Void] = [:]
    /// Main thread only.
    private var bridge: SyncEditorBridge?
    /// The app said it is there (`setForeground`): automatic sync may run.
    private var appIsThere = false
    /// Changes the file watcher reports until then come from the cycle's own git writes.
    private var ownWritesUntil = Date.distantPast
    private(set) var engine: SyncEngine!
    private(set) var scheduler: SyncScheduler!

    /// How GitHub's API is reached; scripted in tests.
    let transport: HTTPTransport

    init(context: PluginContext, runner: GitRunner, transport: HTTPTransport = URLSessionTransport()) {
        self.context = context
        self.transport = transport
        pluginID = context.pluginID
        engine = SyncEngine(root: context.vault.rootURL, runner: runner, host: self)
        let engine = engine!
        let tokens = GitHubTokenStore()
        engine.gitHubToken = { tokens.load() }
        scheduler = SyncScheduler(
            cycle: { options in await engine.cycle(options) },
            willStart: { [weak self] in self?.cycleWillStart() },
            didFinish: { [weak self] outcome in self?.cycleDidFinish(outcome) }
        )
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    func stop() {
        scheduler.stop()
    }

    // MARK: - GitSyncService

    var status: SyncStatus { locked { current } }

    func observe(_ handler: @escaping @Sendable (SyncStatus) -> Void) -> () -> Void {
        let id = UUID()
        locked { observers[id] = handler }
        return { [weak self] in self?.locked { self?.observers[id] = nil } }
    }

    func syncNow() async -> SyncStatus {
        await sync(CycleOptions(forceMerge: true)).status
    }

    func requestSync() {
        Task.detached { [self] in _ = await syncNow() }
    }

    func sync(_ options: CycleOptions) async -> CycleOutcome {
        await scheduler.runNow(options)
    }

    func setForeground(_ isForeground: Bool) {
        locked { appIsThere = true }
        applySettings()
        scheduler.update { policy, now in policy.setForeground(isForeground, at: now) }
    }

    func setEditorBridge(_ bridge: SyncEditorBridge?) {
        self.bridge = bridge
    }

    // MARK: - Inputs

    /// A file changed: a commit follows once changes stop. `fromWatcher` changes right after a cycle are git's own.
    func noteWritten(fromWatcher: Bool) {
        if fromWatcher, locked({ Date() < ownWritesUntil }) { return }
        scheduler.update { policy, now in policy.wrote(at: now) }
    }

    /// Reads the settings again (main thread): automatic sync arms or stops, delays follow.
    func applySettings() {
        let settings = context.settings.value(default: GitSyncSettings())
        let armed = settings.auto && locked { appIsThere }
        scheduler.update { policy, now in
            if armed, !policy.armed { policy.immediate = true }
            policy.armed = armed
            policy.authPaused = policy.authPaused && armed
            policy.commitDelay = TimeInterval(max(settings.commitDelaySeconds, 1))
            policy.pullInterval = TimeInterval(max(settings.pullIntervalMinutes, 1) * 60)
        }
        if !settings.auto { publish(.off) }
    }

    private func cycleWillStart() {
        locked { ownWritesUntil = .distantFuture }
        guard current.state != .off else { return }
        var status = current
        status.state = .syncing
        publish(status)
    }

    private func cycleDidFinish(_ outcome: CycleOutcome) {
        locked { ownWritesUntil = Date().addingTimeInterval(2) }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            // A pull may have brought new settings (they travel with the vault).
            let auto = context.settings.value(default: GitSyncSettings()).auto
            publish(auto ? outcome.status : .off)
            applySettings()
        }
    }

    private func publish(_ status: SyncStatus) {
        let handlers: [@Sendable (SyncStatus) -> Void] = locked {
            guard current != status else { return [] }
            current = status
            return Array(observers.values)
        }
        guard !handlers.isEmpty else { return }
        DispatchQueue.main.async { for handler in handlers { handler(status) } }
    }

    /// `sync.status`: what is on disk, with the last cycle's state while automatic sync is on.
    func report() async -> SyncStatus {
        var inspected = await engine.inspect()
        let last = status
        if inspected.state != .off, last.state != .off {
            inspected.state = last.state
            inspected.message = last.message ?? inspected.message
        }
        return inspected
    }

    // MARK: - SyncHost

    func settings() async -> GitSyncSettings {
        await MainActor.run { context.settings.value(default: GitSyncSettings()) }
    }

    func updateSettings(_ settings: GitSyncSettings) async throws {
        try await MainActor.run { try context.settings.update(settings) }
    }

    func busyPaths(_ paths: [String], quiet: TimeInterval) async -> [String] {
        guard !paths.isEmpty else { return [] }
        return await MainActor.run { bridge?.busyPaths(paths, quiet: quiet) ?? [] }
    }

    func flush(_ paths: [String]) async {
        guard !paths.isEmpty else { return }
        await MainActor.run {
            if let bridge { return bridge.flush(paths) }
            for path in paths { context.emit(NoteWillRead(path: path, pluginID: pluginID)) }
        }
    }

    func reload(_ paths: [String]) async -> [String] {
        guard !paths.isEmpty else { return [] }
        return await MainActor.run {
            if let bridge { return bridge.reload(paths) }
            for path in paths { context.emit(NoteDidChange(path: path, pluginID: pluginID)) }
            return []
        }
    }

    func write(_ path: String, _ data: Data) async throws {
        try await MainActor.run { try context.vault.writeData(path, data) }
    }
}
