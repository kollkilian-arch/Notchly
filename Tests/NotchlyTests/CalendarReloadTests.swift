import AppKit
import XCTest
@testable import Notchly

final class CalendarReloadTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func event(_ id: String, startsIn start: TimeInterval, lasts: TimeInterval) -> CalEvent {
        CalEvent(id: id, title: id, start: now.addingTimeInterval(start), end: now.addingTimeInterval(start + lasts), color: .systemBlue)
    }

    func testWakesWhenTheEarliestEventEnds() {
        let events = [event("a", startsIn: -600, lasts: 900), event("b", startsIn: 3000, lasts: 1800)]
        let next = CalendarMonitor.nextReload(after: events, now: now)
        XCTAssertEqual(next.timeIntervalSince(now), 301, accuracy: 0.001, "end of the running event, plus a second")
    }

    func testIgnoresEventsThatAlreadyEnded() {
        let events = [event("old", startsIn: -4000, lasts: 600), event("b", startsIn: 100, lasts: 600)]
        XCTAssertEqual(CalendarMonitor.nextReload(after: events, now: now).timeIntervalSince(now), 701, accuracy: 0.001)
    }

    func testNeverWaitsLongerThanTheCap() {
        let cap = CalendarMonitor.maxReloadInterval
        XCTAssertEqual(CalendarMonitor.nextReload(after: [], now: now).timeIntervalSince(now), cap, accuracy: 0.001,
                       "an empty list still re-checks, because new events can enter the 48-hour window")
        let far = [event("far", startsIn: 7200, lasts: 3600)]
        XCTAssertEqual(CalendarMonitor.nextReload(after: far, now: now).timeIntervalSince(now), cap, accuracy: 0.001)
    }

    func testAlwaysInTheFuture() {
        let ending = [event("x", startsIn: -10, lasts: 10.2)]
        XCTAssertGreaterThan(CalendarMonitor.nextReload(after: ending, now: now), now)
    }
}
