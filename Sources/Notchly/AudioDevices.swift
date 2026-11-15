import Foundation
import CoreAudio

struct AudioDeviceBattery: Equatable {
    var main: Int?
    var left: Int?
    var right: Int?
    var caseLevel: Int?

    var isEmpty: Bool { main == nil && left == nil && right == nil && caseLevel == nil }
    var listeningLevel: Int? { [left, right].compactMap { $0 }.min() ?? main }
    var summary: String {
        var parts: [String] = []
        if let left { parts.append("L \(left)%") }
        if let right { parts.append("R \(right)%") }
        if parts.isEmpty, let main { parts.append("\(main)%") }
        if let caseLevel { parts.append("Case \(caseLevel)%") }
        return parts.joined(separator: " · ")
    }
}

struct AudioOutputDevice: Identifiable, Equatable {
    let id: AudioDeviceID
    let uid: String
    let name: String
    let transport: UInt32
    var battery: AudioDeviceBattery?

    var isBluetooth: Bool {
        transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE
    }

    var symbol: String {
        let lower = name.lowercased()
        if lower.contains("airpods max") { return "airpods.max" }
        if lower.contains("airpods pro") { return "airpodspro" }
        if lower.contains("airpods") { return "airpods" }
        if lower.contains("headphone") || lower.contains("headset") || lower.contains("earbud") { return "headphones" }
        switch transport {
        case kAudioDeviceTransportTypeBuiltIn: return "laptopcomputer"
        case kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort: return "display"
        case kAudioDeviceTransportTypeAirPlay: return "airplay.audio"
        default: return "speaker.wave.2.fill"
        }
    }

    var transportName: String {
        if isBluetooth { return "Bluetooth" }
        switch transport {
        case kAudioDeviceTransportTypeBuiltIn: return "Built-in"
        case kAudioDeviceTransportTypeUSB: return "USB"
        case kAudioDeviceTransportTypeHDMI: return "HDMI"
        case kAudioDeviceTransportTypeDisplayPort: return "DisplayPort"
        case kAudioDeviceTransportTypeAirPlay: return "AirPlay"
        case kAudioDeviceTransportTypeVirtual, kAudioDeviceTransportTypeAggregate: return "Virtual output"
        default: return "Audio output"
        }
    }

    var announcesConnection: Bool { transport != kAudioDeviceTransportTypeBuiltIn || symbol == "headphones" }
}

enum AudioDeviceError: LocalizedError {
    case unavailable
    case system(OSStatus)

    var errorDescription: String? {
        switch self {
        case .unavailable: return "This output is no longer available. Choose another device."
        case .system(let code): return "macOS couldn't change the sound output (\(code)). Try again or open Sound Settings."
        }
    }
}

protocol AudioDeviceBackend: AnyObject {
    func outputs() throws -> [AudioOutputDevice]
    func defaultOutput() throws -> AudioDeviceID
    func setDefaultOutput(_ device: AudioOutputDevice) throws
    func observeChanges(_ handler: @escaping () -> Void)
    func stopObserving()
}

/// Public Core Audio properties only. Selecting an output never changes the microphone or alert output.
final class CoreAudioDeviceBackend: AudioDeviceBackend {
    private struct Listener {
        let object: AudioObjectID
        var address: AudioObjectPropertyAddress
        let block: AudioObjectPropertyListenerBlock
    }
    private var systemListeners: [Listener] = []
    private var deviceListeners: [Listener] = []
    private var observedIDs: [AudioDeviceID] = []
    private var onChange: (() -> Void)?

    func outputs() throws -> [AudioOutputDevice] {
        let ids = try Self.ids(object: AudioObjectID(kAudioObjectSystemObject), selector: kAudioHardwarePropertyDevices)
        if onChange != nil, ids != observedIDs { observeDevices(ids) }
        return ids.compactMap { id in
            guard Self.uint(id, kAudioDevicePropertyDeviceIsAlive) != 0,
                  Self.uint(id, kAudioDevicePropertyDeviceCanBeDefaultDevice, scope: kAudioObjectPropertyScopeOutput) != 0,
                  let streams = try? Self.ids(object: id, selector: kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeOutput),
                  !streams.isEmpty,
                  let uid = Self.string(id, kAudioDevicePropertyDeviceUID),
                  let name = Self.string(id, kAudioObjectPropertyName) else { return nil }
            return AudioOutputDevice(id: id, uid: uid, name: name,
                                     transport: Self.uint(id, kAudioDevicePropertyTransportType) ?? 0)
        }
    }

    func defaultOutput() throws -> AudioDeviceID {
        var value = AudioDeviceID(kAudioObjectUnknown)
        var address = Self.address(kAudioHardwarePropertyDefaultOutputDevice)
        var size = UInt32(MemoryLayout.size(ofValue: value))
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &value)
        guard status == noErr else { throw AudioDeviceError.system(status) }
        return value
    }

    func setDefaultOutput(_ device: AudioOutputDevice) throws {
        // Revalidate the UID: Core Audio can reuse an ID after a device disconnects.
        guard Self.string(device.id, kAudioDevicePropertyDeviceUID) == device.uid,
              Self.uint(device.id, kAudioDevicePropertyDeviceIsAlive) == 1,
              let streams = try? Self.ids(object: device.id, selector: kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeOutput),
              !streams.isEmpty else { throw AudioDeviceError.unavailable }
        var address = Self.address(kAudioHardwarePropertyDefaultOutputDevice)
        var settable: DarwinBoolean = false
        let object = AudioObjectID(kAudioObjectSystemObject)
        let capability = AudioObjectIsPropertySettable(object, &address, &settable)
        guard capability == noErr, settable.boolValue else { throw AudioDeviceError.unavailable }
        var id = device.id
        let status = AudioObjectSetPropertyData(object, &address, 0, nil, UInt32(MemoryLayout.size(ofValue: id)), &id)
        guard status == noErr else { throw AudioDeviceError.system(status) }
    }

    func observeChanges(_ handler: @escaping () -> Void) {
        stopObserving()
        onChange = handler
        for selector in [kAudioHardwarePropertyDevices, kAudioHardwarePropertyDefaultOutputDevice] {
            if let listener = listen(object: AudioObjectID(kAudioObjectSystemObject), selector: selector) {
                systemListeners.append(listener)
            }
        }
        if let ids = try? Self.ids(object: AudioObjectID(kAudioObjectSystemObject), selector: kAudioHardwarePropertyDevices) {
            observeDevices(ids)
        }
    }

    private func observeDevices(_ ids: [AudioDeviceID]) {
        remove(deviceListeners)
        deviceListeners.removeAll()
        observedIDs = ids
        for id in ids {
            for selector in [kAudioObjectPropertyName, kAudioDevicePropertyDeviceIsAlive] {
                if let listener = listen(object: id, selector: selector) { deviceListeners.append(listener) }
            }
            for selector in [kAudioDevicePropertyStreams, kAudioDevicePropertyJackIsConnected, kAudioDevicePropertyDataSource] {
                if let listener = listen(object: id, selector: selector, scope: kAudioObjectPropertyScopeOutput) {
                    deviceListeners.append(listener)
                }
            }
        }
    }

    private func listen(object: AudioObjectID, selector: AudioObjectPropertySelector,
                        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> Listener? {
        var address = Self.address(selector, scope: scope)
        guard AudioObjectHasProperty(object, &address) else { return nil }
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.onChange?() }
        guard AudioObjectAddPropertyListenerBlock(object, &address, .main, block) == noErr else { return nil }
        return Listener(object: object, address: address, block: block)
    }

    func stopObserving() {
        remove(systemListeners)
        remove(deviceListeners)
        systemListeners.removeAll()
        deviceListeners.removeAll()
        observedIDs.removeAll()
        onChange = nil
    }

    private func remove(_ listeners: [Listener]) {
        for var listener in listeners {
            AudioObjectRemovePropertyListenerBlock(listener.object, &listener.address, .main, listener.block)
        }
    }

    private static func address(_ selector: AudioObjectPropertySelector,
                                scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    private static func uint(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                             scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> UInt32? {
        var address = address(selector, scope: scope)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout.size(ofValue: value))
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    private static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = address(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout.size(ofValue: value))
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value?.takeRetainedValue() as String?
    }

    private static func ids(object: AudioObjectID, selector: AudioObjectPropertySelector,
                            scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) throws -> [UInt32] {
        var address = address(selector, scope: scope)
        var size: UInt32 = 0
        let sizeStatus = AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size)
        guard sizeStatus == noErr else { throw AudioDeviceError.system(sizeStatus) }
        guard size > 0 else { return [] }
        var values = [UInt32](repeating: 0, count: Int(size) / MemoryLayout<UInt32>.size)
        let status = values.withUnsafeMutableBytes {
            AudioObjectGetPropertyData(object, &address, 0, nil, &size, $0.baseAddress!)
        }
        guard status == noErr else { throw AudioDeviceError.system(status) }
        return Array(values.prefix(Int(size) / MemoryLayout<UInt32>.size))
    }

    deinit { stopObserving() }
}
