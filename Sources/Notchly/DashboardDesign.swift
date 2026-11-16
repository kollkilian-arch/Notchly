import SwiftUI

/// Public AppKit vibrancy; keeps a readable solid surface with Reduce Transparency enabled.
struct GlassSurface: View {
    var glass: Bool
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        ZStack {
            if glass && !reduceTransparency {
                DesktopMaterial()
                LinearGradient(colors: [.white.opacity(0.13), .white.opacity(0.025)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                Color.black.opacity(0.22)
            } else { Color.black }
        }
    }
}

private struct DesktopMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        view.appearance = NSAppearance(named: .darkAqua)
        return view
    }
    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

struct DashboardHome: View {
    @ObservedObject var media: MediaMonitor
    @ObservedObject var calendar: CalendarMonitor
    @ObservedObject var audio: AudioMonitor
    @AppStorage(Pref.dashboardLayout) private var layoutJSON = ""
    @AppStorage(Pref.showCalendar) private var calendarEnabled = true

    private var widgets: [DashboardWidget] {
        let visible = DashboardLayout.decode(layoutJSON).visible(calendarEnabled: calendarEnabled)
        return visible.isEmpty ? [.music] : visible
    }

    var body: some View {
        HStack(spacing: 10) {
            ForEach(widgets) { widget in
                Group {
                    switch widget {
                    case .music:
                        VStack(alignment: .leading, spacing: 14) {
                            HStack {
                                Label("Now playing", systemImage: "music.note")
                                    .font(.system(size: 10, weight: .medium)).foregroundStyle(.white.opacity(0.55))
                                Spacer()
                                PlayerOutputButton(audio: audio)
                            }
                            ExperimentalPlayer(media: media)
                                .frame(maxHeight: .infinity)
                        }
                    case .calendar: CalendarCarousel(calendar: calendar)
                    }
                }
                .padding(11)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(RoundedRectangle(cornerRadius: 18).fill(.black.opacity(0.22)))
                .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(.white.opacity(0.1)))
            }
        }
    }
}

struct LayoutEditorButton: View {
    @AppStorage(Pref.dashboardLayout) private var json = ""
    @AppStorage(Pref.glassDashboard) private var glass = true
    @State private var showing = false
    @State private var token = UUID()
    private var layout: DashboardLayout { DashboardLayout.decode(json) }

    var body: some View {
        Button { showing.toggle() } label: {
            Image(systemName: "rectangle.3.group").font(.system(size: 12)).frame(width: 30, height: 28)
        }
        .buttonStyle(.plain)
        .help("Edit dashboard layout")
        .accessibilityLabel("Edit dashboard layout")
        .popover(isPresented: $showing) {
            VStack(alignment: .leading, spacing: 14) {
                Text("Dashboard layout").font(.headline)
                Toggle("Glass cards", isOn: $glass)
                ForEach(Array(layout.order.enumerated()), id: \.element) { index, widget in
                    HStack {
                        Toggle(widget.title, isOn: Binding(
                            get: { !layout.hidden.contains(widget) },
                            set: { visible in var edit = layout; edit.setVisible(widget, visible); json = edit.json }
                        ))
                        Spacer()
                        Button { move(widget, -1) } label: { Image(systemName: "arrow.left") }
                            .disabled(index == 0).help("Move \(widget.title) left")
                        Button { move(widget, 1) } label: { Image(systemName: "arrow.right") }
                            .disabled(index == layout.order.count - 1).help("Move \(widget.title) right")
                    }
                }
                Button("Reset layout") { json = "" }
            }
            .padding(18).frame(width: 300)
        }
        .onChange(of: showing) { _, value in
            if value { NotchInteraction.popovers.insert(token) }
            else { NotchInteraction.popovers.remove(token) }
        }
        .onReceive(NotificationCenter.default.publisher(for: NotchInteraction.dismiss)) { _ in showing = false }
        .onDisappear { NotchInteraction.popovers.remove(token) }
    }

    private func move(_ widget: DashboardWidget, _ offset: Int) {
        var edit = layout
        edit.move(widget, by: offset)
        json = edit.json
    }
}

struct FloatingNavigation: View {
    @ObservedObject var state: NotchState
    @ObservedObject var shelf: ShelfStore
    @ObservedObject var usage: UsageMonitor
    @AppStorage(Pref.scoresEnabled) private var scores = true
    @AppStorage(Pref.showUsage) private var showUsage = true
    @AppStorage(Pref.glassDashboard) private var glass = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 3) {
            ForEach(NotchTab.visible(scores: scores, usage: showUsage), id: \.self) { tab in
                Button {
                    state.tab = tab
                    Feedback.haptic(.light)
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: tab == .usage ? "chart.bar.xaxis" : tab.symbol)
                            .frame(width: 15, height: 15)
                        if state.tab == tab {
                            Text(tab == .usage ? "Usage" : tab.title)
                            if tab == .shelf, !shelf.items.isEmpty {
                                Text("\(shelf.items.count)").foregroundStyle(.white.opacity(0.5))
                            }
                        }
                    }
                    .font(.system(size: 10, weight: .medium))
                    .padding(.horizontal, 12).frame(minWidth: 40, minHeight: 32)
                    .foregroundStyle(.white.opacity(state.tab == tab ? 1 : 0.6))
                    .background(Capsule().fill(.white.opacity(state.tab == tab ? 0.16 : 0)))
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help(tab.title)
                .accessibilityLabel(tab.title)
                .accessibilityValue(tab == .usage ? usage.fiveHourPercent.map { "\(Int($0))% used" } ?? "" : "")
                .accessibilityAddTraits(state.tab == tab ? .isSelected : [])
            }
        }
        .padding(4)
        .background(GlassSurface(glass: glass))
        .clipShape(Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.14)))
        .animation(reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.86), value: state.tab)
    }
}
