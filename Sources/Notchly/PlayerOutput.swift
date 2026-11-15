import SwiftUI
import AVKit

/// Keeps the notch open while its output or layout popover is being used.
enum NotchInteraction {
    static var popovers = Set<UUID>()
    static let dismiss = Notification.Name("NotchlyDismissPopovers")
    static var keepsOpen: Bool { !popovers.isEmpty }
}

struct PlayerOutputButton: View {
    @ObservedObject var audio: AudioMonitor
    @State private var showing = false
    @State private var token = UUID()

    var body: some View {
        Button {
            audio.refresh()
            showing.toggle()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: audio.selectedDevice?.symbol ?? "airplay.audio")
                Text(audio.selectedDevice?.name ?? "Sound output").lineLimit(1)
            }
            .font(.system(size: 10)).foregroundStyle(.white.opacity(0.75))
            .frame(maxWidth: 160, alignment: .trailing)
        }
        .buttonStyle(.plain)
        .help("Mac sound outputs")
        .accessibilityLabel("Mac sound outputs")
        .popover(isPresented: $showing) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Sound output").font(.headline)
                ForEach(audio.devices) { device in
                    Button { audio.select(device) } label: {
                        HStack(spacing: 9) {
                            Image(systemName: device.symbol).frame(width: 24)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(device.name).lineLimit(1)
                                Text(device.transportName).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if audio.pendingUID == device.uid { ProgressView().controlSize(.small) }
                            else if audio.defaultOutputID == device.id { Image(systemName: "checkmark") }
                        }.contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).disabled(audio.pendingUID != nil)
                    .accessibilityValue(audio.defaultOutputID == device.id ? "Selected" : "")
                }
                if let error = audio.errorMessage { Text(error).font(.caption).foregroundStyle(.orange) }
                Divider()
                Button("Sound Settings…") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Sound-Settings.extension")!)
                }
                Text("This changes the Mac’s sound output. Use the AirPlay button beside the playback controls to discover nearby speakers and TVs.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .padding(18).frame(width: 310)
        }
        .onChange(of: showing) { _, value in
            if value { NotchInteraction.popovers.insert(token) }
            else { NotchInteraction.popovers.remove(token) }
        }
        .onReceive(NotificationCenter.default.publisher(for: NotchInteraction.dismiss)) { _ in showing = false }
        .onDisappear { NotchInteraction.popovers.remove(token) }
    }
}

/// Native route discovery rather than a list of already-connected Core Audio devices.
/// No dummy player is created: Notchly does not own or play Spotify's audio.
struct AirPlayPicker: NSViewRepresentable {
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView(frame: NSRect(x: 0, y: 0, width: 28, height: 28))
        view.isRoutePickerButtonBordered = false
        view.setRoutePickerButtonColor(.white.withAlphaComponent(0.8), for: .normal)
        view.setRoutePickerButtonColor(.systemBlue, for: .active)
        view.delegate = context.coordinator
        view.toolTip = "AirPlay speakers and TVs"
        return view
    }
    func updateNSView(_ view: AVRoutePickerView, context: Context) {}
    static func dismantleNSView(_ view: AVRoutePickerView, coordinator: Coordinator) {
        NotchInteraction.popovers.remove(coordinator.token)
        view.delegate = nil
    }
    final class Coordinator: NSObject, AVRoutePickerViewDelegate {
        let token = UUID()
        func routePickerViewWillBeginPresentingRoutes(_ routePickerView: AVRoutePickerView) {
            NotchInteraction.popovers.insert(token)
        }
        func routePickerViewDidEndPresentingRoutes(_ routePickerView: AVRoutePickerView) {
            NotchInteraction.popovers.remove(token)
        }
    }
}
