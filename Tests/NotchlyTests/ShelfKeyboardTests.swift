import AppKit
import SwiftUI
import XCTest
@testable import Notchly

final class ShelfKeyboardTests: XCTestCase {
    func testSelectionAndSpacePreviewInANonactivatingPanel() throws {
        let app = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let shelf = ShelfStore(storeURL: directory.appendingPathComponent("shelf.json"))
        shelf.addText("First snippet")
        shelf.addText("Second snippet")

        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let host = NSHostingView(rootView: ShelfView(shelf: shelf, pasteboard: pasteboard))
        let panel = NotchPanel(contentRect: NSRect(x: 200, y: 200, width: 590, height: 120),
                               styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.contentView = host
        panel.makeKeyAndOrderFront(nil)
        defer { ShelfPreview.shared.close(); panel.close() }
        pump()
        XCTAssertTrue(panel.isKeyWindow, "The Shelf must receive keyboard input without activating the app")

        try sendKey(code: 124, to: panel, app: app)
        XCTAssertEqual(shelf.selectedItem?.text, "First snippet")
        try sendKey(code: 123, to: panel, app: app)
        XCTAssertEqual(shelf.selectedItem?.text, "Second snippet")
        try sendKey(code: 49, to: panel, app: app)
        let preview = try XCTUnwrap(app.windows.first { $0.title == "Second snippet" && $0.isVisible })
        XCTAssertTrue(preview.isKeyWindow)
        try sendKey(code: 49, to: preview, app: app)
        XCTAssertFalse(preview.isVisible, "Space must also dismiss the preview")

        panel.makeKey()
        pasteboard.writeObjects(["Pasted from keyboard" as NSString])
        try sendKey(code: 9, characters: "v", modifiers: .command, to: panel, app: app)
        XCTAssertEqual(shelf.selectedItem?.text, "Pasted from keyboard")
        pasteboard.clearContents()
        try sendKey(code: 8, characters: "c", modifiers: .command, to: panel, app: app)
        XCTAssertEqual(pasteboard.string(forType: .string), "Pasted from keyboard")

        try sendKey(code: 53, to: panel, app: app)
        let click = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: NSPoint(x: 5, y: 5),
                                                     modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                     windowNumber: panel.windowNumber, context: nil,
                                                     eventNumber: 1, clickCount: 1, pressure: 1))
        app.postEvent(click, atStart: true)
        let queuedClick = try XCTUnwrap(app.nextEvent(matching: .leftMouseDown, until: Date().addingTimeInterval(1),
                                                      inMode: .default, dequeue: true))
        app.sendEvent(queuedClick)
        pump()
        XCTAssertTrue(panel.isKeyWindow, "Clicking the Shelf must restore keyboard control after Escape")

        let otherWindow = NSPanel(contentRect: NSRect(x: 200, y: 200, width: 300, height: 150),
                                  styleMask: [.titled, .nonactivatingPanel], backing: .buffered, defer: false)
        otherWindow.isReleasedWhenClosed = false
        otherWindow.makeKeyAndOrderFront(nil)
        defer { otherWindow.close() }
        try sendKey(code: 124, to: otherWindow, app: app)
        XCTAssertEqual(shelf.selectedItem?.text, "Pasted from keyboard", "Other windows must keep their own keys")

        // Hidden Shelf views remain mounted in the notch, so disabling input is essential.
        host.rootView = ShelfView(shelf: shelf, isActive: false, pasteboard: pasteboard)
        pump()
        panel.makeKey()
        try sendKey(code: 124, to: panel, app: app)
        XCTAssertEqual(shelf.selectedItem?.text, "Pasted from keyboard", "A closed Shelf must leave keys alone")
    }

    private func sendKey(code: UInt16, characters: String? = nil, modifiers: NSEvent.ModifierFlags = [],
                         to window: NSWindow, app: NSApplication) throws {
        let text = characters ?? (code == 49 ? " " : "")
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
                                                 timestamp: ProcessInfo.processInfo.systemUptime,
                                                 windowNumber: window.windowNumber, context: nil,
                                                 characters: text, charactersIgnoringModifiers: text,
                                                 isARepeat: false, keyCode: code))
        app.postEvent(event, atStart: true)
        let queued = try XCTUnwrap(app.nextEvent(matching: .keyDown, until: Date().addingTimeInterval(1),
                                                 inMode: .default, dequeue: true))
        app.sendEvent(queued)
        pump()
    }

    private func pump() { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }
}
