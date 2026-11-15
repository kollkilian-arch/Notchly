import XCTest
@testable import Notchly

final class TimerModelTests: XCTestCase {
    func testClockStringFormats() {
        XCTAssertEqual(clockString(0), "00:00")
        XCTAssertEqual(clockString(59), "00:59")
        XCTAssertEqual(clockString(8 * 60 + 42), "08:42")
        XCTAssertEqual(clockString(3600 + 2 * 60 + 3), "1:02:03")
        XCTAssertEqual(clockString(0.2), "00:01", "partial seconds round up so the display never shows 00:00 while running")
    }

    func testStartRunsAndCountsDown() {
        let timer = TimerModel()
        defer { timer.cancel() }
        timer.start(seconds: 90)
        XCTAssertEqual(timer.phase, .running)
        XCTAssertEqual(timer.total, 90)
        XCTAssertEqual(timer.remaining(), 90, accuracy: 1)
        XCTAssertEqual(timer.remaining(at: Date().addingTimeInterval(30)), 60, accuracy: 1)
        XCTAssertEqual(timer.remaining(at: Date().addingTimeInterval(500)), 0, "never negative")
    }

    func testZeroOrNegativeDurationDoesNotStart() {
        let timer = TimerModel()
        timer.start(seconds: 0)
        timer.start(seconds: -5)
        XCTAssertEqual(timer.phase, .idle)
    }

    func testPauseFreezesRemainingTimeAndResumeContinues() {
        let timer = TimerModel()
        defer { timer.cancel() }
        timer.start(seconds: 120)
        timer.pause()
        XCTAssertEqual(timer.phase, .paused)
        let frozen = timer.remaining()
        XCTAssertEqual(timer.remaining(at: Date().addingTimeInterval(60)), frozen, "paused time must not advance")
        timer.resume()
        XCTAssertEqual(timer.phase, .running)
        XCTAssertEqual(timer.remaining(), frozen, accuracy: 1)
    }

    func testAddingTimeWhileRunningAndPaused() {
        let timer = TimerModel()
        defer { timer.cancel() }
        timer.start(seconds: 60)
        timer.add(seconds: 60)
        XCTAssertEqual(timer.total, 120)
        XCTAssertEqual(timer.remaining(), 120, accuracy: 1)
        timer.pause()
        timer.add(seconds: 30)
        XCTAssertEqual(timer.total, 150)
        XCTAssertEqual(timer.remaining(), 150, accuracy: 1)
    }

    func testAddingTimeDoesNothingWhenIdle() {
        let timer = TimerModel()
        timer.add(seconds: 60)
        XCTAssertEqual(timer.phase, .idle)
        XCTAssertEqual(timer.total, 0)
    }

    func testCancelReturnsToIdle() {
        let timer = TimerModel()
        timer.start(seconds: 60)
        timer.cancel()
        XCTAssertEqual(timer.phase, .idle)
        XCTAssertEqual(timer.remaining(), 0)
    }

    func testFinishesWhenTheTimeIsUp() {
        UserDefaults.standard.set(false, forKey: Pref.timerSound)
        defer { UserDefaults.standard.removeObject(forKey: Pref.timerSound) }
        let timer = TimerModel()
        defer { timer.cancel() }
        timer.start(seconds: 0.2)
        let finished = expectation(description: "timer finishes")
        let poll = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { _ in
            if timer.phase == .finished { finished.fulfill() }
        }
        wait(for: [finished], timeout: 3)
        poll.invalidate()
        XCTAssertEqual(timer.remaining(), 0)
    }
}
