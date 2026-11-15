import SwiftUI

/// Debug helper: `Notchly --snapshot <dir>` renders the notch views to PNGs and exits.
/// Handy for checking layout without screen-recording permission.
@MainActor
func renderSnapshots(to dir: String) {
    let state = NotchState()
    state.notchSize = NotchGeometry.find().size
    let media = MediaMonitor()
    let battery = BatteryMonitor()
    let calendar = CalendarMonitor()
    let hud = HUDMonitor()
    // Use a throw-away store with sample files so the real shelf is never touched.
    let storeURL = URL(fileURLWithPath: dir).appendingPathComponent("test-shelf.json")
    try? FileManager.default.removeItem(at: storeURL)
    let shelf = ShelfStore(storeURL: storeURL)

    // Usage: fixed preview states (no Keychain/network), plus a check of the JSON parser.
    let sample = #"{"five_hour":{"utilization":37.0,"resets_at":"2026-11-15T17:00:00.123456+00:00"},"seven_day":{"utilization":84,"resets_at":"2026-11-19T09:00:00Z"},"seven_day_opus":null}"#
    let parsed = UsageMonitor.parseLimits(Data(sample.utf8))
    print("parseLimits: five=\(parsed?.fiveHour?.percent as Any) seven=\(parsed?.sevenDay?.percent as Any) reset5=\(parsed?.fiveHour?.resetsAt != nil)")
    let t0 = Date()
    let local = UsageMonitor.scanLocalLogs()
    print("local logs: last5h=\(local.last5h) last7d=\(local.last7d) tokens, scanned in \(String(format: "%.2f", Date().timeIntervalSince(t0))) s")
    let limitsUsage = UsageMonitor(preview: .limits(LimitUsage(
        fiveHour: LimitWindow(percent: 37, resetsAt: Date().addingTimeInterval(2 * 3600 + 10 * 60)),
        sevenDay: LimitWindow(percent: 84, resetsAt: Date().addingTimeInterval(3 * 86400)),
        plan: "pro", fetched: Date())))
    let highUsage = UsageMonitor(preview: .limits(LimitUsage(
        fiveHour: LimitWindow(percent: 87, resetsAt: Date().addingTimeInterval(50 * 60)),
        sevenDay: LimitWindow(percent: 41, resetsAt: Date().addingTimeInterval(2 * 86400)),
        plan: "pro", fetched: Date())))
    let criticalUsage = UsageMonitor(preview: .limits(LimitUsage(
        fiveHour: LimitWindow(percent: 98, resetsAt: Date().addingTimeInterval(20 * 60)),
        sevenDay: LimitWindow(percent: 60, resetsAt: Date().addingTimeInterval(2 * 86400)),
        plan: "pro", fetched: Date())))
    let localUsage = UsageMonitor(preview: .local(LocalUsage(last5h: 412_300, last7d: 14_800_000),
                                                   note: "Claude sign-in expired. Run “claude” once to refresh it."))
    shelf.add([
        URL(fileURLWithPath: dir).appendingPathComponent("closed.png"),
        URL(fileURLWithPath: "/Applications/Spotify.app"),
        URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app"),
        URL(fileURLWithPath: "/etc/hosts"),
        URL(fileURLWithPath: "/nonexistent/ghost.txt"),   // must be rejected
    ])
    let reloaded = ShelfStore(storeURL: storeURL)
    print("shelf: added=\(shelf.items.count) reloaded=\(reloaded.items.count) (expected 3 or 4 without the ghost)")

    // Give the monitors a moment to poll (music, calendar, artwork download).
    RunLoop.main.run(until: Date().addingTimeInterval(3))
    print("real artwork accent:", media.track.map { "\($0.title) →" } ?? "(no track)", describe(media.accent))

    // Optional live check of the real usage path: NOTCHLY_LIVE_USAGE=1 (makes one network request).
    if ProcessInfo.processInfo.environment["NOTCHLY_LIVE_USAGE"] == "1" {
        let live = UsageMonitor()
        live.refresh(force: true)
        RunLoop.main.run(until: Date().addingTimeInterval(6))
        switch live.state {
        case .limits(let l):
            print("usage live: LIMITS 5h=\(l.fiveHour?.percent as Any) 7d=\(l.sevenDay?.percent as Any) plan=\(l.plan ?? "?") ring=\(live.fiveHourPercent as Any)")
        case .local(let u, let note): print("usage live: LOCAL fallback (\(note)) 5h=\(u.last5h) 7d=\(u.last7d)")
        default: print("usage live: no result yet (\(live.state))")
        }
    }

    // Meeting-link detection on sample event texts.
    let cases: [(String, [String?], String?)] = [
        ("zoom in location", [nil, "https://us02web.zoom.us/j/81234567890?pwd=abc123", nil], "Zoom"),
        ("meet in notes", ["Room 4", "Agenda below.\nJoin: https://meet.google.com/abc-defg-hij\nThanks"], "Google Meet"),
        ("teams via Outlook safelinks", ["https://nam12.safelinks.protection.outlook.com/?url=https%3A%2F%2Fteams.microsoft.com%2Fl%2Fmeetup-join%2F19%253ameeting_abc%2F0%3Fcontext%3D%257b%257d&data=05"], "Teams"),
        ("zoom via Google redirect", ["https://www.google.com/url?q=https://zoom.us/j/123456789&sa=D"], "Zoom"),
        ("webex after an unrelated link", [nil, "see https://example.com/agenda and https://acme.webex.com/meet/jdoe"], "Webex"),
        ("event url wins over notes", ["https://whereby.com/team-room", "https://zoom.us/j/999999"], "Whereby"),
        ("calendar link is not a meeting", ["https://www.google.com/calendar/event?eid=xyz"], nil),
        ("bare zoom.us homepage", ["https://zoom.us/"], nil),
        ("meet landing page", ["https://meet.google.com/landing"], nil),
        ("plain text, no link", ["Conference room 4B, 3rd floor"], nil),
        ("nothing at all", [nil, nil, nil], nil),
    ]
    var meetingFailures = 0
    for (name, texts, expected) in cases {
        let got = MeetingLinks.find(in: texts)?.service
        if got != expected { meetingFailures += 1; print("meeting FAIL: \(name): expected \(expected ?? "none"), got \(got ?? "none")") }
    }
    print("meeting links: \(cases.count - meetingFailures)/\(cases.count) cases correct")

    let zoomURL = URL(string: "https://zoom.us/j/81234567890")!
    let meetingCalendar = CalendarMonitor(preview: [
        CalEvent(id: "1", title: "Weekly sync", start: Date().addingTimeInterval(6 * 60), end: Date().addingTimeInterval(36 * 60),
                 color: .systemBlue, meeting: MeetingLink(url: zoomURL, service: "Zoom")),
        CalEvent(id: "2", title: "Design review", start: Date().addingTimeInterval(2 * 3600), end: Date().addingTimeInterval(3 * 3600),
                 color: .systemOrange, meeting: MeetingLink(url: URL(string: "https://meet.google.com/abc-defg-hij")!, service: "Google Meet")),
    ])

    // Scores: parser tests against samples shaped like the real ESPN responses, then selection logic.
    let scoreboardJSON = #"""
    {"events":[
     {"id":"1001","date":"2026-11-15T14:30Z","status":{"displayClock":"67'","period":2,"type":{"state":"in","completed":false,"description":"In Progress","detail":"67'","shortDetail":"67'"}},
      "competitions":[{"competitors":[
        {"homeAway":"home","score":"2","team":{"id":"132","abbreviation":"MUN","displayName":"Bayern Munich","shortDisplayName":"Bayern Munich","logo":"https://a.espncdn.com/i/teamlogos/soccer/500/132.png"}},
        {"homeAway":"away","score":"1","team":{"id":"124","abbreviation":"DOR","displayName":"Borussia Dortmund","shortDisplayName":"Dortmund","logo":"https://a.espncdn.com/i/teamlogos/soccer/500/124.png"}}]}]},
     {"id":"1003","date":"2026-11-15T17:30Z","status":{"type":{"state":"pre","shortDetail":"11/15 - 12:30 PM EST"}},
      "competitions":[{"competitors":[
        {"homeAway":"home","team":{"id":"1","abbreviation":"B04","displayName":"Bayer Leverkusen","shortDisplayName":"Leverkusen"}},
        {"homeAway":"away","team":{"id":"2","abbreviation":"RBL","displayName":"RB Leipzig","shortDisplayName":"RB Leipzig"}}]}]},
     {"id":"bad","date":"not a date","competitions":[]}]}
    """#
    let scheduleJSON = #"""
    {"events":[{"id":"1002","date":"2026-11-14T14:30Z","competitions":[{"status":{"type":{"state":"post","shortDetail":"FT"}},"competitors":[
        {"homeAway":"home","score":{"value":3.0,"displayValue":"3"},"team":{"id":"598","abbreviation":"FCU","displayName":"1. FC Union Berlin","shortDisplayName":"Union Berlin","logos":[{"href":"https://a.espncdn.com/x.png"}]}},
        {"homeAway":"away","score":{"value":0.0,"displayValue":"0"},"team":{"id":"132","abbreviation":"MUN","displayName":"Bayern Munich","shortDisplayName":"Bayern Munich"}}]}]}]}
    """#
    let nflJSON = #"""
    {"events":[{"id":"2001","date":"2026-11-15T18:00Z","status":{"displayClock":"9:12","period":3,"type":{"state":"in","shortDetail":"9:12 - 3rd"}},
      "competitions":[{"competitors":[
        {"homeAway":"home","score":"17","team":{"id":"17","abbreviation":"NE","displayName":"New England Patriots","shortDisplayName":"Patriots"}},
        {"homeAway":"away","score":"10","team":{"id":"8","abbreviation":"DET","displayName":"Detroit Lions","shortDisplayName":"Lions"}}],
       "situation":{"down":2,"yardLine":3,"distance":3,"downDistanceText":"2nd & Goal at DET 3","shortDownDistanceText":"2nd & Goal","possessionText":"DET 3","possession":"17","isRedZone":true}}]},
     {"id":"2002","date":"2026-11-15T21:00Z","status":{"type":{"state":"post","shortDetail":"Final"}},"competitions":[{"competitors":[
        {"homeAway":"home","score":"24","team":{"id":"1","abbreviation":"ATL","displayName":"Atlanta Falcons","shortDisplayName":"Falcons"}},
        {"homeAway":"away","score":"20","team":{"id":"12","abbreviation":"KC","displayName":"Kansas City Chiefs","shortDisplayName":"Chiefs"}}],"situation":{"downDistanceText":"stale"}}]}]}
    """#
    let bundesliga = League.all[0], nflLeague = League.all[2]
    let sb = ScoresMonitor.parseScoreboard(Data(scoreboardJSON.utf8), league: bundesliga)
    let sched = ScoresMonitor.parseSchedule(Data(scheduleJSON.utf8), league: bundesliga)
    let nfl = ScoresMonitor.parseScoreboard(Data(nflJSON.utf8), league: nflLeague)
    var scoreFails: [String] = []
    var scoreChecks = 0
    func check(_ name: String, _ ok: Bool) {
        scoreChecks += 1
        if !ok { scoreFails.append(name) }
    }
    check("scoreboard parses 2 valid events, skips the broken one", sb.count == 2)
    check("live game: state + clock", sb.first?.state == .live && sb.first?.detail == "67'")
    check("live game: string scores 2-1", sb.first?.home.score == 2 && sb.first?.away.score == 1)
    check("soccer codes derive from names (BAY/DOR)", sb.first?.home.code == "BAY" && sb.first?.away.code == "DOR")
    check("logo URL parsed", sb.first?.home.logo?.absoluteString.hasSuffix("/132.png") == true)
    check("upcoming game has no score", sb.last?.state == .upcoming && sb.last?.home.score == nil)
    check("schedule: status on competition, FT final", sched.first?.state == .final && sched.first?.detail == "FT")
    check("schedule: object scores 3-0", sched.first?.home.score == 3 && sched.first?.away.score == 0)
    check("schedule: logos array fallback", sched.first?.home.logo != nil)
    check("'1. FC ' prefix dropped (UNI)", sched.first?.home.code == "UNI")
    check("NFL: abbreviation as code + clock", nfl.first?.home.code == "NE" && nfl.first?.detail == "9:12 - 3rd" && nfl.first?.state == .live)
    let situation = nfl.first?.situation
    check("NFL situation: down, distance and spot", situation?.text == "2nd & Goal at DET 3")
    check("NFL situation: possession team id + red zone", situation?.possessionTeamID == "17" && situation?.isRedZone == true)
    check("situation ignored on a finished game", nfl.last?.state == .final && nfl.last?.situation == nil)
    check("no situation for soccer", sb.first?.situation == nil)
    check("start date parsed (UTC)", sb.first.map { Calendar(identifier: .gregorian).dateComponents(in: TimeZone(identifier: "UTC")!, from: $0.start).hour } == 14)

    func g(_ id: String, _ state: Game.State, hoursFromNow h: Double, home: String = "132", away: String = "124") -> Game {
        let side = { (tid: String) in Game.Side(teamID: tid, name: tid, code: tid, score: state == .upcoming ? nil : 1, logo: nil) }
        return Game(id: "ger.1/\(id)", leagueID: "ger.1", leagueName: "Bundesliga", start: Date().addingTimeInterval(h * 3600),
                    state: state, detail: state == .live ? "30'" : (state == .final ? "FT" : ""), home: side(home), away: side(away))
    }
    let bayern = FavoriteTeam(leagueID: "ger.1", teamID: "132", name: "Bayern Munich")
    let en: Set<String> = ["ger.1"]
    func pick(_ board: [Game], _ schedule: [Game], favs: [FavoriteTeam] = [bayern]) -> [String] {
        ScoresMonitor.select(scoreboard: board, schedules: [bayern.id: schedule], favorites: favs, enabledLeagues: en).map(\.id)
    }
    check("favourite: live game wins", pick([g("live", .live, hoursFromNow: -0.5)], [g("old", .final, hoursFromNow: -80), g("next", .upcoming, hoursFromNow: 70)]) == ["ger.1/live"])
    check("favourite: result from 5 h ago beats next fixture", pick([], [g("res", .final, hoursFromNow: -5), g("next", .upcoming, hoursFromNow: 70)]) == ["ger.1/res"])
    check("favourite: 30 h old result gives way to the next fixture", pick([], [g("res", .final, hoursFromNow: -30), g("next", .upcoming, hoursFromNow: 70)]) == ["ger.1/next"])
    check("favourite: picks the soonest upcoming", pick([], [g("later", .upcoming, hoursFromNow: 200), g("soon", .upcoming, hoursFromNow: 20)]) == ["ger.1/soon"])
    check("favourite: scoreboard copy preferred over stale schedule copy", ScoresMonitor.select(scoreboard: [g("same", .live, hoursFromNow: -1)], schedules: [bayern.id: [g("same", .upcoming, hoursFromNow: -1)]], favorites: [bayern], enabledLeagues: en).first?.state == .live)
    check("no favourites: live first, then finals, then upcoming", pick([g("u", .upcoming, hoursFromNow: 3, home: "5", away: "6"), g("l", .live, hoursFromNow: -1, home: "7", away: "8"), g("f", .final, hoursFromNow: -3, home: "9", away: "10")], [], favs: []) == ["ger.1/l", "ger.1/f", "ger.1/u"])
    check("disabled league is ignored when there are no favourites", ScoresMonitor.select(scoreboard: [g("x", .live, hoursFromNow: -1)], schedules: [:], favorites: [], enabledLeagues: ["nba"]).isEmpty)
    check("max three games shown", pick([g("a", .live, hoursFromNow: -1, home: "1", away: "2"), g("b", .live, hoursFromNow: -1, home: "3", away: "4"), g("c", .live, hoursFromNow: -1, home: "5", away: "6"), g("d", .live, hoursFromNow: -1, home: "7", away: "8")], [], favs: []).count == 3)
    check("soccerCode: Eintracht Frankfurt → EIN, 'FC Köln' → KÖL", ScoresMonitor.soccerCode("Eintracht Frankfurt") == "EIN" && ScoresMonitor.soccerCode("FC Köln") == "KÖL")
    print("scores: \(scoreChecks - scoreFails.count)/\(scoreChecks) checks pass" + (scoreFails.isEmpty ? "" : " — FAILED: \(scoreFails)"))

    // Optional live check against the real feed: NOTCHLY_LIVE_SCORES=1 (a handful of network requests).
    if ProcessInfo.processInfo.environment["NOTCHLY_LIVE_SCORES"] == "1" {
        let defaults = UserDefaults.standard
        defaults.set(ScoresPrefs.encode([FavoriteTeam(leagueID: "ger.1", teamID: "132", name: "Bayern Munich"),
                                         FavoriteTeam(leagueID: "nba", teamID: "3", name: "New Orleans Pelicans"),
                                         FavoriteTeam(leagueID: "nfl", teamID: "17", name: "New England Patriots")]), forKey: Pref.scoreFavorites)
        let live = ScoresMonitor()
        live.refresh(force: true)
        RunLoop.main.run(until: Date().addingTimeInterval(14))
        print("scores live: failed=\(live.failed) games=\(live.games.count) updated=\(live.updated != nil)")
        for game in live.games {
            print("  \(game.leagueName): \(game.home.name) \(game.home.score.map(String.init) ?? "-") : \(game.away.score.map(String.init) ?? "-") \(game.away.name) [\(game.state), \(game.detail.isEmpty ? game.start.formatted() : game.detail)]"
                  + (game.situation.map { " situation: \($0.text) | ball: \($0.possessionTeamID ?? "?") | redzone: \($0.isRedZone)" } ?? ""))
        }
        defaults.removeObject(forKey: Pref.scoreFavorites)
    }

    // Preview states for the tab and the collapsed notch.
    func side(_ id: String, _ name: String, _ code: String, _ score: Int?) -> Game.Side {
        Game.Side(teamID: id, name: name, code: code, score: score, logo: URL(string: "https://a.espncdn.com/i/teamlogos/soccer/500/\(id).png"))
    }
    let liveGame = Game(id: "ger.1/live", leagueID: "ger.1", leagueName: "Bundesliga", start: Date().addingTimeInterval(-3600),
                        state: .live, detail: "67'", home: side("132", "Bayern Munich", "BAY", 2), away: side("124", "Dortmund", "DOR", 1))
    let finalGame = Game(id: "ger.1/final", leagueID: "ger.1", leagueName: "Bundesliga", start: Date().addingTimeInterval(-5 * 3600),
                         state: .final, detail: "FT", home: side("598", "Union Berlin", "UNI", 3), away: side("127", "Hamburg", "HAM", 0))
    let nextGame = Game(id: "uefa/next", leagueID: "uefa.champions", leagueName: "Champions League", start: Date().addingTimeInterval(26 * 3600),
                        state: .upcoming, detail: "", home: side("86", "Real Madrid", "REA", nil), away: side("132", "Bayern Munich", "BAY", nil))
    func nflSide(_ id: String, _ name: String, _ code: String, _ score: Int?) -> Game.Side {
        Game.Side(teamID: id, name: name, code: code, score: score,
                  logo: URL(string: "https://a.espncdn.com/i/teamlogos/nfl/500/\(code.lowercased()).png"))
    }
    let nflRedZone = Game(id: "nfl/1", leagueID: "nfl", leagueName: "NFL", start: Date().addingTimeInterval(-3000),
                          state: .live, detail: "10:45 - 1st", home: nflSide("17", "Patriots", "NE", 10), away: nflSide("8", "Lions", "DET", 7),
                          situation: Game.Situation(text: "2nd & Goal at DET 3", possessionTeamID: "17", isRedZone: true))
    let nflMidfield = Game(id: "nfl/2", leagueID: "nfl", leagueName: "NFL", start: Date().addingTimeInterval(-6000),
                           state: .live, detail: "4:12 - 3rd", home: nflSide("1", "Falcons", "ATL", 14), away: nflSide("12", "Chiefs", "KC", 21),
                           situation: Game.Situation(text: "1st & 10 at KC 45", possessionTeamID: "12", isRedZone: false))
    let nflFinal = Game(id: "nfl/3", leagueID: "nfl", leagueName: "NFL", start: Date().addingTimeInterval(-6 * 3600),
                        state: .final, detail: "Final", home: nflSide("20", "Giants", "NYG", 17), away: nflSide("28", "Commanders", "WSH", 24))
    let scoresNFL = ScoresMonitor(preview: [nflRedZone, nflMidfield, nflFinal], live: nflRedZone)
    let scoresNFLAway = ScoresMonitor(preview: [nflMidfield], live: nflMidfield)       // away team has the ball
    let scoresNFLFlash = ScoresMonitor(preview: [nflRedZone], live: nflRedZone,
                                       flashes: ["nfl/1": ScoresMonitor.Flash(homeScored: true, until: Date().addingTimeInterval(60))])
    let scoresList = ScoresMonitor(preview: [liveGame, finalGame, nextGame], live: liveGame)
    let scoresNone = ScoresMonitor(preview: [], live: nil)
    let scoresLive = ScoresMonitor(preview: [liveGame], live: liveGame)
    let scoresFlash = ScoresMonitor(preview: [liveGame], live: liveGame,
                                    flashes: ["ger.1/live": ScoresMonitor.Flash(homeScored: true, until: Date().addingTimeInterval(60))])

    // Meeting indicator timing logic.
    func event(_ id: String, startsIn minutes: Double, lasts: Double = 30, link: Bool = true) -> CalEvent {
        let start = Date().addingTimeInterval(minutes * 60)
        return CalEvent(id: id, title: id, start: start, end: start.addingTimeInterval(lasts * 60), color: .systemBlue,
                        meeting: link ? MeetingLink(url: zoomURL, service: "Zoom") : nil)
    }
    func shown(_ e: CalEvent, lead: Int = 5, joined: Bool = false) -> Bool {
        let cal = CalendarMonitor(preview: [e])
        if joined { cal.markJoined(e) }
        return cal.imminentMeeting(leadMinutes: lead) != nil
    }
    let timing: [(String, Bool, Bool)] = [
        ("12 min before, lead 5", shown(event("a", startsIn: 12)), false),
        ("4 min before, lead 5", shown(event("b", startsIn: 4)), true),
        ("4 min before, lead 2", shown(event("c", startsIn: 4), lead: 2), false),
        ("12 min before, lead 15", shown(event("d", startsIn: 12), lead: 15), true),
        ("started 3 min ago", shown(event("e", startsIn: -3)), true),
        ("started 12 min ago (too late)", shown(event("f", startsIn: -12)), false),
        ("no link", shown(event("g", startsIn: 3, link: false)), false),
        ("already joined", shown(event("h", startsIn: 3), joined: true), false),
        ("ended already", shown(event("i", startsIn: -40, lasts: 30)), false),
    ]
    var timingFailures = 0
    for (name, got, expected) in timing where got != expected { timingFailures += 1; print("indicator FAIL: \(name): expected \(expected), got \(got)") }
    print("meeting indicator: \(timing.count - timingFailures)/\(timing.count) timing cases correct")

    let soonCalendar = CalendarMonitor(preview: [event("Weekly sync", startsIn: 4)])
    let nowCalendar = CalendarMonitor(preview: [event("Weekly sync", startsIn: -3)])

    // Synthesised lock sounds: write them out and report basic measurements.
    for (name, data) in [("lock-clack", SynthSounds.lockClack()), ("unlock-click", SynthSounds.unlockClick())] {
        try? data.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).wav"))
        // Written step by step: older Swift compilers time out on one long mixed-arithmetic expression.
        var pcm: [Int16] = []
        var offset = 44                                   // skip the 44-byte WAV header
        while offset + 1 < data.count {
            let low = UInt16(data[offset])
            let high = UInt16(data[offset + 1])
            pcm.append(Int16(bitPattern: low | (high << 8)))
            offset += 2
        }
        var sumOfSquares = 0.0
        var peakSample = 0
        for sample in pcm {
            let value = Double(sample)
            sumOfSquares += value * value
            peakSample = max(peakSample, abs(Int(sample)))
        }
        let count = Double(pcm.count)
        let rms: Double = (sumOfSquares / count).squareRoot() / 32767
        let peak: Double = Double(peakSample) / 32767
        let milliseconds: Double = count / SynthSounds.sampleRate * 1000
        let dbfs: Double = 20 * log10(rms)
        let first = Int(pcm.first ?? 0)
        let last = Int(pcm.last ?? 0)
        let loads = NSSound(data: data) != nil ? "yes" : "NO"
        let line = String(format: "sound %@: %.0f ms, peak %.2f, rms %.3f (%.0f dBFS), first=%d last=%d, NSSound loads=%@",
                          name, milliseconds, peak, rms, dbfs, first, last, loads)
        print(line)
    }

    // Artwork colour extraction on synthetic images with known answers, plus the real artwork below.
    func solid(_ color: NSColor, fraction: Double = 1) -> NSImage {
        let img = NSImage(size: NSSize(width: 100, height: 100))
        img.lockFocus()
        NSColor(white: 0.12, alpha: 1).setFill(); NSRect(x: 0, y: 0, width: 100, height: 100).fill()
        color.setFill(); NSRect(x: 0, y: 0, width: 100, height: 100 * fraction).fill()
        img.unlockFocus()
        return img
    }
    func describe(_ c: NSColor?) -> String {
        guard let c = c?.usingColorSpace(.sRGB) else { return "nil (stays white)" }
        return String(format: "#%02X%02X%02X hue=%.0f° sat=%.2f bri=%.2f", Int(c.redComponent * 255), Int(c.greenComponent * 255),
                      Int(c.blueComponent * 255), c.hueComponent * 360, c.saturationComponent, c.brightnessComponent)
    }
    print("accent red       :", describe(ArtworkColor.accent(for: solid(NSColor(srgbRed: 0.8, green: 0.1, blue: 0.1, alpha: 1)))))
    print("accent blue      :", describe(ArtworkColor.accent(for: solid(NSColor(srgbRed: 0.1, green: 0.2, blue: 0.9, alpha: 1)))))
    print("accent dark navy :", describe(ArtworkColor.accent(for: solid(NSColor(srgbRed: 0.05, green: 0.08, blue: 0.3, alpha: 1)))))
    print("accent grey      :", describe(ArtworkColor.accent(for: solid(NSColor(white: 0.6, alpha: 1)))))
    print("accent 5% orange :", describe(ArtworkColor.accent(for: solid(NSColor.orange, fraction: 0.05))))
    print("accent 30% green :", describe(ArtworkColor.accent(for: solid(NSColor(srgbRed: 0.1, green: 0.7, blue: 0.3, alpha: 1), fraction: 0.3))))

    // Timer logic check with real (short) countdowns. Chime is silenced for the test only.
    UserDefaults.standard.set(false, forKey: Pref.timerSound)
    let lt = TimerModel()
    func spin(_ s: TimeInterval) { RunLoop.main.run(until: Date().addingTimeInterval(s)) }
    func r(_ x: TimeInterval) -> String { String(format: "%.1f", x) }
    lt.start(seconds: 2)
    spin(0.5)
    let a = lt.remaining()                                   // ~1.5
    lt.pause(); let pausedAt = lt.remaining(); spin(0.6)
    let stillPaused = abs(lt.remaining() - pausedAt) < 0.01  // frozen while paused
    lt.resume(); lt.add(seconds: 1)                          // ~2.5 left, total 3
    let b = lt.remaining(); let totalAfterAdd = lt.total
    spin(1.0)
    let stillRunning = lt.phase == .running
    spin(2.0)
    let finishedOK = lt.phase == .finished
    lt.cancel()
    print("timer: afterStart=\(r(a)) frozenWhilePaused=\(stillPaused) afterResume+1=\(r(b)) total=\(r(totalAfterAdd)) runningAt1s=\(stillRunning) finished=\(finishedOK) cancelled=\(lt.phase == .idle)")
    print("clock: \(clockString(522)) \(clockString(3723)) \(clockString(0.2))")
    UserDefaults.standard.removeObject(forKey: Pref.timerSound)

    // Timer: fixed preview states.
    let idleTimer = TimerModel()
    let runningTimer = TimerModel(preview: .running, total: 600, remaining: 522)
    let pausedTimer = TimerModel(preview: .paused, total: 1500, remaining: 1111)
    let finishedTimer = TimerModel(preview: .finished, total: 600, remaining: 0)

    let idleLock = LockMonitor(preview: .unlocked)
    let lockedLock = LockMonitor(preview: .locked)
    let unlockingLock = LockMonitor(preview: .justUnlocked)

    let width = NotchState.openSize.width + 40
    let variants: [(String, Bool, NotchTab, UsageMonitor, TimerModel)] = [
        ("closed", false, .home, limitsUsage, idleTimer), ("open", true, .home, limitsUsage, idleTimer),
        ("shelf", true, .shelf, limitsUsage, idleTimer),
        ("usage-limits", true, .usage, limitsUsage, idleTimer), ("usage-local", true, .usage, localUsage, idleTimer),
        ("timer-idle", true, .timer, limitsUsage, idleTimer), ("timer-running", true, .timer, limitsUsage, runningTimer),
        ("timer-finished", true, .timer, limitsUsage, finishedTimer),
        ("closed-timer-running", false, .home, limitsUsage, runningTimer),
        ("closed-timer-paused", false, .home, limitsUsage, pausedTimer),
        ("closed-timer-finished", false, .home, limitsUsage, finishedTimer),
        ("calendar-join", true, .home, limitsUsage, idleTimer),
        ("closed-meeting-soon", false, .home, limitsUsage, idleTimer),
        ("closed-meeting-now", false, .home, limitsUsage, idleTimer),
        ("closed-meeting-with-timer", false, .home, limitsUsage, runningTimer),     // timer outranks the meeting
        ("scores-tab", true, .scores, limitsUsage, idleTimer),
        ("scores-nfl", true, .scores, limitsUsage, idleTimer),
        ("closed-nfl-home-ball", false, .home, limitsUsage, idleTimer),
        ("closed-nfl-away-ball", false, .home, limitsUsage, idleTimer),
        ("closed-nfl-flash", false, .home, limitsUsage, idleTimer),
        ("scores-empty", true, .scores, limitsUsage, idleTimer),
        ("closed-score-live", false, .home, limitsUsage, idleTimer),
        ("closed-score-flash", false, .home, limitsUsage, idleTimer),
        ("ring-high", true, .home, highUsage, idleTimer),
        ("ring-critical", true, .home, criticalUsage, idleTimer),
        ("ring-unknown", true, .home, localUsage, idleTimer),
        ("closed-locked", false, .home, limitsUsage, runningTimer),      // timer running: lock must win
        ("closed-unlocking", false, .home, limitsUsage, runningTimer),
    ]
    for (name, open, tab, usage, timer) in variants {
        state.isOpen = open
        state.tab = tab
        let view = NotchRoot(state: state, media: media, battery: battery,
                             calendar: ["calendar-join": meetingCalendar, "closed-meeting-soon": soonCalendar,
                                        "closed-meeting-now": nowCalendar, "closed-meeting-with-timer": soonCalendar][name] ?? calendar,
                             hud: hud,
                             shelf: shelf, usage: usage, timer: timer,
                             lock: name == "closed-locked" ? lockedLock : (name == "closed-unlocking" ? unlockingLock : idleLock),
                             scores: ["scores-tab": scoresList, "scores-nfl": scoresNFL, "closed-nfl-home-ball": scoresNFL,
                                      "closed-nfl-away-ball": scoresNFLAway, "closed-nfl-flash": scoresNFLFlash, "scores-empty": scoresNone, "closed-score-live": scoresLive,
                                      "closed-score-flash": scoresFlash, "closed-score-with-meeting": scoresLive][name] ?? scoresNone)
            .environment(\.colorScheme, .dark)
            .frame(width: width, height: 202)
            .background(Color(white: 0.55))
        capture(view, size: NSSize(width: width, height: 202), dark: true, to: dir, name: name)
    }

    // The settings window, one image per tab (light appearance, like a normal window).
    let tabs: [(String, SettingsTab)] = [("settings-general", .general), ("settings-notch", .notch),
                                         ("settings-home", .home), ("settings-hud", .hud),
                                         ("settings-feedback", .feedback), ("settings-scores", .scores)]
    for (name, tab) in tabs {
        capture(SettingsView(initialTab: tab), size: NSSize(width: 520, height: 530), dark: false, to: dir, name: name)
    }
}

/// Host the view for real (ImageRenderer shows a "no entry" placeholder for scroll views) and save a PNG.
@MainActor
private func capture<V: View>(_ view: V, size: NSSize, dark: Bool, to dir: String, name: String) {
    let host = NSHostingView(rootView: view)
    host.frame = NSRect(origin: .zero, size: size)
    let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
    window.contentView = host
    window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    host.layoutSubtreeIfNeeded()
    RunLoop.main.run(until: Date().addingTimeInterval(1.0))   // thumbnails etc.
    host.layoutSubtreeIfNeeded()

    guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
    host.cacheDisplay(in: host.bounds, to: rep)
    guard let png = rep.representation(using: .png, properties: [:]) else { return }
    try? png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
}
