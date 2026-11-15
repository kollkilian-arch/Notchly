import AppKit
import XCTest
@testable import Notchly

final class MeetingIndicatorTests: XCTestCase {
    private let zoom = MeetingLink(url: URL(string: "https://zoom.us/j/81234567890")!, service: "Zoom")

    private func event(_ id: String, startsIn minutes: Double, lasts: Double = 30, link: Bool = true) -> CalEvent {
        let start = Date().addingTimeInterval(minutes * 60)
        return CalEvent(id: id, title: id, start: start, end: start.addingTimeInterval(lasts * 60),
                        color: .systemBlue, meeting: link ? zoom : nil)
    }

    private func shown(_ e: CalEvent, lead: Int = 5, joined: Bool = false) -> Bool {
        let calendar = CalendarMonitor(preview: [e])
        if joined { calendar.markJoined(e) }
        return calendar.imminentMeeting(leadMinutes: lead) != nil
    }

    func testAppearsOnlyWithinTheLeadTime() {
        XCTAssertFalse(shown(event("a", startsIn: 12)), "12 min before, lead 5")
        XCTAssertTrue(shown(event("b", startsIn: 4)), "4 min before, lead 5")
        XCTAssertFalse(shown(event("c", startsIn: 4), lead: 2), "4 min before, lead 2")
        XCTAssertTrue(shown(event("d", startsIn: 12), lead: 15), "12 min before, lead 15")
    }

    func testStaysBrieflyAfterTheStartButNotForLong() {
        XCTAssertTrue(shown(event("e", startsIn: -3)))
        XCTAssertFalse(shown(event("f", startsIn: -12)))
    }

    func testIgnoresEventsWithoutLinkJoinedOrEnded() {
        XCTAssertFalse(shown(event("g", startsIn: 3, link: false)))
        XCTAssertFalse(shown(event("h", startsIn: 3), joined: true))
        XCTAssertFalse(shown(event("i", startsIn: -40, lasts: 30)))
    }

    func testCallStartingNowTakesPrecedenceOverAnOlderOne() {
        let older = event("older", startsIn: -4)
        let current = event("current", startsIn: 1)
        let calendar = CalendarMonitor(preview: [older, current])
        XCTAssertEqual(calendar.imminentMeeting(leadMinutes: 5)?.id, "current")
    }
}
