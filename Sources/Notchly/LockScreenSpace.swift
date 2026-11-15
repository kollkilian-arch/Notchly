import AppKit

/// Moves a window into its own WindowServer "space" that is drawn above the lock screen.
///
/// This uses private SkyLight functions (the same technique other notch apps use), so it is
/// strictly best-effort: if anything is missing, `attach` returns `false` and the window simply
/// behaves normally. Only `LockMonitor`'s lock icon is meant to be visible while locked.
final class LockScreenSpace {
    // Space IDs are 64-bit; levels and flags are passed as full-width ints, which is safe for 32-bit parameters too.
    private typealias MainConnectionID = @convention(c) () -> Int32
    private typealias SpaceCreate = @convention(c) (Int32, Int, CFDictionary?) -> UInt64
    private typealias SetAbsoluteLevel = @convention(c) (Int32, UInt64, Int) -> Int32
    private typealias ShowSpaces = @convention(c) (Int32, CFArray) -> Int32
    private typealias AddWindows = @convention(c) (Int32, UInt64, CFArray, Int) -> Int32

    private(set) var isAttached = false

    @discardableResult
    func attach(_ window: NSWindow) -> Bool {
        guard !isAttached else { return true }
        guard window.windowNumber > 0,
              let handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY),
              let mainSym = dlsym(handle, "SLSMainConnectionID"),
              let createSym = dlsym(handle, "SLSSpaceCreate"),
              let levelSym = dlsym(handle, "SLSSpaceSetAbsoluteLevel"),
              let showSym = dlsym(handle, "SLSShowSpaces"),
              let addSym = dlsym(handle, "SLSSpaceAddWindowsAndRemoveFromSpaces") else {
            NSLog("Notchly: lock-screen support unavailable (SkyLight symbols missing)")
            return false
        }

        let mainConnection = unsafeBitCast(mainSym, to: MainConnectionID.self)
        let createSpace = unsafeBitCast(createSym, to: SpaceCreate.self)
        let setLevel = unsafeBitCast(levelSym, to: SetAbsoluteLevel.self)
        let showSpaces = unsafeBitCast(showSym, to: ShowSpaces.self)
        let addWindows = unsafeBitCast(addSym, to: AddWindows.self)

        let connection = mainConnection()
        // Some builds return a 32-bit id in a 64-bit register; keep only the low 32 bits.
        let space = createSpace(connection, 1, nil) & 0xFFFF_FFFF
        guard space != 0 else {
            NSLog("Notchly: lock-screen support unavailable (could not create space)")
            return false
        }
        _ = setLevel(connection, space, 2_147_483_647)
        _ = showSpaces(connection, [space] as CFArray)
        _ = addWindows(connection, space, [window.windowNumber] as CFArray, 7)

        isAttached = true
        return true
    }
}
