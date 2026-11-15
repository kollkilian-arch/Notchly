import AppKit
import Combine
import CoreAudio
import XCTest
@testable import Notchly

final class AudioDeviceTests: XCTestCase {
    private var speakers: AudioOutputDevice {
        AudioOutputDevice(id: 1, uid: "speakers", name: "MacBook Pro Speakers", transport: kAudioDeviceTransportTypeBuiltIn)
    }
    private var headphones: AudioOutputDevice {
        AudioOutputDevice(id: 2, uid: "AA-BB-CC-DD-EE-FF:output", name: "AirPods Pro", transport: kAudioDeviceTransportTypeBluetooth)
    }

    func testStartupIsSilentAndExistingOutputRemainsSelected() {
        let backend = FakeAudioBackend(devices: [headphones, speakers], selected: speakers.id)
        let monitor = AudioMonitor(backend: backend, batteryProvider: FakeBatteryProvider())
        XCTAssertEqual(monitor.devices.first?.uid, speakers.uid)
        XCTAssertEqual(monitor.selectedDevice?.uid, speakers.uid)
        XCTAssertNil(monitor.connection)
        XCTAssertTrue(backend.selections.isEmpty)
    }

    func testSelectingAnOutputConfirmsActualSystemSelection() {
        let backend = FakeAudioBackend(devices: [speakers, headphones], selected: speakers.id)
        let monitor = AudioMonitor(backend: backend, batteryProvider: FakeBatteryProvider())
        monitor.select(headphones)
        waitForSwitch(monitor)
        XCTAssertEqual(backend.selections, [headphones.uid])
        XCTAssertEqual(monitor.selectedDevice?.uid, headphones.uid)
        XCTAssertEqual(monitor.devices.first?.uid, headphones.uid)
        XCTAssertEqual(monitor.connection?.kind, .selected)
        XCTAssertNil(monitor.errorMessage)
    }

    func testFailedSwitchKeepsActualOutputAndReportsFailure() {
        let backend = FakeAudioBackend(devices: [speakers, headphones], selected: speakers.id)
        backend.failSwitch = true
        let monitor = AudioMonitor(backend: backend, batteryProvider: FakeBatteryProvider())
        monitor.select(headphones)
        waitForSwitch(monitor)
        XCTAssertEqual(monitor.selectedDevice?.uid, speakers.uid)
        XCTAssertNotNil(monitor.errorMessage)
        XCTAssertNil(monitor.connection)
    }

    func testIgnoredSwitchIsNotReportedAsSuccess() {
        let backend = FakeAudioBackend(devices: [speakers, headphones], selected: speakers.id)
        backend.ignoreSwitch = true
        let monitor = AudioMonitor(backend: backend, batteryProvider: FakeBatteryProvider())
        monitor.select(headphones)
        waitForSwitch(monitor)
        XCTAssertEqual(monitor.selectedDevice?.uid, speakers.uid)
        XCTAssertNotNil(monitor.errorMessage)
    }

    func testAlreadySelectedOrStaleDeviceNeverTriggersSwitch() {
        let backend = FakeAudioBackend(devices: [speakers], selected: speakers.id)
        let monitor = AudioMonitor(backend: backend, batteryProvider: FakeBatteryProvider())
        monitor.select(speakers)
        monitor.select(headphones)
        XCTAssertTrue(backend.selections.isEmpty)
        XCTAssertNotNil(monitor.errorMessage)
        XCTAssertNil(monitor.pendingUID)
    }

    func testConnectAndDisconnectNoticesDoNotChangeOutput() throws {
        let backend = FakeAudioBackend(devices: [speakers], selected: speakers.id)
        let monitor = AudioMonitor(backend: backend, batteryProvider: FakeBatteryProvider())
        backend.devices.append(headphones)
        monitor.refresh()
        let event = try XCTUnwrap(monitor.connection)
        XCTAssertEqual(event.device.uid, headphones.uid)
        XCTAssertEqual(event.kind, .connected)
        XCTAssertEqual(monitor.selectedDevice?.uid, speakers.uid)
        monitor.refresh()
        XCTAssertEqual(monitor.connection?.expiresAt, event.expiresAt, "Metadata refreshes must not restart the notice")
        XCTAssertNil(monitor.visibleConnection(at: event.expiresAt))
        backend.devices = [speakers]
        monitor.refresh()
        XCTAssertEqual(monitor.connection?.kind, .disconnected)
        XCTAssertEqual(monitor.connection?.device.uid, headphones.uid)
        XCTAssertTrue(backend.selections.isEmpty)
    }

    func testDisconnectOfActiveHeadphonesReportsHeadphonesRatherThanFallbackSpeaker() {
        let backend = FakeAudioBackend(devices: [speakers, headphones], selected: headphones.id)
        let monitor = AudioMonitor(backend: backend, batteryProvider: FakeBatteryProvider())
        backend.devices = [speakers]
        backend.selected = speakers.id
        monitor.refresh()
        XCTAssertEqual(monitor.selectedDevice?.uid, speakers.uid)
        XCTAssertEqual(monitor.connection?.device.uid, headphones.uid)
        XCTAssertEqual(monitor.connection?.kind, .disconnected)
    }

    func testCoreAudioIDChangesWithoutUIDChangeDoNotCreateFalseConnection() {
        let backend = FakeAudioBackend(devices: [headphones], selected: headphones.id)
        let monitor = AudioMonitor(backend: backend, batteryProvider: FakeBatteryProvider())
        let sameDevice = AudioOutputDevice(id: 22, uid: headphones.uid, name: headphones.name, transport: headphones.transport)
        backend.devices = [sameDevice]
        backend.selected = sameDevice.id
        monitor.refresh()
        XCTAssertNil(monitor.connection)
        XCTAssertEqual(monitor.selectedDevice?.uid, headphones.uid)
    }

    func testDeviceListenerRefreshesOutputsAfterHotPlug() {
        let backend = FakeAudioBackend(devices: [speakers], selected: speakers.id)
        let monitor = AudioMonitor(backend: backend, batteryProvider: FakeBatteryProvider())
        backend.devices.append(headphones)
        let changed = expectation(description: "Device list refreshed")
        let subscription = monitor.$devices.first { $0.count == 2 }.sink { _ in changed.fulfill() }
        backend.onChange?()
        wait(for: [changed], timeout: 2)
        withExtendedLifetime(subscription) {}
        XCTAssertEqual(monitor.connection?.kind, .connected)
    }

    func testBatteryReadingsPopulateDevicesAndStayOffNonBluetoothOutputs() {
        let battery = AudioDeviceBattery(left: 84, right: 80, caseLevel: 5)
        let provider = FakeBatteryProvider(readings: [BluetoothBatteryReading(address: "AABBCCDDEEFF", name: "AirPods Pro", battery: battery)])
        let backend = FakeAudioBackend(devices: [speakers, headphones], selected: headphones.id)
        let monitor = AudioMonitor(backend: backend, batteryProvider: provider)
        let loaded = expectation(description: "Bluetooth battery populated")
        let subscription = monitor.$devices.first { $0.first { $0.isBluetooth }?.battery != nil }.sink { _ in loaded.fulfill() }
        wait(for: [loaded], timeout: 2)
        withExtendedLifetime(subscription) {}
        XCTAssertEqual(monitor.selectedDevice?.battery, battery)
        XCTAssertNil(monitor.devices.first { $0.uid == speakers.uid }?.battery)
        XCTAssertEqual(battery.listeningLevel, 80, "A low case battery isn't the earbuds' listening charge")
        XCTAssertNil(AudioDeviceBattery(caseLevel: 5).listeningLevel, "A case-only reading must not imply a headphone charge")
        XCTAssertEqual(battery.summary, "L 84% · R 80% · Case 5%")
        monitor.refreshBatteriesIfNeeded()
        XCTAssertEqual(provider.fetchCount, 1)
    }

    func testBatteryProbeDoesNotRunWithoutBluetoothAudio() {
        let provider = FakeBatteryProvider()
        let monitor = AudioMonitor(backend: FakeAudioBackend(devices: [speakers], selected: speakers.id), batteryProvider: provider)
        monitor.refreshBatteriesIfNeeded()
        XCTAssertEqual(provider.fetchCount, 0)
    }

    func testSlowBatteryReportDoesNotDelayOutputSwitching() {
        let started = expectation(description: "Battery lookup started")
        let provider = BlockingBatteryProvider { started.fulfill() }
        let backend = FakeAudioBackend(devices: [speakers, headphones], selected: headphones.id)
        let monitor = AudioMonitor(backend: backend, batteryProvider: provider)
        defer { provider.finish.signal() }
        wait(for: [started], timeout: 2)
        monitor.select(speakers)
        waitForSwitch(monitor)
        XCTAssertEqual(monitor.selectedDevice?.uid, speakers.uid)
        XCTAssertNil(monitor.errorMessage)
    }

    func testMacOSBluetoothReportParsesOnlyConnectedReadingsAndValidPercentages() throws {
        let json = #"""
        {"SPBluetoothDataType":[{"device_connected":[
          {"AirPods Pro":{"device_address":"AA-BB-CC-DD-EE-FF","device_batteryLevelLeft":"84%",
            "device_batteryLevelRight":" 80 % ","device_batteryLevelCase":92}},
          {"Headset":{"device_address":"00:11:22:33:44:55","device_batteryLevelMain":"0%"}},
          {"Unknown":{"device_address":"66:77:88:99:AA:BB","device_batteryLevelMain":"unknown"}},
          {"Invalid":{"device_address":"CC:DD:EE:FF:00:11","device_batteryLevelMain":true,
            "device_batteryLevelLeft":"101%","device_batteryLevelRight":"-1%"}}
        ],"device_not_connected":[{"Old Headset":{"device_address":"12:34:56:78:90:AB","device_batteryLevelMain":"100%"}}]}]}
        """#
        let readings = SystemBluetoothBatteryProvider.parse(Data(json.utf8))
        XCTAssertEqual(readings.count, 2)
        let pods = try XCTUnwrap(readings.first { $0.address == "AABBCCDDEEFF" })
        XCTAssertEqual(pods.battery, AudioDeviceBattery(left: 84, right: 80, caseLevel: 92))
        XCTAssertEqual(readings.first { $0.name == "Headset" }?.battery.main, 0)
        XCTAssertTrue(SystemBluetoothBatteryProvider.parse(Data("bad JSON".utf8)).isEmpty)
    }

    func testBatteryMatchingPrefersAddressAndRejectsAmbiguousNames() {
        let first = BluetoothBatteryReading(address: "AABBCCDDEEFF", name: "AirPods Pro", battery: AudioDeviceBattery(main: 80))
        let second = BluetoothBatteryReading(address: "001122334455", name: "AirPods Pro", battery: AudioDeviceBattery(main: 20))
        XCTAssertEqual(SystemBluetoothBatteryProvider.battery(for: headphones, in: [second, first])?.main, 80)
        let opaque = AudioOutputDevice(id: 3, uid: "opaque-uid", name: "AirPods Pro", transport: headphones.transport)
        XCTAssertNil(SystemBluetoothBatteryProvider.battery(for: opaque, in: [first, second]))
        XCTAssertEqual(SystemBluetoothBatteryProvider.battery(for: opaque, in: [first])?.main, 80)
        XCTAssertNil(SystemBluetoothBatteryProvider.battery(for: speakers, in: [first]))
    }

    func testConnectionActivityRestoresPinAndNeverOverridesLockHUDOrUrgentTimer() {
        let now = Date()
        var input = ActivityInputs()
        input.music = true
        var priority = ActivityPriority(pinned: .music)
        XCTAssertEqual(priority.resolve(input, at: now).displayed, .music)
        input.audioConnection = true
        let notice = priority.resolve(input, at: now)
        XCTAssertEqual(notice.displayed, .audioConnection)
        XCTAssertEqual(notice.openingTab, .audio)
        XCTAssertFalse(notice.canCycle)
        XCTAssertFalse(notice.available.contains(.audioConnection))
        input.hud = true
        XCTAssertEqual(priority.resolve(input, at: now).displayed, .hud)
        input.hud = false
        input.timer = .finished
        XCTAssertEqual(priority.resolve(input, at: now).displayed, .timer)
        input.locked = true
        XCTAssertNil(priority.resolve(input, at: now).displayed)
        input.locked = false
        input.timer = .idle
        input.audioConnection = false
        XCTAssertEqual(priority.resolve(input, at: now).displayed, .music)
    }

    func testReadOnlyCoreAudioEnumerationAndStaleUIDRejection() throws {
        let backend = CoreAudioDeviceBackend()
        let devices = try backend.outputs()
        let selectedID = try backend.defaultOutput()
        guard selectedID != kAudioObjectUnknown else { throw XCTSkip("No audio output on this host") }
        let selected = try XCTUnwrap(devices.first { $0.id == selectedID })
        XCTAssertFalse(selected.name.isEmpty)
        let stale = AudioOutputDevice(id: selected.id, uid: "not-the-current-device-uid", name: selected.name, transport: selected.transport)
        XCTAssertThrowsError(try backend.setDefaultOutput(stale))
        XCTAssertEqual(try backend.defaultOutput(), selectedID)
        print("Core Audio read-only check: \(devices.count) output(s), default found; stale UID rejected")
    }

    private func waitForSwitch(_ monitor: AudioMonitor) {
        let finished = expectation(description: "Output switch completed")
        let subscription = monitor.$pendingUID.first { $0 == nil }.sink { _ in finished.fulfill() }
        wait(for: [finished], timeout: 2)
        withExtendedLifetime(subscription) {}
    }
}

private final class FakeAudioBackend: AudioDeviceBackend {
    var devices: [AudioOutputDevice]
    var selected: AudioDeviceID
    var onChange: (() -> Void)?
    var selections: [String] = []
    var failSwitch = false
    var ignoreSwitch = false

    init(devices: [AudioOutputDevice], selected: AudioDeviceID) { self.devices = devices; self.selected = selected }
    func outputs() throws -> [AudioOutputDevice] { devices }
    func defaultOutput() throws -> AudioDeviceID { selected }
    func setDefaultOutput(_ device: AudioOutputDevice) throws {
        if failSwitch { throw AudioDeviceError.system(-1) }
        selections.append(device.uid)
        if !ignoreSwitch { selected = device.id }
    }
    func observeChanges(_ handler: @escaping () -> Void) { onChange = handler }
    func stopObserving() { onChange = nil }
}

private final class FakeBatteryProvider: BluetoothBatteryProvider {
    let readings: [BluetoothBatteryReading]
    private let lock = NSLock()
    private var count = 0
    var fetchCount: Int { lock.lock(); defer { lock.unlock() }; return count }
    init(readings: [BluetoothBatteryReading] = []) { self.readings = readings }
    func fetch() throws -> [BluetoothBatteryReading] {
        lock.lock(); count += 1; lock.unlock()
        return readings
    }
}

private final class BlockingBatteryProvider: BluetoothBatteryProvider {
    let finish = DispatchSemaphore(value: 0)
    private let started: () -> Void
    init(started: @escaping () -> Void) { self.started = started }
    func fetch() throws -> [BluetoothBatteryReading] {
        started()
        _ = finish.wait(timeout: .now() + 3)
        return []
    }
}
