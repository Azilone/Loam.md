import Foundation
import PluginKit

public enum PluginError: Error, Equatable {
    case duplicate(id: String)
    case duplicateProvider(service: String, plugins: [String])
    case missingService(plugin: String, service: String)
    case missingTools(plugin: String, tools: [String])
    case providedServiceMissing(plugin: String, service: String)
    case cycle(ids: [String])
}

/// Registers plugins, orders them by the services they provide and require, and activates
/// them. `activateAll` is strict (a failure rolls back the whole call); `apply` reconciles the
/// active set with an enabled set and keeps going around plugins that cannot start.
public final class PluginHost {
    let kernel: Kernel
    var types: [String: Plugin.Type] = [:]
    /// In activation order, so walking it backwards stops users before their providers.
    var active: [(id: String, plugin: Plugin, context: ScopedContext)] = []

    public init(kernel: Kernel) {
        self.kernel = kernel
    }

    public func register(_ type: Plugin.Type) throws {
        let id = type.manifest.id
        guard types[id] == nil else { throw PluginError.duplicate(id: id) }
        types[id] = type
    }

    /// Every registered plugin, active or not, sorted by id.
    public var manifests: [PluginManifest] {
        types.values.map { $0.manifest }.sorted { $0.id < $1.id }
    }

    public var activeIDs: [String] { active.map(\.id) }

    public func isActive(_ id: String) -> Bool {
        active.contains { $0.id == id }
    }

    /// Manifests ordered so that every provider comes before the plugins that require its
    /// service. `enabled == nil` means every registered plugin; a smaller set is safe mode.
    /// A requirement already in the kernel's service registry (a host service, or a service of
    /// an active plugin) counts as met. Optional requirements only order: a missing provider is
    /// fine, and an optional edge that would close a cycle is ignored.
    public func resolveOrder(enabled: Set<String>? = nil) throws -> [PluginManifest] {
        let ids = (enabled ?? Set(types.keys)).intersection(types.keys).sorted()

        var providers: [String: String] = [:]
        for id in ids {
            for service in types[id]!.manifest.provides {
                if let existing = providers[service] {
                    throw PluginError.duplicateProvider(service: service, plugins: [existing, id])
                }
                providers[service] = id
            }
        }
        return try dependencyOrder(ids, providers: providers, strict: true)
    }

    /// Activates the enabled plugins that are not active yet. If one fails, the plugins this call
    /// activated are deactivated again and the error is thrown; plugins active before stay active.
    public func activateAll(enabled: Set<String>? = nil) throws {
        let order = try resolveOrder(enabled: enabled)
        var started: [String] = []
        do {
            for manifest in order where !isActive(manifest.id) {
                try activate(manifest)
                started.append(manifest.id)
            }
        } catch {
            for id in started.reversed() { stop(id) }
            throw error
        }
    }

    public func deactivateAll() {
        for entry in active.reversed() {
            entry.plugin.deactivate()
            entry.context.scope.dispose()
        }
        active.removeAll()
    }

    // MARK: - Shared steps

    /// Orders `ids` depth first along their requirements, providers first. Strict ordering throws on a
    /// missing service or a cycle; lenient ordering ignores them and leaves the check to activation time.
    func dependencyOrder(_ ids: [String], providers: [String: String], strict: Bool) throws -> [PluginManifest] {
        var edges: [String: [String]] = [:]
        for id in ids {
            edges[id] = types[id]!.manifest.requires.compactMap { providers[$0] }.filter { $0 != id }
        }
        // Optional edges are added one by one, each only if it closes no cycle.
        var optionalEdges: [String: [String]] = [:]
        for id in ids {
            for service in types[id]!.manifest.optionalRequires {
                guard let provider = providers[service], provider != id,
                      !edges[id]!.contains(provider), !reaches(from: provider, to: id, edges) else { continue }
                edges[id]!.append(provider)
                optionalEdges[id, default: []].append(provider)
            }
        }

        var ordered: [PluginManifest] = []
        var done: Set<String> = []
        var visiting: [String] = []

        func visit(_ id: String) throws {
            if done.contains(id) { return }
            if let start = visiting.firstIndex(of: id) {
                if strict { throw PluginError.cycle(ids: Array(visiting[start...]) + [id]) }
                return
            }
            visiting.append(id)
            let manifest = types[id]!.manifest
            for service in manifest.requires {
                guard let provider = providers[service] else {
                    if strict && !kernel.services.isProvided(id: service) {
                        throw PluginError.missingService(plugin: id, service: service)
                    }
                    continue
                }
                if provider != id { try visit(provider) }
            }
            for provider in optionalEdges[id] ?? [] { try visit(provider) }
            visiting.removeLast()
            done.insert(id)
            ordered.append(manifest)
        }

        for id in ids { try visit(id) }
        return ordered
    }

    private func reaches(from start: String, to target: String, _ edges: [String: [String]]) -> Bool {
        var seen: Set<String> = []
        var stack = [start]
        while let id = stack.popLast() {
            if id == target { return true }
            if seen.insert(id).inserted { stack.append(contentsOf: edges[id] ?? []) }
        }
        return false
    }

    /// The programs a plugin cannot run without (`Plugin.requiresTools`), and those it uses when installed.
    public func requiredTools(of id: String) -> [String] { types[id]?.requiresTools ?? [] }
    public func optionalTools(of id: String) -> [String] { types[id]?.optionalTools ?? [] }

    /// The `requiresTools` of a plugin that are not installed, in the order it declares them.
    public func missingTools(of id: String) -> [String] {
        requiredTools(of: id).filter { kernel.tools.locate($0) == nil }
    }

    /// Activates one plugin. On failure only its own registrations are undone.
    func activate(_ manifest: PluginManifest) throws {
        let missing = missingTools(of: manifest.id)
        guard missing.isEmpty else { throw PluginError.missingTools(plugin: manifest.id, tools: missing) }
        let plugin = types[manifest.id]!.init()
        let context = ScopedContext(pluginID: manifest.id, kernel: kernel)
        do {
            try plugin.activate(context: context)
            for service in manifest.provides where !kernel.services.isProvided(id: service) {
                throw PluginError.providedServiceMissing(plugin: manifest.id, service: service)
            }
        } catch {
            context.scope.dispose()
            throw error
        }
        active.append((manifest.id, plugin, context))
    }

    /// Deactivates one plugin without looking at who uses it.
    func stop(_ id: String) {
        guard let index = active.firstIndex(where: { $0.id == id }) else { return }
        let entry = active.remove(at: index)
        entry.plugin.deactivate()
        entry.context.scope.dispose()
    }
}
