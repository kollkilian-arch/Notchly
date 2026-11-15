import SwiftUI

// MARK: - Scores tab

struct ScoresView: View {
    @ObservedObject var scores: ScoresMonitor

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if scores.games.isEmpty {
                empty
            } else {
                VStack(spacing: 5) {
                    ForEach(scores.games) { GameRow(game: $0, flash: scores.flashes[$0.id]) }
                }
            }
            Spacer(minLength: 4)
            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear { scores.refresh() }
    }

    @ViewBuilder private var empty: some View {
        if scores.loading {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Loading scores…").font(.system(size: 12)).foregroundStyle(.white.opacity(0.6))
            }
            .padding(.top, 12)
        } else {
            VStack(alignment: .leading, spacing: 3) {
                Text(scores.failed ? "Couldn't load scores" : "No games right now")
                    .font(.system(size: 13, weight: .semibold))
                Text(scores.failed ? "Check your connection; Notchly will retry."
                                   : "Pick leagues and favourite teams in Settings → Scores.")
                    .font(.system(size: 11)).foregroundStyle(.white.opacity(0.5))
            }
            .padding(.top, 10)
        }
    }

    private var footer: some View {
        HStack(spacing: 6) {
            Text(scores.updated.map { "Scores from ESPN · updated \($0.formatted(date: .omitted, time: .shortened))" } ?? "Scores from ESPN")
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.4))
                .lineLimit(1)
            Spacer()
            Button { scores.refresh(force: true) } label: {
                Image(systemName: "arrow.clockwise").font(.system(size: 10, weight: .semibold))
            }
            .buttonStyle(IconButtonStyle())
        }
    }
}

struct GameRow: View {
    let game: Game
    let flash: ScoresMonitor.Flash?

    var body: some View {
        HStack(spacing: 8) {
            TeamLogo(url: game.home.logo)
            Text(game.home.name)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)

            Text(scoreText)
                .font(.system(size: 17, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .frame(width: 78)

            Text(game.away.name)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .trailing)
            TeamLogo(url: game.away.logo)

            VStack(alignment: .trailing, spacing: 1) {
                statusLabel
                Text(game.leagueName).font(.system(size: 9)).foregroundStyle(.white.opacity(0.4)).lineLimit(1)
            }
            .frame(width: 96, alignment: .trailing)
        }
        .frame(height: 30)
    }

    private var scoreText: String {
        guard let h = game.home.score, let a = game.away.score else { return "vs" }
        return "\(h) – \(a)"
    }

    @ViewBuilder private var statusLabel: some View {
        switch game.state {
        case .live:
            HStack(spacing: 4) {
                Circle().fill(Color.green).frame(width: 5, height: 5)
                Text(game.detail).foregroundStyle(.green)
            }
            .font(.system(size: 11, weight: .semibold))
        case .final:
            Text(game.detail).font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.6))
        case .upcoming:
            Text(kickoff).font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.75))
        }
    }

    private var kickoff: String {
        let time = game.start.formatted(date: .omitted, time: .shortened)
        let calendar = Calendar.current
        if calendar.isDateInToday(game.start) { return time }
        if calendar.isDateInTomorrow(game.start) {
            // "Tomorrow" in the system language ("Morgen", "Demain", …)
            let f = DateFormatter()
            f.doesRelativeDateFormatting = true
            f.dateStyle = .short
            f.timeStyle = .none
            return "\(f.string(from: game.start)) \(time)"
        }
        return game.start.formatted(.dateTime.weekday(.abbreviated).hour().minute())
    }
}

struct TeamLogo: View {
    let url: URL?

    var body: some View {
        AsyncImage(url: url) { image in
            image.resizable().scaledToFit()
        } placeholder: {
            Circle().fill(.white.opacity(0.1))
        }
        .frame(width: 22, height: 22)
    }
}

// MARK: - Collapsed notch

/// One team's code and score, e.g. "BAY 2" (left of the notch) or "1 BVB" (right of it).
/// The side that just scored turns green for a few seconds.
struct ScoreWing: View {
    let game: Game
    let leading: Bool
    let flash: ScoresMonitor.Flash?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let side = leading ? game.home : game.away
            let flashing = flash.map { $0.until > context.date && $0.homeScored == leading } ?? false
            let score = side.score.map(String.init) ?? "–"
            Text(leading ? "\(side.code) \(score)" : "\(score) \(side.code)")
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(flashing ? Color.green : Color.white)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .animation(.easeInOut(duration: 0.3), value: flashing)
        }
    }
}
