import Foundation
import os

/// Where a board spends its time: named intervals around the work done on each frame, as signposts (they show in
/// Instruments, under the `canvas` category) and, when `isCounting`, as totals the benchmark prints.
enum BoardProfile {
    static let signposter = OSSignposter(subsystem: "loam", category: "canvas")
    private struct State {
        var isCounting = false
        var totals: [String: (count: Int, nanoseconds: UInt64)] = [:]
    }
    private static let state = OSAllocatedUnfairLock(initialState: State())

    static var isCounting: Bool {
        get { state.withLock { $0.isCounting } }
        set { state.withLock { $0.isCounting = newValue } }
    }

    static func reset() { state.withLock { $0.totals = [:] } }

    static func measure<T>(_ name: StaticString, _ work: () -> T) -> T {
        let interval = signposter.beginInterval(name)
        defer { signposter.endInterval(name, interval) }
        guard isCounting else { return work() }
        let start = DispatchTime.now().uptimeNanoseconds
        let result = work()
        let spent = DispatchTime.now().uptimeNanoseconds - start
        let key = "\(name)"
        state.withLock {
            let old = $0.totals[key] ?? (0, 0)
            $0.totals[key] = (old.count + 1, old.nanoseconds + spent)
        }
        return result
    }

    static var summary: String {
        state.withLock { $0.totals }.sorted { $0.value.nanoseconds > $1.value.nanoseconds }.map {
            String(format: "%@ %.2f ms x%d", $0.key, Double($0.value.nanoseconds) / 1_000_000 / Double(max(1, $0.value.count)),
                   $0.value.count)
        }.joined(separator: "; ")
    }
}
