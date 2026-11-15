import AppKit
import XCTest
@testable import Notchly

final class FullscreenVisibilityTests: XCTestCase {
    private let display = CGRect(x: 0, y: 0, width: 1512, height: 982)

    func testNativeAndBorderlessFullscreenCoverDisplay() {
        XCTAssertTrue(FullscreenDetection.coversDisplay(display, display: display, topInset: 32))
        XCTAssertTrue(FullscreenDetection.coversDisplay(
            CGRect(x: 0, y: 32, width: 1512, height: 950), display: display, topInset: 32))
    }

    func testMaximizedWindowWithDockAndRegularWindowDoNotMatch() {
        XCTAssertFalse(FullscreenDetection.coversDisplay(
            CGRect(x: 0, y: 32, width: 1512, height: 880), display: display, topInset: 32))
        XCTAssertFalse(FullscreenDetection.coversDisplay(
            CGRect(x: 200, y: 200, width: 800, height: 600), display: display, topInset: 32))
    }

    func testFullscreenOnAnotherDisplayDoesNotMatch() {
        let other = CGRect(x: -1920, y: -98, width: 1920, height: 1080)
        XCTAssertFalse(FullscreenDetection.coversDisplay(other, display: display, topInset: 32))
        XCTAssertTrue(FullscreenDetection.coversDisplay(other, display: other, topInset: 0))
    }

    func testMenuStripAllowanceIsLimitedToNotchedDisplays() {
        let belowMenu = CGRect(x: 0, y: 24, width: 1512, height: 958)
        XCTAssertFalse(FullscreenDetection.coversDisplay(belowMenu, display: display, topInset: 0))
        XCTAssertFalse(FullscreenDetection.coversDisplay(
            CGRect(x: 0, y: 100, width: 1512, height: 882), display: display, topInset: 32))
    }

    func testSpanningWindowDoesNotMatchFullscreen() {
        XCTAssertFalse(FullscreenDetection.coversDisplay(
            CGRect(x: -1920, y: 0, width: 3432, height: 982), display: display, topInset: 32))
    }

    func testDimRestoresOpacityOnlyWhileOpenAndHideStaysInvisible() {
        XCTAssertEqual(FullscreenBehavior.dim.opacity(isOpen: false), 0.25)
        XCTAssertEqual(FullscreenBehavior.dim.opacity(isOpen: true), 1)
        XCTAssertEqual(FullscreenBehavior.hide.opacity(isOpen: false), 0)
        XCTAssertEqual(FullscreenBehavior.hide.opacity(isOpen: true), 0)
        XCTAssertEqual(FullscreenBehavior.show.opacity(isOpen: false), 1)
    }
}
