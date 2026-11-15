import SwiftUI

struct ActivityControls: View {
    @ObservedObject var state: NotchState

    private var current: NotchActivity? {
        if let displayed = state.activity.displayed, state.activity.available.contains(displayed) { return displayed }
        return state.activity.preferred
    }

    var body: some View {
        HStack(spacing: 5) {
            Menu {
                ForEach(state.activity.available, id: \.self) { activity in
                    Button {
                        state.selectActivity(activity)
                        if let tab = activity.tab { state.tab = tab }
                    } label: {
                        Label(activity.title, systemImage: current == activity ? "checkmark" : activity.symbol)
                    }
                }
                Divider()
                if let current {
                    Button {
                        state.toggleActivityPin(current)
                    } label: {
                        Label(state.activity.pinned == current ? "Unpin \(current.title)" : "Pin \(current.title)",
                              systemImage: state.activity.pinned == current ? "pin.slash" : "pin")
                    }
                }
                if let pinned = state.activity.pinned, pinned != current {
                    Text("Pinned: \(pinned.title)")
                }
                Button("Use Automatic Priorities") { state.useAutomaticActivities() }
                Divider()
                Text("Selections last 20 seconds. Pins stay until removed.")
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: current?.symbol ?? "circle.grid.2x2.fill")
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("\(current?.title ?? "Activities"): choose or pin the activity shown while the notch is closed")
            .accessibilityLabel("Activities")
            .accessibilityValue(current?.title ?? "Automatic")

            if state.activity.pinned == current, current != nil {
                Image(systemName: "pin.fill")
                    .font(.system(size: 8))
                    .foregroundStyle(.orange)
                    .help("Pinned activity")
            }

            if state.activity.available.count > 1 {
                Button {
                    state.cycleActivity()
                    if let tab = state.activity.displayed?.tab { state.tab = tab }
                } label: {
                    Image(systemName: "chevron.right.circle")
                        .frame(width: 20, height: 22)
                }
                .buttonStyle(.plain)
                .disabled(!state.activity.canCycle)
                .help("Next activity for 20 seconds. Option-click the closed notch to cycle there.")
                .accessibilityLabel("Next activity")
            }
        }
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(.white.opacity(0.85))
    }
}
