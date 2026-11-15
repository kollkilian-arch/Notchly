import AppKit
import XCTest
@testable import Notchly

final class ExperimentalTests: XCTestCase {
    func testLayoutNormalizesDuplicatesAndMissingWidgets() {
        let layout = DashboardLayout.decode(#"{"order":["calendar","calendar"],"hidden":[]}"#)
        XCTAssertEqual(layout.order, [.calendar, .music])
        XCTAssertEqual(DashboardLayout.decode("invalid"), DashboardLayout())
    }

    func testLayoutMovesHidesAndRestoresWithoutLosingOrder() {
        var layout = DashboardLayout()
        layout.move(.calendar, by: -1)
        layout.setVisible(.music, false)
        XCTAssertEqual(layout.visible(calendarEnabled: true), [.calendar])
        layout.setVisible(.calendar, false)
        XCTAssertEqual(layout.visible(calendarEnabled: true), [.calendar], "Keep at least one card")
        XCTAssertEqual(DashboardLayout.decode(layout.json), layout)
        layout.setVisible(.music, true)
        XCTAssertEqual(layout.visible(calendarEnabled: false), [.music])
    }

    func testAllHiddenLayoutRecoversMusic() {
        let layout = DashboardLayout.decode(#"{"order":["music","calendar"],"hidden":["music","calendar"]}"#)
        XCTAssertEqual(layout.visible(calendarEnabled: false), [.music])
    }

    func testAirDropUsesOwnedAssetAndLinkURL() {
        let url = URL(fileURLWithPath: "/tmp/sample.txt")
        let text = ShelfItem(id: UUID(), kind: .text, url: url, text: "Sample")
        XCTAssertEqual(ShelfSharing.items(for: text).first as? NSURL, url as NSURL)
        let link = ShelfItem(id: UUID(), kind: .link, url: URL(string: "https://example.com")!)
        XCTAssertEqual(ShelfSharing.items(for: link).first as? NSURL, link.url as NSURL)
    }
}

final class CalendarCarouselTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
        calendar.firstWeekday = 2
        return calendar
    }
    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }

    func testDailyCarouselKeepsSelectionCenteredAcrossMonthAndDST() {
        for day in [date(2026, 11, 1), date(2026, 10, 25)] {
            let dates = CalendarMonitor.carouselDays(centeredOn: day, calendar: calendar)
            XCTAssertEqual(dates.count, 7)
            XCTAssertEqual(dates[3], day)
            XCTAssertEqual(dates.first, calendar.date(byAdding: .day, value: -3, to: day))
            XCTAssertEqual(dates.last, calendar.date(byAdding: .day, value: 3, to: day))
        }
    }

    func testDayFilteringIncludesAllDayAndOvernightButExcludesNextMidnight() {
        let events = [
            CalEvent(id: "overnight", title: "Overnight", start: date(2026, 11, 14, 23), end: date(2026, 11, 15, 1), color: .blue),
            CalEvent(id: "all", title: "All day", start: date(2026, 11, 15), end: date(2026, 11, 16), color: .blue, isAllDay: true),
            CalEvent(id: "next", title: "Next day", start: date(2026, 11, 16), end: date(2026, 11, 16, 1), color: .blue),
        ]
        XCTAssertEqual(CalendarMonitor.events(events, on: date(2026, 11, 15), calendar: calendar).map(\.id), ["overnight", "all"])
    }

    func testDSTDayUsesCalendarBoundaries() {
        let event = CalEvent(id: "late", title: "Late", start: date(2026, 10, 25, 23), end: date(2026, 10, 26), color: .blue)
        XCTAssertEqual(CalendarMonitor.events([event], on: date(2026, 10, 25), calendar: calendar).count, 1)
        let days = CalendarMonitor.carouselDays(centeredOn: date(2026, 10, 25), calendar: calendar)
        XCTAssertEqual(days.count, 7)
        XCTAssertEqual(Set(days.map { calendar.component(.weekday, from: $0) }).count, 7)
    }

    func testBrowsingPreviewDoesNotReplaceUpcomingMeetingData() {
        let local = Calendar.current
        let day = local.date(from: DateComponents(year: 2026, month: 12, day: 4))!
        let start = local.date(byAdding: .hour, value: 10, to: day)!
        let end = local.date(byAdding: .hour, value: 11, to: day)!
        let event = CalEvent(id: "future", title: "Future", start: start, end: end, color: .blue)
        let monitor = CalendarMonitor(preview: [event])
        monitor.selectDay(day)
        XCTAssertEqual(monitor.events, [event])
        XCTAssertEqual(CalendarMonitor.events(monitor.weekEvents, on: monitor.browsingDay).map(\.id), ["future"])
    }
}
