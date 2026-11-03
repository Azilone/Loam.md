import Foundation

/// Runs main-actor code from the kernel's callbacks (event listeners), which Swift cannot prove run on the main
/// thread. The kernel is main-thread only, so this is normally a direct call; a command handler that emits an event
/// from another thread is answered by blocking until the main thread ran the body, rather than racing on UI state.
enum MainThread {
    static func sync(_ body: @MainActor @Sendable () -> Void) {
        if Thread.isMainThread {
            MainActor.assumeIsolated(body)
        } else {
            DispatchQueue.main.sync { MainActor.assumeIsolated(body) }
        }
    }
}
