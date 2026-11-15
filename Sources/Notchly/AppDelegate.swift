import AppKit
import Combine

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: NotchController?
    private var statusItem: NSStatusItem?
    private var updateItem: NSMenuItem?
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        let c = NotchController()
        c.start()
        controller = c
        if Pref.bool(Pref.showCalendar) { c.calendar.requestAccessIfNeeded() }
        setupStatusItem()
        Updater.shared.startAutomaticChecks()
    }

    /// Launching the app again (Spotlight, Finder, Dock) opens the settings,
    /// which also covers the case where the menu bar icon is hidden behind the notch.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        SettingsWindowController.shared.show()
        return true
    }

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "capsule.tophalf.filled", accessibilityDescription: "Notchly")

        let menu = NSMenu()

        // Only visible while an update is waiting.
        let update = NSMenuItem(title: "", action: #selector(showUpdate), keyEquivalent: "")
        update.target = self
        update.isHidden = true
        menu.addItem(update)
        updateItem = update

        let settings = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)

        let check = NSMenuItem(title: "Check for Updates…", action: #selector(checkForUpdates), keyEquivalent: "")
        check.target = self
        menu.addItem(check)

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Notchly", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        item.menu = menu
        statusItem = item

        // Show or hide the "Update available" entry, and badge the menu bar icon.
        Updater.shared.$available
            .receive(on: DispatchQueue.main)
            .sink { [weak self] release in
                guard let self else { return }
                self.updateItem?.isHidden = release == nil
                self.updateItem?.title = release.map { "Update Available: Notchly \($0.version)…" } ?? ""
                let symbol = release == nil ? "capsule.tophalf.filled" : "arrow.down.circle.fill"
                self.statusItem?.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Notchly")
            }
            .store(in: &cancellables)
    }

    @objc private func openSettings() {
        SettingsWindowController.shared.show()
    }

    @objc private func checkForUpdates() {
        Updater.shared.checkForUpdates(userInitiated: true)
        SettingsWindowController.shared.show(tab: .about)       // the result shows there
    }

    @objc private func showUpdate() {
        SettingsWindowController.shared.show(tab: .about)
    }
}
