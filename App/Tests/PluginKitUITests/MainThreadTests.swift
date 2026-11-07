import Foundation
import os
import XCTest
@testable import PluginKitUI

/// `MainThread.run` never freezes the app: a thread that waits for a main thread which waits for it goes on after
/// `patience`, and the stall is recorded.
final class MainThreadTests: XCTestCase {
    private var logs: URL!

    override func setUpWithError() throws {
        logs = FileManager.default.temporaryDirectory.appendingPathComponent("loam-hangs-\(UUID().uuidString)")
        HangLog.folderOverride = logs
    }

    override func tearDown() {
        HangLog.folderOverride = nil
        try? FileManager.default.removeItem(at: logs)
    }

    func testOnTheMainThreadTheBodyRunsAtOnce() {
        let ran = OSAllocatedUnfairLock(initialState: false)
        XCTAssertTrue(MainThread.run { ran.withLock { $0 = true } })
        XCTAssertTrue(ran.withLock { $0 })
    }

    func testFromAnotherThreadItWaitsForTheBody() {
        let done = expectation(description: "worker")
        DispatchQueue.global().async {
            let ran = OSAllocatedUnfairLock(initialState: false)
            let answered = MainThread.run { ran.withLock { $0 = true } }
            XCTAssertTrue(answered)
            XCTAssertTrue(ran.withLock { $0 }, "the body ran before run returned")
            XCTAssertEqual(MainThread.value { 42 }, 42)
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
    }

    /// The deadlock of a note dropped on a folder: the main thread waits for a worker, the worker waits for the
    /// main thread. `DispatchQueue.main.sync` never returned; `run` returns after `patience`, records the stall, and
    /// the body still runs once the main thread is free.
    func testAMainThreadWaitingForTheCallerDoesNotFreeze() throws {
        let worker = DispatchSemaphore(value: 0)
        let answered = OSAllocatedUnfairLock<Bool?>(initialState: nil)
        let ran = OSAllocatedUnfairLock(initialState: false)
        DispatchQueue.global().async {
            let result = MainThread.run { ran.withLock { $0 = true } }
            answered.withLock { $0 = result }
            worker.signal()
        }
        // The main thread blocks on the worker, as `concurrentPerform` on the main thread did.
        XCTAssertEqual(worker.wait(timeout: .now() + MainThread.patience + 5), .success, "the worker froze")
        XCTAssertEqual(answered.withLock { $0 }, false)
        XCTAssertFalse(ran.withLock { $0 })
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertTrue(ran.withLock { $0 }, "the body ran once the main thread was free")
        let files = try FileManager.default.contentsOfDirectory(atPath: logs.path)
        XCTAssertEqual(files.filter { $0.hasPrefix("main-thread-wait") }.count, 1)
    }
}
