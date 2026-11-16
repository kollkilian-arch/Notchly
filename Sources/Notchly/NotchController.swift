import AppKit
import SwiftUI
import Combine

enum NotchTab: CaseIterable { case home, shelf, timer, scores, usage, audio }

final class NotchState: ObservableObject {
    @Published var fullscreenBehavior: FullscreenBehavior = .show
    @Published var isOpen = false
    @Published var tab: NotchTab = .home
    @Published var notchSize = CGSize(width: 190, height: 32)
    @Published private(set) var activity = ActivityPresentation()

    private var priority: ActivityPriority
    private var activityInputs = ActivityInputs()
    private let defaults: UserDefaults?

    init(defaults: UserDefaults? = .standard) {
        self.defaults = defaults
        priority = ActivityPriority(pinned: defaults?.string(forKey: Pref.pinnedActivity).flatMap(NotchActivity.init(rawValue:)))
    }

    func updateActivities(_ input: ActivityInputs, at now: Date = Date()) {
        activityInputs = input
        let updated = priority.resolve(input, at: now)
        if activity != updated { activity = updated }
    }

    func selectActivity(_ kind: NotchActivity, at now: Date = Date()) {
        priority.select(kind, from: activityInputs, at: now)
        updateActivities(activityInputs, at: now)
    }

    func cycleActivity(at now: Date = Date()) {
        priority.cycle(from: activityInputs, at: now)
        updateActivities(activityInputs, at: now)
    }

    func toggleActivityPin(_ kind: NotchActivity, at now: Date = Date()) {
        priority.togglePin(kind, from: activityInputs)
        defaults?.set(priority.pinned?.rawValue ?? "", forKey: Pref.pinnedActivity)
        updateActivities(activityInputs, at: now)
    }

    func useAutomaticActivities(at now: Date = Date()) {
        priority.useAutomatic()
        defaults?.set("", forKey: Pref.pinnedActivity)
        updateActivities(activityInputs, at: now)
    }

    static var openSize: CGSize {
        Pref.bool(Pref.useExperimentalBranch) ? CGSize(width: 760, height: 310) : CGSize(width: 610, height: 178)
    }
    static let wing: CGFloat = 46
    static let timerWing: CGFloat = 60
    static let hudWing: CGFloat = 72
}

/// Borderless panel that floats above the menu bar, right where the notch is.
final class NotchPanel: NSPanel {
    override var canBecomeKey: Bool { true }
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
    let audio = AudioMonitor()
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

    /// Keep hit testing and opening on the same activity decision as the views.
    private func refreshActivities() {
        state.updateActivities(ActivityInputs(media: media, battery: battery, calendar: calendar,
                                             hud: hud, timer: timer, lock: lock, scores: scores, audio: audio))
    }

    private func updateHitTesting() {
        panel.ignoresMouseEvents = state.fullscreenBehavior == .hide || !state.isOpen
    }

    private var closedWidth: CGFloat { state.notchSize.width + state.activity.wingWidth * 2 }

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
        panel.becomesKeyOnlyIfNeeded = true
        // Must come after isFloatingPanel (which resets the level to "floating").
        // Above the menu bar (24) and its status items (25), so they don't show through the panel.
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.statusWindow)) + 2)
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]

        let root = NotchRoot(state: state, media: media, battery: battery, calendar: calendar, hud: hud, shelf: shelf, usage: usage, timer: timer, lock: lock, scores: scores, audio: audio)
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
                self.refreshActivities()
                self.refreshFullscreen()
                if locked {
                    NotificationCenter.default.post(name: NotchInteraction.dismiss, object: nil)
                    ShelfPreview.shared.close()
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
            .sink { [weak self] open in
                self?.updateHitTesting()
                self?.updateVisibility()
                if !open { self?.panel.resignKey() }
            }
            .store(in: &cancellables)

        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in self?.relayout() }

        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.relayout() }
            .store(in: &cancellables)

        // Refresh native fullscreen Space state, including transitions within the active app.
        Timer.publish(every: 0.75, on: .main, in: .common).autoconnect()
            .sink { [weak self] _ in self?.refreshFullscreen() }
            .store(in: &cancellables)
        for name in [NSWorkspace.activeSpaceDidChangeNotification, NSWorkspace.didActivateApplicationNotification] {
            NSWorkspace.shared.notificationCenter.publisher(for: name)
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in self?.refreshFullscreen() }
                .store(in: &cancellables)
        }

        // Mouse monitors do not require any special permission.
        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .leftMouseDown]
        if let g = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] e in self?.handleMouse(e) }) {
            monitors.append(g)
        }
        if let l = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] e in self?.handleMouse(e); return e }) {
            monitors.append(l)
        }
        if let k = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] e in self?.handleKey(e) ?? e }) {
            monitors.append(k)
        }
    }

    // MARK: Keyboard

    /// ⌘1…⌘6 and ← / → switch tabs, ⌘, opens Settings, Esc hands the keyboard back. Only while the
    /// open notch is the key window, which a click inside it makes it (hovering never takes the
    /// keyboard away from the app you are working in).
    private func handleKey(_ event: NSEvent) -> NSEvent? {
        guard state.isOpen, panel.isKeyWindow, event.window === panel, panel.attachedSheet == nil else { return event }
        let tabs = NotchTab.visibleNow
        guard let action = TabKeys.action(keyCode: event.keyCode, characters: event.charactersIgnoringModifiers,
                                          modifiers: event.modifierFlags, current: state.tab, visible: tabs) else { return event }
        switch action {
        case .select(let tab): select(tab)
        case .step(let offset): select(NotchTab.step(from: state.tab, by: offset, in: tabs))
        case .releaseKeyboard: panel.resignKey()
        case .openSettings: SettingsWindowController.shared.show()
        }
        return nil
    }

    private func select(_ tab: NotchTab) {
        guard state.tab != tab else { return }
        state.tab = tab
        Feedback.haptic(.light)
    }

    private func relayout() {
        let found = NotchGeometry.find()
        screen = found.screen
        state.notchSize = found.size

        let w = NotchState.openSize.width + 40
        let h = NotchState.openSize.height + 24
        let f = screen.frame
        panel.setFrame(NSRect(x: f.midX - w / 2, y: f.maxY - h, width: w, height: h), display: true)
        refreshFullscreen()
    }

    private func refreshFullscreen() {
        guard screen != nil else { return }
        let preference = FullscreenBehavior(rawValue: UserDefaults.standard.string(forKey: Pref.fullscreenBehavior) ?? "") ?? .dim
        let behavior: FullscreenBehavior = lock.phase == .unlocked && preference != .show
            && FullscreenDetection.isFullscreen(on: screen) ? preference : .show
        if state.fullscreenBehavior != behavior {
            state.fullscreenBehavior = behavior
            if behavior != .show {
                cancelOpen()
                cancelClose()
                NotificationCenter.default.post(name: NotchInteraction.dismiss, object: nil)
                ShelfPreview.shared.close()
                state.isOpen = false
                panel.resignKey()
            }
            updateHitTesting()
        }
        updateVisibility()
    }

    private func updateVisibility() {
        let alpha: CGFloat = lock.phase == .locked
            ? (Pref.bool(Pref.lockIndicator) ? 1 : 0)
            : (lock.phase == .unlocked ? state.fullscreenBehavior.opacity(isOpen: state.isOpen) : 1)
        if panel.alphaValue != alpha { panel.alphaValue = alpha }
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

    private func handleMouse(_ event: NSEvent) {
        guard screen != nil, lock.phase != .locked, state.fullscreenBehavior != .hide else { return }   // never open while locked
        refreshActivities()
        if event.type == .leftMouseDown {
            dragPasteboardCount = NSPasteboard(name: .drag).changeCount
            // Clicking the notch opens it (the only way in when "open on hover" is off).
            if !state.isOpen, hotRect(dragging: false).contains(NSEvent.mouseLocation) {
                if event.modifierFlags.contains(.option) {
                    cancelOpen()
                    state.cycleActivity()
                }
                else { openNotch(dragging: false) }
            } else if state.isOpen, openRect().contains(NSEvent.mouseLocation), !panel.isKeyWindow {
                panel.makeKey()         // a click in the open notch is what gives it the keyboard
            }
            return
        }
        mouseMoved()
    }

    /// Detect any content supported by the shelf without reading the general clipboard.
    private var isDraggingShelfContent: Bool {
        guard NSEvent.pressedMouseButtons & 1 != 0 else { return false }
        let pb = NSPasteboard(name: .drag)
        return pb.changeCount != dragPasteboardCount
            && pb.canReadObject(forClasses: [NSURL.self, NSString.self, NSImage.self], options: nil)
    }

    private func mouseMoved() {
        let p = NSEvent.mouseLocation
        let dragging = isDraggingShelfContent

        if state.isOpen {
            if openRect().contains(p) {
                cancelClose()
                if dragging { state.tab = .shelf }
            } else if !NotchInteraction.keepsOpen {
                scheduleClose()
            }
        } else if hotRect(dragging: dragging).contains(p) {
            if dragging {
                openNotch(dragging: true)
            } else if NSEvent.modifierFlags.contains(.option) {
                cancelOpen() // Keep the notch closed while Option-clicking through activities.
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
        guard lock.phase != .locked, state.fullscreenBehavior != .hide else { return }
        cancelClose()
        cancelOpen()
        refreshActivities()
        state.tab = dragging ? .shelf : state.activity.openingTab
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
        guard closeWork == nil, !NotchInteraction.keepsOpen else { return }
        let work = DispatchWorkItem { [weak self] in
            guard !NotchInteraction.keepsOpen else { self?.closeWork = nil; return }
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
