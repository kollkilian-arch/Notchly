import XCTest
@testable import Notchly

final class DashboardStyleTests: XCTestCase {
    func testLegacyPreferenceAndExplicitStyles() {
        XCTAssertEqual(DashboardStyle.resolve("", legacyGlass: true), .hybrid)
        XCTAssertEqual(DashboardStyle.resolve("", legacyGlass: false), .black)
        for style in DashboardStyle.allCases {
            XCTAssertEqual(DashboardStyle.resolve(style.rawValue, legacyGlass: false), style)
        }
        XCTAssertEqual(DashboardStyle.resolve("unknown", legacyGlass: true), .hybrid)
    }
}
