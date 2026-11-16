import SwiftUI
import AppKit

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
                Text("This changes the Mac’s sound output. For AirPlay, use Music’s speaker picker or macOS Control Center.")
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

/// Controls the devices owned by Music, rather than an unrelated AVPlayer route.
struct MusicAirPlayButton: View {
    @StateObject private var routes = MusicAirPlayRoutes()
    @State private var showing = false
    @State private var token = UUID()

    var body: some View {
        Button {
            showing.toggle()
            if showing { routes.refresh() }
        } label: {
            Image(systemName: "airplay.audio").frame(width: 32, height: 32)
        }
        .help("Music AirPlay speakers")
        .accessibilityLabel("Music AirPlay speakers")
        .popover(isPresented: $showing) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Music AirPlay speakers").font(.headline)
                if routes.loading { ProgressView().controlSize(.small) }
                ForEach(routes.devices) { device in
                    Button { routes.toggle(device) } label: {
                        HStack {
                            Text(device.name)
                            Spacer()
                            if device.selected { Image(systemName: "checkmark") }
                        }.contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(routes.loading)
                    .accessibilityValue(device.selected ? "Selected" : "")
                }
                if !routes.loading && routes.devices.isEmpty && routes.error == nil {
                    Text("No available speakers found.").foregroundStyle(.secondary)
                }
                if let error = routes.error { Text(error).foregroundStyle(.orange) }
                Button("Refresh") { routes.refresh() }.disabled(routes.loading)
                Text("For passcode-protected speakers, use the AirPlay picker in Music.")
                    .foregroundStyle(.secondary)
            }
            .font(.caption).padding(18).frame(width: 280)
        }
        .onChange(of: showing) { _, value in
            if value { NotchInteraction.popovers.insert(token) }
            else { NotchInteraction.popovers.remove(token) }
        }
        .onReceive(NotificationCenter.default.publisher(for: NotchInteraction.dismiss)) { _ in showing = false }
        .onDisappear { NotchInteraction.popovers.remove(token) }
    }
}

@MainActor
final class MusicAirPlayRoutes: ObservableObject {
    struct Device: Identifiable {
        let id: Int
        let name: String
        let selected: Bool
    }
    @Published var devices: [Device] = []
    @Published var loading = false
    @Published var error: String?
    private let queue = DispatchQueue(label: "Notchly.MusicAirPlay")

    func refresh() { run(selection: nil) }
    func toggle(_ device: Device) { run(selection: device) }

    private func run(selection: Device?) {
        guard !loading else { return }
        loading = true
        error = nil
        queue.async { [weak self] in
            var script = """
            tell application "Music"
            """
            if let device = selection {
                // Verify the name as the device list can change while the popover is open.
                let name = device.name.replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "\"", with: "\\\"")
                script += "\nif name of AirPlay device \(device.id) is not \"\(name)\" then error \"Speaker list changed. Refresh and try again.\""
                script += "\nset selected of AirPlay device \(device.id) to \(!device.selected)"
            }
            script += """

                set routeList to {}
                repeat with i from 1 to count of AirPlay devices
                    set routeDevice to AirPlay device i
                    if available of routeDevice and supports audio of routeDevice then
                        set end of routeList to {i, name of routeDevice, selected of routeDevice}
                    end if
                end repeat
                return routeList
            end tell
            """
            var scriptError: NSDictionary?
            let result = NSAppleScript(source: script)?.executeAndReturnError(&scriptError)
            var found: [Device] = []
            if let result {
                for index in 1...max(result.numberOfItems, 1) where index <= result.numberOfItems {
                    guard let item = result.atIndex(index), let name = item.atIndex(2)?.stringValue else { continue }
                    found.append(Device(id: Int(item.atIndex(1)?.int32Value ?? 0), name: name,
                                        selected: item.atIndex(3)?.booleanValue ?? false))
                }
            }
            let message = scriptError?[NSAppleScript.errorMessage] as? String
            DispatchQueue.main.async {
                guard let self else { return }
                self.loading = false
                if let scriptError {
                    self.error = (scriptError[NSAppleScript.errorNumber] as? Int) == -1743
                        ? "Allow Notchly to control Music in Privacy & Security → Automation."
                        : (message ?? "Couldn’t access Music speakers. Open the AirPlay picker in Music.")
                } else { self.devices = found }
            }
        }
    }
}
