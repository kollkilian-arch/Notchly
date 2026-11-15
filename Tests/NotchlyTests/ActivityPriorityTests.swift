import AppKit
import XCTest
@testable import Notchly

final class ActivityPriorityTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func inputs(timer: TimerModel.Phase = .running, meetingIn seconds: TimeInterval? = nil,
                        music: Bool = true) -> ActivityInputs {
        var input = ActivityInputs()
        input.timer = timer
        input.music = music
        if let seconds {
            input.meetingID = "meeting/occurrence-1"
            input.meetingStart = now.addingTimeInterval(seconds)
        }
        return input
    }

    func testAutomaticOrderFallsBackAsActivitiesEnd() {
        var priority = ActivityPriority()
        var input = inputs(meetingIn: 240)
        input.scores = true
        input.charging = true
        XCTAssertEqual(priority.resolve(input, at: now).displayed, .timer)
        input.timer = .idle
        XCTAssertEqual(priority.resolve(input, at: now).displayed, .meeting)
        input.meetingID = nil
        input.meetingStart = nil
        XCTAssertEqual(priority.resolve(input, at: now).displayed, .scores)
        input.scores = false
        XCTAssertEqual(priority.resolve(input, at: now).displayed, .music)
        input.music = false
        XCTAssertEqual(priority.resolve(input, at: now).displayed, .charging)
        input.charging = false
        XCTAssertNil(priority.resolve(input, at: now).displayed)
    }

    func testMeetingStartingSoonOutranksRunningTimerAutomatically() {
        var priority = ActivityPriority()
        let input = inputs(meetingIn: 180)
        XCTAssertEqual(priority.resolve(input, at: now).displayed, .timer)
        XCTAssertEqual(priority.resolve(input, at: now.addingTimeInterval(119)).displayed, .timer)
        XCTAssertEqual(priority.resolve(input, at: now.addingTimeInterval(120)).displayed, .meeting)
        XCTAssertEqual(priority.resolve(input, at: now.addingTimeInterval(150)).displayed, .meeting)
        XCTAssertEqual(priority.resolve(input, at: now.addingTimeInterval(241)).displayed, .timer)
    }

    func testFinishedTimerBrieflyOverridesPinThenRestoresItWithoutRepeating() {
        var priority = ActivityPriority(pinned: .music)
        var input = inputs()
        XCTAssertEqual(priority.resolve(input, at: now).displayed, .music)
        input.timer = .finished
        let alert = priority.resolve(input, at: now.addingTimeInterval(1))
        XCTAssertEqual(alert.displayed, .timer)
        XCTAssertTrue(alert.isUrgent)
        XCTAssertEqual(priority.resolve(input, at: now.addingTimeInterval(12.9)).displayed, .timer)
        let restored = priority.resolve(input, at: now.addingTimeInterval(13))
        XCTAssertEqual(restored.displayed, .music)
        XCTAssertFalse(restored.isUrgent)
        XCTAssertEqual(restored.pinned, .music)
        XCTAssertEqual(priority.resolve(input, at: now.addingTimeInterval(30)).displayed, .music)
    }

    func testMeetingAnnouncesLastMinuteAndStartOnlyOnceEach() {
        var priority = ActivityPriority(pinned: .music)
        let input = inputs(meetingIn: 120)
        XCTAssertEqual(priority.resolve(input, at: now).displayed, .music)
        XCTAssertEqual(priority.resolve(input, at: now.addingTimeInterval(60)).displayed, .meeting)
        XCTAssertEqual(priority.resolve(input, at: now.addingTimeInterval(72)).displayed, .music)
        XCTAssertEqual(priority.resolve(input, at: now.addingTimeInterval(100)).displayed, .music)
        XCTAssertEqual(priority.resolve(input, at: now.addingTimeInterval(120)).displayed, .meeting)
        XCTAssertEqual(priority.resolve(input, at: now.addingTimeInterval(132)).displayed, .music)
        XCTAssertEqual(priority.resolve(input, at: now.addingTimeInterval(150)).displayed, .music)
    }

    func testSimultaneousAlertsShowTimerThenMeetingThenPin() {
        var priority = ActivityPriority(pinned: .music)
        let input = inputs(timer: .finished, meetingIn: 45)
        XCTAssertEqual(priority.resolve(input, at: now).displayed, .timer)
        XCTAssertEqual(priority.resolve(input, at: now.addingTimeInterval(12)).displayed, .meeting)
        XCTAssertEqual(priority.resolve(input, at: now.addingTimeInterval(24)).displayed, .music)
    }

    func testUserCanCycleAwayFromAnAlertWithoutItReappearing() {
        var priority = ActivityPriority()
        let input = inputs(timer: .finished)
        XCTAssertEqual(priority.resolve(input, at: now).displayed, .timer)
        priority.cycle(from: input, at: now)
        XCTAssertEqual(priority.resolve(input, at: now).displayed, .music)
        XCTAssertFalse(priority.resolve(input, at: now.addingTimeInterval(1)).isUrgent)
        XCTAssertEqual(priority.resolve(input, at: now.addingTimeInterval(20)).displayed, .timer)
    }

    func testCyclingWrapsAndRestoresPinAfterTwentySeconds() {
        var priority = ActivityPriority(pinned: .music)
        var input = inputs()
        input.scores = true
        priority.cycle(from: input, at: now)
        XCTAssertEqual(priority.resolve(input, at: now).displayed, .timer)
        priority.cycle(from: input, at: now.addingTimeInterval(1))
        XCTAssertEqual(priority.resolve(input, at: now.addingTimeInterval(1)).displayed, .scores)
        XCTAssertEqual(priority.resolve(input, at: now.addingTimeInterval(20)).displayed, .scores)
        XCTAssertEqual(priority.resolve(input, at: now.addingTimeInterval(21)).displayed, .music)
    }

    func testNewUrgentEventOverridesTemporarySelection() {
        var priority = ActivityPriority()
        var input = inputs()
        _ = priority.resolve(input, at: now)
        priority.select(.music, from: input, at: now)
        input.timer = .finished
        XCTAssertEqual(priority.resolve(input, at: now.addingTimeInterval(1)).displayed, .timer)
        XCTAssertEqual(priority.resolve(input, at: now.addingTimeInterval(13)).displayed, .music)
    }

    func testUnavailableSelectionFallsBackImmediatelyAndDormantPinReturns() {
        var priority = ActivityPriority(pinned: .music)
        var input = inputs(music: false)
        XCTAssertEqual(priority.resolve(input, at: now).displayed, .timer)
        input.music = true
        XCTAssertEqual(priority.resolve(input, at: now).displayed, .music)
        priority.select(.timer, from: input, at: now)
        input.timer = .idle
        XCTAssertEqual(priority.resolve(input, at: now).displayed, .music)
        input.music = false
        XCTAssertNil(priority.resolve(input, at: now).displayed)
        XCTAssertEqual(priority.pinned, .music)
    }

    func testLockHidesPrivateActivitiesEvenWithIndicatorDisabled() {
        var priority = ActivityPriority(pinned: .music)
        var input = inputs(timer: .finished, meetingIn: 0)
        input.hud = true
        input.locked = true
        let hidden = priority.resolve(input, at: now)
        XCTAssertNil(hidden.displayed)
        XCTAssertTrue(hidden.available.isEmpty)
        XCTAssertEqual(hidden.wingWidth, 0)
        input.lockVisible = true
        XCTAssertEqual(priority.resolve(input, at: now).displayed, .lock)
        priority.cycle(from: input, at: now)
        priority.togglePin(.timer, from: input)
        XCTAssertEqual(priority.pinned, .music)
        input.locked = false // The unlock animation still wins.
        XCTAssertEqual(priority.resolve(input, at: now).displayed, .lock)
    }

    func testHUDTemporarilyOverridesPinAndUsesItsOwnWidth() {
        var priority = ActivityPriority(pinned: .music)
        var input = inputs()
        XCTAssertEqual(priority.resolve(input, at: now).wingWidth, NotchState.wing)
        input.hud = true
        let hud = priority.resolve(input, at: now)
        XCTAssertEqual(hud.displayed, .hud)
        XCTAssertEqual(hud.wingWidth, NotchState.hudWing)
        XCTAssertFalse(hud.canCycle)
        priority.cycle(from: input, at: now)
        input.hud = false
        XCTAssertEqual(priority.resolve(input, at: now).displayed, .music)
    }

    func testChoosingAHiddenActivityChangesBothGeometryAndOpeningDestination() {
        let state = NotchState(defaults: nil)
        var input = inputs()
        input.scores = true
        state.updateActivities(input, at: now)
        XCTAssertEqual(state.activity.openingTab, .timer)
        state.selectActivity(.scores, at: now)
        XCTAssertEqual(state.activity.displayed, .scores)
        XCTAssertEqual(state.activity.wingWidth, NotchState.hudWing)
        XCTAssertEqual(state.activity.openingTab, .scores)
        state.selectActivity(.music, at: now)
        XCTAssertEqual(state.activity.wingWidth, NotchState.wing)
        XCTAssertEqual(state.activity.openingTab, .home)
    }

    func testPinsPersistAcrossLaunchesAndAutomaticModeClearsThem() throws {
        let suite = "Notchly.ActivityPriorityTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let state = NotchState(defaults: defaults)
        state.updateActivities(inputs(), at: now)
        state.toggleActivityPin(.music, at: now)
        let reloaded = NotchState(defaults: defaults)
        reloaded.updateActivities(inputs(), at: now)
        XCTAssertEqual(reloaded.activity.displayed, .music)
        reloaded.useAutomaticActivities(at: now)
        XCTAssertEqual(reloaded.activity.displayed, .timer)
        XCTAssertNil(reloaded.activity.pinned)
        XCTAssertEqual(defaults.string(forKey: Pref.pinnedActivity), "")
    }

    func testNewTimerAndRecurringMeetingCanAnnounceAgain() {
        var priority = ActivityPriority(pinned: .music)
        var input = inputs(timer: .finished, meetingIn: 45)
        _ = priority.resolve(input, at: now)
        _ = priority.resolve(input, at: now.addingTimeInterval(25))
        input.timer = .running
        input.meetingID = nil
        input.meetingStart = nil
        _ = priority.resolve(input, at: now.addingTimeInterval(26))
        input.timer = .finished
        input.meetingID = "meeting/occurrence-2"
        input.meetingStart = now.addingTimeInterval(70)
        XCTAssertEqual(priority.resolve(input, at: now.addingTimeInterval(27)).displayed, .timer)
        XCTAssertEqual(priority.resolve(input, at: now.addingTimeInterval(39)).displayed, .meeting)
    }

    func testNoCyclingWhenThereIsOnlyOneActivityAndTransientPinsAreIgnored() {
        var priority = ActivityPriority(pinned: .hud)
        let input = inputs(music: false)
        priority.cycle(from: input, at: now)
        XCTAssertEqual(priority.resolve(input, at: now).displayed, .timer)
        XCTAssertFalse(priority.resolve(input, at: now).canCycle)
        XCTAssertNil(priority.pinned)
    }

    func testMeetingStartingNowIsNotHiddenBehindAnOlderUnjoinedCall() {
        let link = MeetingLink(url: URL(string: "https://example.com/call")!, service: "Meeting")
        let old = CalEvent(id: "old", title: "Old meeting", start: now.addingTimeInterval(-300),
                           end: now.addingTimeInterval(900), color: .blue, meeting: link)
        let next = CalEvent(id: "next", title: "Next meeting", start: now.addingTimeInterval(45),
                            end: now.addingTimeInterval(1800), color: .blue, meeting: link)
        let calendar = CalendarMonitor(preview: [old, next])
        XCTAssertEqual(calendar.imminentMeeting(at: now, leadMinutes: 5)?.id, "next")
        calendar.markJoined(next)
        XCTAssertEqual(calendar.imminentMeeting(at: now, leadMinutes: 5)?.id, "old")
    }
}
