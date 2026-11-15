import SwiftUI
import Combine
import ServiceManagement
import EventKit

enum SettingsTab: Hashable { case general, notch, home, hud, feedback, scores, about }

/// Which settings tab is showing, so other parts of the app can open the window on a specific tab.
final class SettingsNavigator: ObservableObject {
    static let shared = SettingsNavigator()
    @Published var tab: SettingsTab = .general
}

struct SettingsView: View {
    @ObservedObject private var navigator = SettingsNavigator.shared

    init(initialTab: SettingsTab = .general) {
        SettingsNavigator.shared.tab = initialTab
    }

    var body: some View {
        TabView(selection: $navigator.tab) {
            GeneralSettings()
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag(SettingsTab.general)
            NotchSettings()
                .tabItem { Label("Notch", systemImage: "capsule.tophalf.filled") }
                .tag(SettingsTab.notch)
            HomeSettings()
                .tabItem { Label("Home", systemImage: "house") }
                .tag(SettingsTab.home)
            HUDSettings()
                .tabItem { Label("HUD", systemImage: "speaker.wave.2") }
                .tag(SettingsTab.hud)
            FeedbackSettings()
                .tabItem { Label("Feedback", systemImage: "hand.tap") }
                .tag(SettingsTab.feedback)
            ScoresSettings()
                .tabItem { Label("Scores", systemImage: "sportscourt") }
                .tag(SettingsTab.scores)
            AboutSettings()
                .tabItem { Label("About", systemImage: "info.circle") }
                .tag(SettingsTab.about)
        }
        .frame(width: 520, height: 530)
    }
}

// MARK: - Shared rows

private struct SliderRow: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 8) {
                Slider(value: $value, in: range, step: step)
                    .frame(width: 170)
                Text(String(format: "%.2f s", value))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 52, alignment: .trailing)
            }
        }
    }
}

private struct PermissionRow: View {
    let title: String
    let detail: String
    /// `nil` when macOS offers no way to query the status.
    let granted: Bool?
    let pane: String

    var body: some View {
        LabeledContent {
            HStack(spacing: 10) {
                if granted == true {
                    Label("Granted", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .labelStyle(.titleAndIcon)
                } else {
                    Button("Open Settings") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")!)
                    }
                }
            }
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - General

private struct GeneralSettings: View {
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var accessibility = AXIsProcessTrusted()
    @State private var calendar = EKEventStore.authorizationStatus(for: .event)
    private let timer = Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()

    var body: some View {
        Form {
            Section {
                Toggle("Launch Notchly at login", isOn: Binding(
                    get: { launchAtLogin },
                    set: { setLaunchAtLogin($0) }
                ))
            }

            Section("Permissions") {
                PermissionRow(title: "Accessibility",
                              detail: "Lets Notchly replace the system volume & brightness overlay.",
                              granted: accessibility, pane: "Privacy_Accessibility")
                PermissionRow(title: "Calendar",
                              detail: "Shows your upcoming events on the Home tab.",
                              granted: calendar == .fullAccess, pane: "Privacy_Calendars")
                PermissionRow(title: "Automation",
                              detail: "Lets Notchly read and control Music and Spotify.",
                              granted: nil, pane: "Privacy_Automation")
            }
        }
        .formStyle(.grouped)
        .onReceive(timer) { _ in
            accessibility = AXIsProcessTrusted()
            calendar = EKEventStore.authorizationStatus(for: .event)
        }
    }

    private func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            NSLog("Launch at login failed: \(error)")
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }
}

// MARK: - About & updates

private struct AboutSettings: View {
    @ObservedObject private var updater = Updater.shared
    @AppStorage(Pref.autoCheckUpdates) private var autoCheck = true

    var body: some View {
        Form {
            Section {
                LabeledContent("Notchly", value: "Version \(Updater.currentVersion)")
            }

            Section {
                Toggle("Check for updates automatically", isOn: $autoCheck)

                LabeledContent {
                    Button(updater.phase == .checking ? "Checking…" : "Check for Updates") {
                        updater.checkForUpdates(userInitiated: true)
                    }
                    .disabled(updater.phase != .idle)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(statusTitle)
                        if let detail = statusDetail {
                            Text(detail).font(.caption).foregroundStyle(statusIsError ? Color.red : Color.secondary)
                        }
                    }
                }

                if let release = updater.available { availableBlock(release) }
            } header: {
                Text("Updates")
            } footer: {
                Text("Notchly looks at the project's GitHub releases. An update is only installed if it is signed by the same developer as this version.")
            }

            Section {
                Button("Quit Notchly", role: .destructive) { NSApp.terminate(nil) }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: Status text

    private var statusTitle: String {
        if updater.phase == .checking { return "Checking for updates…" }
        if let release = updater.available { return "Version \(release.version) is available" }
        switch updater.status {
        case .upToDate: return "Notchly is up to date"
        case .failed: return "Couldn't check for updates"
        case .none: return updater.lastChecked == nil ? "Not checked yet" : "Last checked"
        }
    }

    private var statusDetail: String? {
        if case .failed(let message) = updater.status, updater.available == nil { return message }
        guard let last = updater.lastChecked else { return nil }
        return "Last checked \(last.formatted(date: .abbreviated, time: .shortened))"
    }

    private var statusIsError: Bool {
        if case .failed = updater.status, updater.available == nil { return true }
        return false
    }

    // MARK: Install

    @ViewBuilder private func availableBlock(_ release: AppRelease) -> some View {
        switch updater.phase {
        case .downloading(let fraction):
            VStack(alignment: .leading, spacing: 4) {
                ProgressView(value: fraction)
                Text("Downloading… \(Int(fraction * 100))%").font(.caption).foregroundStyle(.secondary)
            }
        case .installing:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Installing, Notchly will restart…").font(.caption).foregroundStyle(.secondary)
            }
        default:
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Button("Install and Restart") { updater.installAvailableUpdate() }
                        .buttonStyle(.borderedProminent)
                        .disabled(release.zip == nil || !updater.canInstallInPlace)
                    Button("Release Notes") { NSWorkspace.shared.open(release.pageURL) }
                }
                if case .failed(let message) = updater.status {
                    Text(message).font(.caption).foregroundStyle(.red)
                } else if !updater.canInstallInPlace {
                    Text("Notchly can't replace itself where it is now. Use Release Notes to download the update and replace the app yourself.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}

// MARK: - Notch

private struct NotchSettings: View {
    @AppStorage(Pref.openOnHover) private var openOnHover = true
    @AppStorage(Pref.hoverDelay) private var hoverDelay = 0.0
    @AppStorage(Pref.closeDelay) private var closeDelay = 0.25
    @AppStorage(Pref.showMediaActivity) private var showMedia = true
    @AppStorage(Pref.showChargingActivity) private var showCharging = true
    @AppStorage(Pref.showUsage) private var usage = true

    var body: some View {
        Form {
            Section {
                Toggle("Open when hovering over the notch", isOn: $openOnHover)
                if openOnHover {
                    SliderRow(title: "Hover delay", value: $hoverDelay, range: 0...0.8, step: 0.05)
                }
                SliderRow(title: "Close delay", value: $closeDelay, range: 0.1...1.5, step: 0.05)
            } header: {
                Text("Opening")
            } footer: {
                Text(openOnHover
                     ? "Dragging files toward the notch always opens the shelf."
                     : "With hover off, click the notch to open it. Dragging files toward it still opens the shelf.")
            }

            Section("While the notch is closed") {
                Toggle("Show what's playing (artwork and equalizer)", isOn: $showMedia)
                Toggle("Show charging status", isOn: $showCharging)
            }

            Section {
                Toggle("Show the Claude usage tab", isOn: $usage)
            } header: {
                Text("Tabs")
            } footer: {
                Text("The usage tab shows how much of your Claude 5-hour and weekly limits you've used. It reads your Claude Code sign-in (read-only); if that has expired, local token counts are shown instead.")
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Feedback & lock screen

private struct FeedbackSettings: View {
    @AppStorage(Pref.lockIndicator) private var lockIndicator = true
    @AppStorage(Pref.lockScreenVisible) private var lockScreen = true
    @AppStorage(Pref.haptics) private var haptics = true
    @AppStorage(Pref.soundLockUnlock) private var soundLock = true
    @AppStorage(Pref.soundOpenClose) private var soundOpen = false
    @AppStorage(Pref.timerSound) private var timerSound = true

    var body: some View {
        Form {
            Section {
                Toggle("Trackpad haptics", isOn: $haptics)
                Toggle("Chime when a timer ends", isOn: $timerSound)
                Toggle("Sound when the Mac locks and unlocks", isOn: $soundLock)
                Toggle("Sound when the notch opens and closes", isOn: $soundOpen)
            } header: {
                Text("Feedback")
            } footer: {
                Text("Haptics are felt only while a finger rests on a Force Touch trackpad.")
            }

            Section {
                Toggle("Show a padlock when the Mac locks and unlocks", isOn: $lockIndicator)
                Toggle("Also show it on the lock screen", isOn: $lockScreen)
                    .disabled(!lockIndicator)
            } header: {
                Text("Lock screen")
            } footer: {
                Text("While locked, only the padlock is shown — never music, events or files. Showing it on the lock screen uses a private macOS interface and takes effect after restarting Notchly.")
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Scores

private struct ScoresSettings: View {
    @AppStorage(Pref.scoresEnabled) private var enabled = true
    @AppStorage(Pref.scoresLiveActivity) private var liveActivity = true
    @AppStorage(Pref.scoreLeagues) private var leaguesCSV = "ger.1,uefa.champions,nfl,nba"
    @AppStorage(Pref.scoreFavorites) private var favoritesJSON = "[]"
    @State private var teams: [String: [TeamInfo]] = [:]

    private var enabledIDs: Set<String> { Set(leaguesCSV.split(separator: ",").map(String.init)) }
    private var favorites: [FavoriteTeam] { ScoresPrefs.decode(favoritesJSON) }
    private var enabledLeagues: [League] { League.all.filter { enabledIDs.contains($0.id) } }

    var body: some View {
        Form {
            Section {
                Toggle("Show sports scores", isOn: $enabled)
                Toggle("Show the live score next to the closed notch", isOn: $liveActivity)
                    .disabled(!enabled)
            } footer: {
                Text("While a favourite team plays, its score appears beside the notch, and the side that scores flashes green. Data comes from ESPN's public score feed, which is unofficial and may change without notice.")
            }

            Section("Leagues") {
                ForEach(League.all) { league in
                    Toggle(league.name, isOn: Binding(
                        get: { enabledIDs.contains(league.id) },
                        set: { setLeague(league, on: $0) }
                    ))
                }
            }
            .disabled(!enabled)

            Section {
                ForEach(favorites) { team in
                    LabeledContent {
                        Button { remove(team) } label: { Image(systemName: "minus.circle.fill") }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                    } label: {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(team.name)
                            Text(League.all.first { $0.id == team.leagueID }?.name ?? team.leagueID)
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                Menu("Add a team…") {
                    ForEach(enabledLeagues) { league in
                        Menu(league.name) {
                            if let list = teams[league.id], !list.isEmpty {
                                ForEach(list) { team in
                                    Button(team.name) { add(team, in: league) }
                                        .disabled(favorites.contains { $0.id == "\(league.id)/\(team.id)" })
                                }
                            } else {
                                Text("Loading teams…")
                            }
                        }
                    }
                }
            } header: {
                Text("Favourite teams")
            } footer: {
                Text(favorites.isEmpty
                     ? "With no favourites, the Scores tab lists today's games from your leagues."
                     : "The Scores tab shows each favourite's live game, latest result or next fixture.")
            }
            .disabled(!enabled)
        }
        .formStyle(.grouped)
        .task(id: leaguesCSV) { await loadTeams() }
    }

    private func setLeague(_ league: League, on: Bool) {
        var ids = enabledIDs
        if on { ids.insert(league.id) } else { ids.remove(league.id) }
        leaguesCSV = League.all.map(\.id).filter(ids.contains).joined(separator: ",")   // keep a stable order
    }

    private func add(_ team: TeamInfo, in league: League) {
        var list = favorites
        let new = FavoriteTeam(leagueID: league.id, teamID: team.id, name: team.name)
        guard !list.contains(new) else { return }
        list.append(new)
        favoritesJSON = ScoresPrefs.encode(list)
    }

    private func remove(_ team: FavoriteTeam) {
        favoritesJSON = ScoresPrefs.encode(favorites.filter { $0 != team })
    }

    private func loadTeams() async {
        for league in enabledLeagues where teams[league.id] == nil {
            teams[league.id] = await ScoresAPI.teams(in: league)
        }
    }
}

// MARK: - Home

private struct HomeSettings: View {
    @AppStorage(Pref.enableSpotify) private var spotify = true
    @AppStorage(Pref.enableMusic) private var music = true
    @AppStorage(Pref.tintFromArtwork) private var tint = true
    @AppStorage(Pref.showCalendar) private var calendar = true
    @AppStorage(Pref.showJoinButton) private var joinButton = true
    @AppStorage(Pref.meetingIndicator) private var meetingIndicator = true
    @AppStorage(Pref.meetingLeadMinutes) private var meetingLead = 5

    var body: some View {
        Form {
            Section {
                Toggle("Spotify", isOn: $spotify)
                Toggle("Apple Music", isOn: $music)
                Toggle("Tint the progress bar and equalizer with the album colours", isOn: $tint)
            } header: {
                Text("Now Playing sources")
            } footer: {
                Text("Notchly shows whichever enabled player is currently playing.")
            }

            Section {
                Toggle("Show upcoming events", isOn: $calendar)
                Toggle("Show a Join button for video calls", isOn: $joinButton)
                    .disabled(!calendar)
                Toggle("Remind me in the notch before a video call", isOn: $meetingIndicator)
                    .disabled(!calendar)
                Picker("Start reminding", selection: $meetingLead) {
                    ForEach([1, 2, 5, 10, 15], id: \.self) { minutes in
                        Text(minutes == 1 ? "1 minute before" : "\(minutes) minutes before").tag(minutes)
                    }
                }
                .disabled(!calendar || !meetingIndicator)
            } header: {
                Text("Calendar")
            } footer: {
                Text("Finds Zoom, Google Meet, Teams, Webex and other links in an event's location, URL or notes. The reminder shows a video icon and countdown next to the closed notch until you join.")
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - HUD

private struct HUDSettings: View {
    @AppStorage(Pref.replaceSystemHUD) private var replaceSystem = true
    @AppStorage(Pref.hudVolume) private var volume = true
    @AppStorage(Pref.hudBrightness) private var brightness = true
    @AppStorage(Pref.hudDuration) private var duration = 1.4

    var body: some View {
        Form {
            Section {
                Toggle("Show volume in the notch", isOn: $volume)
                Toggle("Show brightness in the notch", isOn: $brightness)
                SliderRow(title: "Visible for", value: $duration, range: 0.8...3.0, step: 0.1)
            } header: {
                Text("Notch HUD")
            } footer: {
                Text("A turned-off HUD falls back to the standard macOS overlay.")
            }

            Section {
                Toggle("Hide the macOS volume & brightness overlay", isOn: $replaceSystem)
            } header: {
                Text("System overlay")
            } footer: {
                Text("Needs Accessibility access. Notchly then handles the volume, mute and brightness keys itself.")
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Window

final class SettingsWindowController {
    static let shared = SettingsWindowController()
    private var window: NSWindow?

    /// Opens the settings window, optionally on a specific tab.
    func show(tab: SettingsTab? = nil) {
        defer { if let tab { SettingsNavigator.shared.tab = tab } }   // after the window exists (creating the view resets it)
        if window == nil {
            let w = NSWindow(contentViewController: NSHostingController(rootView: SettingsView()))
            w.title = "Notchly Settings"
            w.styleMask = [.titled, .closable, .miniaturizable]
            w.isReleasedWhenClosed = false
            w.center()
            window = w
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }
}
