import Foundation

// MARK: - Models

struct League: Identifiable, Hashable {
    let id: String          // ESPN league slug, e.g. "ger.1"
    let sport: String       // ESPN sport path component, e.g. "soccer"
    let name: String

    static let all: [League] = [
        League(id: "ger.1", sport: "soccer", name: "Bundesliga"),
        League(id: "uefa.champions", sport: "soccer", name: "Champions League"),
        League(id: "nfl", sport: "football", name: "NFL"),
        League(id: "nba", sport: "basketball", name: "NBA"),
    ]

    private var base: String { "https://site.api.espn.com/apis/site/v2/sports/\(sport)/\(id)" }
    var scoreboardURL: URL { URL(string: "\(base)/scoreboard?limit=100")! }
    var teamsURL: URL { URL(string: "\(base)/teams?limit=100")! }
    func scheduleURL(team: String, upcoming: Bool) -> URL {
        URL(string: "\(base)/teams/\(team)/schedule\(upcoming ? "?fixture=true" : "")")!
    }
}

struct FavoriteTeam: Codable, Hashable, Identifiable {
    let leagueID: String
    let teamID: String
    let name: String
    var id: String { "\(leagueID)/\(teamID)" }
}

struct Game: Identifiable, Equatable {
    enum State { case upcoming, live, final }

    struct Side: Equatable {
        let teamID: String
        let name: String
        /// Three-letter style code for the cramped collapsed notch.
        let code: String
        let score: Int?
        let logo: URL?
    }

    let id: String
    let leagueID: String
    let leagueName: String
    let start: Date
    let state: State
    /// Live clock ("67'", "Q3 5:12") or "FT" / "Final". Empty before kickoff.
    let detail: String
    let home: Side
    let away: Side

    func involves(_ team: FavoriteTeam) -> Bool {
        leagueID == team.leagueID && (home.teamID == team.teamID || away.teamID == team.teamID)
    }
}

/// Favourite teams and enabled leagues, as stored in UserDefaults.
enum ScoresPrefs {
    static var enabledLeagues: [League] {
        let ids = Set((UserDefaults.standard.string(forKey: Pref.scoreLeagues) ?? "").split(separator: ",").map(String.init))
        return League.all.filter { ids.contains($0.id) }
    }

    static var favorites: [FavoriteTeam] {
        decode(UserDefaults.standard.string(forKey: Pref.scoreFavorites) ?? "[]")
    }

    static func decode(_ json: String) -> [FavoriteTeam] {
        (try? JSONDecoder().decode([FavoriteTeam].self, from: Data(json.utf8))) ?? []
    }

    static func encode(_ teams: [FavoriteTeam]) -> String {
        (try? String(data: JSONEncoder().encode(teams), encoding: .utf8)) ?? "[]"
    }
}

// MARK: - Monitor

/// Live scores, results and fixtures from ESPN's public score feed (unofficial; no account needed).
///
/// - Live games come from each enabled league's scoreboard.
/// - A favourite team's next game and latest result come from its schedule (cached for a few hours).
/// - Polling is adaptive: every 20 s while a favourite is playing, every 5 minutes otherwise,
///   and not at all while the feature is switched off.
// `@unchecked Sendable`: all state changes happen on the main thread (results are handed back via
// DispatchQueue.main), the background task only reads value copies.
final class ScoresMonitor: ObservableObject, @unchecked Sendable {
    struct Flash: Equatable {
        let homeScored: Bool
        let until: Date
    }

    /// What the Scores tab lists (at most three).
    @Published private(set) var games: [Game] = []
    /// A favourite team's game in progress, for the collapsed notch.
    @Published private(set) var liveFavorite: Game?
    /// A side that just scored (highlighted for a few seconds).
    @Published private(set) var flashes: [String: Flash] = [:]
    @Published private(set) var loading = false
    @Published private(set) var failed = false
    @Published private(set) var updated: Date?

    private var scoreboard: [Game] = []
    private var scheduleCache: [String: (fetched: Date, games: [Game])] = [:]
    private var lastFetch: Date?
    private var inFlight = false
    private var timer: Timer?
    private var settingsSignature = ""
    private let isPreview: Bool

    init() {
        isPreview = false
        settingsSignature = Self.signature()
        timer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in self?.tick() }
        // Changing leagues or favourites in Settings refreshes right away.
        NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            let now = Self.signature()
            if now != self.settingsSignature {
                self.settingsSignature = now
                self.refresh(force: true)
            }
        }
    }

    /// For the debug snapshot tool.
    init(preview games: [Game], live: Game?, flashes: [String: Flash] = [:]) {
        isPreview = true
        self.games = games
        liveFavorite = live
        self.flashes = flashes
        updated = Date()
    }

    /// The live game for the collapsed notch, honouring the settings.
    var liveGameForNotch: Game? {
        Pref.bool(Pref.scoresEnabled) && Pref.bool(Pref.scoresLiveActivity) ? liveFavorite : nil
    }

    private static func signature() -> String {
        let d = UserDefaults.standard
        return [d.bool(forKey: Pref.scoresEnabled) ? "1" : "0",
                d.string(forKey: Pref.scoreLeagues) ?? "", d.string(forKey: Pref.scoreFavorites) ?? ""].joined(separator: "|")
    }

    // MARK: Scheduling

    private func tick() {
        guard Pref.bool(Pref.scoresEnabled), !isPreview else { return }
        let interval: TimeInterval = liveFavorite != nil ? 20 : (scoreboard.contains { $0.state == .live } ? 60 : 300)
        if let last = lastFetch, Date().timeIntervalSince(last) < interval { return }
        refresh(force: true)
    }

    /// - Parameter minInterval: skip if the last refresh was more recent than this (seconds).
    func refresh(force: Bool = false, minInterval: TimeInterval = 60) {
        guard !isPreview, !inFlight else { return }
        guard Pref.bool(Pref.scoresEnabled) else {
            games = []; liveFavorite = nil
            return
        }
        if !force, let last = lastFetch, Date().timeIntervalSince(last) < minInterval { return }

        let leagues = ScoresPrefs.enabledLeagues
        let enabledIDs = Set(leagues.map(\.id))
        let favorites = ScoresPrefs.favorites.filter { enabledIDs.contains($0.leagueID) }
        let cache = scheduleCache
        inFlight = true
        if games.isEmpty { loading = true }

        Task.detached(priority: .utility) { [weak self] in
            let result = await Self.fetchAll(leagues: leagues, favorites: favorites, cache: cache)
            DispatchQueue.main.async { self?.apply(result, favorites: favorites, leagues: leagues) }
        }
    }

    // MARK: Fetching

    private struct FetchResult {
        var scoreboard: [Game]
        var schedules: [String: (fetched: Date, games: [Game])]
        var failed: Bool
    }

    private static func get(_ url: URL) async -> Data? {
        var request = URLRequest(url: url, timeoutInterval: 12)
        request.setValue("Notchly", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return data
    }

    private static func fetchAll(leagues: [League], favorites: [FavoriteTeam],
                                 cache: [String: (fetched: Date, games: [Game])]) async -> FetchResult {
        var scoreboard: [Game] = []
        var failures = 0

        for league in leagues {
            if let data = await get(league.scoreboardURL) {
                scoreboard += parseScoreboard(data, league: league)
            } else { failures += 1 }
        }

        // Schedules change slowly: refresh each favourite at most every 3 hours.
        var schedules = cache.filter { entry in favorites.contains { $0.id == entry.key } }
        for fav in favorites {
            if let cached = schedules[fav.id], Date().timeIntervalSince(cached.fetched) < 3 * 3600 { continue }
            guard let league = League.all.first(where: { $0.id == fav.leagueID }) else { continue }
            var games: [Game] = []
            for upcoming in [false, true] {
                if let data = await get(league.scheduleURL(team: fav.teamID, upcoming: upcoming)) {
                    games += parseSchedule(data, league: league)
                }
            }
            if !games.isEmpty { schedules[fav.id] = (Date(), games) }
        }
        return FetchResult(scoreboard: scoreboard, schedules: schedules, failed: !leagues.isEmpty && failures == leagues.count)
    }

    private func apply(_ result: FetchResult, favorites: [FavoriteTeam], leagues: [League]) {
        inFlight = false
        loading = false
        lastFetch = Date()
        failed = result.failed
        if result.failed { return }          // keep showing the last good data

        // Highlight a side whose score went up since the last refresh.
        var newFlashes = flashes.filter { $0.value.until > Date() }
        for game in result.scoreboard where game.state == .live {
            guard let old = scoreboard.first(where: { $0.id == game.id }) else { continue }
            if let n = game.home.score, let o = old.home.score, n > o { newFlashes[game.id] = Flash(homeScored: true, until: Date().addingTimeInterval(8)) }
            if let n = game.away.score, let o = old.away.score, n > o { newFlashes[game.id] = Flash(homeScored: false, until: Date().addingTimeInterval(8)) }
        }
        flashes = newFlashes

        scoreboard = result.scoreboard
        scheduleCache = result.schedules
        let enabled = Set(leagues.map(\.id))
        games = Self.select(scoreboard: result.scoreboard, schedules: result.schedules.mapValues(\.games),
                            favorites: favorites, enabledLeagues: enabled)
        liveFavorite = favorites.isEmpty ? nil : games.first { $0.state == .live }
        updated = Date()
    }

    // MARK: Choosing what to show

    /// Picks up to three games: for each favourite, its live game, else a result from the last 18 hours,
    /// else its next fixture. Without favourites: today's games from the enabled leagues.
    static func select(scoreboard: [Game], schedules: [String: [Game]], favorites: [FavoriteTeam],
                       enabledLeagues: Set<String>, now: Date = Date()) -> [Game] {
        func order(_ games: [Game]) -> [Game] {
            let live = games.filter { $0.state == .live }.sorted { $0.start < $1.start }
            let final = games.filter { $0.state == .final }.sorted { $0.start > $1.start }
            let upcoming = games.filter { $0.state == .upcoming }.sorted { $0.start < $1.start }
            return live + final + upcoming
        }

        if favorites.isEmpty {
            return Array(order(scoreboard.filter { enabledLeagues.contains($0.leagueID) }).prefix(3))
        }

        var picks: [Game] = []
        for fav in favorites {
            var seen = Set<String>()
            let candidates = (scoreboard.filter { $0.involves(fav) } + (schedules[fav.id] ?? []))
                .filter { seen.insert($0.id).inserted }          // the scoreboard copy is fresher: it comes first

            // Written as separate steps (a chain of `??` with closures is slow for the compiler to type-check).
            var pick: Game? = candidates.first { $0.state == .live }
            if pick == nil {
                let recentFinals = candidates.filter { game in
                    game.state == .final && now.timeIntervalSince(game.start) < 18 * 3600
                }
                pick = recentFinals.max { $0.start < $1.start }
            }
            if pick == nil {
                let cutoff = now.addingTimeInterval(-3600)
                let upcoming = candidates.filter { game in
                    game.state == .upcoming && game.start > cutoff
                }
                pick = upcoming.min { $0.start < $1.start }
            }
            if let pick, !picks.contains(where: { $0.id == pick.id }) { picks.append(pick) }
        }
        return Array(order(picks).prefix(3))
    }

    // MARK: Parsing

    static func parseScoreboard(_ data: Data, league: League) -> [Game] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let events = root["events"] as? [[String: Any]] else { return [] }
        return events.compactMap { parseGame($0, league: league) }
    }

    static func parseSchedule(_ data: Data, league: League) -> [Game] {
        parseScoreboard(data, league: league)      // same event shape under "events"
    }

    static func parseGame(_ event: [String: Any], league: League) -> Game? {
        guard let id = event["id"] as? String,
              let dateString = event["date"] as? String, let start = parseDate(dateString),
              let competition = (event["competitions"] as? [[String: Any]])?.first,
              let competitors = competition["competitors"] as? [[String: Any]] else { return nil }

        // The scoreboard puts status on the event, the schedule on the competition.
        let status = (event["status"] as? [String: Any]) ?? (competition["status"] as? [String: Any]) ?? [:]
        let type = status["type"] as? [String: Any] ?? [:]
        let state: Game.State
        switch type["state"] as? String {
        case "in": state = .live
        case "post": state = .final
        default: state = .upcoming
        }

        var detail = ""
        switch state {
        case .live: detail = (type["shortDetail"] as? String) ?? (status["displayClock"] as? String) ?? "Live"
        case .final: detail = (type["shortDetail"] as? String) ?? "Final"
        case .upcoming: break
        }

        func side(_ homeAway: String) -> Game.Side? {
            guard let c = competitors.first(where: { $0["homeAway"] as? String == homeAway }),
                  let team = c["team"] as? [String: Any], let teamID = team["id"] as? String else { return nil }
            let name = (team["shortDisplayName"] as? String) ?? (team["displayName"] as? String) ?? "?"
            let abbreviation = (team["abbreviation"] as? String) ?? name
            let logo = (team["logo"] as? String) ?? ((team["logos"] as? [[String: Any]])?.first?["href"] as? String)
            return Game.Side(teamID: teamID, name: name,
                             code: league.sport == "soccer" ? soccerCode(name) : abbreviation.uppercased(),
                             score: state == .upcoming ? nil : intValue(c["score"]),
                             logo: logo.flatMap(URL.init(string:)))
        }
        guard let home = side("home"), let away = side("away") else { return nil }
        return Game(id: "\(league.id)/\(id)", leagueID: league.id, leagueName: league.name,
                    start: start, state: state, detail: detail, home: home, away: away)
    }

    /// Scores are a string on the scoreboard ("2") and an object on schedules ({"displayValue": "2"}).
    private static func intValue(_ any: Any?) -> Int? {
        switch any {
        case let s as String: return Int(s)
        case let n as NSNumber: return n.intValue
        case let d as [String: Any]: return intValue(d["displayValue"] ?? d["value"])
        default: return nil
        }
    }

    /// ESPN's soccer abbreviations are unreliable ("MUN" for Bayern), so derive a code from the name.
    static func soccerCode(_ name: String) -> String {
        var s = name
        for prefix in ["1. FC ", "1. ", "FC ", "SV ", "VfL ", "VfB ", "TSG ", "FSV ", "SC "] where s.hasPrefix(prefix) {
            s.removeFirst(prefix.count)
            break
        }
        return String(s.prefix(3)).uppercased()
    }

    private static func parseDate(_ s: String) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        for format in ["yyyy-MM-dd'T'HH:mm'Z'", "yyyy-MM-dd'T'HH:mm:ss'Z'", "yyyy-MM-dd'T'HH:mm:ss.SSS'Z'"] {
            f.dateFormat = format
            if let d = f.date(from: s) { return d }
        }
        return nil
    }
}

// MARK: - Team list for the settings picker

struct TeamInfo: Identifiable, Hashable {
    let id: String
    let name: String
}

enum ScoresAPI {
    private static var cache: [String: [TeamInfo]] = [:]

    static func teams(in league: League) async -> [TeamInfo] {
        if let cached = cache[league.id] { return cached }
        var request = URLRequest(url: league.teamsURL, timeoutInterval: 12)
        request.setValue("Notchly", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sport = (root["sports"] as? [[String: Any]])?.first,
              let leagueDict = (sport["leagues"] as? [[String: Any]])?.first,
              let teams = leagueDict["teams"] as? [[String: Any]] else { return [] }

        let list = teams.compactMap { entry -> TeamInfo? in
            guard let t = entry["team"] as? [String: Any], let id = t["id"] as? String,
                  let name = (t["shortDisplayName"] as? String) ?? (t["displayName"] as? String) else { return nil }
            return TeamInfo(id: id, name: (t["displayName"] as? String) ?? name)
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        cache[league.id] = list
        return list
    }
}
