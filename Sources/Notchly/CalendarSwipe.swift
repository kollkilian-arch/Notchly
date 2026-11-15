import SwiftUI

/// Turns a horizontal trackpad gesture into discrete dates, without treating vertical scrolling
/// or the inertial tail of a gesture as more day selections.
struct DaySwipeAccumulator {
    private var distance: CGFloat = 0
    mutating func reset() { distance = 0 }
    mutating func consume(x: CGFloat, y: CGFloat) -> Int {
        guard abs(x) > abs(y) else { return 0 }
        distance = max(-108, min(108, distance + x))
        let steps = max(-3, min(3, Int(distance / 36)))
        distance -= CGFloat(steps) * 36
        return -steps
    }
}

struct CalendarSwipeInput: NSViewRepresentable {
    var shift: (Int) -> Void
    func makeNSView(context: Context) -> SwipeView { SwipeView(shift: shift) }
    func updateNSView(_ view: SwipeView, context: Context) { view.shift = shift }
    static func dismantleNSView(_ view: SwipeView, coordinator: ()) { view.stop() }

    final class SwipeView: NSView {
        var shift: (Int) -> Void
        private var monitor: Any?
        private var accumulator = DaySwipeAccumulator()
        init(shift: @escaping (Int) -> Void) {
            self.shift = shift
            super.init(frame: .zero)
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .swipe]) { [weak self] event in
                guard let self, let window = self.window, event.window === window,
                      self.bounds.contains(self.convert(event.locationInWindow, from: nil)) else { return event }
                if event.type == .swipe {
                    guard abs(event.deltaX) > abs(event.deltaY) else { return event }
                    self.shift(event.deltaX < 0 ? 1 : -1)
                    return nil
                }
                if event.phase.contains(.began) { self.accumulator.reset() }
                guard event.momentumPhase.isEmpty else { return event }
                guard abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) else { return event }
                let steps = self.accumulator.consume(x: event.scrollingDeltaX, y: event.scrollingDeltaY)
                if steps != 0 { self.shift(steps) }
                if event.phase.contains(.ended) || event.phase.contains(.cancelled) { self.accumulator.reset() }
                return nil
            }
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        func stop() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }
        deinit { stop() }
    }
}
