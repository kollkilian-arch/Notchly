import XCTest
@testable import Notchly

/// Parser tests use samples shaped like real ESPN responses; selection tests cover which games
/// the notch chooses to show.
final class ScoresParsingTests: XCTestCase {
    private let bundesliga = League.all[0]
    private let nflLeague = League.all[2]

    private let scoreboardJSON = #"""
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

    private let scheduleJSON = #"""
    {"events":[{"id":"1002","date":"2026-11-14T14:30Z","competitions":[{"status":{"type":{"state":"post","shortDetail":"FT"}},"competitors":[
        {"homeAway":"home","score":{"value":3.0,"displayValue":"3"},"team":{"id":"598","abbreviation":"FCU","displayName":"1. FC Union Berlin","shortDisplayName":"Union Berlin","logos":[{"href":"https://a.espncdn.com/x.png"}]}},
        {"homeAway":"away","score":{"value":0.0,"displayValue":"0"},"team":{"id":"132","abbreviation":"MUN","displayName":"Bayern Munich","shortDisplayName":"Bayern Munich"}}]}]}]}
    """#

    private let nflJSON = #"""
    {"events":[{"id":"2001","date":"2026-11-15T18:00Z","status":{"displayClock":"9:12","period":3,"type":{"state":"in","shortDetail":"9:12 - 3rd"}},
      "competitions":[{"competitors":[
        {"homeAway":"home","score":"17","team":{"id":"17","abbreviation":"NE","displayName":"New England Patriots","shortDisplayName":"Patriots"}},
        {"homeAway":"away","score":"10","team":{"id":"8","abbreviation":"DET","displayName":"Detroit Lions","shortDisplayName":"Lions"}}],
       "situation":{"down":2,"yardLine":3,"distance":3,"downDistanceText":"2nd & Goal at DET 3","shortDownDistanceText":"2nd & Goal","possessionText":"DET 3","possession":"17","isRedZone":true}}]},
     {"id":"2002","date":"2026-11-15T21:00Z","status":{"type":{"state":"post","shortDetail":"Final"}},"competitions":[{"competitors":[
        {"homeAway":"home","score":"24","team":{"id":"1","abbreviation":"ATL","displayName":"Atlanta Falcons","shortDisplayName":"Falcons"}},
        {"homeAway":"away","score":"20","team":{"id":"12","abbreviation":"KC","displayName":"Kansas City Chiefs","shortDisplayName":"Chiefs"}}],"situation":{"downDistanceText":"stale"}}]}]}
    """#

    // MARK: Parsing

    func testScoreboardSkipsBrokenEventsAndParsesLiveGame() {
        let games = ScoresMonitor.parseScoreboard(Data(scoreboardJSON.utf8), league: bundesliga)
        XCTAssertEqual(games.count, 2, "the event with an invalid date must be skipped")
        let live = games[0]
        XCTAssertEqual(live.state, .live)
        XCTAssertEqual(live.detail, "67'")
        XCTAssertEqual(live.home.score, 2)
        XCTAssertEqual(live.away.score, 1)
        XCTAssertEqual(live.home.code, "BAY", "soccer codes are derived from names, not ESPN's abbreviation")
        XCTAssertEqual(live.away.code, "DOR")
        XCTAssertEqual(live.home.logo?.lastPathComponent, "132.png")
        XCTAssertNil(live.situation)
    }

    func testUpcomingGameHasNoScore() {
        let upcoming = ScoresMonitor.parseScoreboard(Data(scoreboardJSON.utf8), league: bundesliga).last
        XCTAssertEqual(upcoming?.state, .upcoming)
        XCTAssertNil(upcoming?.home.score)
    }

    func testStartDateIsParsedAsUTC() throws {
        let live = try XCTUnwrap(ScoresMonitor.parseScoreboard(Data(scoreboardJSON.utf8), league: bundesliga).first)
        let hour = Calendar(identifier: .gregorian).dateComponents(in: TimeZone(identifier: "UTC")!, from: live.start).hour
        XCTAssertEqual(hour, 14)
    }

    func testSchedulePutsStatusOnTheCompetitionAndReadsObjectScores() throws {
        let game = try XCTUnwrap(ScoresMonitor.parseSchedule(Data(scheduleJSON.utf8), league: bundesliga).first)
        XCTAssertEqual(game.state, .final)
        XCTAssertEqual(game.detail, "FT")
        XCTAssertEqual(game.home.score, 3)
        XCTAssertEqual(game.away.score, 0)
        XCTAssertNotNil(game.home.logo, "falls back to the logos array")
        XCTAssertEqual(game.home.code, "UNI", "'1. FC ' prefix is dropped")
    }

    func testNFLUsesAbbreviationsAndReadsTheSituation() throws {
        let games = ScoresMonitor.parseScoreboard(Data(nflJSON.utf8), league: nflLeague)
        let live = try XCTUnwrap(games.first)
        XCTAssertEqual(live.home.code, "NE")
        XCTAssertEqual(live.detail, "9:12 - 3rd")
        XCTAssertEqual(live.state, .live)
        XCTAssertEqual(live.situation?.text, "2nd & Goal at DET 3")
        XCTAssertEqual(live.situation?.possessionTeamID, "17")
        XCTAssertEqual(live.situation?.isRedZone, true)
    }

    func testSituationIsIgnoredOnFinishedGames() {
        let final = ScoresMonitor.parseScoreboard(Data(nflJSON.utf8), league: nflLeague).last
        XCTAssertEqual(final?.state, .final)
        XCTAssertNil(final?.situation)
    }

    func testGarbageInputGivesNoGames() {
        XCTAssertTrue(ScoresMonitor.parseScoreboard(Data("nope".utf8), league: bundesliga).isEmpty)
        XCTAssertTrue(ScoresMonitor.parseSchedule(Data("{}".utf8), league: bundesliga).isEmpty)
    }

    func testSoccerCodes() {
        XCTAssertEqual(ScoresMonitor.soccerCode("Eintracht Frankfurt"), "EIN")
        XCTAssertEqual(ScoresMonitor.soccerCode("FC Köln"), "KÖL")
    }

    // MARK: Selection

    private func game(_ id: String, _ state: Game.State, hoursFromNow h: Double, home: String = "132", away: String = "124") -> Game {
        let side = { (tid: String) in Game.Side(teamID: tid, name: tid, code: tid, score: state == .upcoming ? nil : 1, logo: nil) }
        return Game(id: "ger.1/\(id)", leagueID: "ger.1", leagueName: "Bundesliga", start: Date().addingTimeInterval(h * 3600),
                    state: state, detail: state == .live ? "30'" : (state == .final ? "FT" : ""), home: side(home), away: side(away))
    }

    private let bayern = FavoriteTeam(leagueID: "ger.1", teamID: "132", name: "Bayern Munich")
    private let enabled: Set<String> = ["ger.1"]

    private func pick(_ board: [Game], _ schedule: [Game], favorites: [FavoriteTeam]? = nil) -> [String] {
        ScoresMonitor.select(scoreboard: board, schedules: [bayern.id: schedule],
                             favorites: favorites ?? [bayern], enabledLeagues: enabled).map(\.id)
    }

    func testFavouriteLiveGameWins() {
        XCTAssertEqual(pick([game("live", .live, hoursFromNow: -0.5)],
                            [game("old", .final, hoursFromNow: -80), game("next", .upcoming, hoursFromNow: 70)]), ["ger.1/live"])
    }

    func testRecentResultBeatsNextFixtureButOldResultDoesNot() {
        let next = game("next", .upcoming, hoursFromNow: 70)
        XCTAssertEqual(pick([], [game("res", .final, hoursFromNow: -5), next]), ["ger.1/res"])
        XCTAssertEqual(pick([], [game("res", .final, hoursFromNow: -30), next]), ["ger.1/next"])
    }

    func testPicksTheSoonestUpcomingFixture() {
        XCTAssertEqual(pick([], [game("later", .upcoming, hoursFromNow: 200), game("soon", .upcoming, hoursFromNow: 20)]), ["ger.1/soon"])
    }

    func testScoreboardCopyIsPreferredOverStaleScheduleCopy() {
        let result = ScoresMonitor.select(scoreboard: [game("same", .live, hoursFromNow: -1)],
                                          schedules: [bayern.id: [game("same", .upcoming, hoursFromNow: -1)]],
                                          favorites: [bayern], enabledLeagues: enabled)
        XCTAssertEqual(result.first?.state, .live)
    }

    func testWithoutFavouritesLiveComesBeforeFinalBeforeUpcoming() {
        let board = [game("u", .upcoming, hoursFromNow: 3, home: "5", away: "6"),
                     game("l", .live, hoursFromNow: -1, home: "7", away: "8"),
                     game("f", .final, hoursFromNow: -3, home: "9", away: "10")]
        XCTAssertEqual(pick(board, [], favorites: []), ["ger.1/l", "ger.1/f", "ger.1/u"])
    }

    func testDisabledLeagueIsIgnoredWithoutFavourites() {
        XCTAssertTrue(ScoresMonitor.select(scoreboard: [game("x", .live, hoursFromNow: -1)], schedules: [:],
                                           favorites: [], enabledLeagues: ["nba"]).isEmpty)
    }

    func testAtMostThreeGamesAreShown() {
        let board = (0..<4).map { game("g\($0)", .live, hoursFromNow: -1, home: "h\($0)", away: "a\($0)") }
        XCTAssertEqual(pick(board, [], favorites: []).count, 3)
    }
}
