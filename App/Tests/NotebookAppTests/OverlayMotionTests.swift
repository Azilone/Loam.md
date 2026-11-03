import PluginKitUI
import XCTest
@testable import NotebookApp

final class ToastMotionTests: XCTestCase {
    func testASwipeDownPastTheThresholdDismisses() {
        XCTAssertTrue(ToastSwipe.shouldDismiss(translation: ToastSwipe.dismissDistance, predicted: 0))
        XCTAssertFalse(ToastSwipe.shouldDismiss(translation: ToastSwipe.dismissDistance - 1, predicted: 0))
    }

    func testAShortFlickDownDismissesButUpOrStillDoesNot() {
        XCTAssertTrue(ToastSwipe.shouldDismiss(translation: 8, predicted: ToastSwipe.flickDistance))
        XCTAssertFalse(ToastSwipe.shouldDismiss(translation: 2, predicted: 500), "a tremor is not a swipe")
        XCTAssertFalse(ToastSwipe.shouldDismiss(translation: -40, predicted: -200))
    }

    func testDownFollowsTheHandAndUpIsHeldBack() {
        XCTAssertEqual(ToastSwipe.offset(for: 30), 30)
        XCTAssertEqual(ToastSwipe.offset(for: 0), 0)
        XCTAssertLessThan(ToastSwipe.offset(for: -100), 0)
        XCTAssertGreaterThan(ToastSwipe.offset(for: -100), -20, "dragging up stretches only a little")
    }

    func testTheToastFadesAsItIsTakenDown() {
        XCTAssertEqual(ToastSwipe.opacity(for: 0), 1)
        XCTAssertEqual(ToastSwipe.opacity(for: -10), 1)
        XCTAssertLessThan(ToastSwipe.opacity(for: 60), 1)
        XCTAssertGreaterThanOrEqual(ToastSwipe.opacity(for: 1000), 0.35)
    }
}

@MainActor
final class ToastTimerTests: XCTestCase {
    private func wait(_ milliseconds: Int) async {
        try? await Task.sleep(for: .milliseconds(milliseconds))
    }

    func testThePointerOverAToastHoldsItsTimer() async {
        let runner = CommandRunner(toastDuration: .milliseconds(60), toastGrace: .milliseconds(30)) { _ in nil }
        runner.show("Read me", isError: false)
        runner.holdToast(true)
        await wait(200)
        XCTAssertEqual(runner.toast?.text, "Read me", "held: still there long after its time")
    }

    func testLeavingLetsItGoAfterAtLeastTheGrace() async {
        let runner = CommandRunner(toastDuration: .milliseconds(60), toastGrace: .milliseconds(150)) { _ in nil }
        runner.show("Read me", isError: false)
        await wait(40)
        runner.holdToast(true)
        await wait(100)
        runner.holdToast(false)
        await wait(60)
        XCTAssertNotNil(runner.toast, "the grace has not run out")
        await wait(250)
        XCTAssertNil(runner.toast)
    }

    func testANewToastRestartsTheTimerEvenWhileHeld() async {
        let runner = CommandRunner(toastDuration: .milliseconds(80), toastGrace: .milliseconds(30)) { _ in nil }
        runner.show("One", isError: false)
        runner.holdToast(true)
        runner.show("Two", isError: false)
        await wait(160)
        XCTAssertNil(runner.toast, "a message that replaced the held one keeps its own time")
    }

    func testDismissingStopsTheTimer() async {
        let runner = CommandRunner(toastDuration: .milliseconds(40)) { _ in nil }
        runner.show("One", isError: false)
        runner.dismissToast()
        runner.show("Two", isError: false)
        XCTAssertEqual(runner.toast?.text, "Two")
        runner.holdToast(false)
        XCTAssertEqual(runner.toast?.text, "Two")
    }
}
