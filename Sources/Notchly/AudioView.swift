import SwiftUI

struct AudioView: View {
    @ObservedObject var audio: AudioMonitor

    var body: some View {
        VStack(spacing: 4) {
            if audio.devices.isEmpty {
                VStack(spacing: 5) {
                    Image(systemName: "speaker.slash").font(.system(size: 22))
                    Text("No sound outputs available").font(.system(size: 12, weight: .semibold))
                }
                .foregroundStyle(.white.opacity(0.55))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: 3) {
                        ForEach(audio.devices) { device in
                            AudioDeviceRow(device: device, selected: audio.defaultOutputID == device.id,
                                           pending: audio.pendingUID == device.uid) { audio.select(device) }
                                .disabled(audio.pendingUID != nil)
                        }
                    }
                }
            }
            HStack(spacing: 8) {
                Text(audio.errorMessage ?? "Sound output · battery levels when available")
                    .foregroundStyle(audio.errorMessage == nil ? .white.opacity(0.4) : .orange)
                    .lineLimit(1)
                    .help(audio.errorMessage ?? "Switches the Mac's sound output. Microphone settings stay as they are.")
                Spacer(minLength: 0)
                if audio.errorMessage != nil {
                    Button("Retry") { audio.refresh() }.buttonStyle(.plain)
                }
                Button("Sound Settings") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Sound-Settings.extension")!)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white.opacity(0.7))
            }
            .font(.system(size: 10))
            .frame(height: 16)
        }
        .onAppear { audio.refreshBatteriesIfNeeded() }
    }
}

private struct AudioDeviceRow: View {
    let device: AudioOutputDevice
    let selected: Bool
    let pending: Bool
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            HStack(spacing: 10) {
                Image(systemName: device.symbol)
                    .font(.system(size: 17))
                    .frame(width: 25)
                    .foregroundStyle(selected ? .white : .white.opacity(0.6))
                VStack(alignment: .leading, spacing: 1) {
                    Text(device.name).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                    Text(device.transportName).font(.system(size: 9)).foregroundStyle(.white.opacity(0.45))
                }
                Spacer(minLength: 6)
                if let battery = device.battery, !battery.isEmpty {
                    Text(battery.summary)
                        .font(.system(size: 10, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle((battery.listeningLevel ?? 100) <= 20 ? .orange : .white.opacity(0.65))
                        .lineLimit(1)
                }
                if pending {
                    ProgressView().controlSize(.small).frame(width: 16, height: 16)
                } else {
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(selected ? Color.accentColor : .white.opacity(0.2))
                        .font(.system(size: 14))
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 9).fill(.white.opacity(selected ? 0.1 : 0.035)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("\(device.name)\(device.battery.map { " · " + $0.summary } ?? "")")
        .accessibilityLabel(device.name)
        .accessibilityValue((selected ? "Selected. " : "") + (device.battery?.summary ?? device.transportName))
    }
}

struct AudioConnectionReadout: View {
    let connection: AudioConnection

    var body: some View {
        VStack(spacing: 1) {
            Text(connection.device.name)
                .font(.system(size: 10, weight: .semibold))
            Text(detail)
                .font(.system(size: 8, weight: .medium))
                .foregroundStyle(.white.opacity(0.65))
        }
        .lineLimit(1)
        .minimumScaleFactor(0.75)
    }

    private var detail: String {
        guard connection.kind != .disconnected, let level = connection.device.battery?.listeningLevel else {
            return connection.status
        }
        return "\(connection.status) · \(level)%"
    }
}
