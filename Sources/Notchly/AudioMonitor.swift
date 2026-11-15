import Foundation
import CoreAudio

struct AudioConnection: Equatable {
    enum Kind { case connected, disconnected, selected }
    let device: AudioOutputDevice
    let kind: Kind
    let expiresAt: Date

    var status: String {
        switch kind {
        case .connected: return "Connected"
        case .disconnected: return "Disconnected"
        case .selected: return "Selected"
        }
    }
}

final class AudioMonitor: ObservableObject {
    static let connectionDuration: TimeInterval = 6
    @Published private(set) var devices: [AudioOutputDevice] = []
    @Published private(set) var defaultOutputID = AudioDeviceID(kAudioObjectUnknown)
    @Published private(set) var connection: AudioConnection?
    @Published private(set) var pendingUID: String?
    @Published private(set) var errorMessage: String?

    var selectedDevice: AudioOutputDevice? { devices.first { $0.id == defaultOutputID } }

    private let backend: AudioDeviceBackend?
    private let batteryProvider: BluetoothBatteryProvider
    private let workQueue = DispatchQueue(label: "notchly.audio.control", qos: .userInitiated)
    private let batteryQueue = DispatchQueue(label: "notchly.audio.battery", qos: .utility)
    private var refreshWork: DispatchWorkItem?
    private var hideWork: DispatchWorkItem?
    private var batteryTimer: Timer?
    private var batteryReadings: [BluetoothBatteryReading] = []
    private var lastBatteryRefresh: Date?
    private var batteryBusy = false
    private var hasBaseline = false

    init(backend: AudioDeviceBackend = CoreAudioDeviceBackend(),
         batteryProvider: BluetoothBatteryProvider = SystemBluetoothBatteryProvider()) {
        self.backend = backend
        self.batteryProvider = batteryProvider
        refresh()
        backend.observeChanges { [weak self] in self?.scheduleRefresh() }
        batteryTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.refreshBatteriesIfNeeded()
        }
    }

    init(preview devices: [AudioOutputDevice], selected: AudioDeviceID, connection: AudioConnection? = nil) {
        backend = nil
        batteryProvider = SystemBluetoothBatteryProvider()
        self.devices = devices
        defaultOutputID = selected
        self.connection = connection
        hasBaseline = true
    }

    func visibleConnection(at now: Date = Date()) -> AudioConnection? {
        guard let connection, connection.expiresAt > now else { return nil }
        return connection
    }

    private func scheduleRefresh() {
        refreshWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.refresh() }
        refreshWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    func refresh() {
        guard let backend else { return }
        do {
            let found = try backend.outputs()
            let selectedID = try backend.defaultOutput()
            apply(found, selected: selectedID)
            errorMessage = nil
            refreshBatteriesIfNeeded()
        } catch { errorMessage = "Couldn't read sound outputs. \(error.localizedDescription)" }
    }

    private func apply(_ found: [AudioOutputDevice], selected selectedID: AudioDeviceID) {
        let previous = selectedDevice
        let previousDevices = devices
        let previousIDs = Set(devices.map(\.uid))
        let updated = found.map { device -> AudioOutputDevice in
            var device = device
            device.battery = SystemBluetoothBatteryProvider.battery(for: device, in: batteryReadings)
            return device
        }.sorted {
            if ($0.id == selectedID) != ($1.id == selectedID) { return $0.id == selectedID }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
        devices = updated
        defaultOutputID = selectedID
        if hasBaseline {
            let added = updated.filter { !previousIDs.contains($0.uid) && $0.announcesConnection }
            let removed = previousDevices.filter { old in
                old.announcesConnection && !updated.contains(where: { $0.uid == old.uid })
            }
            if added.contains(where: \.isBluetooth) { lastBatteryRefresh = nil }
            if let connected = added.first(where: { $0.id == selectedID }) ?? added.first {
                show(connected, kind: .connected)
            } else if let previous, removed.contains(where: { $0.uid == previous.uid }) {
                show(previous, kind: .disconnected)
            } else if previous?.uid != selectedDevice?.uid, let selectedDevice {
                show(selectedDevice, kind: .selected)
            } else if let removed = removed.first {
                show(removed, kind: .disconnected)
            }
        }
        hasBaseline = true
    }

    func select(_ device: AudioOutputDevice) {
        guard let backend, pendingUID == nil, device.id != defaultOutputID else { return }
        guard devices.contains(where: { $0.id == device.id && $0.uid == device.uid }) else {
            errorMessage = AudioDeviceError.unavailable.localizedDescription
            return
        }
        pendingUID = device.uid
        errorMessage = nil
        workQueue.async { [weak self] in
            let result = Result { try backend.setDefaultOutput(device) }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.refresh()
                self.pendingUID = nil
                switch result {
                case .success:
                    if self.selectedDevice?.uid != device.uid {
                        self.errorMessage = "macOS didn't select this output. Try again or open Sound Settings."
                    }
                case .failure(let error): self.errorMessage = error.localizedDescription
                }
            }
        }
    }

    private func show(_ device: AudioOutputDevice, kind: AudioConnection.Kind) {
        connection = AudioConnection(device: device, kind: kind, expiresAt: Date().addingTimeInterval(Self.connectionDuration))
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.connection = nil }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.connectionDuration, execute: work)
    }

    /// Probe only while Bluetooth audio outputs exist, at most once per minute, off the main thread.
    func refreshBatteriesIfNeeded() {
        guard backend != nil, devices.contains(where: \.isBluetooth), !batteryBusy,
              lastBatteryRefresh.map({ Date().timeIntervalSince($0) >= 60 }) ?? true else { return }
        batteryBusy = true
        lastBatteryRefresh = Date()
        let provider = batteryProvider
        batteryQueue.async { [weak self] in
            let readings = (try? provider.fetch()) ?? []
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.batteryBusy = false
                self.batteryReadings = readings
                self.devices = self.devices.map { device in
                    var device = device
                    device.battery = SystemBluetoothBatteryProvider.battery(for: device, in: readings)
                    return device
                }
                if let connection = self.connection,
                   let device = self.devices.first(where: { $0.uid == connection.device.uid }) {
                    self.connection = AudioConnection(device: device, kind: connection.kind, expiresAt: connection.expiresAt)
                }
                // A new headset may have arrived while the previous report was still being collected.
                self.refreshBatteriesIfNeeded()
            }
        }
    }

    deinit {
        refreshWork?.cancel()
        hideWork?.cancel()
        batteryTimer?.invalidate()
        backend?.stopObserving()
    }
}
