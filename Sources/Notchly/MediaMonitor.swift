import AppKit
import Combine

enum MediaSource: String, CaseIterable {
    case spotify = "Spotify"
    case music = "Music"

    var prefKey: String { self == .spotify ? Pref.enableSpotify : Pref.enableMusic }
}

struct Track: Equatable {
    var source: MediaSource
    var title: String
    var artist: String
    var album: String
    var duration: Double
    var artworkURL: String?

    var key: String { "\(source.rawValue)|\(title)|\(artist)|\(album)" }
}

/// Polls Spotify and Apple Music via AppleScript.
/// (The private MediaRemote framework is locked down for third-party apps on current macOS.)
final class MediaMonitor: ObservableObject {
    @Published private(set) var track: Track?
    @Published private(set) var isPlaying = false
    @Published private(set) var position: Double = 0
    @Published private(set) var artwork: NSImage?
    /// A vivid colour taken from the artwork (nil for greyscale art or when there is none).
    @Published private(set) var accent: NSColor?

    private let queue = DispatchQueue(label: "notchly.media")
    private var timer: Timer?
    private var artworkKey = ""
    private var busy = false
    private var positionLockedUntil = Date.distantPast

    init() {
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.poll() }
        poll()
    }

    // MARK: Controls

    func togglePlayPause() { command("playpause") }
    func next() { command("next track") }
    func previous() { command("previous track") }

    /// Jumps to `seconds` in the current track.
    func seek(to seconds: Double) {
        guard let track, track.duration > 0 else { return }
        let target = min(max(seconds, 0), track.duration)
        let source = track.source
        position = target                                       // move the bar immediately
        positionLockedUntil = Date().addingTimeInterval(0.8)
        queue.async {
            _ = Self.run("tell application \"\(source.rawValue)\" to set player position to \(Int(target))")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak self] in self?.poll() }
    }

    private func command(_ verb: String) {
        guard let source = track?.source else { return }
        queue.async {
            _ = Self.run("tell application \"\(source.rawValue)\" to \(verb)")
            DispatchQueue.main.async { self.poll() }
        }
        // Optimistic UI for play/pause.
        if verb == "playpause" { isPlaying.toggle() }
    }

    // MARK: Polling

    private func poll() {
        guard !busy else { return }
        busy = true
        queue.async { [weak self] in
            guard let self else { return }
            let snapshot = Self.snapshot()
            DispatchQueue.main.async {
                self.busy = false
                self.apply(snapshot)
            }
        }
    }

    private struct Snapshot {
        var track: Track
        var playing: Bool
        var position: Double
    }

    private func apply(_ s: Snapshot?) {
        guard let s else {
            if track != nil { track = nil }
            isPlaying = false
            position = 0
            artwork = nil
            accent = nil
            artworkKey = ""
            return
        }
        if track != s.track { track = s.track }
        isPlaying = s.playing
        // Right after a seek, ignore polls that were already in flight (they carry the old position).
        if Date() >= positionLockedUntil { position = s.position }
        loadArtworkIfNeeded(for: s.track)
    }

    private func loadArtworkIfNeeded(for t: Track) {
        guard t.key != artworkKey else { return }
        artworkKey = t.key
        artwork = nil
        accent = nil
        let key = t.key
        if let urlString = t.artworkURL, let url = URL(string: urlString) {
            URLSession.shared.dataTask(with: url) { data, _, _ in
                guard let data, let image = NSImage(data: data) else { return }
                let accent = ArtworkColor.accent(for: image)
                DispatchQueue.main.async { self.setArtwork(image, accent: accent, for: key) }
            }.resume()
        } else if t.source == .music {
            queue.async {
                let desc = Self.run("tell application \"Music\" to return data of artwork 1 of current track")
                let image = desc.flatMap { NSImage(data: $0.data) }
                let accent = image.flatMap { ArtworkColor.accent(for: $0) }
                DispatchQueue.main.async { self.setArtwork(image, accent: accent, for: key) }
            }
        }
    }

    private func setArtwork(_ image: NSImage?, accent: NSColor?, for key: String) {
        guard artworkKey == key else { return }     // the track changed while this was loading
        artwork = image
        self.accent = accent
    }

    // MARK: AppleScript

    private static var loggedErrors = Set<Int>()

    private static func run(_ source: String) -> NSAppleEventDescriptor? {
        var error: NSDictionary?
        let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
        if let error, let code = error[NSAppleScript.errorNumber] as? Int, loggedErrors.insert(code).inserted {
            // Logged once per error code, e.g. -1743 = Automation permission denied.
            NSLog("Notchly AppleScript error \(code): \(error[NSAppleScript.errorMessage] ?? "")")
        }
        return result
    }

    /// Parses numbers from AppleScript text, tolerating locale decimal commas ("49,5").
    private static func number(_ s: String) -> Double {
        Double(s.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")) ?? 0
    }

    private static func snapshot() -> Snapshot? {
        var paused: Snapshot?
        for source in MediaSource.allCases {
            guard Pref.bool(source.prefKey),
                  NSWorkspace.shared.runningApplications.contains(where: { $0.localizedName == source.rawValue }),
                  let s = query(source) else { continue }
            if s.playing { return s }
            paused = paused ?? s
        }
        return paused
    }

    private static func query(_ source: MediaSource) -> Snapshot? {
        let script: String
        switch source {
        case .spotify:
            script = """
            tell application "Spotify"
                if player state is stopped then return ""
                set t to current track
                return (player state as text) & "||" & (name of t) & "||" & (artist of t) & "||" & (album of t) & "||" & (player position as text) & "||" & ((duration of t) as text) & "||" & (artwork url of t)
            end tell
            """
        case .music:
            script = """
            tell application "Music"
                if player state is stopped then return ""
                set t to current track
                return (player state as text) & "||" & (name of t) & "||" & (artist of t) & "||" & (album of t) & "||" & (player position as text) & "||" & ((duration of t) as text)
            end tell
            """
        }
        guard let out = run(script)?.stringValue, !out.isEmpty else { return nil }
        let f = out.components(separatedBy: "||")
        guard f.count >= 6 else { return nil }
        // Spotify reports milliseconds, Music reports seconds.
        let rawDuration = number(f[5])
        let duration = source == .spotify ? rawDuration / 1000 : rawDuration
        let track = Track(
            source: source, title: f[1], artist: f[2], album: f[3], duration: duration,
            artworkURL: f.count > 6 ? f[6] : nil
        )
        return Snapshot(track: track, playing: f[0] == "playing", position: number(f[4]))
    }
}
