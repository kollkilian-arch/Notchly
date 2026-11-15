import AppKit
import SwiftUI
import Combine

enum NotchTab { case home, shelf, timer, scores, usage }

final class NotchState: ObservableObject {
    @Published var isOpen = false
    @Published var tab: NotchTab = .home
    @Published var notchSize = CGSize(width: 190, height: 32)

    static let openSize = CGSize(width: 610, height: 178)
    static let wing: CGFloat = 46
    static let timerWing: CGFloat = 60
    static let hudWing: CGFloat = 72

    /// Width of each collapsed "wing". Priority: the lock icon, then a HUD, then a running timer,
    /// then an upcoming meeting, then a live score, then the passive activities (music, charging).
    static func wingWidth(lock: Bool, hud: Bool, timer: Bool, meeting: Bool, liveScore: Bool, activity: Bool) -> CGFloat {
        lock ? wing : hud ? hudWing : (timer || meeting) ? timerWing : liveScore ? hudWing : activity ? wing : 0
    }
}

/// Borderless panel that floats above the menu bar, right where the notch is.
final class NotchPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    // Allow the panel to sit over the menu bar instead of being pushed below it.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

final class NotchController {
    let state = NotchState()
    let media = MediaMonitor()
    let battery = BatteryMonitor()
    let calendar = CalendarMonitor()
    let hud = HUDMonitor()
    let shelf = ShelfStore()
    let usage = UsageMonitor()
    let timer = TimerModel()
    let lock = LockMonitor()
    let scores = ScoresMonitor()
    private let lockSpace = LockScreenSpace()

    /// Drag-pasteboard change count at the last mouse-down. A different count while the
    /// button is held means a drag session has started (and put its payload on the pasteboard).
    private var dragPasteboardCount = NSPasteboard(name: .drag).changeCount

    private var panel: NotchPanel!
    private var screen: NSScreen!
    private var monitors: [Any] = []
    private var cancellables = Set<AnyCancellable>()
    private var closeWork: DispatchWorkItem?
    private var openWork: DispatchWorkItem?

    /// Width of each collapsed "wing" (live activity or HUD) next to the notch.
    private var wingWidth: CGFloat {
        let playing = Pref.bool(Pref.showMediaActivity) && media.isPlaying
        let charging = Pref.bool(Pref.showChargingActivity) && battery.isCharging
        return NotchState.wingWidth(lock: lock.indicatorVisible, hud: hud.event != nil,
                                    timer: timer.isActive, meeting: calendar.indicatorMeeting != nil,
                                    liveScore: scores.liveGameForNotch != nil, activity: playing || charging)
    }

    private var closedWidth: CGFloat { state.notchSize.width + wingWidth * 2 }

    func start() {
        let panel = NotchPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isFloatingPanel = true
        // Must come after isFloatingPanel (which resets the level to "floating").
        // Above the menu bar (24) and its status items (25), so they don't show through the panel.
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.statusWindow)) + 2)
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]

        let root = NotchRoot(state: state, media: media, battery: battery, calendar: calendar, hud: hud, shelf: shelf, usage: usage, timer: timer, lock: lock, scores: scores)
        let host = NSHostingView(rootView: root)
        host.autoresizingMask = [.width, .height]
        panel.contentView = host
        self.panel = panel

        relayout()
        panel.orderFrontRegardless()

        // Draw the lock icon on the lock screen too (private API, best-effort, applied at launch).
        if Pref.bool(Pref.lockIndicator), Pref.bool(Pref.lockScreenVisible) {
            NSLog("Notchly: lock-screen space attached = \(lockSpace.attach(panel))")
        }

        // While locked, nothing but the lock icon may be shown or interacted with.
        lock.$phase
            .receive(on: DispatchQueue.main)
            .sink { [weak self] phase in
                guard let self else { return }
                let locked = phase == .locked
                self.panel.alphaValue = (locked && !Pref.bool(Pref.lockIndicator)) ? 0 : 1
                if locked {
                    self.cancelClose()
                    self.cancelOpen()
                    self.state.isOpen = false
                    self.panel.ignoresMouseEvents = true
                }
            }
            .store(in: &cancellables)

        // Only let clicks hit the panel while it is open; otherwise it is click-through.
        state.$isOpen
            .receive(on: DispatchQueue.main)
            .sink { [weak self] open in self?.panel.ignoresMouseEvents = !open }
            .store(in: &cancellables)

        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in self?.relayout() }

        // Mouse monitors do not require any special permission.
        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .leftMouseDown]
        if let g = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] e in self?.handleMouse(e.type) }) {
            monitors.append(g)
        }
        if let l = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] e in self?.handleMouse(e.type); return e }) {
            monitors.append(l)
        }
    }

    private func relayout() {
        let found = NotchGeometry.find()
        screen = found.screen
        state.notchSize = found.size

        let w = NotchState.openSize.width + 40
        let h = NotchState.openSize.height + 24
        let f = screen.frame
        panel.setFrame(NSRect(x: f.midX - w / 2, y: f.maxY - h, width: w, height: h), display: true)
    }

    // MARK: Geometry

    private func hotRect(dragging: Bool) -> NSRect {
        let f = screen.frame
        let w = closedWidth + 24
        var hot = NSRect(x: f.midX - w / 2, y: f.maxY - state.notchSize.height - 2,
                         width: w, height: state.notchSize.height + 4)
        // Be more forgiving when aiming a file at the notch.
        if dragging { hot = hot.insetBy(dx: -50, dy: -18) }
        return hot
    }

    private func openRect() -> NSRect {
        let f = screen.frame
        return NSRect(x: f.midX - NotchState.openSize.width / 2 - 14,
                      y: f.maxY - NotchState.openSize.height - 14,
                      width: NotchState.openSize.width + 28,
                      height: NotchState.openSize.height + 20)
    }

    // MARK: Mouse handling

    private func handleMouse(_ type: NSEvent.EventType) {
        guard screen != nil, lock.phase != .locked else { return }   // never open while locked
        if type == .leftMouseDown {
            dragPasteboardCount = NSPasteboard(name: .drag).changeCount
            // Clicking the notch opens it (the only way in when "open on hover" is off).
            if !state.isOpen, hotRect(dragging: false).contains(NSEvent.mouseLocation) {
                openNotch(dragging: false)
            }
            return
        }
        mouseMoved()
    }

    /// True while the user is dragging file(s) from anywhere on screen.
    private var isDraggingFiles: Bool {
        guard NSEvent.pressedMouseButtons & 1 != 0 else { return false }
        let pb = NSPasteboard(name: .drag)
        return pb.changeCount != dragPasteboardCount
            && pb.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
    }

    private func mouseMoved() {
        let p = NSEvent.mouseLocation
        let dragging = isDraggingFiles

        if state.isOpen {
            if openRect().contains(p) {
                cancelClose()
                if dragging { state.tab = .shelf }
            } else {
                scheduleClose()
            }
        } else if hotRect(dragging: dragging).contains(p) {
            if dragging {
                openNotch(dragging: true)
            } else if Pref.bool(Pref.openOnHover) {
                let delay = Pref.double(Pref.hoverDelay)
                if delay <= 0 {
                    openNotch(dragging: false)
                } else if openWork == nil {
                    let work = DispatchWorkItem { [weak self] in self?.openNotch(dragging: false) }
                    openWork = work
                    DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
                }
            }
        } else {
            cancelOpen()   // left the notch before the hover delay elapsed
        }
    }

    private func openNotch(dragging: Bool) {
        cancelClose()
        cancelOpen()
        // A finished timer takes you straight to its "Time's up" screen.
        state.tab = dragging ? .shelf : (timer.phase == .finished ? .timer : .home)
        // Accept clicks and drops right away instead of waiting for the Combine hop above.
        panel.ignoresMouseEvents = false
        state.isOpen = true
        Feedback.haptic(.open)
        Feedback.sound(.open, if: Pref.soundOpenClose)
        // Keep the usage ring in the tab bar current (at most one request per 5 minutes).
        if Pref.bool(Pref.showUsage) { usage.refresh(minInterval: 300) }
        scores.refresh()      // no-op unless scores are on and the last refresh is over a minute old
    }

    private func scheduleClose() {
        guard closeWork == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            self?.state.isOpen = false
            self?.closeWork = nil
            Feedback.sound(.close, if: Pref.soundOpenClose)
        }
        closeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Pref.double(Pref.closeDelay), execute: work)
    }

    private func cancelClose() {
        closeWork?.cancel()
        closeWork = nil
    }

    private func cancelOpen() {
        openWork?.cancel()
        openWork = nil
    }
}
