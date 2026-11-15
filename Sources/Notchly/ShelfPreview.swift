import SwiftUI
import QuickLookUI

/// A separate preview stays usable after the pointer leaves the notch.
final class ShelfPreview: NSObject, NSWindowDelegate {
    static let shared = ShelfPreview()
    private var panel: ShelfPreviewPanel?
    private var itemID: UUID?

    func toggle(_ item: ShelfItem) {
        if panel?.isVisible == true, itemID == item.id { close() }
        else { show(item) }
    }

    func show(_ item: ShelfItem) {
        if panel == nil {
            let panel = ShelfPreviewPanel(contentRect: NSRect(x: 0, y: 0, width: 640, height: 440),
                                          styleMask: [.titled, .closable, .resizable, .nonactivatingPanel],
                                          backing: .buffered, defer: false)
            panel.isReleasedWhenClosed = false
            panel.hidesOnDeactivate = false
            panel.isFloatingPanel = true
            panel.minSize = NSSize(width: 360, height: 240)
            panel.title = "Shelf Preview"
            panel.delegate = self
            panel.center()
            self.panel = panel
        }
        itemID = item.id
        panel?.title = item.name
        panel?.contentViewController = NSHostingController(rootView: ShelfPreviewContent(item: item))
        panel?.makeKeyAndOrderFront(nil)
    }

    func close() { panel?.close() }

    func windowWillClose(_ notification: Notification) {
        panel?.contentViewController = nil
        itemID = nil
    }
}

private final class ShelfPreviewPanel: NSPanel {
    override var canBecomeKey: Bool { true }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown,
           event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty,
           event.keyCode == 49 || event.keyCode == 53 {
            close()
            return
        }
        super.sendEvent(event)
    }
}

struct ShelfPreviewContent: View {
    let item: ShelfItem

    var body: some View {
        VStack(spacing: 0) {
            if item.kind == .link {
                VStack(spacing: 18) {
                    Image(systemName: "link.circle.fill").font(.system(size: 48)).foregroundStyle(.blue)
                    Text(item.name).font(.title2)
                    Text(item.url.absoluteString).textSelection(.enabled).multilineTextAlignment(.center)
                    Link("Open in Browser", destination: item.url)
                }
                .padding(30)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if item.kind == .text {
                ScrollView {
                    Text(item.text ?? "")
                        .font(.system(size: 14))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(24)
                }
            } else {
                ShelfQuickLook(url: item.url)
            }
            Divider()
            HStack {
                Text("Space or Esc to close").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Copy") { item.copy() }
            }
            .padding(12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

private struct ShelfQuickLook: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> QLPreviewView {
        let view = QLPreviewView(frame: .zero, style: .normal)!
        view.shouldCloseWithWindow = false
        view.autostarts = false
        view.previewItem = url as NSURL
        return view
    }

    func updateNSView(_ view: QLPreviewView, context: Context) { view.previewItem = url as NSURL }

    static func dismantleNSView(_ view: QLPreviewView, coordinator: ()) { view.close() }
}

/// Window-local handling avoids intercepting another app's Paste or Space key.
struct ShelfKeyboardInput: NSViewRepresentable {
    let isActive: Bool
    let shelf: ShelfStore
    let pasteboard: NSPasteboard

    func makeNSView(context: Context) -> KeyboardView { KeyboardView() }

    func updateNSView(_ view: KeyboardView, context: Context) {
        view.shelf = shelf
        view.pasteboard = pasteboard
        view.setActive(isActive)
    }

    static func dismantleNSView(_ view: KeyboardView, coordinator: ()) { view.setActive(false) }

    final class KeyboardView: NSView {
        var shelf: ShelfStore?
        var pasteboard: NSPasteboard = .general
        private var active = false
        private var monitor: Any?

        override var acceptsFirstResponder: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if active { focus() }
        }

        func setActive(_ value: Bool) {
            guard active != value else { return }
            active = value
            if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
            if value {
                monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown]) { [weak self] event in
                    guard let self, self.active, let window = self.window,
                          window.attachedSheet == nil, event.window === window else { return event }
                    if event.type != .keyDown {
                        if self.bounds.contains(self.convert(event.locationInWindow, from: nil)) { self.focus() }
                        return event
                    }
                    guard window.isKeyWindow else { return event }
                    return self.handle(event) ? nil : event
                }
                focus()
            } else if window?.firstResponder === self { window?.resignKey() }
        }

        private func focus() {
            DispatchQueue.main.async { [weak self] in
                guard let self, self.active, let window = self.window, window.isVisible else { return }
                window.makeKey()
                window.makeFirstResponder(self)
            }
        }

        private func handle(_ event: NSEvent) -> Bool {
            guard let shelf else { return false }
            let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
            if modifiers == .command {
                switch event.charactersIgnoringModifiers?.lowercased() {
                case "v": shelf.paste(from: pasteboard); return true
                case "c": shelf.selectedItem?.copy(to: pasteboard); return true
                default: return false
                }
            }
            guard modifiers.isEmpty else { return false }
            switch event.keyCode {
            case 49:
                if let item = shelf.selectedItem { ShelfPreview.shared.toggle(item) }
            case 123: shelf.select(offset: -1)
            case 124: shelf.select(offset: 1)
            case 36, 76:
                if let item = shelf.selectedItem { NSWorkspace.shared.open(item.url) }
            case 53: window?.resignKey()
            default: return false
            }
            return true
        }

        deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
    }
}
