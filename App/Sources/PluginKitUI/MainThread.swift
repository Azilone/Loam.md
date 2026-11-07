import Foundation
import os

/// Runs main-actor code from a place Swift cannot prove is the main thread: an event listener (events come from any
/// thread: a note read by a worker sends `NoteWillRead`), a command handler, a callback.
///
/// Every plugin once had its own copy of `DispatchQueue.main.sync`, which froze the app for good when the main thread
/// was itself waiting for the calling thread (a parallel loop on the main thread whose worker sends an event: a note
/// dropped on a folder). `run` waits at most `patience`: past it the caller goes on, the body still runs once the main
/// thread is free, and the stall is written to `~/Library/Logs/Loam/Hangs` with the waiting thread's stack. A
/// UI rule (`UIRulesTests`) keeps `DispatchQueue.main.sync` out of the app's sources.
public enum MainThread {
    /// How long a background thread waits for the main thread before going on without it.
    public static let patience: TimeInterval = 2

    /// Runs `body` on the main thread: at once when called on it; from another thread, waits until the main thread
    /// ran it, at most `patience`. Returns false when it went on without waiting for the end (the body then runs
    /// later).
    @discardableResult
    public static func run(_ body: @escaping @MainActor @Sendable () -> Void) -> Bool {
        if Thread.isMainThread {
            MainActor.assumeIsolated(body)
            return true
        }
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.main.async {
            MainActor.assumeIsolated(body)
            done.signal()
        }
        if done.wait(timeout: .now() + patience) == .success { return true }
        HangLog.record(
            "main-thread-wait",
            "A thread waited \(patience) s for the main thread and went on without it: the main thread was busy or "
                + "waiting for this thread.\n\nWaiting thread:\n" + Thread.callStackSymbols.joined(separator: "\n")
        )
        return false
    }

    /// The value `body` gives on the main thread, or nil when the main thread did not answer within `patience`.
    public static func value<T: Sendable>(_ body: @escaping @MainActor @Sendable () -> T) -> T? {
        if Thread.isMainThread { return MainActor.assumeIsolated(body) }
        let box = OSAllocatedUnfairLock<T?>(initialState: nil)
        let answered = run {
            let value = body()
            box.withLock { $0 = value }
        }
        return answered ? box.withLock { $0 } : nil
    }
}

/// Watches the main thread from a thread of its own: when it does not answer for `threshold`, the main thread's
/// stack is sampled (`/usr/bin/sample`) into `~/Library/Logs/Loam/Hangs`, once per stall. A freeze then leaves the
/// line of code that held the main thread, where macOS writes no report for a hang the user ends with Force Quit.
public enum HangWatchdog {
    /// How long the main thread may stay silent before a stall is recorded.
    public static let threshold: TimeInterval = 3

    private static let started = OSAllocatedUnfairLock(initialState: false)

    /// Starts the watchdog; later calls do nothing. Called by the app at launch.
    public static func start() {
        guard started.withLock({ let was = $0; $0 = true; return !was }) else { return }
        let thread = Thread { watch() }
        thread.name = "loam-hang-watchdog"
        thread.qualityOfService = .utility
        thread.start()
    }

    private static func watch() {
        let beat = OSAllocatedUnfairLock(initialState: Date())
        var reported = false
        while true {
            DispatchQueue.main.async { beat.withLock { $0 = Date() } }
            Thread.sleep(forTimeInterval: 0.5)
            let silent = Date().timeIntervalSince(beat.withLock { $0 })
            if silent < threshold {
                reported = false
            } else if !reported {
                reported = true
                sampleMainThread(silentFor: silent)
            }
        }
    }

    private static func sampleMainThread(silentFor seconds: TimeInterval) {
        let pid = ProcessInfo.processInfo.processIdentifier
        guard let url = HangLog.record(
            "main-thread-hang",
            "The main thread did not answer for \(Int(seconds)) s. Sample of every thread follows.\n"
        ) else { return }
        let sample = Process()
        sample.executableURL = URL(fileURLWithPath: "/usr/bin/sample")
        sample.arguments = [String(pid), "2", "-mayDie", "-file", url.path + ".sample.txt"]
        sample.standardOutput = FileHandle.nullDevice
        sample.standardError = FileHandle.nullDevice
        try? sample.run()
    }
}

/// Stalls written for later: a fault in the unified log and a file in `~/Library/Logs/Loam/Hangs`.
enum HangLog {
    private static let log = Logger(subsystem: "com.azilone.loam", category: "hang")

    /// Where tests write instead of the user's logs.
    nonisolated(unsafe) static var folderOverride: URL?

    /// The folder stalls go to.
    static var folder: URL {
        folderOverride
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Loam/Hangs")
    }

    /// Writes `text` to a new file named after `kind` and the time; returns it, nil when it could not be written.
    @discardableResult
    static func record(_ kind: String, _ text: String) -> URL? {
        log.fault("\(kind, privacy: .public): \(text, privacy: .public)")
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate, .withTime, .withColonSeparatorInTime]
        let stamp = formatter.string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let url = folder.appendingPathComponent("\(kind)-\(stamp)-\(UUID().uuidString.prefix(4)).txt")
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            return nil
        }
    }
}
