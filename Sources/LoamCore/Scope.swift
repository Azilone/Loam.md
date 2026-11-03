import Foundation

/// Collects the undo actions of everything one plugin registered.
public final class Scope {
    private var disposers: [() -> Void] = []

    public init() {}

    public func add(_ dispose: @escaping () -> Void) {
        disposers.append(dispose)
    }

    /// Runs every disposer, last registered first. Safe to call twice.
    public func dispose() {
        let pending = disposers
        disposers = []
        for dispose in pending.reversed() { dispose() }
    }
}
