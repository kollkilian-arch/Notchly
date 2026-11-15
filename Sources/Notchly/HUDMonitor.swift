import AppKit
import CoreAudio
import Combine

enum HUDKind { case volume, brightness }

struct HUDEvent: Equatable {
    var kind: HUDKind
    var level: Float          // 0...1
    var muted = false
}

/// Watches system volume (CoreAudio listeners) and built-in display brightness
/// (polling the private DisplayServices framework) and publishes a short-lived HUD event.
final class HUDMonitor: ObservableObject {
    @Published private(set) var event: HUDEvent?

    private var hideWork: DispatchWorkItem?

    // Audio
    private var deviceID = AudioObjectID(kAudioObjectUnknown)
    private var lastVolume: Float?
    private var lastMuted: Bool?
    private var audioBlock: AudioObjectPropertyListenerBlock!
    private var deviceBlock: AudioObjectPropertyListenerBlock!

    // Brightness
    private typealias GetBrightness = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private typealias SetBrightness = @convention(c) (CGDirectDisplayID, Float) -> Int32
    private var getBrightness: GetBrightness?
    private var setBrightness: SetBrightness?
    private var builtinDisplay: CGDirectDisplayID?
    private var lastBrightness: Float?
    private var brightnessTimer: Timer?

    /// Minimum brightness change between two polls (0.1 s) that counts as a user action.
    /// Auto-brightness ramps are much slower than a key press or slider drag.
    private let brightnessThreshold: Float = 0.012
    // Replacing the system HUD (controlled by the "replaceSystemHUD" preference)
    private let keyTap = MediaKeyTap()
    private var tapRequested = false
    private var premuteVolume: Float?

    var replacesSystemHUD: Bool { Pref.bool(Pref.replaceSystemHUD) }

    /// Installs the key tap (asking for Accessibility access) the first time the setting is on.
    private func startTapIfNeeded() {
        guard replacesSystemHUD, !tapRequested else { return }
        tapRequested = true
        keyTap.start()
    }

    // 'vmvc' = kAudioHardwareServiceDeviceProperty_VirtualMainVolume
    private let virtualMainVolume: AudioObjectPropertySelector = 0x766D_7663

    init() {
        audioBlock = { [weak self] _, _ in self?.audioChanged() }
        deviceBlock = { [weak self] _, _ in self?.rebindDevice() }

        var defaultDevice = address(kAudioHardwarePropertyDefaultOutputDevice, scope: kAudioObjectPropertyScopeGlobal)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &defaultDevice, .main, deviceBlock)
        rebindDevice()

        setupBrightness()

        keyTap.handler = { [weak self] key, isDown, fine in
            guard let self, self.replacesSystemHUD else { return false }
            return self.handleKey(key, isDown: isDown, fine: fine)
        }
        startTapIfNeeded()
        // Turning the setting on later (in the settings window) installs the tap then.
        NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.startTapIfNeeded() }
    }

    // MARK: Key handling (system HUD replacement)

    /// Applies a volume/brightness key press ourselves. Returns `true` if the key was handled
    /// (so the system never sees it); `false` lets macOS deal with it (e.g. unsupported output device).
    private func handleKey(_ key: MediaKey, isDown: Bool, fine: Bool) -> Bool {
        let step: Float = fine ? 1.0 / 64 : 1.0 / 16

        switch key {
        case .soundUp, .soundDown, .mute:
            guard Pref.bool(Pref.hudVolume), let volume = readVolume() else { return false }
            guard isDown else { return true }
            let muted = readMuted()

            if key == .mute {
                if let muted {
                    setMuted(!muted)
                    finishVolume(volume, muted: !muted)
                } else if volume > 0 {          // device without a mute switch: emulate it
                    premuteVolume = volume
                    setVolume(0)
                    finishVolume(0, muted: true)
                } else {
                    let restored = premuteVolume ?? 0.3
                    setVolume(restored)
                    finishVolume(restored, muted: false)
                }
            } else {
                let target = min(max(volume + (key == .soundUp ? step : -step), 0), 1)
                if key == .soundUp, muted == true { setMuted(false) }
                setVolume(target)
                finishVolume(target, muted: key == .soundUp ? false : (muted ?? false))
            }
            return true

        case .brightnessUp, .brightnessDown:
            guard Pref.bool(Pref.hudBrightness),
                  let get = getBrightness, let set = setBrightness, let display = builtinDisplay else { return false }
            guard isDown else { return true }
            var current: Float = 0
            guard get(display, &current) == 0 else { return true }
            let target = min(max(current + (key == .brightnessUp ? step : -step), 0), 1)
            _ = set(display, target)
            lastBrightness = target
            show(HUDEvent(kind: .brightness, level: target))
            return true
        }
    }

    private func finishVolume(_ volume: Float, muted: Bool) {
        lastVolume = volume       // so the CoreAudio listener doesn't show a second HUD
        lastMuted = muted
        show(HUDEvent(kind: .volume, level: muted ? 0 : volume, muted: muted))
    }

    private func setVolume(_ value: Float) {
        var a = address(virtualMainVolume)
        var v = Float32(value)
        AudioObjectSetPropertyData(deviceID, &a, 0, nil, UInt32(MemoryLayout<Float32>.size), &v)
    }

    private func setMuted(_ muted: Bool) {
        var a = address(kAudioDevicePropertyMute)
        var v: UInt32 = muted ? 1 : 0
        AudioObjectSetPropertyData(deviceID, &a, 0, nil, UInt32(MemoryLayout<UInt32>.size), &v)
    }

    // MARK: Volume

    private func address(_ selector: AudioObjectPropertySelector,
                         scope: AudioObjectPropertyScope = kAudioDevicePropertyScopeOutput) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    private func rebindDevice() {
        // Stop listening to the previous output device.
        if deviceID != kAudioObjectUnknown {
            for sel in [virtualMainVolume, kAudioDevicePropertyMute] {
                var a = address(sel)
                AudioObjectRemovePropertyListenerBlock(deviceID, &a, .main, audioBlock)
            }
        }

        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var id = AudioObjectID(kAudioObjectUnknown)
        var a = address(kAudioHardwarePropertyDefaultOutputDevice, scope: kAudioObjectPropertyScopeGlobal)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size, &id) == noErr else { return }
        deviceID = id

        for sel in [virtualMainVolume, kAudioDevicePropertyMute] {
            var addr = address(sel)
            AudioObjectAddPropertyListenerBlock(deviceID, &addr, .main, audioBlock)
        }
        // Take a fresh baseline without flashing the HUD for the device switch.
        lastVolume = readVolume()
        lastMuted = readMuted()
    }

    private func readVolume() -> Float? {
        var a = address(virtualMainVolume)
        guard AudioObjectHasProperty(deviceID, &a) else { return nil }
        var value: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectGetPropertyData(deviceID, &a, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    private func readMuted() -> Bool? {
        var a = address(kAudioDevicePropertyMute)
        guard AudioObjectHasProperty(deviceID, &a) else { return nil }
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(deviceID, &a, 0, nil, &size, &value) == noErr else { return nil }
        return value != 0
    }

    private func audioChanged() {
        let volume = readVolume()
        let muted = readMuted() ?? false
        defer { lastVolume = volume; lastMuted = muted }
        guard let volume else { return }
        if let lastVolume, abs(lastVolume - volume) < 0.001, lastMuted == muted { return }
        show(HUDEvent(kind: .volume, level: muted ? 0 : volume, muted: muted))
    }

    // MARK: Brightness

    private func setupBrightness() {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY),
              let sym = dlsym(handle, "DisplayServicesGetBrightness") else {
            NSLog("Notchly: DisplayServices unavailable; brightness HUD disabled")
            return
        }
        getBrightness = unsafeBitCast(sym, to: GetBrightness.self)
        if let setSym = dlsym(handle, "DisplayServicesSetBrightness") {
            setBrightness = unsafeBitCast(setSym, to: SetBrightness.self)
        }

        var ids = [CGDirectDisplayID](repeating: 0, count: 8)
        var count: UInt32 = 0
        CGGetActiveDisplayList(8, &ids, &count)
        builtinDisplay = ids.prefix(Int(count)).first(where: { CGDisplayIsBuiltin($0) != 0 })
        guard builtinDisplay != nil else { return }

        brightnessTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            self?.pollBrightness()
        }
    }

    private func pollBrightness() {
        guard let getBrightness, let display = builtinDisplay else { return }
        var value: Float = 0
        guard getBrightness(display, &value) == 0 else { return }
        defer { lastBrightness = value }
        if let last = lastBrightness, abs(value - last) > brightnessThreshold {
            show(HUDEvent(kind: .brightness, level: value))
        }
    }

    // MARK: Presentation

    private func show(_ e: HUDEvent) {
        guard Pref.bool(e.kind == .volume ? Pref.hudVolume : Pref.hudBrightness) else { return }
        event = e
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.event = nil }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Pref.double(Pref.hudDuration), execute: work)
    }
}
