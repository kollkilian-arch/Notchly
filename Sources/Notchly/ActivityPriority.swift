import Foundation

enum NotchActivity: String, CaseIterable {
    case lock, hud, timer, meeting, scores, music, charging, audioConnection

    static let selectable: [NotchActivity] = [.timer, .meeting, .scores, .music, .charging]

    var title: String {
        switch self {
        case .lock: return "Lock"
        case .hud: return "System controls"
        case .timer: return "Timer"
        case .meeting: return "Meeting"
        case .scores: return "Live scores"
        case .music: return "Music"
        case .charging: return "Charging"
        case .audioConnection: return "Audio"
        }
    }

    var symbol: String {
        switch self {
        case .lock: return "lock.fill"
        case .hud: return "slider.horizontal.3"
        case .timer: return "timer"
        case .meeting: return "video.fill"
        case .scores: return "sportscourt.fill"
        case .music: return "music.note"
        case .charging: return "bolt.fill"
        case .audioConnection: return "headphones"
        }
    }

    var tab: NotchTab? {
        switch self {
        case .timer: return .timer
        case .scores: return .scores
        case .meeting, .music, .charging: return .home
        case .lock, .hud: return nil
        case .audioConnection: return .audio
        }
    }

    var wingWidth: CGFloat {
        switch self {
        case .timer, .meeting: return NotchState.timerWing
        case .hud, .scores, .audioConnection: return NotchState.hudWing
        default: return NotchState.wing
        }
    }
}

/// Value inputs keep selection, rendering, hit testing, and opening on the same policy.
struct ActivityInputs: Equatable {
    var locked = false
    var lockVisible = false
    var hud = false
    var timer: TimerModel.Phase = .idle
    var meetingID: String?
    var meetingStart: Date?
    var scores = false
    var music = false
    var charging = false
    var audioConnection = false

    var available: [NotchActivity] {
        var result: [NotchActivity] = []
        if timer != .idle { result.append(.timer) }
        if meetingID != nil { result.append(.meeting) }
        if scores { result.append(.scores) }
        if music { result.append(.music) }
        if charging { result.append(.charging) }
        return result
    }

    init() {}

    init(media: MediaMonitor, battery: BatteryMonitor, calendar: CalendarMonitor,
         hud: HUDMonitor, timer: TimerModel, lock: LockMonitor, scores: ScoresMonitor,
         audio: AudioMonitor? = nil, at now: Date = Date()) {
        locked = lock.phase == .locked
        lockVisible = lock.indicatorVisible
        self.hud = hud.event != nil
        self.timer = timer.phase
        let meeting = Pref.bool(Pref.meetingIndicator)
            ? calendar.imminentMeeting(at: now, leadMinutes: Pref.int(Pref.meetingLeadMinutes)) : nil
        meetingID = meeting?.occurrenceKey
        meetingStart = meeting?.start
        self.scores = scores.liveGameForNotch != nil
        music = Pref.bool(Pref.showMediaActivity) && media.isPlaying
        charging = Pref.bool(Pref.showChargingActivity) && battery.isCharging
        audioConnection = Pref.bool(Pref.showAudioActivity) && audio?.visibleConnection(at: now) != nil
    }
}

struct ActivityPresentation: Equatable {
    var displayed: NotchActivity?
    var available: [NotchActivity] = []
    var pinned: NotchActivity?
    var preferred: NotchActivity?
    var isUrgent = false

    var wingWidth: CGFloat { displayed?.wingWidth ?? 0 }
    var openingTab: NotchTab { displayed?.tab ?? preferred?.tab ?? .home }
    var canCycle: Bool { available.count > 1 && displayed != .lock && displayed != .hud && displayed != .audioConnection }
}

/// Stateful arbitration with an injectable clock. No timers or system services are needed to test it.
struct ActivityPriority {
    static let alertDuration: TimeInterval = 12
    static let selectionDuration: TimeInterval = 20

    private(set) var pinned: NotchActivity?
    private var selected: NotchActivity?
    private var selectedUntil: Date?
    private var timerWasFinished = false
    private var timerAlertUntil: Date?
    private var meetingAlertUntil: Date?
    private var meetingID: String?
    private var meetingStages: Set<Int> = []

    init(pinned: NotchActivity? = nil) {
        self.pinned = pinned.flatMap { NotchActivity.selectable.contains($0) ? $0 : nil }
    }

    mutating func resolve(_ input: ActivityInputs, at now: Date) -> ActivityPresentation {
        let available = input.available
        if selectedUntil.map({ $0 <= now }) == true || selected.map({ !available.contains($0) }) == true {
            selected = nil
            selectedUntil = nil
        }

        if input.timer == .finished && !timerWasFinished {
            timerAlertUntil = now.addingTimeInterval(Self.alertDuration)
            if let until = meetingAlertUntil, until > now {
                meetingAlertUntil = until.addingTimeInterval(Self.alertDuration)
            }
        }
        timerWasFinished = input.timer == .finished
        if !timerWasFinished { timerAlertUntil = nil }

        if meetingID != input.meetingID {
            meetingID = input.meetingID
            meetingStages.removeAll()
            meetingAlertUntil = nil
        }
        if let start = input.meetingStart, input.meetingID != nil {
            let until = start.timeIntervalSince(now)
            // Announce once on entering the last minute and once at the start, never on every poll.
            if (-60...60).contains(until) {
                let stage = until > 0 ? 0 : 1
                if meetingStages.insert(stage).inserted {
                    let afterTimer = max(now, timerAlertUntil ?? now)
                    meetingAlertUntil = afterTimer.addingTimeInterval(Self.alertDuration)
                }
            }
        }

        let timelyMeeting = input.meetingStart.map { (-60...60).contains($0.timeIntervalSince(now)) } ?? false
        let automatic: NotchActivity? = input.timer == .finished ? .timer
            : (timelyMeeting && available.contains(.meeting)) ? .meeting : available.first
        let preferred = selected ?? pinned.flatMap { available.contains($0) ? $0 : nil } ?? automatic
        let urgent: NotchActivity? = (timerAlertUntil ?? .distantPast) > now ? .timer
            : (meetingAlertUntil ?? .distantPast) > now ? .meeting : nil

        // Privacy wins even when the padlock itself is disabled.
        if input.locked || input.lockVisible {
            return ActivityPresentation(displayed: input.lockVisible ? .lock : nil, pinned: pinned)
        }
        let foreground = urgent ?? (input.audioConnection ? .audioConnection : preferred)
        return ActivityPresentation(displayed: input.hud ? .hud : foreground,
                                    available: available, pinned: pinned, preferred: preferred,
                                    isUrgent: !input.hud && urgent != nil)
    }

    mutating func select(_ activity: NotchActivity, from input: ActivityInputs, at now: Date) {
        guard !input.locked, !input.lockVisible, input.available.contains(activity) else { return }
        selected = activity
        selectedUntil = now.addingTimeInterval(Self.selectionDuration)
        acknowledgeAlerts()
    }

    mutating func cycle(from input: ActivityInputs, at now: Date) {
        let current = resolve(input, at: now)
        guard current.canCycle else { return }
        let index = current.available.firstIndex(of: current.displayed ?? .timer) ?? -1
        select(current.available[(index + 1) % current.available.count], from: input, at: now)
    }

    mutating func togglePin(_ activity: NotchActivity, from input: ActivityInputs) {
        guard !input.locked, !input.lockVisible, input.available.contains(activity) else { return }
        pinned = pinned == activity ? nil : activity
        selected = nil
        selectedUntil = nil
        acknowledgeAlerts()
    }

    mutating func useAutomatic() {
        pinned = nil
        selected = nil
        selectedUntil = nil
        acknowledgeAlerts()
    }

    private mutating func acknowledgeAlerts() {
        timerAlertUntil = nil
        meetingAlertUntil = nil
    }
}
