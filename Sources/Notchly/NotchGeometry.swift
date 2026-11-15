import AppKit

enum NotchGeometry {
    /// Picks the screen with a notch (falls back to the main screen) and measures the notch.
    static func find() -> (screen: NSScreen, size: CGSize) {
        let screen = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 })
            ?? NSScreen.main
            ?? NSScreen.screens[0]

        if screen.safeAreaInsets.top > 0,
           let left = screen.auxiliaryTopLeftArea,
           let right = screen.auxiliaryTopRightArea {
            let width = screen.frame.width - left.width - right.width
            // +2 so the black shape fully covers the hardware cut-out edges
            return (screen, CGSize(width: width + 2, height: screen.safeAreaInsets.top))
        }

        // No notch: emulate one the height of the menu bar.
        let menuBar = max(screen.frame.maxY - screen.visibleFrame.maxY, 24)
        return (screen, CGSize(width: 190, height: menuBar))
    }
}
