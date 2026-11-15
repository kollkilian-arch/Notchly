import XCTest
@testable import Notchly

final class MeetingLinkTests: XCTestCase {
    private func service(_ texts: [String?]) -> String? { MeetingLinks.find(in: texts)?.service }

    func testDetectsKnownServices() {
        XCTAssertEqual(service([nil, "https://us02web.zoom.us/j/81234567890?pwd=abc123", nil]), "Zoom")
        XCTAssertEqual(service(["Room 4", "Agenda below.\nJoin: https://meet.google.com/abc-defg-hij\nThanks"]), "Google Meet")
        XCTAssertEqual(service([nil, "see https://example.com/agenda and https://acme.webex.com/meet/jdoe"]), "Webex")
    }

    func testUnwrapsRedirectsAndSafelinks() {
        XCTAssertEqual(service(["https://nam12.safelinks.protection.outlook.com/?url=https%3A%2F%2Fteams.microsoft.com%2Fl%2Fmeetup-join%2F19%253ameeting_abc%2F0%3Fcontext%3D%257b%257d&data=05"]), "Teams")
        XCTAssertEqual(service(["https://www.google.com/url?q=https://zoom.us/j/123456789&sa=D"]), "Zoom")
    }

    func testEarlierFieldWins() {
        XCTAssertEqual(service(["https://whereby.com/team-room", "https://zoom.us/j/999999"]), "Whereby")
    }

    func testIgnoresNonMeetingLinks() {
        XCTAssertNil(service(["https://www.google.com/calendar/event?eid=xyz"]))
        XCTAssertNil(service(["https://zoom.us/"]))
        XCTAssertNil(service(["https://meet.google.com/landing"]))
        XCTAssertNil(service(["Conference room 4B, 3rd floor"]))
        XCTAssertNil(service([nil, nil, nil]))
    }
}
