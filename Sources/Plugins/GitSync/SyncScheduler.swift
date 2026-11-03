import Foundation

/// When the next sync is due, and how it may run. Pure: every input carries its time, so tests drive it with
/// made-up dates. The rules keep the sync light: nothing runs in the background but a pending commit, and the
/// remote is checked only while the app is in front.
struct SchedulePolicy: Equatable {
    /// Wait this long after the last change, so a burst of typing makes one commit.
    var commitDelay: TimeInterval = 30
    /// Check the remote this often while the app is in front.
    var pullInterval: TimeInterval = 300
    /// Commit at least this often while changes keep coming.
    var longestWriteWait: TimeInterval = 300
    /// Coming to the front checks the remote, unless the last check is more recent than this.
    var focusGap: TimeInterval = 60
    /// After a passing problem (a lock, a save racing the merge).
    var retryDelay: TimeInterval = 30
    /// A merge waiting for the user to stop typing is tried again this often…
    var deferRetry: TimeInterval = 5
    /// …and goes ahead anyway after this long (its notes are saved first, and the post-merge check keeps their text).
    var longestDefer: TimeInterval = 120
    /// How long the network rests after each failed attempt in a row.
    static let backoff: [TimeInterval] = [60, 120, 300, 600, 1800]

    /// Automatic sync is on and the app said whether it is in front.
    var armed = false
    var foreground = false
    var firstWrite: Date?
    var lastWrite: Date?
    /// The last cycle that used the network.
    var lastAttempt: Date?
    var immediate = false
    var retryAt: Date?
    var deferredSince: Date?
    /// The remote was unreachable: no network before this.
    var offlineUntil: Date?
    var failures = 0
    /// The remote refused the credentials: no network until a manual sync or a settings change.
    var authPaused = false

    mutating func wrote(at now: Date) {
        if firstWrite == nil { firstWrite = now }
        lastWrite = now
    }

    mutating func setForeground(_ value: Bool, at now: Date) {
        foreground = value
        guard value, lastAttempt.map({ now.timeIntervalSince($0) >= focusGap }) ?? true else { return }
        immediate = true
        if offlineUntil != nil { offlineUntil = now }
    }

    /// A sync asked for by the user: everything that holds the network back is lifted.
    mutating func manual() {
        authPaused = false
        offlineUntil = nil
    }

    /// When the next cycle should run; `nil` when nothing is pending.
    func due(now: Date) -> Date? {
        guard armed else { return nil }
        if immediate { return now }
        var dates: [Date] = []
        if let firstWrite, let lastWrite {
            dates.append(min(lastWrite.addingTimeInterval(commitDelay), firstWrite.addingTimeInterval(longestWriteWait)))
        }
        if foreground, !authPaused {
            let next = (lastAttempt ?? .distantPast).addingTimeInterval(pullInterval)
            dates.append(max(next, offlineUntil ?? .distantPast))
        }
        if let retryAt { dates.append(retryAt) }
        return dates.min()
    }

    func networkAllowed(at now: Date) -> Bool {
        !authPaused && (offlineUntil.map { now >= $0 } ?? true)
    }

    func options(at now: Date) -> CycleOptions {
        var options = CycleOptions()
        options.network = networkAllowed(at: now)
        options.forceMerge = deferredSince.map { now.timeIntervalSince($0) >= longestDefer } ?? false
        return options
    }

    /// A cycle starts: the changes so far are in it.
    mutating func started(at now: Date, network: Bool) {
        firstWrite = nil
        lastWrite = nil
        immediate = false
        retryAt = nil
        if network { lastAttempt = now }
    }

    mutating func finished(_ outcome: CycleOutcome, at now: Date) {
        switch outcome.networkFailure {
        case .offline?:
            offlineUntil = now.addingTimeInterval(Self.backoff[min(failures, Self.backoff.count - 1)])
            failures += 1
        case .authentication?:
            authPaused = true
        default:
            if outcome.reachedRemote {
                offlineUntil = nil
                failures = 0
            }
        }
        if outcome.mergeDeferred {
            if deferredSince == nil { deferredSince = now }
            retryAt = now.addingTimeInterval(deferRetry)
        } else {
            deferredSince = nil
        }
        if outcome.retrySoon { retryAt = now.addingTimeInterval(retryDelay) }
    }
}

/// Runs the cycles `SchedulePolicy` asks for, one at a time, off the main thread. Pokes (a change, the app coming
/// to the front, new settings) wake it to look again.
final class SyncScheduler: @unchecked Sendable {
    private let lock = NSLock()
    private var policy = SchedulePolicy()
    private var task: Task<Void, Never>?
    private var sleeper: CheckedContinuation<Void, Never>?
    private var poked = false
    private var stopped = false
    private let gate = SerialGate()
    private let clock: @Sendable () -> Date
    private let cycle: @Sendable (CycleOptions) async -> CycleOutcome
    private let willStart: @Sendable () -> Void
    private let didFinish: @Sendable (CycleOutcome) -> Void

    init(clock: @escaping @Sendable () -> Date = { Date() },
         cycle: @escaping @Sendable (CycleOptions) async -> CycleOutcome,
         willStart: @escaping @Sendable () -> Void = {},
         didFinish: @escaping @Sendable (CycleOutcome) -> Void = { _ in }) {
        self.clock = clock
        self.cycle = cycle
        self.willStart = willStart
        self.didFinish = didFinish
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    var state: SchedulePolicy { locked { policy } }

    /// Changes the policy's inputs and looks again. Starts the loop on first use.
    func update(_ change: (inout SchedulePolicy, Date) -> Void) {
        let start: Bool = locked {
            change(&policy, clock())
            return task == nil && !stopped
        }
        if start {
            let loop = Task.detached { [self] in await run() }
            locked { task = loop }
        }
        poke()
    }

    func stop() {
        let loop: Task<Void, Never>? = locked {
            stopped = true
            return task
        }
        loop?.cancel()
        poke()
    }

    /// Runs a cycle now, after the one running (`sync.now`, `sync.setup`).
    func runNow(_ options: CycleOptions) async -> CycleOutcome {
        locked {
            policy.manual()
            policy.started(at: clock(), network: options.network)
        }
        willStart()
        let outcome = await gate.run { [cycle] in await cycle(options) }
        locked { policy.finished(outcome, at: clock()) }
        didFinish(outcome)
        poke()
        return outcome
    }

    private func run() async {
        while !locked({ stopped }) {
            let next: (wait: TimeInterval?, options: CycleOptions?) = locked {
                let now = clock()
                guard let due = policy.due(now: now) else { return (nil, nil) }
                guard due <= now else { return (due.timeIntervalSince(now), nil) }
                let options = policy.options(at: now)
                policy.started(at: now, network: options.network)
                return (nil, options)
            }
            if let options = next.options {
                willStart()
                let outcome = await gate.run { [cycle] in await cycle(options) }
                locked { policy.finished(outcome, at: clock()) }
                didFinish(outcome)
            } else {
                await sleep(next.wait)
            }
        }
    }

    /// Sleeps `seconds` (forever if `nil`), or until the next poke.
    private func sleep(_ seconds: TimeInterval?) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let resumeNow: Bool = locked {
                if poked || stopped {
                    poked = false
                    return true
                }
                sleeper = continuation
                return false
            }
            if resumeNow { return continuation.resume() }
            if let seconds {
                DispatchQueue.global().asyncAfter(deadline: .now() + max(seconds, 0.01)) { [weak self] in self?.wake() }
            }
        }
    }

    private func wake() {
        locked { () -> CheckedContinuation<Void, Never>? in
            defer { sleeper = nil }
            return sleeper
        }?.resume()
    }

    private func poke() {
        locked { () -> CheckedContinuation<Void, Never>? in
            guard let sleeper else {
                poked = true
                return nil
            }
            self.sleeper = nil
            return sleeper
        }?.resume()
    }
}

/// Runs async work one piece at a time, in the order asked: two syncs never overlap.
actor SerialGate {
    private var tail: Task<Void, Never>?

    func run<T: Sendable>(_ body: @escaping @Sendable () async -> T) async -> T {
        let previous = tail
        let task = Task { () -> T in
            await previous?.value
            return await body()
        }
        tail = Task { _ = await task.value }
        return await task.value
    }
}
