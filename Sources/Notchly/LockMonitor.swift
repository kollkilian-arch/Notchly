import AppKit

/// Tracks whether the screen is locked, for the lock indicator in the notch.
///
/// Uses the distributed notifications macOS posts when the screen locks and unlocks
/// (not formally documented, but stable for many releases).
final class LockMonitor: ObservableObject {
    enum Phase: Equatable {
        case unlocked
        case locked
        /// Briefly after unlocking, while the padlock plays its "open" animation.
        case justUnlocked
    }

    @Published private(set) var phase: Phase

    private var settleWork: DispatchWorkItem?
    private let isPreview: Bool

    init() {
        isPreview = false
        phase = Self.screenIsLocked() ? .locked : .unlocked

        let center = DistributedNotificationCenter.default()
        center.addObserver(forName: Notification.Name("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            self?.settleWork?.cancel()
            self?.phase = .locked
            Feedback.sound(.lock, if: Pref.soundLockUnlock)
        }
        center.addObserver(forName: Notification.Name("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in
            self?.didUnlock()
        }
    }

    /// For the debug snapshot tool.
    init(preview phase: Phase) {
        isPreview = true
        self.phase = phase
    }

    /// Whether the lock icon should currently be drawn (the user can turn the indicator off).
    var indicatorVisible: Bool { phase != .unlocked && Pref.bool(Pref.lockIndicator) }

    private func didUnlock() {
        settleWork?.cancel()
        phase = .justUnlocked
        Feedback.sound(.unlock, if: Pref.soundLockUnlock)
        let work = DispatchWorkItem { [weak self] in
            if self?.phase == .justUnlocked { self?.phase = .unlocked }
        }
        settleWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
    }

    private static func screenIsLocked() -> Bool {
        let session = CGSessionCopyCurrentDictionary() as? [String: Any]
        return session?["CGSSessionScreenIsLocked"] as? Bool ?? false
    }
}
