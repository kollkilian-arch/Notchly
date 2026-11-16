import XCTest
@testable import Notchly

private final class SpotifyMockProtocol: URLProtocol {
    static var handler: ((URLRequest) -> (Int, Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let (status, data) = Self.handler?(request), let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse)); return
        }
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@MainActor
final class SpotifyLibraryTests: XCTestCase {
    private let uri = "spotify:track:7a3LWj5xSFhFRYmztS8wgK"

    func testTrackIdentifiersExcludeLocalFilesAndEpisodes() {
        XCTAssertEqual(SpotifyLibrary.validTrackURI(uri), uri)
        XCTAssertNil(SpotifyLibrary.validTrackURI("spotify:local:artist:album:song:12"))
        XCTAssertNil(SpotifyLibrary.validTrackURI("spotify:episode:7a3LWj5xSFhFRYmztS8wgK"))
        XCTAssertNil(SpotifyLibrary.validTrackURI("spotify:track:bad"))
        let snapshot = MediaMonitor.parseSnapshot("playing||Song||Artist||Album||1||2000||art||false||true||\(uri)", source: .spotify)
        XCTAssertEqual(snapshot?.track.spotifyURI, uri)
    }

    func testCallbackRequiresExactPathAndState() {
        XCTAssertEqual(try? SpotifyLibrary.callback(request: "GET /callback?code=abc&state=right HTTP/1.1\r\n\r\n", expectedState: "right")?.get(), "abc")
        XCTAssertNil(SpotifyLibrary.callback(request: "GET /callback?code=abc&state=wrong HTTP/1.1\r\n\r\n", expectedState: "right"))
        XCTAssertNil(SpotifyLibrary.callback(request: "GET /other?code=abc&state=right HTTP/1.1\r\n\r\n", expectedState: "right"))
        XCTAssertNil(SpotifyLibrary.callback(request: "GET /callback?code=abc&state=right&state=right HTTP/1.1\r\n\r\n", expectedState: "right"))
        XCTAssertThrowsError(try SpotifyLibrary.callback(request: "GET /callback?error=access_denied&state=right HTTP/1.1\r\n\r\n", expectedState: "right")!.get())
    }

    func testCheckAndSaveCurrentTrack() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SpotifyMockProtocol.self]
        let session = URLSession(configuration: configuration)
        let library = SpotifyLibrary(testSession: session, accessToken: "token")
        SpotifyMockProtocol.handler = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer token")
            let components = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!
            XCTAssertEqual(components.queryItems?.first(where: { $0.name == "uris" })?.value, self.uri)
            if request.httpMethod == "GET" {
                XCTAssertEqual(components.path, "/v1/me/library/contains")
                return (200, Data("[false]".utf8))
            }
            XCTAssertTrue(["PUT", "DELETE"].contains(request.httpMethod ?? ""))
            XCTAssertEqual(components.path, "/v1/me/library")
            return (200, Data())
        }
        defer { SpotifyMockProtocol.handler = nil; session.invalidateAndCancel() }
        library.setTrack(Track(source: .spotify, title: "Song", artist: "Artist", album: "Album", duration: 1, artworkURL: nil, spotifyURI: uri))
        try await waitUntil { library.trackState == .unsaved }
        SpotifyMockProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "PUT")
            XCTAssertEqual(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first?.value, self.uri)
            return (200, Data())
        }
        library.toggleCurrentTrack()
        try await waitUntil { library.trackState == .saved }
        SpotifyMockProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "DELETE")
            XCTAssertEqual(request.url?.path, "/v1/me/library")
            XCTAssertEqual(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first?.value, self.uri)
            return (200, Data())
        }
        library.toggleCurrentTrack()
        try await waitUntil { library.trackState == .unsaved }
        library.setTrack(Track(source: .music, title: "Song", artist: "Artist", album: "Album", duration: 1, artworkURL: nil))
        XCTAssertEqual(library.trackState, .unavailable)
    }

    func testFailedSaveIsVisibleAndRetryable() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SpotifyMockProtocol.self]
        let session = URLSession(configuration: configuration)
        let library = SpotifyLibrary(testSession: session, accessToken: "token")
        SpotifyMockProtocol.handler = { request in
            request.httpMethod == "GET" ? (200, Data("[false]".utf8)) : (403, Data())
        }
        defer { SpotifyMockProtocol.handler = nil; session.invalidateAndCancel() }
        library.setTrack(Track(source: .spotify, title: "Song", artist: "Artist", album: "Album", duration: 1, artworkURL: nil, spotifyURI: uri))
        try await waitUntil { library.trackState == .unsaved }
        library.toggleCurrentTrack()
        try await waitUntil { library.trackState == .failed }
        XCTAssertTrue(library.message?.contains("allowlist") == true)
        library.toggleCurrentTrack()
        try await waitUntil { library.trackState == .unsaved }
    }

    func testFailedRemovalRechecksBeforeAnotherChange() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SpotifyMockProtocol.self]
        let session = URLSession(configuration: configuration)
        let library = SpotifyLibrary(testSession: session, accessToken: "token")
        defer { SpotifyMockProtocol.handler = nil; session.invalidateAndCancel() }
        SpotifyMockProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "GET")
            return (200, Data("[true]".utf8))
        }
        library.setTrack(Track(source: .spotify, title: "Song", artist: "Artist", album: "Album", duration: 1, artworkURL: nil, spotifyURI: uri))
        try await waitUntil { library.trackState == .saved }
        SpotifyMockProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "DELETE")
            return (403, Data())
        }
        library.toggleCurrentTrack()
        try await waitUntil { library.trackState == .failed }
        SpotifyMockProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "GET")
            return (200, Data("[true]".utf8))
        }
        library.toggleCurrentTrack()
        try await waitUntil { library.trackState == .saved }
    }

    private func waitUntil(_ predicate: () -> Bool) async throws {
        for _ in 0..<100 {
            if predicate() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Timed out waiting for Spotify state")
    }
}
