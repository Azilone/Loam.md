import Foundation
import PluginKit

/// Holds the services plugins provide to each other. Main-thread use only.
public final class ServiceRegistry {
    private var services: [String: Any] = [:]

    public init() {}

    /// Returns the function that removes the service again.
    public func provide<S>(_ key: ServiceKey<S>, _ service: S) throws -> () -> Void {
        guard services[key.id] == nil else { throw ServiceError.alreadyProvided(id: key.id) }
        services[key.id] = service
        let id = key.id
        return { [weak self] in self?.services[id] = nil }
    }

    public func service<S>(_ key: ServiceKey<S>) -> S? {
        services[key.id] as? S
    }

    public func isProvided(id: String) -> Bool {
        services[id] != nil
    }
}
