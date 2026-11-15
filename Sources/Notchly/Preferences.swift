import Foundation

/// UserDefaults keys for every user-facing setting. SwiftUI views bind to them with
/// `@AppStorage`; the rest of the app reads them with `Pref.bool` / `Pref.double` at the moment
/// they matter, so changes in the settings window apply immediately.
enum Pref {
    static let useExperimentalBranch = "useExperimentalBranch"

    // Updates
    static let autoCheckUpdates = "autoCheckUpdates"
    static let lastUpdateCheck = "lastUpdateCheck"             // seconds since 1970

    // Notch
    static let openOnHover = "openOnHover"
    static let hoverDelay = "hoverDelay"                       // seconds
    static let closeDelay = "closeDelay"                       // seconds
    static let haptics = "haptics"
    static let soundLockUnlock = "soundLockUnlock"
    static let soundOpenClose = "soundOpenClose"
    static let closedMusicProgress = "closedMusicProgress"
    static let tintFromArtwork = "tintFromArtwork"
    static let lockIndicator = "lockIndicator"
    static let lockScreenVisible = "lockScreenVisible"         // applied at launch
    static let showMediaActivity = "showMediaActivity"
    static let showChargingActivity = "showChargingActivity"
    static let pinnedActivity = "pinnedActivity"
    static let showAudioActivity = "showAudioActivity"

    // Home tab
    static let enableSpotify = "enableSpotify"
    static let enableMusic = "enableMusic"
    static let showCalendar = "showCalendar"
    static let showJoinButton = "showJoinButton"
    static let meetingIndicator = "meetingIndicator"
    static let meetingLeadMinutes = "meetingLeadMinutes"       // how early the indicator appears
    static let showUsage = "showUsage"
    static let scoresEnabled = "scoresEnabled"
    static let scoreLeagues = "scoreLeagues"                   // comma-separated league ids
    static let scoreFavorites = "scoreFavorites"               // JSON array of FavoriteTeam
    static let scoresLiveActivity = "scoresLiveActivity"
    static let timerSound = "timerSound"
    static let timerMinutes = "timerMinutes"                   // last used duration

    // HUD
    static let replaceSystemHUD = "replaceSystemHUD"
    static let hudVolume = "hudVolume"
    static let hudBrightness = "hudBrightness"
    static let hudDuration = "hudDuration"                     // seconds

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            autoCheckUpdates: true,
            useExperimentalBranch: UpdateChannel.current == .experimental,
            openOnHover: true,
            hoverDelay: 0.0,
            closeDelay: 0.25,
            haptics: true,
            soundLockUnlock: true,
            soundOpenClose: false,
            tintFromArtwork: true,
            closedMusicProgress: true,
            lockIndicator: true,
            lockScreenVisible: true,
            showMediaActivity: true,
            showChargingActivity: true,
            pinnedActivity: "",
            showAudioActivity: true,
            enableSpotify: true,
            enableMusic: true,
            showCalendar: true,
            showJoinButton: true,
            meetingIndicator: true,
            meetingLeadMinutes: 5,
            showUsage: true,
            scoresEnabled: true,
            scoreLeagues: "ger.1,uefa.champions,nfl,nba",
            scoreFavorites: "[]",
            scoresLiveActivity: true,
            timerSound: true,
            timerMinutes: 10,
            replaceSystemHUD: true,
            hudVolume: true,
            hudBrightness: true,
            hudDuration: 1.4,
        ])
    }

    static func bool(_ key: String) -> Bool { UserDefaults.standard.bool(forKey: key) }
    static func double(_ key: String) -> Double { UserDefaults.standard.double(forKey: key) }
    static func int(_ key: String) -> Int { UserDefaults.standard.integer(forKey: key) }
}
