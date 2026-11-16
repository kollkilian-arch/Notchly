import AppKit

/// Controls the whole overlay, including progress, HUDs and message previews.
enum FullscreenBehavior: String, CaseIterable {
    case show, dim, hide

    var title: String {
        switch self {
        case .show: return "Show normally"
        case .dim: return "Dim"
        case .hide: return "Hide"
        }
    }

    func opacity(isOpen: Bool) -> CGFloat {
        switch self {
        case .show: return 1
        case .dim: return isOpen ? 1 : 0.25
        case .hide: return 0
        }
    }
}

enum FullscreenDetection {
    private typealias MainConnectionID = @convention(c) () -> Int32
    private typealias CopyManagedDisplaySpaces = @convention(c) (Int32) -> Unmanaged<CFArray>?

    // Like lock-screen support, this is a best-effort private SkyLight query. Resolve
    // once and keep the framework loaded for the lifetime of its function pointers.
    private static let skyLight = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)
    private static let readSpaces: (() -> [[String: Any]]?)? = {
        guard let handle = skyLight,
              let mainSymbol = dlsym(handle, "SLSMainConnectionID"),
              let copySymbol = dlsym(handle, "SLSCopyManagedDisplaySpaces") else { return nil }
        let connection = unsafeBitCast(mainSymbol, to: MainConnectionID.self)
        let copySpaces = unsafeBitCast(copySymbol, to: CopyManagedDisplaySpaces.self)
        return { copySpaces(connection())?.takeRetainedValue() as? [[String: Any]] }
    }()

    static func isFullscreen(on screen: NSScreen) -> Bool {
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
              let uuid = CGDisplayCreateUUIDFromDisplayID(number.uint32Value)?.takeRetainedValue(),
              let displays = readSpaces?() else { return false }
        let identifier = CFUUIDCreateString(nil, uuid) as String
        return isFullscreen(displayID: identifier, displays: displays,
                            separateSpaces: NSScreen.screensHaveSeparateSpaces)
    }

    /// Native fullscreen (including Split View) has Space type 4; maximized windows
    /// remain in a desktop Space (type 0), regardless of their bounds or Dock settings.
    /// Schema also used by https://github.com/Hammerspoon/hammerspoon/tree/master/extensions/spaces
    static func isFullscreen(displayID: String, displays: [[String: Any]], separateSpaces: Bool = true) -> Bool {
        guard let display = displays.first(where: {
            guard let identifier = $0["Display Identifier"] as? String else { return false }
            return identifier == displayID || (!separateSpaces && identifier == "Main")
        }), let current = display["Current Space"] as? [String: Any],
            let type = current["type"] as? Int else { return false }
        // Never fall back to window bounds if the query is unavailable or unknown.
        return type == 4
    }
}
