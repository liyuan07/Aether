import XCTest
@testable import TimerFeature
final class ManualCountdownTests: XCTestCase {
    func testMissedCallbacksIncludingSleepDoNotLoseTime() {
        var timer = ManualCountdown()
        XCTAssertTrue(timer.start(duration: 1200, now: 100))
        XCTAssertEqual(timer.remaining(at: 700), 600)
        XCTAssertEqual(timer.remaining(at: 1312), -12)
    }
    func testPauseAndResumePreserveFractionalRemainingTime() {
        var timer = ManualCountdown()
        _ = timer.start(duration: 60, now: 100)
        timer.pause(at: 110.25)
        XCTAssertEqual(timer.remaining(at: 500), 49.75)
        timer.resume(at: 500)
        XCTAssertEqual(timer.remaining(at: 520), 29.75)
    }
    func testOvertimeCanPauseAndContinue() {
        var timer = ManualCountdown()
        _ = timer.start(duration: 10, now: 0)
        timer.pause(at: 15)
        XCTAssertEqual(timer.remaining(at: 100), -5)
        timer.resume(at: 100)
        XCTAssertEqual(timer.remaining(at: 103), -8)
    }
    func testInvalidStartDoesNotInterruptExistingTimer() {
        var timer = ManualCountdown()
        _ = timer.start(duration: 10, now: 0)
        for duration in [0, -1, .infinity, .nan] {
            XCTAssertFalse(timer.start(duration: duration, now: 2))
            XCTAssertEqual(timer.remaining(at: 2), 8)
        }
    }
    func testReplacementAndStopClearPreviousState() {
        var timer = ManualCountdown()
        _ = timer.start(duration: 10, now: 0)
        timer.pause(at: 3)
        _ = timer.start(duration: 20, now: 5)
        XCTAssertFalse(timer.isPaused)
        XCTAssertEqual(timer.remaining(at: 6), 19)
        timer.stop()
        XCTAssertFalse(timer.isActive)
        XCTAssertEqual(timer.remaining(at: 500), 0)
    }
}
