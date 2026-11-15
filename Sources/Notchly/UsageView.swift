import SwiftUI

/// Tab icon for the Usage tab: a ring that fills as the 5-hour limit is used.
/// Orange from 80%, red from 95%; an empty faint ring while the value is unknown.
struct UsageRing: View {
    let percent: Double?

    private var fraction: Double { min(max((percent ?? 0) / 100, 0), 1) }
    private var tint: Color {
        guard let percent else { return .white }
        return percent >= 95 ? .red : (percent >= 80 ? .orange : .white)
    }

    var body: some View {
        ZStack {
            Circle().stroke(.white.opacity(0.28), lineWidth: 2)
            if percent != nil {
                Circle()
                    .trim(from: 0, to: max(fraction, 0.04))      // a sliver at 0% so the ring never looks empty
                    .stroke(tint, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
        }
        .frame(width: 13, height: 13)
        .animation(.easeOut(duration: 0.5), value: fraction)
        .animation(.easeOut(duration: 0.3), value: tint)
    }
}

/// The "Usage" tab: two thin bars (5-hour and weekly limit), or token counts as a fallback.
struct UsageView: View {
    @ObservedObject var usage: UsageMonitor

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            content
            Spacer(minLength: 6)
            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear { usage.refresh() }
    }

    @ViewBuilder private var content: some View {
        switch usage.state {
        case .idle, .loading:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Loading usage…").font(.system(size: 12)).foregroundStyle(.white.opacity(0.6))
            }
            .padding(.top, 14)

        case .limits(let l):
            HStack(alignment: .top, spacing: 30) {
                if let w = l.fiveHour { LimitColumn(title: "5-hour limit", window: w) }
                if let w = l.sevenDay { LimitColumn(title: "Weekly limit", window: w) }
            }

        case .local(let u, _):
            HStack(alignment: .top, spacing: 30) {
                TokenColumn(title: "Last 5 hours", tokens: u.last5h)
                TokenColumn(title: "Last 7 days", tokens: u.last7d)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 6) {
            Text(footerText)
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.45))
                .lineLimit(1)
            Spacer()
            Button { usage.refresh(force: true) } label: {
                Image(systemName: "arrow.clockwise").font(.system(size: 10, weight: .semibold))
            }
            .buttonStyle(IconButtonStyle())
        }
    }

    private var footerText: String {
        switch usage.state {
        case .idle, .loading: return ""
        case .limits(let l):
            let plan = l.plan.map { "Claude \($0.capitalized) · " } ?? ""
            return plan + "updated " + l.fetched.formatted(date: .omitted, time: .shortened)
        case .local(_, let note):
            return note + " Showing local token counts."
        }
    }
}

private struct LimitColumn: View {
    let title: String
    let window: LimitWindow

    private var fraction: Double { min(max(window.percent / 100, 0), 1) }
    private var tint: Color { window.percent >= 95 ? .red : (window.percent >= 80 ? .orange : .white) }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.system(size: 12, weight: .semibold))
                Spacer()
                Text("\(Int(window.percent.rounded()))%")
                    .font(.system(size: 18, weight: .semibold))
                    .monospacedDigit()
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.16))
                    Capsule().fill(tint).frame(width: max(geo.size.width * fraction, fraction > 0 ? 5 : 0))
                }
            }
            .frame(height: 5)
            if let reset = window.resetsAt {
                Text(resetText(reset)).font(.system(size: 10)).foregroundStyle(.white.opacity(0.5))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func resetText(_ date: Date) -> String {
        let secs = date.timeIntervalSinceNow
        if secs <= 0 { return "resets now" }
        if secs < 86400 {
            let h = Int(secs) / 3600, m = (Int(secs) % 3600) / 60
            return h > 0 ? "resets in \(h) h \(m) min" : "resets in \(m) min"
        }
        return "resets " + date.formatted(.dateTime.weekday(.abbreviated).hour().minute())
    }
}

private struct TokenColumn: View {
    let title: String
    let tokens: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 12, weight: .semibold))
            Text(format(tokens))
                .font(.system(size: 22, weight: .semibold))
                .monospacedDigit()
            Text("tokens").font(.system(size: 10)).foregroundStyle(.white.opacity(0.5))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func format(_ n: Int) -> String {
        switch n {
        case 1_000_000...: return String(format: "%.1fM", Double(n) / 1_000_000)
        case 10_000...: return "\(n / 1000)K"
        case 1_000...: return String(format: "%.1fK", Double(n) / 1000)
        default: return "\(n)"
        }
    }
}
