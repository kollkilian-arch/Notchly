import XCTest
@testable import Notchly

final class UpdateChannelTests: XCTestCase {
    private func release(_ tag: String, prerelease: Bool = false, draft: Bool = false) -> [String: Any] {
        ["tag_name": tag, "html_url": "https://github.com/kollkilian-arch/Notchly/releases/tag/\(tag)",
         "prerelease": prerelease, "draft": draft]
    }

    func testStableFeedNeverAcceptsExperimentalBuilds() throws {
        let data = try JSONSerialization.data(withJSONObject: [release("v0.5.0-experimental.1", prerelease: true), release("v0.4.1")])
        XCTAssertEqual(try Updater.parseFeed(data, channel: .stable).tag, "v0.4.1")
        XCTAssertEqual(try Updater.parseFeed(data, channel: .experimental).tag, "v0.5.0-experimental.1")
        XCTAssertFalse(UpdateChannel.stable.accepts(tag: "v0.5.0-experimental.1", prerelease: false))
    }

    func testExperimentalFeedSkipsDraftsAndUnrelatedPrereleases() throws {
        let data = try JSONSerialization.data(withJSONObject: [
            release("v9.0.0-beta.1", prerelease: true),
            release("v0.5.0-experimental.12", prerelease: true, draft: true),
            release("v0.5.0-experimental.9", prerelease: true),
            release("v0.5.0-experimental.10", prerelease: true),
        ])
        XCTAssertEqual(try Updater.parseFeed(data, channel: .experimental).version, "0.5.0-experimental.10")
    }

    func testNoExperimentalReleaseDoesNotOfferStableAsExperimental() throws {
        let data = try JSONSerialization.data(withJSONObject: [release("v0.4.1")])
        XCTAssertThrowsError(try Updater.parseFeed(data, channel: .experimental))
    }

    func testPrereleaseVersionOrdering() {
        XCTAssertTrue(Updater.isNewer("0.5.0-experimental.10", than: "0.5.0-experimental.9"))
        XCTAssertTrue(Updater.isNewer("0.5.0", than: "0.5.0-experimental.10"))
        XCTAssertFalse(Updater.isNewer("0.5.0-experimental.10", than: "0.5.0"))
        XCTAssertFalse(Updater.isNewer("0.5.0-experimental.10", than: "0.5.0-experimental.10"))
    }

    func testSwitchingBackToStableCanOfferLowerVersion() throws {
        let data = try JSONSerialization.data(withJSONObject: release("v0.4.1"))
        let stable = try Updater.parseRelease(data)
        XCTAssertTrue(Updater.shouldOffer(stable, currentVersion: "0.5.0-experimental.1", currentChannel: .experimental, selectedChannel: .stable))
        XCTAssertFalse(Updater.shouldOffer(stable, currentVersion: "0.5.0", currentChannel: .stable, selectedChannel: .stable))
    }

}
