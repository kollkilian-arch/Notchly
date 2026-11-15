import SwiftUI

struct NotchRoot: View {
    @ObservedObject var state: NotchState
    @ObservedObject var media: MediaMonitor
    @ObservedObject var battery: BatteryMonitor
    @ObservedObject var calendar: CalendarMonitor
    @ObservedObject var hud: HUDMonitor
    @ObservedObject var shelf: ShelfStore
    @ObservedObject var usage: UsageMonitor
    @ObservedObject var timer: TimerModel
    @ObservedObject var lock: LockMonitor
    @ObservedObject var scores: ScoresMonitor

    private var showHUD: Bool { hud.event != nil }
    @AppStorage(Pref.showMediaActivity) private var showMedia = true
    @AppStorage(Pref.showChargingActivity) private var showCharging = true

    private var showWings: Bool {
        lock.indicatorVisible || showHUD || timer.isActive || calendar.indicatorMeeting != nil
            || scores.liveGameForNotch != nil
            || (showMedia && media.isPlaying) || (showCharging && battery.isCharging)
    }

    private var size: CGSize {
        if state.isOpen { return NotchState.openSize }
        let wing = NotchState.wingWidth(lock: lock.indicatorVisible, hud: showHUD, timer: timer.isActive,
                                        meeting: calendar.indicatorMeeting != nil,
                                        liveScore: scores.liveGameForNotch != nil, activity: showWings)
        return CGSize(width: state.notchSize.width + wing * 2, height: state.notchSize.height)
    }

    var body: some View {
        ZStack(alignment: .top) {
            // Each layer gets an explicit size so neither can stretch the other's layout.
            ClosedContent(state: state, media: media, battery: battery, hud: hud, timer: timer, lock: lock,
                          calendar: calendar, scores: scores)
                .frame(width: size.width, height: state.notchSize.height)
                .opacity(state.isOpen ? 0 : 1)

            OpenContent(state: state, media: media, battery: battery, calendar: calendar, shelf: shelf, usage: usage, timer: timer, scores: scores)
                .frame(width: NotchState.openSize.width, height: NotchState.openSize.height, alignment: .top)
                .opacity(state.isOpen ? 1 : 0)
                .blur(radius: state.isOpen ? 0 : 8)
                .allowsHitTesting(state.isOpen)
        }
        .frame(width: size.width, height: size.height, alignment: .top)
        .background(Color.black)
        .clipShape(NotchShape(topRadius: state.isOpen ? 19 : 6, bottomRadius: state.isOpen ? 26 : 12))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .ignoresSafeArea()
        .animation(.spring(response: 0.42, dampingFraction: 0.78), value: state.isOpen)
        .animation(.spring(response: 0.42, dampingFraction: 0.78), value: showWings)
        .animation(.spring(response: 0.42, dampingFraction: 0.78), value: showHUD)
        .animation(.spring(response: 0.42, dampingFraction: 0.78), value: timer.isActive)
        .animation(.spring(response: 0.42, dampingFraction: 0.78), value: lock.indicatorVisible)
        .preferredColorScheme(.dark)
    }
}

// MARK: - Collapsed "live activity"

struct ClosedContent: View {
    @ObservedObject var state: NotchState
    @ObservedObject var media: MediaMonitor
    @ObservedObject var battery: BatteryMonitor
    @ObservedObject var hud: HUDMonitor
    @ObservedObject var timer: TimerModel
    @ObservedObject var lock: LockMonitor
    @ObservedObject var calendar: CalendarMonitor
    @ObservedObject var scores: ScoresMonitor

    @AppStorage(Pref.showMediaActivity) private var showMedia = true
    @AppStorage(Pref.showChargingActivity) private var showCharging = true
    @AppStorage(Pref.tintFromArtwork) private var tintFromArtwork = true

    private var playing: Bool { showMedia && media.isPlaying }
    private var charging: Bool { showCharging && battery.isCharging }
    private var wingWidth: CGFloat {
        NotchState.wingWidth(lock: lock.indicatorVisible, hud: hud.event != nil, timer: timer.isActive,
                             meeting: calendar.indicatorMeeting != nil,
                             liveScore: scores.liveGameForNotch != nil, activity: true)
    }

    var body: some View {
        HStack(spacing: 0) {
            leading.frame(width: wingWidth)
            Spacer(minLength: state.notchSize.width - 12)
            trailing.frame(width: wingWidth)
        }
        .padding(.horizontal, 6)
        .frame(height: state.notchSize.height)
        .opacity(lock.indicatorVisible || hud.event != nil || timer.isActive || calendar.indicatorMeeting != nil
                 || scores.liveGameForNotch != nil
                 || playing || charging ? 1 : 0)
    }

    // While locked (or just unlocked) the lock icon replaces everything else; nothing private is shown.
    @ViewBuilder private var leading: some View {
        if lock.indicatorVisible {
            LockIcon(phase: lock.phase)
        } else if let e = hud.event {
            Image(systemName: e.symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .contentTransition(.symbolEffect(.replace))
        } else if timer.phase == .finished {
            Image(systemName: "bell.fill")
                .font(.system(size: 13))
                .foregroundStyle(.orange)
                .symbolEffect(.pulse)
        } else if timer.isActive {
            TimerRing(timer: timer)
        } else if let meeting = calendar.indicatorMeeting {
            MeetingIcon(started: meeting.start <= Date())
        } else if let game = scores.liveGameForNotch {
            ScoreWing(game: game, leading: true, flash: scores.flashes[game.id])
        } else if playing {
            ArtworkView(image: media.artwork, size: 22, radius: 5)
        } else if charging {
            Image(systemName: "bolt.fill").foregroundStyle(.green).font(.system(size: 12))
        }
    }

    @ViewBuilder private var trailing: some View {
        if lock.indicatorVisible {
            Color.clear
        } else if let e = hud.event {
            LevelBar(level: CGFloat(e.level)).frame(width: 46, height: 5)
        } else if timer.phase == .finished {
            Text("Done").font(.system(size: 12, weight: .semibold)).foregroundStyle(.orange)
        } else if timer.isActive {
            TimerReadout(timer: timer)
        } else if let meeting = calendar.indicatorMeeting {
            MeetingCountdown(start: meeting.start)
        } else if let game = scores.liveGameForNotch {
            ScoreWing(game: game, leading: false, flash: scores.flashes[game.id])
        } else if playing {
            EqualizerBars(tint: media.tint(artworkColors: tintFromArtwork))
        } else if charging {
            Text("\(battery.level)%").font(.system(size: 11, weight: .semibold)).foregroundStyle(.green)
        }
    }
}

/// Padlock for the collapsed notch: closed while locked, opens (green) when you unlock.
struct LockIcon: View {
    let phase: LockMonitor.Phase

    var body: some View {
        Image(systemName: phase == .locked ? "lock.fill" : "lock.open.fill")
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(phase == .locked ? Color.white : Color.green)
            .contentTransition(.symbolEffect(.replace))
            .animation(.easeInOut(duration: 0.3), value: phase)
    }
}

extension HUDEvent {
    var symbol: String {
        switch kind {
        case .volume:
            if muted || level <= 0.001 { return "speaker.slash.fill" }
            return level < 0.34 ? "speaker.wave.1.fill" : (level < 0.67 ? "speaker.wave.2.fill" : "speaker.wave.3.fill")
        case .brightness:
            return level < 0.3 ? "sun.min.fill" : "sun.max.fill"
        }
    }
}

struct LevelBar: View {
    let level: CGFloat

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.22))
                Capsule().fill(.white)
                    .frame(width: max(geo.size.width * min(max(level, 0), 1), level > 0 ? 5 : 0))
                    .animation(.easeOut(duration: 0.12), value: level)
            }
        }
    }
}

extension MediaMonitor {
    /// The colour for progress bars and the equalizer: the artwork's accent, or white.
    func tint(artworkColors enabled: Bool) -> Color {
        guard enabled, let accent else { return .white }
        return Color(nsColor: accent)
    }
}

struct EqualizerBars: View {
    var tint: Color = .white

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 20)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            HStack(alignment: .center, spacing: 2.5) {
                ForEach(0..<4, id: \.self) { i in
                    Capsule()
                        .fill(tint.opacity(0.95))
                        .frame(width: 2.5, height: 4 + 10 * abs(sin(t * 4 + Double(i) * 1.3)))
                }
            }
            .frame(height: 16)
        }
    }
}

// MARK: - Expanded

struct OpenContent: View {
    @ObservedObject var state: NotchState
    @ObservedObject var media: MediaMonitor
    @ObservedObject var battery: BatteryMonitor
    @ObservedObject var calendar: CalendarMonitor
    @ObservedObject var shelf: ShelfStore
    @ObservedObject var usage: UsageMonitor
    @ObservedObject var timer: TimerModel
    @ObservedObject var scores: ScoresMonitor

    var body: some View {
        VStack(spacing: 0) {
            // Header sits beside the camera cut-out.
            HStack {
                HStack(spacing: 8) {
                    TimelineView(.periodic(from: .now, by: 1)) { ctx in
                        Text(ctx.date, format: .dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute())
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.85))
                    }
                    SettingsButton()
                }
                Spacer(minLength: state.notchSize.width)
                HStack(spacing: 8) {
                    TabSwitcher(state: state, shelf: shelf, usage: usage)
                    if battery.hasBattery { BatteryPill(battery: battery).fixedSize() }
                }
            }
            .padding(.horizontal, 29)
            .frame(height: state.notchSize.height)

            Group {
                switch state.tab {
                case .home: homeContent
                case .shelf: ShelfView(shelf: shelf)
                case .timer: TimerView(timer: timer)
                case .scores: ScoresView(scores: scores)
                case .usage: UsageView(usage: usage)
                }
            }
            .padding(.horizontal, 29)
            .padding(.top, 8)
            .padding(.bottom, 20)
            .animation(.easeOut(duration: 0.18), value: state.tab)
        }
    }

    @AppStorage(Pref.showCalendar) private var showCalendar = true

    private var homeContent: some View {
        HStack(alignment: .top, spacing: 18) {
            NowPlayingView(media: media)
                .frame(maxWidth: .infinity, alignment: .leading)
            if showCalendar {
                Rectangle().fill(.white.opacity(0.12)).frame(width: 1)
                CalendarView(calendar: calendar)
                    .frame(width: 188, alignment: .leading)
            }
        }
    }
}

/// Opens the Notchly settings window straight from the notch.
struct SettingsButton: View {
    @State private var hovering = false
    @ObservedObject private var updater = Updater.shared

    private var updateAvailable: Bool { updater.available != nil }

    var body: some View {
        Button {
            Feedback.haptic(.light)
            // With an update waiting, go straight to where it can be installed.
            SettingsWindowController.shared.show(tab: updateAvailable ? .about : nil)
        } label: {
            Image(systemName: "gearshape.fill")
                .font(.system(size: 11))
                .frame(width: 22, height: 20)
                .foregroundStyle(.white.opacity(hovering || updateAvailable ? 0.95 : 0.5))
                .background(Circle().fill(.white.opacity(hovering ? 0.14 : 0)))
                .overlay(alignment: .topTrailing) {
                    if updateAvailable {
                        Circle().fill(Color.orange).frame(width: 6, height: 6).offset(x: -1, y: 2)
                    }
                }
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .help(updateAvailable ? "Update available: Notchly \(updater.available?.version ?? "")" : "Notchly Settings")
    }
}

struct BatteryPill: View {
    @ObservedObject var battery: BatteryMonitor

    private var symbol: String {
        if battery.isCharging { return "battery.100.bolt" }
        switch battery.level {
        case ..<13: return "battery.0"
        case ..<38: return "battery.25"
        case ..<63: return "battery.50"
        case ..<88: return "battery.75"
        default: return "battery.100"
        }
    }

    var body: some View {
        HStack(spacing: 4) {
            Text("\(battery.level)%").font(.system(size: 12, weight: .semibold))
            Image(systemName: symbol)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(battery.isCharging ? .green : (battery.level <= 20 ? .red : .white))
        }
        .foregroundStyle(.white.opacity(0.85))
    }
}

struct ArtworkView: View {
    let image: NSImage?
    let size: CGFloat
    let radius: CGFloat

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().scaledToFill()
            } else {
                ZStack {
                    Color.white.opacity(0.12)
                    Image(systemName: "music.note")
                        .font(.system(size: size * 0.4))
                        .foregroundStyle(.white.opacity(0.6))
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
}

struct NowPlayingView: View {
    @ObservedObject var media: MediaMonitor
    @AppStorage(Pref.tintFromArtwork) private var tintFromArtwork = true

    var body: some View {
        if let track = media.track {
            HStack(alignment: .center, spacing: 14) {
                ArtworkView(image: media.artwork, size: 86, radius: 12)
                VStack(alignment: .leading, spacing: 3) {
                    Text(track.title).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                    Text(track.artist).font(.system(size: 12)).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
                    Spacer(minLength: 2)
                    ProgressRow(position: media.position, duration: track.duration,
                                tint: media.tint(artworkColors: tintFromArtwork), onSeek: media.seek(to:))
                    controls
                }
                .frame(height: 86)
            }
        } else {
            HStack(spacing: 10) {
                Image(systemName: "music.note.list").font(.system(size: 22)).foregroundStyle(.white.opacity(0.4))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Nothing playing").font(.system(size: 13, weight: .semibold))
                    Text("Start Music or Spotify").font(.system(size: 11)).foregroundStyle(.white.opacity(0.5))
                }
            }
            .frame(maxHeight: .infinity)
        }
    }

    private var controls: some View {
        HStack(spacing: 22) {
            Spacer()
            Button(action: media.previous) { Image(systemName: "backward.fill") }
            Button(action: media.togglePlayPause) {
                Image(systemName: media.isPlaying ? "pause.fill" : "play.fill").font(.system(size: 18))
            }
            Button(action: media.next) { Image(systemName: "forward.fill") }
            Spacer()
        }
        .buttonStyle(IconButtonStyle())
        .font(.system(size: 14))
    }
}

/// Elapsed time, a bar you can click or drag to seek, and the total time.
struct ProgressRow: View {
    let position: Double
    let duration: Double
    var tint: Color = .white
    let onSeek: (Double) -> Void

    /// Fraction under the finger while scrubbing (nil otherwise).
    @State private var scrub: Double?
    @State private var hovering = false

    private var fraction: Double {
        scrub ?? (duration > 0 ? min(max(position / duration, 0), 1) : 0)
    }
    private var shownPosition: Double { scrub.map { $0 * duration } ?? position }
    private var active: Bool { hovering || scrub != nil }

    private func fmt(_ s: Double) -> String {
        let t = Int(max(s, 0))
        return String(format: "%d:%02d", t / 60, t % 60)
    }

    var body: some View {
        HStack(spacing: 6) {
            Text(fmt(shownPosition)).monospacedDigit()
            GeometryReader { geo in
                let width = max(geo.size.width, 1)
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.18))
                    Capsule().fill(tint.opacity(active ? 1 : 0.9))
                        .animation(.easeInOut(duration: 0.4), value: tint)
                        .frame(width: width * fraction)
                        // Smooth ticking, but no lag while scrubbing.
                        .animation(scrub == nil ? .linear(duration: 1) : nil, value: fraction)
                }
                .frame(height: active ? 5 : 3)
                .frame(width: width, height: geo.size.height)   // centre the bar in the taller hit area
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { scrub = min(max($0.location.x / width, 0), 1) }
                        .onEnded {
                            let f = min(max($0.location.x / width, 0), 1)
                            scrub = nil
                            if duration > 0 {
                                onSeek(f * duration)
                                Feedback.haptic(.light)
                            }
                        }
                )
            }
            .frame(height: 16)
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.12), value: active)
            Text(fmt(duration)).monospacedDigit()
        }
        .font(.system(size: 9, weight: .medium))
        .foregroundStyle(.white.opacity(0.55))
    }
}

struct IconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.white.opacity(configuration.isPressed ? 0.5 : 0.95))
            .scaleEffect(configuration.isPressed ? 0.88 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
            .contentShape(Rectangle())
    }
}

/// Collapsed-notch indicator for an upcoming meeting: a video icon on one side...
struct MeetingIcon: View {
    /// The meeting has begun: the icon stops pulsing.
    let started: Bool

    var body: some View {
        Image(systemName: "video.fill")
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.green)
            .symbolEffect(.pulse, isActive: !started)
    }
}

/// ...and the countdown on the other ("4 min", "Now").
struct MeetingCountdown: View {
    let start: Date

    var body: some View {
        TimelineView(.periodic(from: .now, by: 5)) { context in
            Text(label(at: context.date))
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(.green)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
    }

    private func label(at now: Date) -> String {
        let seconds = start.timeIntervalSince(now)
        if seconds <= 0 { return "Now" }
        if seconds < 60 { return "<1 min" }
        return "\(Int((seconds / 60).rounded(.up))) min"
    }
}

/// "Join" pill for an event with a video-call link. Filled when the meeting is starting or running.
struct JoinButton: View {
    let meeting: MeetingLink
    let urgent: Bool
    var onJoin: () -> Void = {}

    var body: some View {
        Button {
            Feedback.haptic(.open)
            NSWorkspace.shared.open(meeting.url)
            onJoin()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "video.fill").font(.system(size: 9, weight: .semibold))
                Text("Join").font(.system(size: 11, weight: .semibold))
            }
            .padding(.horizontal, 9)
            .frame(height: 22)
            .foregroundStyle(urgent ? Color.black : Color.white.opacity(0.9))
            .background(Capsule().fill(urgent ? Color.green : Color.white.opacity(0.16)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help("Join \(meeting.service) meeting")
    }
}

struct CalendarView: View {
    @ObservedObject var calendar: CalendarMonitor
    @AppStorage(Pref.showJoinButton) private var showJoin = true

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Up next", systemImage: "calendar")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white.opacity(0.5))
                .textCase(.uppercase)

            if !calendar.authorized {
                Button(calendar.denied ? "Enable in System Settings" : "Allow calendar access") {
                    if calendar.denied {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars")!)
                    } else {
                        calendar.requestAccess()
                    }
                }
                .buttonStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(.blue)
            } else if calendar.events.isEmpty {
                Text("No upcoming events").font(.system(size: 12)).foregroundStyle(.white.opacity(0.5))
            } else {
                ForEach(calendar.events.prefix(2)) { event in
                    HStack(alignment: .center, spacing: 8) {
                        Capsule().fill(Color(nsColor: event.color)).frame(width: 3, height: 30)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(event.title).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                            Text(timeText(event)).font(.system(size: 11)).foregroundStyle(.white.opacity(0.55))
                                .lineLimit(1)
                        }
                        if showJoin, let meeting = event.meeting {
                            Spacer(minLength: 0)
                            JoinButton(meeting: meeting, urgent: isImminent(event)) {
                                calendar.markJoined(event)      // no collapsed-notch reminder once you've joined
                            }
                        }
                    }
                }
            }
            Spacer(minLength: 0)
        }
    }

    /// Running now, or starting within 10 minutes: the Join button is highlighted.
    private func isImminent(_ e: CalEvent) -> Bool {
        e.start.timeIntervalSinceNow <= 10 * 60
    }

    private func timeText(_ e: CalEvent) -> String {
        let now = Date()
        if e.start <= now { return "Now · until \(e.end.formatted(date: .omitted, time: .shortened))" }
        let mins = Int(e.start.timeIntervalSince(now) / 60)
        if mins < 60 { return "In \(mins + 1) min" }
        return e.start.formatted(.dateTime.weekday(.abbreviated).hour().minute())
    }
}
