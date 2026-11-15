import AppKit
import ApplicationServices

enum MediaKey: Int {
    case soundUp = 0, soundDown = 1, brightnessUp = 2, brightnessDown = 3, mute = 7
}

/// Intercepts the volume / brightness / mute keys so macOS never shows its own overlay.
/// Needs the Accessibility permission. If the handler returns `true` the key event is swallowed.
final class MediaKeyTap {
    /// (key, isKeyDown, fineStep) -> consumed
    var handler: ((MediaKey, Bool, Bool) -> Bool)?

    private var tap: CFMachPort?
    private var retryTimer: Timer?

    /// Installs the tap now, or asks for Accessibility access and keeps retrying until it is granted.
    func start() {
        if install() { return }
        // Literal key of kAXTrustedCheckOptionPrompt: shows the system permission prompt.
        AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        retryTimer?.invalidate()
        retryTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] timer in
            if self?.install() == true { timer.invalidate() }
        }
    }

    private func install() -> Bool {
        if tap != nil { return true }
        guard AXIsProcessTrusted() else { return false }

        let systemDefined: CGEventMask = 1 << 14 // NX_SYSDEFINED
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            return Unmanaged<MediaKeyTap>.fromOpaque(refcon).takeUnretainedValue().handle(type: type, event: event)
        }
        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: systemDefined, callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return false }

        tap = port
        let source = CFMachPortCreateRunLoopSource(nil, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        return true
    }

    fileprivate func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)

        // macOS disables taps that respond too slowly; switch it back on.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return pass
        }

        guard let ns = NSEvent(cgEvent: event), ns.type == .systemDefined, ns.subtype.rawValue == 8 else { return pass }
        let code = (ns.data1 & 0xFFFF_0000) >> 16
        let flags = ns.data1 & 0x0000_FFFF
        let isDown = ((flags & 0xFF00) >> 8) == 0xA
        guard let key = MediaKey(rawValue: code) else { return pass }

        let fine = ns.modifierFlags.contains([.option, .shift])
        return handler?(key, isDown, fine) == true ? nil : pass
    }
}
