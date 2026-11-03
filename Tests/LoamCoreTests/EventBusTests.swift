import Foundation
import PluginKit
import XCTest
@testable import LoamCore

/// Reads on background queues (the note index's) emit `NoteWillRead` while the main thread adds and removes listeners.
final class EventBusTests: XCTestCase {
    func testEmitsFromManyThreadsWhileListenersComeAndGo() {
        let bus = EventBus()
        let count = NSLock()
        var seen = 0
        let stop = bus.on(NoteWillRead.self) { _ in count.lock(); seen += 1; count.unlock() }
        let done = expectation(description: "emitted")
        DispatchQueue.global().async {
            DispatchQueue.concurrentPerform(iterations: 2000) { index in
                bus.emit(NoteWillRead(path: "\(index).md", pluginID: "test"))
            }
            done.fulfill()
        }
        for _ in 0..<500 { bus.on(NoteWillRead.self) { _ in }() }
        wait(for: [done], timeout: 30)
        stop()
        XCTAssertEqual(seen, 2000)
    }
}
