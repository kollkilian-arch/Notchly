import XCTest
@testable import Notchly

final class UsageHeatmapTests: XCTestCase {
    private func calendar(_ zone: String) -> Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: zone)!
        return c
    }

    private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 0, _ min: Int = 0, calendar: Calendar) -> Date {
        calendar.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
    }

    // MARK: Window

    func testWindowCoversSixDaysBeforeTodayAndToday() {
        let cal = calendar("Europe/Berlin")
        let now = date(2026, 11, 15, 21, 58, calendar: cal)
        XCTAssertEqual(UsageHeatmap.windowStart(now: now, calendar: cal), date(2026, 11, 9, calendar: cal))
    }

    // MARK: Bucketing

    func testEventsLandInTheirDayAndHour() {
        let cal = calendar("UTC")
        let now = date(2026, 11, 15, 21, 58, calendar: cal)
        let start = UsageHeatmap.windowStart(now: now, calendar: cal)
        let map = UsageHeatmap.build(events: [
            UsageEvent(date: date(2026, 11, 9, 5, 10, calendar: cal), tokens: 100),      // first row, 05:xx
            UsageEvent(date: date(2026, 11, 9, 5, 50, calendar: cal), tokens: 50),       // same hour: adds up
            UsageEvent(date: date(2026, 11, 15, 21, 0, calendar: cal), tokens: 7),       // today, 21:xx
        ], start: start, now: now, calendar: cal)
        XCTAssertEqual(map.tokens(day: 0, hour: 5), 150)
        XCTAssertEqual(map.tokens(day: 6, hour: 21), 7)
        XCTAssertEqual(map.total, 157)
        XCTAssertEqual(map.peak, 150)
        XCTAssertFalse(map.isEmpty)
    }

    func testEventsOutsideTheWindowOrWithoutTokensAreIgnored() {
        let cal = calendar("UTC")
        let now = date(2026, 11, 15, 12, 0, calendar: cal)
        let start = UsageHeatmap.windowStart(now: now, calendar: cal)
        let map = UsageHeatmap.build(events: [
            UsageEvent(date: date(2026, 11, 8, 23, 59, calendar: cal), tokens: 999),     // before the first row
            UsageEvent(date: date(2026, 11, 15, 13, 0, calendar: cal), tokens: 999),     // after "now"
            UsageEvent(date: date(2026, 11, 12, 9, 0, calendar: cal), tokens: 0),
            UsageEvent(date: date(2026, 11, 12, 9, 0, calendar: cal), tokens: -5),
        ], start: start, now: now, calendar: cal)
        XCTAssertTrue(map.isEmpty)
        XCTAssertEqual(map.total, 0)
    }

    func testOutOfRangeLookupsAreZero() {
        let map = UsageHeatmap(start: .distantPast, now: .now, tokens: [Int](repeating: 1, count: 168))
        XCTAssertEqual(map.tokens(day: -1, hour: 0), 0)
        XCTAssertEqual(map.tokens(day: 7, hour: 0), 0)
        XCTAssertEqual(map.tokens(day: 0, hour: 24), 0)
    }

    func testDaylightSavingDayKeepsHoursApart() {
        // Europe/Berlin springs forward on 29 March 2026: 02:00 does not exist.
        let cal = calendar("Europe/Berlin")
        let now = date(2026, 3, 31, 12, 0, calendar: cal)
        let start = UsageHeatmap.windowStart(now: now, calendar: cal)          // 25 March
        let map = UsageHeatmap.build(events: [
            UsageEvent(date: date(2026, 3, 29, 1, 30, calendar: cal), tokens: 10),
            UsageEvent(date: date(2026, 3, 29, 3, 30, calendar: cal), tokens: 20),
        ], start: start, now: now, calendar: cal)
        XCTAssertEqual(map.tokens(day: 4, hour: 1), 10)
        XCTAssertEqual(map.tokens(day: 4, hour: 2), 0)
        XCTAssertEqual(map.tokens(day: 4, hour: 3), 20)
        XCTAssertNotNil(map.hourStart(day: 4, hour: 2, calendar: cal), "the missing hour must not crash")
    }

    // MARK: Shades

    func testLevelsFollowASquareRootScale() {
        func level(_ tokens: Int, peak: Int = 100) -> UsageHeatmap.Cell { UsageHeatmap.level(tokens, peak: peak) }
        XCTAssertEqual(level(0), .idle)
        XCTAssertEqual(level(5, peak: 0), .idle)
        XCTAssertEqual(level(1), .level(1))
        XCTAssertEqual(level(6), .level(1))
        XCTAssertEqual(level(7), .level(2))
        XCTAssertEqual(level(25), .level(3))
        XCTAssertEqual(level(57), .level(4))
        XCTAssertEqual(level(100), .level(4), "the busiest hour is the darkest")
        XCTAssertEqual(level(500), .level(4), "never beyond the top shade")
    }

    func testOneHugeHourDoesNotFlattenTheRest() {
        // On a linear scale 100K of a 1M peak would be the faintest shade.
        XCTAssertEqual(UsageHeatmap.level(100_000, peak: 1_000_000), .level(2))
    }

    func testHoursLaterTodayAreFuture() {
        let cal = calendar("UTC")
        let now = date(2026, 11, 15, 10, 30, calendar: cal)
        let start = UsageHeatmap.windowStart(now: now, calendar: cal)
        let map = UsageHeatmap.build(events: [UsageEvent(date: date(2026, 11, 15, 10, 5, calendar: cal), tokens: 40)],
                                     start: start, now: now, calendar: cal)
        XCTAssertEqual(map.cell(day: 6, hour: 10, calendar: cal), .level(4), "the current hour is not the future")
        XCTAssertEqual(map.cell(day: 6, hour: 11, calendar: cal), .future)
        XCTAssertEqual(map.cell(day: 6, hour: 23, calendar: cal), .future)
        XCTAssertEqual(map.cell(day: 5, hour: 23, calendar: cal), .idle, "yesterday is over")
    }

    // MARK: Totals (the local fallback shares the log reader)

    func testTotalsSplitFiveHoursAndSevenDays() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let events = [
            UsageEvent(date: now.addingTimeInterval(-3600), tokens: 100),              // within 5 h
            UsageEvent(date: now.addingTimeInterval(-6 * 3600), tokens: 10),           // within 7 d only
            UsageEvent(date: now.addingTimeInterval(-6 * 86_400), tokens: 1),
            UsageEvent(date: now.addingTimeInterval(-8 * 86_400), tokens: 1_000),      // too old
        ]
        XCTAssertEqual(UsageMonitor.totals(of: events, now: now), LocalUsage(last5h: 100, last7d: 111))
    }

    func testTokenFormatting() {
        XCTAssertEqual(formatTokens(850), "850")
        XCTAssertEqual(formatTokens(1_500), "1.5K")
        XCTAssertEqual(formatTokens(412_300), "412K")
        XCTAssertEqual(formatTokens(14_800_000), "14.8M")
    }
}
