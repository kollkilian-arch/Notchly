import Foundation

struct MeetingLink: Equatable {
    let url: URL
    let service: String
}

/// Finds a video-call link in a calendar event's URL, location and notes.
enum MeetingLinks {
    /// Texts are searched in order (e.g. the event URL first, then location, then notes); the first
    /// recognised meeting link wins.
    static func find(in texts: [String?]) -> MeetingLink? {
        for text in texts.compactMap({ $0 }) where !text.isEmpty {
            for url in urls(in: text) {
                if let link = classify(unwrap(url)) { return link }
            }
        }
        return nil
    }

    // MARK: URL extraction

    private static let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

    private static func urls(in text: String) -> [URL] {
        let range = NSRange(text.startIndex..., in: text)
        return detector?.matches(in: text, options: [], range: range).compactMap { $0.url } ?? []
    }

    /// Outlook "Safe Links" and Google redirect links hide the real URL in a query parameter.
    private static func unwrap(_ url: URL) -> URL {
        guard let host = url.host?.lowercased(),
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { return url }
        let key: String?
        if host.hasSuffix("safelinks.protection.outlook.com") { key = "url" }
        else if host == "www.google.com" || host == "google.com", url.path == "/url" { key = "q" }
        else { key = nil }
        if let key, let value = items.first(where: { $0.name == key })?.value, let inner = URL(string: value) {
            return inner
        }
        return url
    }

    // MARK: Recognised services

    private static func classify(_ url: URL) -> MeetingLink? {
        guard let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
              let host = url.host?.lowercased() else { return nil }
        let path = url.path.lowercased()

        func isHost(_ domain: String) -> Bool { host == domain || host.hasSuffix("." + domain) }
        func make(_ service: String) -> MeetingLink { MeetingLink(url: url, service: service) }

        // Zoom: /j/<id>, /my/<name>, /wc/join/<id>, /s/<id> …
        if isHost("zoom.us") || isHost("zoom.com") || isHost("zoomgov.com") {
            return path.count > 2 ? make("Zoom") : nil
        }
        // Google Meet: /abc-defg-hij (not the landing page)
        if host == "meet.google.com" {
            return path.count > 4 && !path.hasPrefix("/landing") ? make("Google Meet") : nil
        }
        // Microsoft Teams
        if host == "teams.microsoft.com" {
            return path.contains("meetup-join") || path.hasPrefix("/meet/") ? make("Teams") : nil
        }
        if host == "teams.live.com" {
            return path.hasPrefix("/meet") ? make("Teams") : nil
        }
        // Cisco Webex
        if isHost("webex.com") {
            return path.contains("/meet") || path.contains("/j.php") || path.contains("/join") || path.count > 1 ? make("Webex") : nil
        }
        if isHost("whereby.com") { return path.count > 1 ? make("Whereby") : nil }
        if host == "meet.jit.si" { return path.count > 1 ? make("Jitsi") : nil }
        if host == "gotomeet.me" || (isHost("goto.com") && path.contains("/meet")) || (isHost("gotomeeting.com") && path.count > 1) {
            return make("GoTo")
        }
        if isHost("bluejeans.com") { return path.count > 1 ? make("BlueJeans") : nil }
        if host == "facetime.apple.com" { return path.contains("/join") ? make("FaceTime") : nil }
        if isHost("chime.aws") { return path.count > 1 ? make("Chime") : nil }
        if host == "app.slack.com" || host == "slack.com", path.contains("huddle") { return make("Slack") }
        if isHost("around.co") { return path.count > 1 ? make("Around") : nil }
        return nil
    }
}
