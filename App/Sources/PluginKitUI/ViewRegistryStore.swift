import Foundation
import Observation

/// The standard `ViewRegistry`. Observable, so the shell's "Open with" menu and open tabs refresh when a plugin
/// loads or unloads. The shell provides it as `ui.views`; tests use it as the real thing.
@MainActor
@Observable
public final class ViewRegistryStore: ViewRegistry {
    private var entries = RegistryEntries<ViewType>()

    public init() {}

    /// Every registered type, by id.
    public var all: [ViewType] { entries.values.sorted { $0.id < $1.id } }

    public func register(_ type: ViewType) -> @MainActor () -> Void {
        let token = entries.insert(type, id: type.id)
        return { [weak self] in self?.entries.remove(token) }
    }

    public func viewTypes(for resource: Resource) -> [ViewType] {
        let types = entries.values.filter { $0.canOpen(resource) }
        let preferred = Set(types.filter { $0.prefers(resource) }.map(\.id))
        return types.sorted {
            let (a, b) = (preferred.contains($0.id), preferred.contains($1.id))
            if a != b { return a }
            return $0.priority != $1.priority ? $0.priority > $1.priority : $0.id < $1.id
        }
    }
}
