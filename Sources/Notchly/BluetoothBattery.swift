import Foundation

struct BluetoothBatteryReading: Equatable {
    let address: String
    let name: String
    let battery: AudioDeviceBattery
}

protocol BluetoothBatteryProvider {
    func fetch() throws -> [BluetoothBatteryReading]
}

/// Uses macOS's own connected-device report, without pairing or opening a Bluetooth connection.
/// Its battery fields are best-effort and may be absent for any device or component.
struct SystemBluetoothBatteryProvider: BluetoothBatteryProvider {
    func fetch() throws -> [BluetoothBatteryReading] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
        process.arguments = ["SPBluetoothDataType", "-json", "-timeout", "8"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 10, execute: timeout)
        defer { timeout.cancel() }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return [] }
        return Self.parse(data)
    }

    static func parse(_ data: Data) -> [BluetoothBatteryReading] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let controllers = root["SPBluetoothDataType"] as? [[String: Any]] else { return [] }
        var readings: [BluetoothBatteryReading] = []
        for controller in controllers {
            for entry in controller["device_connected"] as? [[String: Any]] ?? [] {
                for (name, value) in entry {
                    guard let info = value as? [String: Any],
                          let address = normalizedAddress(info["device_address"] as? String ?? "") else { continue }
                    let battery = AudioDeviceBattery(main: percent(info["device_batteryLevelMain"]),
                                                     left: percent(info["device_batteryLevelLeft"]),
                                                     right: percent(info["device_batteryLevelRight"]),
                                                     caseLevel: percent(info["device_batteryLevelCase"]))
                    if !battery.isEmpty { readings.append(BluetoothBatteryReading(address: address, name: name, battery: battery)) }
                }
            }
        }
        return readings
    }

    static func battery(for device: AudioOutputDevice, in readings: [BluetoothBatteryReading]) -> AudioDeviceBattery? {
        guard device.isBluetooth else { return nil }
        // Core Audio UIDs are opaque. Some contain an address; otherwise only use an unambiguous exact name.
        let pattern = "(?i)(?:[0-9a-f]{2}[:-]){5}[0-9a-f]{2}"
        if let range = device.uid.range(of: pattern, options: .regularExpression),
           let address = normalizedAddress(String(device.uid[range])) {
            return readings.first { $0.address == address }?.battery
        }
        let matches = readings.filter { $0.name.caseInsensitiveCompare(device.name) == .orderedSame }
        return matches.count == 1 ? matches[0].battery : nil
    }

    private static func normalizedAddress(_ value: String) -> String? {
        let cleaned = value.replacingOccurrences(of: ":", with: "").replacingOccurrences(of: "-", with: "").uppercased()
        guard cleaned.count == 12, cleaned.allSatisfy({ $0.isHexDigit }) else { return nil }
        return cleaned
    }

    private static func percent(_ value: Any?) -> Int? {
        let number: Double?
        if let string = value as? String {
            number = Double(string.replacingOccurrences(of: "%", with: "").trimmingCharacters(in: .whitespacesAndNewlines))
        } else if let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID() {
            number = value.doubleValue
        } else { number = nil }
        guard let number, number.isFinite, (0...100).contains(number) else { return nil }
        return Int(number.rounded())
    }
}
