import SwiftUI

struct CalendarCarousel: View {
    @ObservedObject var calendar: CalendarMonitor
    @AppStorage(Pref.showJoinButton) private var showJoin = true
    private var days: [Date] { CalendarMonitor.carouselDays(centeredOn: calendar.browsingDay) }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var events: [CalEvent] { CalendarMonitor.events(calendar.weekEvents, on: calendar.browsingDay) }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                Button { calendar.selectDay(Date()) } label: {
                    Text(calendar.browsingDay.formatted(.dateTime.month(.abbreviated)))
                        .font(.system(size: 23, weight: .bold))
                        .fixedSize()
                }
                .buttonStyle(.plain)
                .help("Return to today")
                .accessibilityLabel("\(calendar.browsingDay.formatted(.dateTime.month(.wide).year())). Return to today")
                HStack(spacing: 0) {
                    ForEach(Array(days.enumerated()), id: \.element) { index, day in
                        dayButton(day, distance: abs(index - 3))
                    }
                }
                .frame(height: 55)
                .background(CalendarSwipeInput(shift: shift))
                .highPriorityGesture(DragGesture(minimumDistance: 14).onEnded { value in
                    guard abs(value.translation.width) > abs(value.translation.height) else { return }
                    shift(value.translation.width < 0 ? 1 : -1)
                })
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.22), value: calendar.browsingDay)
            }
            if !calendar.authorized {
                CalendarView(calendar: calendar)
            } else if events.isEmpty {
                VStack(spacing: 5) {
                    Image(systemName: "calendar.badge.checkmark").font(.system(size: 18))
                    Text("Nothing for \(Calendar.current.isDateInToday(calendar.browsingDay) ? "today" : "this day")")
                        .font(.system(size: 11))
                }
                .foregroundStyle(.white.opacity(0.55))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 9) {
                        ForEach(events, id: \.occurrenceKey) { event in
                            HStack(spacing: 7) {
                                Capsule().fill(Color(nsColor: event.color)).frame(width: 3, height: 29)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(event.title).font(.system(size: 11, weight: .semibold)).lineLimit(1)
                                    Text(event.isAllDay ? "All day" : event.start.formatted(date: .omitted, time: .shortened))
                                        .font(.system(size: 10)).foregroundStyle(.white.opacity(0.6))
                                }
                                Spacer(minLength: 0)
                                if showJoin, let meeting = event.meeting {
                                    JoinButton(meeting: meeting, urgent: event.start <= Date() && event.end > Date()) {
                                        calendar.markJoined(event)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            HStack {
                dayStepButton(-1, symbol: "chevron.left", label: "Previous day")
                Spacer()
                Button("Today") { calendar.selectDay(Date()) }
                    .font(.system(size: 9)).foregroundStyle(.white.opacity(0.4)).buttonStyle(.plain)
                Spacer()
                dayStepButton(1, symbol: "chevron.right", label: "Next day")
            }
        }
        .onAppear { calendar.selectDay(calendar.browsingDay) }
        .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged)) { _ in calendar.selectDay(Date()) }
    }

    private func dayButton(_ day: Date, distance: Int) -> some View {
        let selected = Calendar.current.isDate(day, inSameDayAs: calendar.browsingDay)
        let today = Calendar.current.isDateInToday(day)
        let hasEvents = !CalendarMonitor.events(calendar.weekEvents, on: day).isEmpty
        return Button { calendar.selectDay(day) } label: {
            VStack(spacing: 4) {
                Text(day.formatted(.dateTime.weekday(.narrow)))
                    .font(.system(size: 9)).foregroundStyle(.white.opacity(0.5))
                Text(day.formatted(.dateTime.day()))
                    .font(.system(size: selected ? 22 : 16, weight: selected ? .bold : .medium))
                    .foregroundStyle(today ? Color.accentColor : .white.opacity(selected ? 1 : 0.65))
                Circle().fill(hasEvents ? Color.accentColor : .clear).frame(width: 3, height: 3)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 5)
            .opacity(selected || today ? 1 : max(0.12, 0.8 - Double(distance) * 0.22))
            .scaleEffect(selected ? 1 : 1 - Double(distance) * 0.08)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(day.formatted(date: .complete, time: .omitted))
        .accessibilityValue("\(selected ? "Selected. " : "")\(hasEvents ? "Has events" : "No events")")
    }

    private func dayStepButton(_ offset: Int, symbol: String, label: String) -> some View {
        Button { shift(offset) } label: {
            Image(systemName: symbol).font(.system(size: 10, weight: .semibold)).frame(width: 18, height: 22)
        }.buttonStyle(.plain).help(label).accessibilityLabel(label)
    }

    private func shift(_ days: Int) {
        if let day = Calendar.current.date(byAdding: .day, value: days, to: calendar.browsingDay) {
            calendar.selectDay(day)
        }
    }
}
