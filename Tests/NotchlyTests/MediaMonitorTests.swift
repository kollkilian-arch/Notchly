import AppKit
import XCTest
@testable import Notchly

final class PositionClockTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    func testAdvancesWhilePlaying() {
        let clock = PositionClock(base: 30, at: t0, playing: true)
        XCTAssertEqual(clock.value(at: t0), 30)
        XCTAssertEqual(clock.value(at: t0.addingTimeInterval(12.5)), 42.5, accuracy: 0.001)
    }

    func testStandsStillWhilePaused() {
        let clock = PositionClock(base: 30, at: t0, playing: false)
        XCTAssertEqual(clock.value(at: t0.addingTimeInterval(500)), 30)
    }

    func testNeverRunsBackwards() {
        let clock = PositionClock(base: 30, at: t0, playing: true)
        XCTAssertEqual(clock.value(at: t0.addingTimeInterval(-5)), 30)
    }
}

/// The monitor must react to the players' notifications and otherwise stay quiet.
final class MediaMonitorTests: XCTestCase {
    private final class FakePlayer {
        private let lock = NSLock()
        private var count = 0
        private var snapshot: MediaMonitor.Snapshot?

        var reads: Int { lock.lock(); defer { lock.unlock() }; return count }
        func set(_ s: MediaMonitor.Snapshot?) { lock.lock(); snapshot = s; lock.unlock() }
        func read() -> MediaMonitor.Snapshot? { lock.lock(); defer { lock.unlock() }; count += 1; return snapshot }
    }

    private func song(_ title: String, playing: Bool = true, position: Double = 10) -> MediaMonitor.Snapshot {
        // Spotify with no artwork URL: nothing is downloaded and Music is never asked for artwork.
        .init(track: Track(source: .spotify, title: title, artist: "Artist", album: "Album", duration: 200, artworkURL: nil),
              playing: playing, position: position)
    }

    private func spin(_ seconds: TimeInterval) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }

    private func waitUntil(_ timeout: TimeInterval = 3, _ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline { spin(0.02) }
    }

    private struct Rig {
        let monitor: MediaMonitor
        let player: FakePlayer
        let distributed: NotificationCenter
        let workspace: NotificationCenter
    }

    private func makeRig(initial: MediaMonitor.Snapshot?, fallback: TimeInterval = 1000) -> Rig {
        let player = FakePlayer()
        player.set(initial)
        let distributed = NotificationCenter()
        let workspace = NotificationCenter()
        let monitor = MediaMonitor(distributed: distributed, workspace: workspace,
                                   fallbackInterval: fallback, fetch: { player.read() })
        return Rig(monitor: monitor, player: player, distributed: distributed, workspace: workspace)
    }

    func testReadsOnceAtStartAndThenStaysQuiet() {
        let rig = makeRig(initial: song("First"))
        waitUntil { rig.monitor.track != nil }
        XCTAssertEqual(rig.monitor.track?.title, "First")
        XCTAssertTrue(rig.monitor.isPlaying)
        spin(1.6)       // the old implementation read every second
        XCTAssertEqual(rig.player.reads, 1, "no polling without events")
    }

    func testPlaybackNotificationTriggersARead() {
        let rig = makeRig(initial: song("First"))
        waitUntil { rig.monitor.track != nil }
        rig.player.set(song("Second"))
        rig.distributed.post(name: Notification.Name(MediaMonitor.playbackNotifications[2]), object: nil)
        waitUntil { rig.monitor.track?.title == "Second" }
        XCTAssertEqual(rig.monitor.track?.title, "Second")
    }

    func testEveryPlayerNotificationIsObserved() {
        for name in MediaMonitor.playbackNotifications {
            let rig = makeRig(initial: nil)
            spin(0.2)
            let before = rig.player.reads
            rig.distributed.post(name: Notification.Name(name), object: nil)
            waitUntil { rig.player.reads > before }
            XCTAssertGreaterThan(rig.player.reads, before, name)
        }
    }

    func testRealDistributedCenterDeliversSpotifyNotifications() {
        // The same system-wide channel Spotify posts on, with the production observer setup.
        let player = FakePlayer()
        player.set(nil)
        let monitor = MediaMonitor(fallbackInterval: 1000, fetch: { player.read() })
        waitUntil { player.reads >= 1 }
        spin(0.3)
        let before = player.reads
        DistributedNotificationCenter.default().postNotificationName(
            Notification.Name("com.spotify.client.PlaybackStateChanged"), object: nil,
            userInfo: ["Player State": "Playing"], deliverImmediately: true)
        waitUntil { player.reads > before }
        XCTAssertGreaterThan(player.reads, before)
        withExtendedLifetime(monitor) {}
    }

    func testBurstOfNotificationsIsOneRead() {
        let rig = makeRig(initial: song("First"))
        waitUntil { rig.player.reads == 1 }
        spin(0.2)
        let before = rig.player.reads
        for _ in 0..<6 { rig.distributed.post(name: Notification.Name(MediaMonitor.playbackNotifications[2]), object: nil) }
        spin(0.8)
        XCTAssertEqual(rig.player.reads - before, 1)
    }

    func testPausingIsPickedUp() {
        let rig = makeRig(initial: song("First"))
        waitUntil { rig.monitor.isPlaying }
        rig.player.set(song("First", playing: false))
        rig.distributed.post(name: Notification.Name(MediaMonitor.playbackNotifications[2]), object: nil)
        waitUntil { !rig.monitor.isPlaying }
        XCTAssertFalse(rig.monitor.isPlaying)
        XCTAssertNotNil(rig.monitor.track, "paused is not the same as gone")
    }

    func testPlayerQuittingClearsTheTrack() {
        let rig = makeRig(initial: song("First"))
        waitUntil { rig.monitor.track != nil }
        rig.player.set(nil)
        rig.distributed.post(name: Notification.Name(MediaMonitor.playbackNotifications[0]), object: nil)
        waitUntil { rig.monitor.track == nil }
        XCTAssertNil(rig.monitor.track)
        XCTAssertFalse(rig.monitor.isPlaying)
    }

    func testFallbackPollCatchesAMissedNotification() {
        let rig = makeRig(initial: song("First"), fallback: 0.3)
        waitUntil { rig.monitor.track != nil }
        rig.player.set(song("Second"))              // no notification posted
        waitUntil { rig.monitor.track?.title == "Second" }
        XCTAssertEqual(rig.monitor.track?.title, "Second")
    }

    func testChangeDuringAReadIsNotLost() {
        // A read that is already running may predate the change; a second read must follow.
        let release = DispatchSemaphore(value: 0)
        let started = expectation(description: "slow read started")
        started.assertForOverFulfill = false
        let lock = NSLock()
        var reads = 0
        var title = "Old"
        let monitor = MediaMonitor(distributed: NotificationCenter(), workspace: NotificationCenter(), fallbackInterval: 1000) {
            lock.lock(); reads += 1; let n = reads; let current = title; lock.unlock()
            if n == 1 { started.fulfill(); _ = release.wait(timeout: .now() + 3) }     // first read is slow
            return .init(track: Track(source: .spotify, title: current, artist: "A", album: "B", duration: 100, artworkURL: nil),
                         playing: true, position: 0)
        }
        wait(for: [started], timeout: 2)
        lock.lock(); title = "New"; lock.unlock()
        monitor.perform(Selector(("playbackChanged")))     // the change arrives mid-read
        spin(0.4)
        release.signal()
        waitUntil { monitor.track?.title == "New" }
        XCTAssertEqual(monitor.track?.title, "New")
    }

    func testPositionAdvancesLocallyOnlyWhileTracking() {
        let rig = makeRig(initial: song("First", position: 10))
        waitUntil { rig.monitor.track != nil }
        let reads = rig.player.reads
        spin(1.3)
        XCTAssertEqual(rig.monitor.position, 10, "closed notch: the position is not maintained")

        rig.monitor.setPositionTracking(true)
        waitUntil { rig.player.reads > reads }          // a resync read on opening
        spin(2.2)
        XCTAssertGreaterThan(rig.monitor.position, 11.5, "advances without asking the player every second")
        XCTAssertLessThan(rig.player.reads, reads + 4)

        rig.monitor.setPositionTracking(false)
        let frozen = rig.monitor.position
        spin(1.3)
        XCTAssertEqual(rig.monitor.position, frozen)
    }
}
