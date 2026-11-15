import AppKit

extension NotchTab {
    /// The tabs in the order the tab bar shows them, left to right.
    static func visible(scores: Bool, usage: Bool) -> [NotchTab] {
        var tabs: [NotchTab] = [.home, .audio, .shelf, .timer]
        if scores { tabs.append(.scores) }
        if usage { tabs.append(.usage) }
        return tabs
    }

    /// The tabs currently switched on in Settings.
    static var visibleNow: [NotchTab] {
        visible(scores: Pref.bool(Pref.scoresEnabled), usage: Pref.bool(Pref.showUsage))
    }

    var title: String {
        switch self {
        case .home: return "Home"
        case .audio: return "Audio"
        case .shelf: return "Shelf"
        case .timer: return "Timer"
        case .scores: return "Scores"
        case .usage: return "Claude usage"
        }
    }

    /// SF Symbol for the tab bar. The Usage tab draws its own ring instead.
    var symbol: String {
        switch self {
        case .home: return "house.fill"
        case .audio: return "headphones"
        case .shelf: return "tray.fill"
        case .timer: return "timer"
        case .scores: return "sportscourt.fill"
        case .usage: return ""
        }
    }

    /// The neighbouring tab, wrapping around at both ends. A tab that is switched off in Settings
    /// counts as the first one.
    static func step(from current: NotchTab, by offset: Int, in tabs: [NotchTab]) -> NotchTab {
        guard !tabs.isEmpty else { return current }
        let index = tabs.firstIndex(of: current) ?? 0
        return tabs[((index + offset) % tabs.count + tabs.count) % tabs.count]
    }
}

/// What a key press does while the open notch has the keyboard.
enum TabKeyAction: Equatable {
    case select(NotchTab)
    case step(Int)
    /// Gives the keyboard back to the app the user was working in.
    case releaseKeyboard
    case openSettings
}

enum TabKeys {
    /// Maps a key press to an action, or nil when it is none of ours.
    ///
    /// The Shelf keeps ← / → for moving between items and Esc for releasing the keyboard (its own
    /// handler), so those two are only claimed on the other tabs. ⌘1…⌘6 work everywhere.
    static func action(keyCode: UInt16, characters: String?, modifiers: NSEvent.ModifierFlags,
                       current: NotchTab, visible: [NotchTab]) -> TabKeyAction? {
        let held = modifiers.intersection([.command, .control, .option, .shift])
        if held == .command {
            guard let characters else { return nil }
            if characters == "," { return .openSettings }
            if let number = Int(characters), (1...visible.count).contains(number) { return .select(visible[number - 1]) }
            return nil
        }
        guard held.isEmpty, current != .shelf else { return nil }
        switch keyCode {
        case 123: return .step(-1)
        case 124: return .step(1)
        case 53: return .releaseKeyboard
        default: return nil
        }
    }
}
