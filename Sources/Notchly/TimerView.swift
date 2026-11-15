import SwiftUI

/// The "Timer" tab: pick a duration and start, or control the running countdown.
struct TimerView: View {
    @ObservedObject var timer: TimerModel
    @AppStorage(Pref.timerMinutes) private var minutes = 10

    private let presets = [5, 10, 25, 45, 60]

    var body: some View {
        Group {
            switch timer.phase {
            case .idle: setup
            case .running, .paused: running
            case .finished: finished
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.easeOut(duration: 0.15), value: timer.phase)
    }

    // MARK: Idle

    private var setup: some View {
        HStack(spacing: 28) {
            VStack(spacing: 8) {
                Text(clockString(TimeInterval(minutes * 60)))
                    .font(.system(size: 38, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                HStack(spacing: 12) {
                    CircleButton(symbol: "minus") { minutes = max(1, minutes - (minutes > 10 ? 5 : 1)) }
                    CircleButton(symbol: "plus") { minutes = min(180, minutes + (minutes >= 10 ? 5 : 1)) }
                }
            }

            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 6) {
                    ForEach(presets, id: \.self) { preset in
                        Button("\(preset)m") { minutes = preset }
                            .buttonStyle(ChipStyle(selected: minutes == preset))
                    }
                }
                Button {
                    timer.start(minutes: minutes)
                    Feedback.haptic(.open)
                } label: {
                    Label("Start", systemImage: "play.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(width: 150, height: 30)
                }
                .buttonStyle(PrimaryPillStyle())
            }
        }
    }

    // MARK: Running / paused

    private var running: some View {
        TimelineView(.periodic(from: .now, by: 0.25)) { context in
            let remaining = timer.remaining(at: context.date)
            let fraction = timer.total > 0 ? 1 - remaining / timer.total : 0

            HStack(spacing: 30) {
                VStack(alignment: .leading, spacing: 9) {
                    Text(clockString(remaining))
                        .font(.system(size: 38, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .opacity(timer.phase == .paused ? 0.5 : 1)
                    ProgressBar(fraction: fraction)
                        .frame(height: 5)
                    Text(timer.phase == .paused ? "Paused" : "of \(clockString(timer.total))")
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.5))
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                HStack(spacing: 12) {
                    CircleButton(symbol: timer.phase == .paused ? "play.fill" : "pause.fill", size: 40) { timer.togglePause() }
                    CircleButton(symbol: "plus.circle", size: 40, help: "Add a minute") { timer.add(seconds: 60) }
                    CircleButton(symbol: "xmark", size: 40, help: "Cancel timer") { timer.cancel() }
                }
            }
        }
    }

    // MARK: Finished

    private var finished: some View {
        HStack(spacing: 18) {
            Image(systemName: "bell.fill")
                .font(.system(size: 30))
                .foregroundStyle(.orange)
                .symbolEffect(.pulse)
            VStack(alignment: .leading, spacing: 3) {
                Text("Time's up").font(.system(size: 22, weight: .semibold))
                Text("\(clockString(timer.total)) timer")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.55))
            }
            Spacer()
            Button("Restart") { timer.restart() }
                .buttonStyle(ChipStyle(selected: false))
            Button("Dismiss") { timer.cancel() }
                .buttonStyle(ChipStyle(selected: true))
        }
        .padding(.horizontal, 8)
    }
}

// MARK: - Collapsed notch pieces

/// Small countdown ring for the left side of the collapsed notch.
struct TimerRing: View {
    @ObservedObject var timer: TimerModel

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let remaining = timer.remaining(at: context.date)
            let fraction = timer.total > 0 ? remaining / timer.total : 0
            ZStack {
                Circle().stroke(.white.opacity(0.22), lineWidth: 2.2)
                Circle().trim(from: 0, to: fraction)
                    .stroke(.white, style: StrokeStyle(lineWidth: 2.2, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            .frame(width: 15, height: 15)
            .opacity(timer.phase == .paused ? 0.5 : 1)
        }
    }
}

/// Remaining time for the right side of the collapsed notch.
struct TimerReadout: View {
    @ObservedObject var timer: TimerModel

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.25)) { context in
            Text(clockString(timer.remaining(at: context.date)))
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.white.opacity(timer.phase == .paused ? 0.5 : 1))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
    }
}

// MARK: - Shared styling

struct ProgressBar: View {
    let fraction: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.16))
                Capsule().fill(.white)
                    .frame(width: max(geo.size.width * min(max(fraction, 0), 1), fraction > 0 ? 5 : 0))
            }
        }
    }
}

struct CircleButton: View {
    let symbol: String
    var size: CGFloat = 28
    var help: String = ""
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size * 0.4, weight: .semibold))
                .frame(width: size, height: size)
                .background(Circle().fill(.white.opacity(0.12)))
        }
        .buttonStyle(IconButtonStyle())
        .help(help)
    }
}

struct ChipStyle: ButtonStyle {
    let selected: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .semibold))
            .padding(.horizontal, 10)
            .frame(height: 24)
            .foregroundStyle(selected ? .black : .white.opacity(0.85))
            .background(Capsule().fill(selected ? Color.white : Color.white.opacity(0.13)))
            .opacity(configuration.isPressed ? 0.7 : 1)
            .contentShape(Capsule())
    }
}

struct PrimaryPillStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.black)
            .background(Capsule().fill(Color.white))
            .opacity(configuration.isPressed ? 0.75 : 1)
            .contentShape(Capsule())
    }
}
