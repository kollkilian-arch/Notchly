import AppKit

/// Trackpad haptics and small UI sounds. Everything is gated by the user's settings.
enum Feedback {
    enum Haptic {
        /// A firm tick: opening the notch, starting a timer.
        case open
        /// A light tick: switching tabs, releasing the seek bar.
        case light
    }

    enum Sound {
        case open, close, lock, unlock

        /// The lock sounds are synthesised in code; open/close use quiet sounds that ship with macOS.
        fileprivate var sound: NSSound? {
            switch self {
            case .lock: return Feedback.lockClack
            case .unlock: return Feedback.unlockClick
            case .open: return NSSound(named: "Tink")
            case .close: return NSSound(named: "Pop")
            }
        }

        fileprivate var volume: Float {
            switch self {
            case .lock, .unlock: return 0.3      // already a short, soft transient; kept quiet
            case .open, .close: return 0.35
            }
        }
    }

    // Built once, reused for every lock and unlock.
    private static let lockClack = NSSound(data: SynthSounds.lockClack())
    private static let unlockClick = NSSound(data: SynthSounds.unlockClick())

    /// Haptics are only felt while a finger rests on a Force Touch trackpad; otherwise this does nothing.
    static func haptic(_ kind: Haptic) {
        guard Pref.bool(Pref.haptics) else { return }
        let pattern: NSHapticFeedbackManager.FeedbackPattern = kind == .open ? .levelChange : .alignment
        NSHapticFeedbackManager.defaultPerformer.perform(pattern, performanceTime: .now)
    }

    /// Plays a quiet system sound if the given preference is on.
    static func sound(_ sound: Sound, if pref: String) {
        guard Pref.bool(pref), let s = sound.sound else { return }
        s.stop()                 // the sound objects are shared; restart if still playing
        s.volume = sound.volume
        s.play()
    }
}
