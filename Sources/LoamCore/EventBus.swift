import Foundation
import PluginKit

/// Typed events with two dispatch modes: `emit` (observe) and `waterfall` (wrap, transform
/// or short-circuit). Safe from any thread (`NoteWillRead` is emitted by reads on background queues, such as the
/// index's); the handlers run on the emitting thread, outside the lock.
public final class EventBus {
    private struct Entry {
        let id: UUID
        let handler: Any
    }

    private let lock = NSLock()
    private var observers: [ObjectIdentifier: [Entry]] = [:]
    private var interceptors: [ObjectIdentifier: [Entry]] = [:]

    public init() {}

    /// Returns the function that removes the listener again.
    public func on<E: PluginEvent>(_ type: E.Type, _ handler: @escaping (E) -> Void) -> () -> Void {
        let key = ObjectIdentifier(type)
        let id = UUID()
        locked { observers[key, default: []].append(Entry(id: id, handler: handler)) }
        return { [weak self] in self?.locked { self?.observers[key]?.removeAll { $0.id == id } } }
    }

    public func intercept<E: PluginEvent>(_ type: E.Type, _ handler: @escaping Interceptor<E>) -> () -> Void {
        let key = ObjectIdentifier(type)
        let id = UUID()
        locked { interceptors[key, default: []].append(Entry(id: id, handler: handler)) }
        return { [weak self] in self?.locked { self?.interceptors[key]?.removeAll { $0.id == id } } }
    }

    public func emit<E: PluginEvent>(_ event: E) {
        let entries = locked { observers[ObjectIdentifier(E.self)] ?? [] }
        for entry in entries {
            if let handler = entry.handler as? (E) -> Void { handler(event) }
        }
    }

    public func waterfall<E: PluginEvent>(_ initial: E) -> E {
        let chain: [Interceptor<E>] = locked { interceptors[ObjectIdentifier(E.self)] ?? [] }
            .compactMap { $0.handler as? Interceptor<E> }
        func run(_ index: Int, _ value: E) -> E {
            guard index < chain.count else { return value }
            return chain[index](value) { run(index + 1, $0) }
        }
        return run(0, initial)
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}
