import AppKit
import XCTest
@testable import Notchly

final class FullscreenVisibilityTests: XCTestCase {
    private func display(_ id: String = "notch", type: Int) -> [String: Any] {
        ["Display Identifier": id, "Current Space": ["type": type, "ManagedSpaceID": 42]]
    }

    func testNativeFullscreenMatches() {
        XCTAssertTrue(FullscreenDetection.isFullscreen(displayID: "notch", displays: [display(type: 4)]))
    }

    func testDesktopDoesNotMatchEvenWithMaximizedWindowAndHiddenDock() {
        // Window geometry and Dock settings have no role in this decision.
        XCTAssertFalse(FullscreenDetection.isFullscreen(displayID: "notch", displays: [display(type: 0)]))
    }

    func testFullscreenOnAnotherDisplayDoesNotMatch() {
        XCTAssertFalse(FullscreenDetection.isFullscreen(displayID: "notch", displays: [
            display("external", type: 4), display(type: 0)
        ]))
        XCTAssertTrue(FullscreenDetection.isFullscreen(displayID: "notch", displays: [
            display("external", type: 0), display(type: 4)
        ]))
    }

    func testInactiveFullscreenSpaceDoesNotMatch() {
        var desktop = display(type: 0)
        desktop["Spaces"] = [["type": 0], ["type": 4]]
        XCTAssertFalse(FullscreenDetection.isFullscreen(displayID: "notch", displays: [desktop]))
    }

    func testUnavailableUnknownAndMalformedStateStayVisible() {
        for displays: [[String: Any]] in [[], [display(type: 99)], [[:]],
                                        [["Display Identifier": "notch"]],
                                        [["Display Identifier": "notch", "Current Space": ["type": "4"]]],
                                        [display("disconnected", type: 4)]] {
            XCTAssertFalse(FullscreenDetection.isFullscreen(displayID: "notch", displays: displays))
        }
    }

    func testSharedSpacesUseMainOnlyWhenSeparateSpacesAreDisabled() {
        let main = [display("Main", type: 4)]
        XCTAssertTrue(FullscreenDetection.isFullscreen(displayID: "notch", displays: main, separateSpaces: false))
        XCTAssertFalse(FullscreenDetection.isFullscreen(displayID: "notch", displays: main, separateSpaces: true))
        XCTAssertFalse(FullscreenDetection.isFullscreen(displayID: "notch", displays: [display("Main", type: 0)], separateSpaces: false))
    }

    func testDimRestoresOpacityOnlyWhileOpenAndHideStaysInvisible() {
        XCTAssertEqual(FullscreenBehavior.dim.opacity(isOpen: false), 0.25)
        XCTAssertEqual(FullscreenBehavior.dim.opacity(isOpen: true), 1)
        XCTAssertEqual(FullscreenBehavior.hide.opacity(isOpen: false), 0)
        XCTAssertEqual(FullscreenBehavior.hide.opacity(isOpen: true), 0)
        XCTAssertEqual(FullscreenBehavior.show.opacity(isOpen: false), 1)
    }
}
