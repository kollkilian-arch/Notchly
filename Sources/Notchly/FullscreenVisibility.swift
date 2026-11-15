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
    /// WindowServer bounds are available without reading window titles or screen contents.
    /// Inspect only the foremost normal window on the notch's display, so a fullscreen
    /// player on another display does not dim the notch.
    static func isFullscreen(on screen: NSScreen) -> Bool {
        guard let primary = NSScreen.screens.first,
              let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return false }
        let frame = screen.frame
        let display = CGRect(x: frame.minX, y: primary.frame.maxY - frame.maxY,
                             width: frame.width, height: frame.height)
        for window in windows {
            guard let layer = window[kCGWindowLayer as String] as? Int, layer == 0,
                  (window[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                  let dictionary = window[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: dictionary),
                  bounds.intersection(display).width > 1,
                  bounds.intersection(display).height > 1 else { continue }
            return coversDisplay(bounds, display: display, topInset: screen.safeAreaInsets.top)
        }
        return false
    }

    /// Fullscreen apps may leave the camera/menu strip black on notched displays.
    /// A regular maximized window still leaves room for the Dock at the bottom.
    static func coversDisplay(_ window: CGRect, display: CGRect, topInset: CGFloat) -> Bool {
        let tolerance: CGFloat = 2
        return abs(window.minX - display.minX) <= tolerance
            && abs(window.maxX - display.maxX) <= tolerance
            && window.minY >= display.minY - tolerance
            && window.minY <= display.minY + topInset + tolerance
            && abs(window.maxY - display.maxY) <= tolerance
    }
}
