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
    var spotifyURI: String? = nil

    var key: String { "\(source.rawValue)|\(title)|\(artist)|\(album)" }
}

/// Where the playhead is, extrapolated from the last real reading so nothing has to ask the player
/// every second.
struct PositionClock: Equatable {
    var base: Double = 0
    var at: Date = .distantPast
    var playing = false

    func value(at now: Date = Date()) -> Double {
        playing ? base + max(0, now.timeIntervalSince(at)) : base
    }
}

/// Follows Spotify and Apple Music through AppleScript, but only asks when something happened:
/// both apps broadcast a distributed notification on every play, pause and track change, and
/// launching or quitting them is observed through NSWorkspace. A slow fallback poll covers a missed
/// notification. While a progress bar is visible, it advances locally and is re-synced every
/// few seconds. Hidden progress bars do not need a position timer.
/// (The private MediaRemote framework is locked down for third-party apps on current macOS.)
final class MediaMonitor: NSObject, ObservableObject {
    @Published private(set) var track: Track?
    @Published private(set) var isPlaying = false
    @Published private(set) var position: Double = 0
    @Published private(set) var artwork: NSImage?
    /// A vivid colour taken from the artwork (nil for greyscale art or when there is none).
    @Published private(set) var accent: NSColor?
    @Published private(set) var isShuffling = false
    @Published private(set) var canShuffle = false

    /// What the players broadcast. Used only as a "something changed" signal, so there is one
    /// parsing path (the AppleScript snapshot).
    static let playbackNotifications = [
        "com.apple.Music.playerInfo", "com.apple.iTunes.playerInfo", "com.spotify.client.PlaybackStateChanged",
    ]
    private static let playerBundleIDs: Set<String> = ["com.spotify.client", "com.apple.Music"]
    /// While a progress bar is visible, ask the player for the real position every this many seconds.
    private static let resyncTicks = 10

    private let queue = DispatchQueue(label: "notchly.media")
    private let fetch: () -> Snapshot?
    private var fallbackTimer: Timer?
    private var positionTimer: Timer?
    private var pollWork: DispatchWorkItem?
    private var artworkKey = ""
    private var busy = false
    private var pollAgain = false
    private var positionLockedUntil = Date.distantPast
    private var clock = PositionClock()
    private var trackingPosition = false
    private var ticks = 0
    private var lastEnabled: [Bool]
    private var isPreview = false

    /// Fixed sample playback for layout verification; never controls a real player.
    init(preview snapshot: Snapshot, artwork: NSImage? = nil, accent: NSColor? = nil) {
        fetch = { snapshot }
        lastEnabled = []
        super.init()
        isPreview = true
        track = snapshot.track
        isPlaying = snapshot.playing
        position = snapshot.position
        clock = PositionClock(base: snapshot.position, at: Date(), playing: snapshot.playing)
        self.artwork = artwork
        self.accent = accent
        isShuffling = snapshot.shuffling
        canShuffle = snapshot.canShuffle
    }

    /// - Parameters:
    ///   - distributed: where the players post their playback notifications.
    ///   - workspace: where app launch/quit and wake notifications come from.
    ///   - fallbackInterval: how often to poll when no notification arrives (seconds).
    ///   - fetch: reads the player state; replaced in tests.
    init(distributed: NotificationCenter = DistributedNotificationCenter.default(),
         workspace: NotificationCenter = NSWorkspace.shared.notificationCenter,
         fallbackInterval: TimeInterval = 30,
         fetch: @escaping () -> Snapshot? = MediaMonitor.snapshot) {
        self.fetch = fetch
        lastEnabled = MediaSource.allCases.map { Pref.bool($0.prefKey) }
        super.init()

        for name in Self.playbackNotifications {
            if let center = distributed as? DistributedNotificationCenter {
                // Without this, a background app has these held back until it becomes active.
                center.addObserver(self, selector: #selector(playbackChanged), name: .init(name), object: nil,
                                   suspensionBehavior: .deliverImmediately)
            } else {
                distributed.addObserver(self, selector: #selector(playbackChanged), name: .init(name), object: nil)
            }
        }
        workspace.addObserver(self, selector: #selector(playerLaunched(_:)),
                              name: NSWorkspace.didLaunchApplicationNotification, object: nil)
        workspace.addObserver(self, selector: #selector(playerTerminated(_:)),
                              name: NSWorkspace.didTerminateApplicationNotification, object: nil)
        workspace.addObserver(self, selector: #selector(playbackChanged),
                              name: NSWorkspace.didWakeNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(defaultsChanged),
                                               name: UserDefaults.didChangeNotification, object: nil)

        fallbackTimer = Timer.scheduledTimer(withTimeInterval: fallbackInterval, repeats: true) { [weak self] _ in
            self?.poll()
        }
        poll()
    }

    deinit {
        fallbackTimer?.invalidate()
        positionTimer?.invalidate()
        pollWork?.cancel()
    }

    // MARK: Events

    @objc private func playbackChanged() { requestPoll() }

    @objc private func playerLaunched(_ note: Notification) {
        if isPlayer(note) { requestPoll(after: 1) }       // give it a moment to load its state
    }

    @objc private func playerTerminated(_ note: Notification) {
        if isPlayer(note) { requestPoll() }
    }

    /// The Settings toggles for Spotify and Music apply at once.
    @objc private func defaultsChanged() {
        let enabled = MediaSource.allCases.map { Pref.bool($0.prefKey) }
        guard enabled != lastEnabled else { return }
        lastEnabled = enabled
        requestPoll()
    }

    private func isPlayer(_ note: Notification) -> Bool {
        let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        return app?.bundleIdentifier.map(Self.playerBundleIDs.contains) ?? false
    }

    /// Several notifications arrive for one change (track change, state, artwork); ask once.
    private func requestPoll(after delay: TimeInterval = 0.15) {
        pollWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.poll() }
        pollWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    // MARK: Progress bar

    /// Call with `true` while an expanded or closed-notch progress bar is visible. It then advances
    /// locally every second and is re-read from the player every few seconds; when `false`,
    /// nothing runs.
    func setPositionTracking(_ on: Bool) {
        guard !isPreview else { return }
        guard on != trackingPosition else { return }
        trackingPosition = on
        positionTimer?.invalidate()
        positionTimer = nil
        guard on else { return }
        if isPlaying, Date() >= positionLockedUntil { position = clamped(clock.value()) }   // no stale flash
        ticks = 0
        positionTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.tickPosition() }
        poll()
    }

    private func tickPosition() {
        guard isPlaying else { return }
        ticks += 1
        if ticks % Self.resyncTicks == 0 { poll(); return }
        if Date() >= positionLockedUntil { position = clamped(clock.value()) }
    }

    private func clamped(_ seconds: Double) -> Double {
        guard let duration = track?.duration, duration > 0 else { return seconds }
        return min(seconds, duration)
    }

    // MARK: Controls

    func togglePlayPause() { command("playpause") }
    func next() { command("next track") }
    func previous() { command("previous track") }

    func toggleShuffle() {
        guard canShuffle, let source = track?.source else { return }
        let target = !isShuffling
        isShuffling = target
        guard !isPreview else { return }
        let property = source == .spotify ? "shuffling" : "shuffle enabled"
        queue.async {
            _ = Self.run("tell application \"\(source.rawValue)\" to set \(property) to \(target ? "true" : "false")")
            DispatchQueue.main.async { self.poll() }
        }
    }

    /// Jumps to `seconds` in the current track.
    func seek(to seconds: Double) {
        guard let track, track.duration > 0 else { return }
        let target = min(max(seconds, 0), track.duration)
        let source = track.source
        position = target                                       // move the bar immediately
        clock = PositionClock(base: target, at: Date(), playing: isPlaying)
        positionLockedUntil = Date().addingTimeInterval(0.8)
        guard !isPreview else { return }
        queue.async {
            _ = Self.run("tell application \"\(source.rawValue)\" to set player position to \(Int(target))")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak self] in self?.poll() }
    }

    private func command(_ verb: String) {
        if isPreview {
            if verb == "playpause" { isPlaying.toggle() }
            return
        }
        guard let source = track?.source else { return }
        queue.async {
            _ = Self.run("tell application \"\(source.rawValue)\" to \(verb)")
            DispatchQueue.main.async { self.poll() }
        }
        // Optimistic UI for play/pause.
        if verb == "playpause" {
            isPlaying.toggle()
            clock = PositionClock(base: clock.value(), at: Date(), playing: isPlaying)
        }
    }

    // MARK: Polling

    private func poll() {
        // A change that arrives while a read is in flight must not be dropped: that read may predate it.
        guard !busy else { pollAgain = true; return }
        busy = true
        queue.async { [weak self] in
            guard let self else { return }
            let snapshot = self.fetch()
            DispatchQueue.main.async {
                self.busy = false
                self.apply(snapshot)
                if self.pollAgain {
                    self.pollAgain = false
                    self.poll()
                }
            }
        }
    }

    struct Snapshot {
        var track: Track
        var playing: Bool
        var position: Double
        var shuffling = false
        var canShuffle = false
    }

    private func apply(_ s: Snapshot?) {
        guard let s else {
            if track != nil { track = nil }
            isPlaying = false
            position = 0
            clock = PositionClock()
            artwork = nil
            accent = nil
            isShuffling = false
            canShuffle = false
            artworkKey = ""
            return
        }
        if track != s.track { track = s.track }
        isPlaying = s.playing
        isShuffling = s.shuffling
        canShuffle = s.canShuffle
        // Right after a seek, ignore polls that were already in flight (they carry the old position).
        if Date() >= positionLockedUntil {
            position = s.position
            clock = PositionClock(base: s.position, at: Date(), playing: s.playing)
        }
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

    static func snapshot() -> Snapshot? {
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
                return (player state as text) & "||" & (name of t) & "||" & (artist of t) & "||" & (album of t) & "||" & (player position as text) & "||" & ((duration of t) as text) & "||" & (artwork url of t) & "||" & (shuffling as text) & "||" & (shuffling enabled as text) & "||" & (id of t)
            end tell
            """
        case .music:
            script = """
            tell application "Music"
                if player state is stopped then return ""
                set t to current track
                return (player state as text) & "||" & (name of t) & "||" & (artist of t) & "||" & (album of t) & "||" & (player position as text) & "||" & ((duration of t) as text) & "||||" & (shuffle enabled as text) & "||true"
            end tell
            """
        }
        guard let out = run(script)?.stringValue, !out.isEmpty else { return nil }
        return parseSnapshot(out, source: source)
    }

    static func parseSnapshot(_ out: String, source: MediaSource) -> Snapshot? {
        let f = out.components(separatedBy: "||")
        guard f.count >= 6 else { return nil }
        // Spotify reports milliseconds, Music reports seconds.
        let rawDuration = number(f[5])
        let duration = source == .spotify ? rawDuration / 1000 : rawDuration
        let track = Track(
            source: source, title: f[1], artist: f[2], album: f[3], duration: duration,
            artworkURL: f.count > 6 && !f[6].isEmpty ? f[6] : nil,
            spotifyURI: source == .spotify && f.count > 9 ? f[9] : nil
        )
        return Snapshot(track: track, playing: f[0] == "playing", position: number(f[4]),
                        shuffling: f.count > 7 && f[7] == "true", canShuffle: f.count > 8 && f[8] == "true")
    }
}
