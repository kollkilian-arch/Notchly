import AppKit
import XCTest
@testable import Notchly

final class TabNavigationTests: XCTestCase {
    private let all = NotchTab.visible(scores: true, usage: true)

    private func action(_ keyCode: UInt16 = 0, _ characters: String? = nil, _ modifiers: NSEvent.ModifierFlags = [],
                        on tab: NotchTab = .home, visible: [NotchTab]? = nil) -> TabKeyAction? {
        TabKeys.action(keyCode: keyCode, characters: characters, modifiers: modifiers, current: tab, visible: visible ?? all)
    }

    // MARK: Tab order

    func testTabBarOrderAndOptionalTabs() {
        XCTAssertEqual(all, [.home, .audio, .shelf, .timer, .scores, .usage])
        XCTAssertEqual(NotchTab.visible(scores: false, usage: true), [.home, .audio, .shelf, .timer, .usage])
        XCTAssertEqual(NotchTab.visible(scores: true, usage: false), [.home, .audio, .shelf, .timer, .scores])
        XCTAssertEqual(NotchTab.visible(scores: false, usage: false), [.home, .audio, .shelf, .timer])
    }

    func testEveryTabIsInTheBarWhenAllAreEnabled() {
        XCTAssertEqual(Set(all), Set(NotchTab.allCases))
        for tab in NotchTab.allCases { XCTAssertFalse(tab.title.isEmpty) }
        for tab in NotchTab.allCases where tab != .usage { XCTAssertFalse(tab.symbol.isEmpty, "\(tab)") }
    }

    func testStepWrapsAroundBothEnds() {
        XCTAssertEqual(NotchTab.step(from: .home, by: 1, in: all), .audio)
        XCTAssertEqual(NotchTab.step(from: .usage, by: 1, in: all), .home)
        XCTAssertEqual(NotchTab.step(from: .home, by: -1, in: all), .usage)
        XCTAssertEqual(NotchTab.step(from: .timer, by: -1, in: all), .shelf)
    }

    func testStepFromATabThatIsSwitchedOffStartsAtTheFirstOne() {
        let withoutScores = NotchTab.visible(scores: false, usage: true)
        XCTAssertEqual(NotchTab.step(from: .scores, by: 1, in: withoutScores), .audio)
        XCTAssertEqual(NotchTab.step(from: .home, by: 1, in: []), .home)
    }

    // MARK: Keys

    func testCommandDigitsSelectTheTabInThatPosition() {
        XCTAssertEqual(action(18, "1", .command), .select(.home))
        XCTAssertEqual(action(20, "3", .command), .select(.shelf))
        XCTAssertEqual(action(22, "6", .command), .select(.usage))
    }

    func testDigitsFollowTheTabsThatAreSwitchedOn() {
        let compact = NotchTab.visible(scores: false, usage: false)
        XCTAssertEqual(action(21, "4", .command, visible: compact), .select(.timer))
        XCTAssertNil(action(23, "5", .command, visible: compact), "there is no fifth tab")
        XCTAssertNil(action(29, "0", .command))
        XCTAssertNil(action(26, "7", .command))
    }

    func testCommandDigitsWorkOnTheShelfToo() {
        XCTAssertEqual(action(18, "1", .command, on: .shelf), .select(.home))
    }

    func testCommandCommaOpensSettings() {
        XCTAssertEqual(action(43, ",", .command), .openSettings)
        XCTAssertEqual(action(43, ",", .command, on: .shelf), .openSettings)
    }

    func testArrowsStepThroughTabsExceptOnTheShelf() {
        XCTAssertEqual(action(123), .step(-1))
        XCTAssertEqual(action(124), .step(1))
        XCTAssertNil(action(123, on: .shelf), "the Shelf uses the arrows to move between items")
        XCTAssertNil(action(124, on: .shelf))
    }

    func testEscapeReleasesTheKeyboardExceptOnTheShelf() {
        XCTAssertEqual(action(53), .releaseKeyboard)
        XCTAssertEqual(action(53, on: .timer), .releaseKeyboard)
        XCTAssertNil(action(53, on: .shelf), "the Shelf handles Escape itself")
    }

    func testOtherModifierCombinationsAreLeftAlone() {
        XCTAssertNil(action(18, "1", [.command, .shift]))
        XCTAssertNil(action(18, "1", [.command, .option]))
        XCTAssertNil(action(18, "1", .control))
        XCTAssertNil(action(124, nil, .shift))
        XCTAssertNil(action(124, nil, .command))
        XCTAssertNil(action(53, nil, .option))
    }

    func testUnrelatedKeysAreLeftAlone() {
        XCTAssertNil(action(0, "a"))
        XCTAssertNil(action(49, " "))
        XCTAssertNil(action(18, "1"), "a bare digit is not a shortcut")
        XCTAssertNil(action(18, nil, .command))
    }

    func testCapsLockAndFunctionFlagsDoNotGetInTheWay() {
        XCTAssertEqual(action(18, "1", [.command, .capsLock]), .select(.home))
        XCTAssertEqual(action(124, nil, [.function, .numericPad]), .step(1))
    }
}

final class UsageHintTests: XCTestCase {
    func testSignedOutHintSaysWhatToDo() {
        let hint = UsageView.localHint(for: "Not signed in to Claude Code")
        XCTAssertTrue(hint.hasPrefix("Sign in to Claude Code"))
        XCTAssertTrue(hint.hasSuffix("Showing local token counts instead."))
    }

    func testOtherReasonsBecomeAProperSentence() {
        XCTAssertEqual(UsageView.localHint(for: "Can't reach Anthropic"), "Can't reach Anthropic. Showing local token counts instead.")
        XCTAssertEqual(UsageView.localHint(for: "Claude sign-in expired. Run “claude” once to refresh it."),
                       "Claude sign-in expired. Run “claude” once to refresh it. Showing local token counts instead.",
                       "a note that already ends in a full stop is not given a second one")
    }
}
