import Foundation

/// A typed handle for a service. Declare keys next to the service protocol:
///
///     extension ServiceKey where Service == Greeter {
///         static var greeter: ServiceKey<Greeter> { ServiceKey("greeter") }
///     }
///
/// The `id` is the string used in `PluginManifest.provides` and `requires`.
public struct ServiceKey<Service> {
    public let id: String

    public init(_ id: String) {
        self.id = id
    }
}

public enum ServiceError: Error, Equatable {
    case alreadyProvided(id: String)
}
