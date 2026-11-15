import AppKit
import EventKit

struct CalEvent: Identifiable, Equatable {
    let id: String
    let title: String
    let start: Date
    let end: Date
    let color: NSColor
    /// A video-call link found in the event's URL, location or notes.
    var meeting: MeetingLink? = nil

    /// Unique per occurrence (a recurring event keeps one identifier for all its occurrences).
    var occurrenceKey: String { "\(id)|\(Int(start.timeIntervalSince1970))" }
}

final class CalendarMonitor: ObservableObject {
    @Published private(set) var events: [CalEvent] = []
    @Published private(set) var authorized = false
    @Published private(set) var denied = false
    /// Meetings the user has already joined: no more indicator for these.
    @Published private(set) var joinedMeetings: Set<String> = []

    /// Longest the list goes without a refresh: events that come into the 48-hour window as time
    /// passes are the only thing that can change without a notification.
    static let maxReloadInterval: TimeInterval = 30 * 60

    private let store = EKEventStore()
    private var reloadTimer: Timer?
    private var observers: [(center: NotificationCenter, token: NSObjectProtocol)] = []

    /// Reloads when EventKit reports a change, when the Mac wakes, or when the clock, time zone or
    /// day changes, and otherwise only when the next listed event ends. (The meeting indicator does
    /// not depend on this: it is re-evaluated against the clock every second by the notch itself.)
    init() {
        refreshAuthorization()
        observe(.EKEventStoreChanged, on: .default, object: store)
        observe(.NSSystemClockDidChange, on: .default)
        observe(.NSCalendarDayChanged, on: .default)
        observe(NSNotification.Name.NSSystemTimeZoneDidChange, on: .default)
        observe(NSWorkspace.didWakeNotification, on: NSWorkspace.shared.notificationCenter)
    }

    /// For the debug snapshot tool: fixed events, no EventKit access, no refresh timer.
    init(preview events: [CalEvent]) {
        self.events = events
        authorized = true
    }

    deinit {
        reloadTimer?.invalidate()
        for (center, token) in observers { center.removeObserver(token) }
    }

    private func observe(_ name: Notification.Name, on center: NotificationCenter, object: Any? = nil) {
        let token = center.addObserver(forName: name, object: object, queue: .main) { [weak self] _ in self?.reload() }
        observers.append((center, token))
    }

    /// When the listed events next change by themselves: the moment the earliest one ends, but
    /// never later than `maxReloadInterval`.
    static func nextReload(after events: [CalEvent], now: Date) -> Date {
        let cap = now.addingTimeInterval(maxReloadInterval)
        let nextEnd = events.map(\.end).filter { $0 > now }.min()
        // A second past the end, so the event is really over when the reload filters on `endDate > now`.
        return min(cap, nextEnd.map { $0.addingTimeInterval(1) } ?? cap)
    }

    private func scheduleReload(now: Date) {
        reloadTimer?.invalidate()
        let fire = Self.nextReload(after: events, now: now)
        let timer = Timer(fire: fire, interval: 0, repeats: false) { [weak self] _ in self?.reload() }
        RunLoop.main.add(timer, forMode: .common)
        reloadTimer = timer
    }

    // MARK: Meeting indicator

    /// The meeting to hint at in the collapsed notch: it has a video-call link, starts within
    /// `leadMinutes` (or began at most 10 minutes ago, since people join late) and wasn't joined yet.
    func imminentMeeting(at now: Date = Date(), leadMinutes: Int) -> CalEvent? {
        let eligible = events.filter { e in
            guard e.meeting != nil, e.end > now, !joinedMeetings.contains(e.occurrenceKey) else { return false }
            let untilStart = e.start.timeIntervalSince(now)
            return untilStart <= Double(leadMinutes) * 60 && untilStart >= -10 * 60
        }
        // A call starting now takes precedence over an older call the user hasn't marked joined.
        return eligible.first { (-60...60).contains($0.start.timeIntervalSince(now)) } ?? eligible.first
    }

    /// The meeting shown in the collapsed notch, or nil (also when the user turned the indicator off).
    var indicatorMeeting: CalEvent? {
        guard Pref.bool(Pref.meetingIndicator) else { return nil }
        return imminentMeeting(leadMinutes: Pref.int(Pref.meetingLeadMinutes))
    }

    func markJoined(_ event: CalEvent) {
        joinedMeetings.insert(event.occurrenceKey)
    }

    func requestAccessIfNeeded() {
        guard EKEventStore.authorizationStatus(for: .event) == .notDetermined else { return }
        requestAccess()
    }

    func requestAccess() {
        store.requestFullAccessToEvents { [weak self] _, _ in
            DispatchQueue.main.async { self?.refreshAuthorization() }
        }
    }

    private func refreshAuthorization() {
        let status = EKEventStore.authorizationStatus(for: .event)
        authorized = status == .fullAccess
        denied = status == .denied || status == .restricted
        if authorized { reload() }
    }

    func reload() {
        guard authorized else { return }
        let now = Date()
        let end = Calendar.current.date(byAdding: .hour, value: 48, to: now) ?? now.addingTimeInterval(172_800)
        let predicate = store.predicateForEvents(withStart: now, end: end, calendars: nil)
        let loaded: [CalEvent] = store.events(matching: predicate)
            .filter { !$0.isAllDay && $0.endDate > now }
            .sorted { $0.startDate < $1.startDate }
            .prefix(3)
            .map {
                CalEvent(id: $0.eventIdentifier ?? UUID().uuidString,
                         title: $0.title ?? "Untitled",
                         start: $0.startDate, end: $0.endDate,
                         color: $0.calendar.color ?? .systemBlue,
                         meeting: MeetingLinks.find(in: [$0.url?.absoluteString, $0.location,
                                                        $0.structuredLocation?.title, $0.notes]))
            }
        if loaded != events { events = loaded }       // an unchanged list must not redraw the notch
        scheduleReload(now: now)
    }
}
