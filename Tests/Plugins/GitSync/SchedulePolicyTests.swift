import XCTest
@testable import GitSyncPlugin

final class SchedulePolicyTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    private func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

    private func armed(foreground: Bool = false) -> SchedulePolicy {
        var policy = SchedulePolicy()
        policy.armed = true
        policy.foreground = foreground
        policy.lastAttempt = t0
        return policy
    }

    func testNothingRunsUntilArmed() {
        var policy = SchedulePolicy()
        policy.wrote(at: t0)
        policy.setForeground(true, at: t0)
        XCTAssertNil(policy.due(now: t0))
    }

    func testABurstOfWritesMakesOneCommitAfterTheLastOne() {
        var policy = armed()
        for second in [0.0, 10, 20] { policy.wrote(at: at(second)) }
        XCTAssertEqual(policy.due(now: at(20)), at(50))
        policy.started(at: at(50), network: true)
        XCTAssertNil(policy.due(now: at(50)), "in the background, nothing else is pending")
    }

    func testWritingNonStopStillCommitsEveryFiveMinutes() {
        var policy = armed()
        for second in stride(from: 0.0, through: 400, by: 10) { policy.wrote(at: at(second)) }
        XCTAssertEqual(policy.due(now: at(400)), at(300))
    }

    func testTheRemoteIsCheckedOnlyInFront() {
        var policy = armed()
        XCTAssertNil(policy.due(now: at(1000)))
        policy.setForeground(true, at: at(30))
        XCTAssertEqual(policy.due(now: at(30)), at(300), "the last check is under a minute old: no immediate sync")
        policy.setForeground(true, at: at(90))
        XCTAssertEqual(policy.due(now: at(90)), at(90), "coming to the front after a minute syncs at once")
    }

    func testOfflineBacksOffAndCommitsStayLocal() {
        var policy = armed(foreground: true)
        let offline = CycleOutcome(status: SyncStatus(state: .offline), networkFailure: .offline)
        policy.started(at: at(0), network: true)
        policy.finished(offline, at: at(0))
        XCTAssertFalse(policy.networkAllowed(at: at(30)))
        XCTAssertTrue(policy.networkAllowed(at: at(60)))
        policy.started(at: at(60), network: true)
        policy.finished(offline, at: at(60))
        XCTAssertEqual(policy.offlineUntil, at(180))
        policy.wrote(at: at(70))
        XCTAssertFalse(policy.options(at: at(100)).network, "a commit still runs, without the network")
        policy.finished(CycleOutcome(status: SyncStatus(state: .synced), reachedRemote: true), at: at(200))
        XCTAssertNil(policy.offlineUntil)
        XCTAssertEqual(policy.failures, 0)
    }

    func testRefusedCredentialsPauseTheNetworkUntilASyncByHand() {
        var policy = armed(foreground: true)
        policy.finished(CycleOutcome(status: SyncStatus(state: .attention), networkFailure: .authentication), at: at(0))
        XCTAssertFalse(policy.networkAllowed(at: at(10_000)))
        XCTAssertNil(policy.due(now: at(10_000)))
        policy.manual()
        XCTAssertTrue(policy.networkAllowed(at: at(10_000)))
    }

    func testAMergeWaitingForTypingRetriesThenGoesAhead() {
        var policy = armed()
        let deferred = CycleOutcome(status: SyncStatus(state: .syncing), mergeDeferred: true)
        policy.finished(deferred, at: at(0))
        XCTAssertEqual(policy.due(now: at(0)), at(5))
        XCTAssertFalse(policy.options(at: at(5)).forceMerge)
        policy.finished(deferred, at: at(100))
        XCTAssertTrue(policy.options(at: at(120)).forceMerge, "after two minutes the merge goes ahead")
        policy.finished(CycleOutcome(status: SyncStatus(state: .synced)), at: at(121))
        XCTAssertNil(policy.deferredSince)
    }

    func testAPassingProblemRetriesSoon() {
        var policy = armed()
        policy.finished(CycleOutcome(status: SyncStatus(state: .syncing), retrySoon: true), at: at(0))
        XCTAssertEqual(policy.due(now: at(0)), at(30))
    }

    func testTheSchedulerRunsOneCycleAtATimeAndOneMoreForATriggerDuringIt() async {
        let counter = Counter()
        let scheduler = SyncScheduler(cycle: { _ in
            await counter.enter()
            try? await Task.sleep(nanoseconds: 50_000_000)
            await counter.leave()
            return CycleOutcome(status: SyncStatus(state: .synced))
        })
        scheduler.update { policy, _ in
            policy.armed = true
            policy.immediate = true
        }
        try? await Task.sleep(nanoseconds: 10_000_000)
        scheduler.update { policy, _ in policy.immediate = true }
        try? await Task.sleep(nanoseconds: 300_000_000)
        let (runs, _) = await counter.result
        XCTAssertEqual(runs, 2, "the trigger during the first cycle gives exactly one more")
        scheduler.update { policy, _ in policy.immediate = true }
        _ = await scheduler.runNow(CycleOptions())
        try? await Task.sleep(nanoseconds: 300_000_000)
        scheduler.stop()
        let (total, overlap) = await counter.result
        XCTAssertGreaterThanOrEqual(total, 3)
        XCTAssertFalse(overlap, "two cycles never run at once")
    }
}

private actor Counter {
    private var running = 0
    private var runs = 0
    private var overlapped = false

    func enter() {
        running += 1
        runs += 1
        if running > 1 { overlapped = true }
    }

    func leave() { running -= 1 }

    var result: (Int, Bool) { (runs, overlapped) }
}
