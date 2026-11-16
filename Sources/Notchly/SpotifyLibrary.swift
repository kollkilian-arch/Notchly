import AppKit
import Combine
import CryptoKit
import Network
import Security

/// Spotify account authorization and Liked Songs, independent of playback control.
@MainActor
final class SpotifyLibrary: ObservableObject {
    static let shared = SpotifyLibrary()
    static let redirectURI = "http://127.0.0.1:43871/callback"
    private static let service = "app.notchly.spotify.library"

    enum TrackState: Equatable { case unavailable, signedOut, checking, unsaved, saved, saving, removing, failed }
    @Published private(set) var connected = false
    @Published private(set) var connecting = false
    @Published private(set) var trackState: TrackState = .signedOut
    @Published private(set) var message: String?
    @Published private(set) var currentURI: String?

    private let session: URLSession
    private var credentials: Credentials?
    private var accessToken: String?
    private var tokenExpiry = Date.distantPast
    private var listener: NWListener?
    private var authTimeout: DispatchWorkItem?
    private var authID = UUID()
    private var requestID = UUID()
    private var checkTask: Task<Void, Never>?

    private struct Credentials: Codable {
        let clientID: String
        var refreshToken: String
    }
    private struct TokenResponse: Decodable {
        let access_token: String
        let token_type: String
        let expires_in: Double
        let refresh_token: String?
    }
    private struct APIError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    init() {
        session = .shared
        if let data = Self.readKeychain(), let saved = try? JSONDecoder().decode(Credentials.self, from: data) {
            credentials = saved
            connected = true
        }
    }

    /// An isolated account with an injected transport for deterministic tests.
    init(testSession: URLSession, accessToken: String) {
        session = testSession
        self.accessToken = accessToken
        tokenExpiry = .distantFuture
        credentials = Credentials(clientID: "test", refreshToken: "test")
        connected = true
    }

    func connect(clientID: String) {
        let id = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty, id.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else {
            message = "Enter a valid Spotify client ID in Settings."
            return
        }
        guard !connecting else { return }
        do {
            let verifier = try Self.randomString()
            let state = try Self.randomString()
            let challenge = Self.base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
            let params = NWParameters.tcp
            params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: 43871)
            let server = try NWListener(using: params)
            let attempt = UUID()
            authID = attempt
            connecting = true
            message = nil
            listener = server
            let timeout = DispatchWorkItem { [weak self] in
                guard let self, self.authID == attempt else { return }
                self.finishAuthorization(message: "Spotify sign-in timed out. Please try again.")
            }
            authTimeout = timeout
            DispatchQueue.main.asyncAfter(deadline: .now() + 180, execute: timeout)
            server.stateUpdateHandler = { [weak self] status in
                Task { @MainActor in
                    guard let self, self.authID == attempt else { return }
                    switch status {
                    case .ready:
                        var components = URLComponents(string: "https://accounts.spotify.com/authorize")!
                        components.queryItems = [
                            URLQueryItem(name: "client_id", value: id), URLQueryItem(name: "response_type", value: "code"),
                            URLQueryItem(name: "redirect_uri", value: Self.redirectURI),
                            URLQueryItem(name: "scope", value: "user-library-read user-library-modify"),
                            URLQueryItem(name: "state", value: state), URLQueryItem(name: "code_challenge_method", value: "S256"),
                            URLQueryItem(name: "code_challenge", value: challenge),
                        ]
                        guard let url = components.url, NSWorkspace.shared.open(url) else {
                            self.finishAuthorization(message: "Couldn't open the browser for Spotify sign-in.")
                            return
                        }
                    case .failed:
                        self.finishAuthorization(message: "Couldn't start the Spotify sign-in callback. Check whether port 43871 is in use.")
                    default: break
                    }
                }
            }
            server.newConnectionHandler = { [weak self] connection in
                connection.start(queue: .main)
                connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { data, _, _, _ in
                    let request = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                    Task { @MainActor [weak self] in
                        let result = Self.callback(request: request, expectedState: state)
                        let text = result == nil ? "Invalid sign-in response. Return to Notchly and try again." : "You can return to Notchly."
                        let body = "<!doctype html><html><body>\(text)</body></html>"
                        let response = "HTTP/1.1 \(result == nil ? "400 Bad Request" : "200 OK")\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
                        connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
                        guard let result, let self, self.authID == attempt else { return }
                        self.listener?.cancel(); self.listener = nil
                        switch result {
                        case .failure(let error): self.finishAuthorization(message: error.localizedDescription)
                        case .success(let code):
                            do {
                                let token = try await Self.tokenRequest([
                                    "client_id": id, "grant_type": "authorization_code", "code": code,
                                    "redirect_uri": Self.redirectURI, "code_verifier": verifier,
                                ], session: self.session)
                                guard self.authID == attempt else { return }
                                guard let refresh = token.refresh_token else { throw APIError(message: "Spotify didn't provide a refresh token. Please sign in again.") }
                                let saved = Credentials(clientID: id, refreshToken: refresh)
                                try Self.writeKeychain(try JSONEncoder().encode(saved))
                                self.credentials = saved
                                self.accessToken = token.access_token
                                self.tokenExpiry = Date().addingTimeInterval(token.expires_in - 60)
                                self.connected = true
                                self.finishAuthorization(message: nil)
                                self.refreshCurrentTrack()
                            } catch {
                                guard self.authID == attempt else { return }
                                self.finishAuthorization(message: error.localizedDescription)
                            }
                        }
                    }
                }
            }
            server.start(queue: .main)
        } catch { message = error.localizedDescription }
    }

    func disconnect() {
        authID = UUID()
        finishAuthorization(message: nil)
        checkTask?.cancel()
        requestID = UUID()
        let status = Self.deleteKeychain()
        guard status == errSecSuccess || status == errSecItemNotFound else {
            message = "Couldn't remove Spotify sign-in from Keychain (\(status))."
            return
        }
        credentials = nil
        accessToken = nil
        connected = false
        trackState = currentURI == nil ? .unavailable : .signedOut
    }

    func setTrack(_ track: Track?) {
        let uri = track.flatMap { $0.source == .spotify ? Self.validTrackURI($0.spotifyURI) : nil }
        guard uri != currentURI else { return }
        currentURI = uri
        refreshCurrentTrack()
    }

    private func refreshCurrentTrack() {
        checkTask?.cancel()
        let request = UUID()
        requestID = request
        guard let uri = currentURI else { trackState = .unavailable; return }
        guard connected else { trackState = .signedOut; return }
        trackState = .checking
        checkTask = Task {
            do {
                let data = try await libraryRequest(path: "/v1/me/library/contains", method: "GET", uri: uri)
                let values = try JSONDecoder().decode([Bool].self, from: data)
                guard let saved = values.first else { throw APIError(message: "Spotify returned an empty library response.") }
                guard !Task.isCancelled, requestID == request else { return }
                trackState = saved ? .saved : .unsaved
                message = nil
            } catch {
                guard !Task.isCancelled, requestID == request else { return }
                trackState = .failed
                message = error.localizedDescription
            }
        }
    }

    func toggleCurrentTrack() {
        guard let uri = currentURI, connected else { return }
        // An error can leave the server state uncertain. Check again before another change.
        if trackState == .failed { refreshCurrentTrack(); return }
        guard trackState == .unsaved || trackState == .saved else { return }
        let removing = trackState == .saved
        checkTask?.cancel()
        let request = UUID()
        requestID = request
        trackState = removing ? .removing : .saving
        message = nil
        Task {
            do {
                _ = try await libraryRequest(path: "/v1/me/library", method: removing ? "DELETE" : "PUT", uri: uri)
                guard requestID == request else { return }
                trackState = removing ? .unsaved : .saved
                message = nil
            } catch {
                guard requestID == request else { return }
                trackState = .failed
                message = error.localizedDescription
            }
        }
    }

    private func finishAuthorization(message: String?) {
        listener?.cancel(); listener = nil
        authTimeout?.cancel(); authTimeout = nil
        connecting = false
        self.message = message
        authID = UUID()
    }

    private func libraryRequest(path: String, method: String, uri: String) async throws -> Data {
        for attempt in 0...1 {
            let token = try await validAccessToken(forceRefresh: attempt == 1)
            var components = URLComponents(string: "https://api.spotify.com\(path)")!
            components.queryItems = [URLQueryItem(name: "uris", value: uri)]
            var request = URLRequest(url: components.url!)
            request.httpMethod = method
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw APIError(message: "Invalid Spotify response.") }
            if http.statusCode == 401 && attempt == 0 { continue }
            guard (200...299).contains(http.statusCode) else {
                if http.statusCode == 403 { throw APIError(message: "Spotify denied access. Check your app's user allowlist and permissions.") }
                if http.statusCode == 429 { throw APIError(message: "Spotify's request limit was reached. Try again later.") }
                throw APIError(message: "Spotify request failed (\(http.statusCode)).")
            }
            return data
        }
        throw APIError(message: "Spotify sign-in expired. Please reconnect in Settings.")
    }

    private func validAccessToken(forceRefresh: Bool) async throws -> String {
        if !forceRefresh, let accessToken, tokenExpiry > Date() { return accessToken }
        guard let credentials else { throw APIError(message: "Connect Spotify in Settings first.") }
        let token = try await Self.tokenRequest(["client_id": credentials.clientID, "grant_type": "refresh_token", "refresh_token": credentials.refreshToken], session: session)
        guard self.credentials?.clientID == credentials.clientID, self.credentials?.refreshToken == credentials.refreshToken else {
            throw APIError(message: "Spotify account changed. Please try again.")
        }
        if let refresh = token.refresh_token {
            let updated = Credentials(clientID: credentials.clientID, refreshToken: refresh)
            try Self.writeKeychain(try JSONEncoder().encode(updated))
            self.credentials = updated
        }
        accessToken = token.access_token
        tokenExpiry = Date().addingTimeInterval(token.expires_in - 60)
        return token.access_token
    }

    private static func tokenRequest(_ fields: [String: String], session: URLSession) async throws -> TokenResponse {
        var request = URLRequest(url: URL(string: "https://accounts.spotify.com/api/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var components = URLComponents()
        components.queryItems = fields.map { URLQueryItem(name: $0.key, value: $0.value) }
        request.httpBody = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B").data(using: .utf8)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw APIError(message: "Spotify authorization failed. Check your client ID and reconnect.")
        }
        return try JSONDecoder().decode(TokenResponse.self, from: data)
    }

    static func validTrackURI(_ uri: String?) -> String? {
        guard let uri, uri.hasPrefix("spotify:track:") else { return nil }
        let id = uri.dropFirst("spotify:track:".count)
        guard id.count == 22, id.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else { return nil }
        return uri
    }

    static func callback(request: String, expectedState: String) -> Result<String, Error>? {
        guard let line = request.components(separatedBy: "\r\n").first else { return nil }
        let parts = line.split(separator: " ")
        guard parts.count >= 2, parts[0] == "GET", let components = URLComponents(string: "http://127.0.0.1\(parts[1])"), components.path == "/callback" else { return nil }
        let items = components.queryItems ?? []
        guard items.filter({ $0.name == "state" }).count == 1, items.first(where: { $0.name == "state" })?.value == expectedState else { return nil }
        if let error = items.first(where: { $0.name == "error" })?.value { return .failure(APIError(message: "Spotify sign-in was declined (\(error)).")) }
        guard items.filter({ $0.name == "code" }).count == 1, let code = items.first(where: { $0.name == "code" })?.value, !code.isEmpty else { return nil }
        return .success(code)
    }

    private static func randomString() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw APIError(message: "Couldn't create a secure Spotify sign-in request.") }
        return base64URL(Data(bytes))
    }
    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    private static var keychainQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: "spotify"]
    }
    private static func readKeychain() -> Data? {
        var query = keychainQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        return SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess ? result as? Data : nil
    }
    private static func writeKeychain(_ data: Data) throws {
        let query = keychainQuery
        let update = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else { throw APIError(message: "Couldn't update Spotify sign-in in Keychain (\(update)).") }
        var item = query
        item[kSecValueData as String] = data
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw APIError(message: "Couldn't store Spotify sign-in in Keychain (\(status)).") }
    }
    private static func deleteKeychain() -> OSStatus { SecItemDelete(keychainQuery as CFDictionary) }
}
