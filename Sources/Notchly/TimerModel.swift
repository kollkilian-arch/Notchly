import AppKit

/// A single countdown timer.
///
/// Time is tracked as a wall-clock `endDate`, so the countdown stays accurate however often the UI
/// redraws (views read `remaining(at:)` from a `TimelineView`; only phase changes are published).
final class TimerModel: ObservableObject {
    enum Phase: Equatable { case idle, running, paused, finished }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var total: TimeInterval = 0

    private var endDate = Date()
    private var pausedRemaining: TimeInterval = 0
    private var finishTimer: Timer?
    private var dismissWork: DispatchWorkItem?
    private var sounds: [NSSound] = []
    private let isPreview: Bool

    init() { isPreview = false }

    /// For the debug snapshot tool: a fixed state that never schedules anything.
    init(preview phase: Phase, total: TimeInterval, remaining: TimeInterval) {
        isPreview = true
        self.phase = phase
        self.total = total
        endDate = Date().addingTimeInterval(remaining)
        pausedRemaining = remaining
    }

    var isActive: Bool { phase != .idle }

    func remaining(at date: Date = Date()) -> TimeInterval {
        switch phase {
        case .running: return max(0, endDate.timeIntervalSince(date))
        case .paused: return pausedRemaining
        case .idle, .finished: return 0
        }
    }

    // MARK: Controls

    func start(minutes: Int) { start(seconds: TimeInterval(minutes * 60)) }

    func start(seconds: TimeInterval) {
        guard seconds > 0 else { return }
        dismissWork?.cancel()
        total = seconds
        endDate = Date().addingTimeInterval(seconds)
        phase = .running
        scheduleFinish()
    }

    func pause() {
        guard phase == .running else { return }
        pausedRemaining = remaining()
        finishTimer?.invalidate()
        phase = .paused
    }

    func resume() {
        guard phase == .paused else { return }
        endDate = Date().addingTimeInterval(pausedRemaining)
        phase = .running
        scheduleFinish()
    }

    func togglePause() { phase == .running ? pause() : resume() }

    func add(seconds: TimeInterval) {
        switch phase {
        case .running:
            endDate = endDate.addingTimeInterval(seconds)
            total += seconds
            scheduleFinish()
        case .paused:
            pausedRemaining += seconds
            total += seconds
        default: break
        }
    }

    /// Stops the timer (also dismisses the "time's up" state).
    func cancel() {
        finishTimer?.invalidate()
        dismissWork?.cancel()
        phase = .idle
    }

    func restart() { start(seconds: total) }

    // MARK: Finishing

    private func scheduleFinish() {
        guard !isPreview else { return }
        finishTimer?.invalidate()
        let timer = Timer(fire: endDate, interval: 0, repeats: false) { [weak self] _ in self?.finish() }
        RunLoop.main.add(timer, forMode: .common)
        finishTimer = timer
    }

    private func finish() {
        guard phase == .running else { return }
        phase = .finished
        playChime()
        // Don't leave "time's up" in the notch forever.
        let work = DispatchWorkItem { [weak self] in
            if self?.phase == .finished { self?.phase = .idle }
        }
        dismissWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 120, execute: work)
    }

    private func playChime() {
        guard Pref.bool(Pref.timerSound) else { return }
        sounds.removeAll()
        for i in 0..<3 {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 1.1) { [weak self] in
                guard self?.phase == .finished, let sound = NSSound(named: "Glass") else { return }
                self?.sounds.append(sound)
                sound.play()
            }
        }
    }
}

/// "08:42" or "1:02:03".
func clockString(_ seconds: TimeInterval) -> String {
    let s = Int(seconds.rounded(.up))
    let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
    return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%02d:%02d", m, sec)
}
