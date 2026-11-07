import Foundation
import PluginKit

/// Turning single plugins on and off while the others keep running: what the plugin manager and
/// the `plugins.enable` / `plugins.disable` commands need.
extension PluginHost {
    /// Active plugins that need `id` to run: those that `requires` a service it provides, and theirs in
    /// turn. Listed in the order they would be deactivated, deepest dependents first. Optional users are
    /// not dependents: they stay active and see the service disappear.
    public func dependents(of id: String) -> [String] {
        guard let manifest = types[id]?.manifest else { return [] }
        var removed: Set<String> = [id]
        var lost = Set(manifest.provides)
        var changed = true
        while changed {
            changed = false
            for entry in active where !removed.contains(entry.id) {
                let entryManifest = types[entry.id]!.manifest
                guard entryManifest.requires.contains(where: lost.contains) else { continue }
                removed.insert(entry.id)
                lost.formUnion(entryManifest.provides)
                changed = true
            }
        }
        // Activation order puts providers first, so its reverse stops users first.
        return active.reversed().map(\.id).filter { $0 != id && removed.contains($0) }
    }

    /// Deactivates `id` and its dependents, dependents first. Returns the ids deactivated, in order;
    /// empty if `id` is not active.
    @discardableResult
    public func deactivate(_ id: String) -> [String] {
        guard isActive(id) else { return [] }
        let order = dependents(of: id) + [id]
        for target in order { stop(target) }
        return order
    }

    /// Makes the active set match `enabled` (`nil` means every registered plugin), without the
    /// all-or-nothing rule of `activateAll`: plugins no longer enabled are deactivated with their
    /// dependents, the others are activated in dependency order, and a plugin that cannot start is
    /// reported while the rest keep running. When a provider starts, its active optional users are
    /// restarted so they register their extras again. Calling it twice with one set changes nothing.
    @discardableResult
    public func apply(enabled: Set<String>?) -> ActivationReport {
        let target = (enabled ?? Set(types.keys)).intersection(types.keys)
        let before = Set(activeIDs)
        var report = ActivationReport()
        var stopped: [String] = []
        // Each plugin is tried at most once per call, which also ends restarts between optional cycles.
        var handled: Set<String> = []

        for entry in active.reversed() where !target.contains(entry.id) && isActive(entry.id) {
            stopped += deactivate(entry.id)
        }

        // Providers are chosen among the enabled plugins, active ones first, for the ordering and the
        // reasons. A second provider of one service fails when it registers it.
        var providers: [String: String] = [:]
        for id in activeIDs + target.sorted() where target.contains(id) {
            for service in types[id]!.manifest.provides where providers[service] == nil {
                providers[service] = id
            }
        }

        func start(_ manifest: PluginManifest) {
            let id = manifest.id
            guard !isActive(id), handled.insert(id).inserted else { return }
            for service in manifest.requires where !kernel.services.isProvided(id: service) {
                if let provider = providers[service], provider != id {
                    report.skipped[id] = "requires service '\(service)', whose provider '\(provider)' is not active"
                } else {
                    report.skipped[id] = "requires service '\(service)', which no enabled plugin provides"
                }
                return
            }
            // Not started, not failed: the plugin waits until the tools are installed and the host is asked again.
            let missing = missingTools(of: id)
            guard missing.isEmpty else {
                report.skipped[id] = "needs \(missing.joined(separator: ", ")), not installed"
                return
            }
            do {
                try activate(manifest)
            } catch {
                report.failed[id] = String(describing: error)
                return
            }
            report.activated.append(id)
            restartOptionalUsers(of: manifest)
        }

        func restartOptionalUsers(of manifest: PluginManifest) {
            let users = active.map(\.id).filter { user in
                user != manifest.id && !handled.contains(user)
                    && types[user]!.manifest.optionalRequires.contains(where: manifest.provides.contains)
            }
            for user in users where isActive(user) {
                let down = deactivate(user)
                stopped += down
                // Dependents brought down with the user start again even if this call already started them.
                handled.subtract(down)
                for id in down.reversed() { start(types[id]!.manifest) }
            }
        }

        // Ordering cannot fail here: unmet requirements and cycles are found when each plugin starts.
        let order = (try? dependencyOrder(target.sorted(), providers: providers, strict: false)) ?? []
        for manifest in order { start(manifest) }

        let after = Set(activeIDs)
        var seen: Set<String> = []
        report.activated = report.activated.filter { seen.insert($0).inserted }
        seen = []
        report.deactivated = stopped.filter { before.contains($0) && !after.contains($0) && seen.insert($0).inserted }
        return report
    }
}
