import Foundation
import IOKit.ps

final class BatteryMonitor: ObservableObject {
    @Published private(set) var level = 100
    @Published private(set) var isCharging = false
    @Published private(set) var pluggedIn = false
    @Published private(set) var hasBattery = false

    init(previewLevel: Int, charging: Bool = false) {
        level = previewLevel
        hasBattery = true
        isCharging = charging
    }

    init() {
        update()
        let context = Unmanaged.passUnretained(self).toOpaque()
        let source = IOPSNotificationCreateRunLoopSource({ ctx in
            guard let ctx else { return }
            Unmanaged<BatteryMonitor>.fromOpaque(ctx).takeUnretainedValue().update()
        }, context).takeRetainedValue()
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
    }

    func update() {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return }

        for ps in list {
            guard let d = IOPSGetPowerSourceDescription(info, ps)?.takeUnretainedValue() as? [String: Any],
                  d[kIOPSTypeKey] as? String == kIOPSInternalBatteryType else { continue }
            hasBattery = true
            level = d[kIOPSCurrentCapacityKey] as? Int ?? level
            isCharging = d[kIOPSIsChargingKey] as? Bool ?? false
            pluggedIn = (d[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue
        }
    }
}
