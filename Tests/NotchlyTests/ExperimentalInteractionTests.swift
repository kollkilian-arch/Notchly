import AppKit
import UniformTypeIdentifiers
import XCTest
@testable import Notchly

final class DaySwipeTests: XCTestCase {
    func testAccumulatesTrackpadMovementAndPreservesRemainder() {
        var swipe = DaySwipeAccumulator()
        XCTAssertEqual(swipe.consume(x: -20, y: 1), 0)
        XCTAssertEqual(swipe.consume(x: -20, y: 1), 1)
        XCTAssertEqual(swipe.consume(x: -32, y: 0), 1)
    }
    func testVerticalScrollingDoesNotMoveDates() {
        var swipe = DaySwipeAccumulator()
        XCTAssertEqual(swipe.consume(x: -4, y: 60), 0)
        XCTAssertEqual(swipe.consume(x: -32, y: 0), 0)
    }
    func testDirectionResetAndLargeGestureClamp() {
        var swipe = DaySwipeAccumulator()
        XCTAssertEqual(swipe.consume(x: 36, y: 0), -1)
        _ = swipe.consume(x: 24, y: 0)
        swipe.reset()
        XCTAssertEqual(swipe.consume(x: 20, y: 0), 0)
        XCTAssertEqual(swipe.consume(x: -1000, y: 0), 3)
        XCTAssertEqual(swipe.consume(x: -1, y: 0), 0)
    }
}

final class ShuffleTests: XCTestCase {
    func testPreviewReflectsPlayerShuffleStateAndTogglesIt() {
        let track = Track(source: .spotify, title: "Test", artist: "Artist", album: "Album", duration: 100, artworkURL: nil)
        let media = MediaMonitor(preview: .init(track: track, playing: true, position: 0, shuffling: true, canShuffle: true))
        XCTAssertTrue(media.isShuffling)
        media.toggleShuffle()
        XCTAssertFalse(media.isShuffling)
        media.toggleShuffle()
        XCTAssertTrue(media.isShuffling)
    }
    func testSpotifySnapshotParsesShuffleAndCapability() throws {
        let snapshot = try XCTUnwrap(MediaMonitor.parseSnapshot("playing||Song||Artist||Album||12.5||200000||https://example.com/art.jpg||true||true", source: .spotify))
        XCTAssertEqual(snapshot.position, 12.5)
        XCTAssertEqual(snapshot.track.duration, 200)
        XCTAssertTrue(snapshot.shuffling)
        XCTAssertTrue(snapshot.canShuffle)
    }
    func testMusicSnapshotKeepsArtworkSlotAndParsesShuffle() throws {
        let snapshot = try XCTUnwrap(MediaMonitor.parseSnapshot("paused||Song||Artist||Album||12||200||||false||true", source: .music))
        XCTAssertNil(snapshot.track.artworkURL)
        XCTAssertEqual(snapshot.track.duration, 200)
        XCTAssertFalse(snapshot.shuffling)
        XCTAssertTrue(snapshot.canShuffle)
    }

    func testUnavailableShuffleDoesNotPretendToChangeIt() {
        let track = Track(source: .spotify, title: "Test", artist: "Artist", album: "Album", duration: 100, artworkURL: nil)
        let media = MediaMonitor(preview: .init(track: track, playing: true, position: 0))
        media.toggleShuffle()
        XCTAssertFalse(media.isShuffling)
    }
}

final class AirDropDropTests: XCTestCase {
    private func load(_ providers: [NSItemProvider]) throws -> AirDropPayload {
        let done = expectation(description: "Resolved AirDrop payload")
        var loaded: Result<AirDropPayload, Error>?
        AirDropDropLoader.load(providers) { result in loaded = result; done.fulfill() }
        wait(for: [done], timeout: 5)
        return try XCTUnwrap(loaded).get()
    }
    func testDropResolvesFilesAndTextWithoutAddingThemToShelf() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("Original.txt")
        try "Original".write(to: file, atomically: true, encoding: .utf8)
        let shelf = ShelfStore(storeURL: root.appendingPathComponent("shelf.json"))
        let payload = try load([NSItemProvider(object: file as NSURL), NSItemProvider(object: "Shared note" as NSString)])
        XCTAssertEqual(payload.urls.count, 2)
        XCTAssertEqual(payload.urls.first?.standardizedFileURL, file.standardizedFileURL)
        XCTAssertEqual(try String(contentsOf: payload.urls[1]), "Shared note")
        XCTAssertTrue(shelf.items.isEmpty)
        payload.cleanUp()
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path), "Cleanup must not delete the source")
        XCTAssertFalse(FileManager.default.fileExists(atPath: payload.temporaryDirectory.path))
    }
    func testImageDropCreatesAnOwnedPNG() throws {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1, pixelsHigh: 1,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 4, bitsPerPixel: 32))
        bitmap.setColor(.red, atX: 0, y: 0)
        let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        let provider = NSItemProvider(item: data as NSData, typeIdentifier: UTType.png.identifier)
        let payload = try load([provider])
        defer { payload.cleanUp() }
        XCTAssertEqual(payload.urls.first?.pathExtension, "png")
        XCTAssertEqual(NSBitmapImageRep(data: try Data(contentsOf: payload.urls[0]))?.pixelsWide, 1)
    }

    func testLinkUsesOneRepresentation() throws {
        let url = URL(string: "https://example.com/notes")!
        let payload = try load([NSItemProvider(object: url as NSURL)])
        defer { payload.cleanUp() }
        XCTAssertEqual(payload.urls, [url])
    }
    func testUnsupportedDropFailsBeforeSharing() {
        let done = expectation(description: "Rejected unsupported provider")
        AirDropDropLoader.load([NSItemProvider()]) { result in
            if case .success(let payload) = result { payload.cleanUp(); XCTFail("Unsupported data must not be shared") }
            done.fulfill()
        }
        wait(for: [done], timeout: 2)
    }
    func testMissingFileDoesNotProduceAPartialShare() throws {
        let missing = URL(fileURLWithPath: "/tmp/Notchly-missing-\(UUID().uuidString)")
        XCTAssertThrowsError(try load([NSItemProvider(object: missing as NSURL), NSItemProvider(object: "Note" as NSString)]))
    }
}
