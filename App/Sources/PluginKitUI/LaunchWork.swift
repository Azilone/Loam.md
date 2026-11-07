import Foundation

/// Work a plugin moves off the main thread at launch, so a large vault does not hold the window, then finishes on
/// the main actor. `pending` lets tests wait until the launch has settled.
@MainActor
public enum LaunchWork {
    public private(set) static var pending = 0
    /// Background parts still running. Read from any thread: a test inside a main-actor task cannot let the main
    /// queue run, so it waits for these, not for `pending`.
    nonisolated public static var running: Int {
        lock.lock()
        defer { lock.unlock() }
        return runningCount
    }
    nonisolated private static let lock = NSLock()
    nonisolated(unsafe) private static var runningCount = 0

    public static func run(_ work: @escaping @Sendable () -> Void, then done: @escaping @MainActor () -> Void) {
        pending += 1
        lock.lock()
        runningCount += 1
        lock.unlock()
        DispatchQueue.global(qos: .userInitiated).async {
            work()
            lock.lock()
            runningCount -= 1
            lock.unlock()
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    pending -= 1
                    done()
                }
            }
        }
    }
}
