import Foundation

/// Marker for values sent through the event bus.
public protocol PluginEvent {}

/// A waterfall listener. Call `next` to delegate, return without calling it to short-circuit.
public typealias Interceptor<E> = (E, (E) -> E) -> E
