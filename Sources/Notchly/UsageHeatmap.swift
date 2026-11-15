import Foundation

/// One assistant message from Claude Code's session logs.
struct UsageEvent: Equatable {
    var date: Date
    var tokens: Int
}

/// Token use per hour over the last seven calendar days (today is the last row), in local time.
/// Built from Claude Code's logs on this Mac, so it shows that activity only.
struct UsageHeatmap: Equatable {
    static let days = 7
    static let hoursPerDay = 24

    /// Midnight (local) of the first row.
    let start: Date
    let now: Date
    /// `days * 24` hour buckets, oldest first.
    let tokens: [Int]

    enum Cell: Equatable {
        /// Not yet happened (later today).
        case future
        /// Nothing in that hour.
        case idle
        /// 1 (a little) ... 4 (the busiest hours), relative to the busiest hour of the period.
        case level(Int)
    }

    var peak: Int { tokens.max() ?? 0 }
    var isEmpty: Bool { peak == 0 }
    var total: Int { tokens.reduce(0, +) }

    /// The first day shown: six days before today, so seven rows end with today.
    static func windowStart(now: Date, calendar: Calendar = .current) -> Date {
        let today = calendar.startOfDay(for: now)
        return calendar.date(byAdding: .day, value: -(days - 1), to: today) ?? today.addingTimeInterval(-6 * 86_400)
    }

    /// Sorts events into hour buckets. Events outside the window are ignored.
    static func build(events: [UsageEvent], start: Date, now: Date, calendar: Calendar = .current) -> UsageHeatmap {
        var buckets = [Int](repeating: 0, count: days * hoursPerDay)
        for event in events where event.date >= start && event.date <= now && event.tokens > 0 {
            let day = calendar.dateComponents([.day], from: start, to: calendar.startOfDay(for: event.date)).day ?? -1
            let hour = calendar.component(.hour, from: event.date)
            guard (0..<days).contains(day), (0..<hoursPerDay).contains(hour) else { continue }
            buckets[day * hoursPerDay + hour] += event.tokens
        }
        return UsageHeatmap(start: start, now: now, tokens: buckets)
    }

    func tokens(day: Int, hour: Int) -> Int {
        guard (0..<Self.days).contains(day), (0..<Self.hoursPerDay).contains(hour) else { return 0 }
        return tokens[day * Self.hoursPerDay + hour]
    }

    /// When this hour starts. Hours that don't exist on a daylight-saving day come out as the next valid time.
    func hourStart(day: Int, hour: Int, calendar: Calendar = .current) -> Date? {
        guard let midnight = calendar.date(byAdding: .day, value: day, to: start) else { return nil }
        return calendar.date(bySettingHour: hour, minute: 0, second: 0, of: midnight)
    }

    func cell(day: Int, hour: Int, calendar: Calendar = .current) -> Cell {
        if let begin = hourStart(day: day, hour: hour, calendar: calendar), begin > now { return .future }
        return Self.level(tokens(day: day, hour: hour), peak: peak)
    }

    /// Square-root scale, so a single huge hour doesn't turn every other hour into the faintest shade.
    static func level(_ tokens: Int, peak: Int) -> Cell {
        guard tokens > 0, peak > 0 else { return .idle }
        let ratio = min(Double(tokens) / Double(peak), 1).squareRoot()
        return .level(min(4, 1 + Int(ratio * 4)))
    }
}
