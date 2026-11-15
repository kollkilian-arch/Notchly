import Foundation

enum DashboardWidget: String, CaseIterable, Identifiable, Codable {
    case music, calendar
    var id: String { rawValue }
    var title: String { self == .music ? "Music" : "Calendar" }
}

/// Stored independently from the stable preferences so trying a layout never resets them.
struct DashboardLayout: Equatable, Codable {
    var order: [DashboardWidget] = [.music, .calendar]
    var hidden: Set<DashboardWidget> = []

    static func decode(_ json: String) -> DashboardLayout {
        guard let data = json.data(using: .utf8),
              var layout = try? JSONDecoder().decode(Self.self, from: data) else { return Self() }
        var seen = Set<DashboardWidget>()
        layout.order = layout.order.filter { seen.insert($0).inserted }
        layout.order += DashboardWidget.allCases.filter { !seen.contains($0) }
        if layout.hidden.count == DashboardWidget.allCases.count { layout.hidden.remove(.music) }
        return layout
    }

    var json: String { (try? JSONEncoder().encode(self)).flatMap { String(data: $0, encoding: .utf8) } ?? "" }
    func visible(calendarEnabled: Bool) -> [DashboardWidget] {
        order.filter { !hidden.contains($0) && ($0 != .calendar || calendarEnabled) }
    }

    mutating func move(_ widget: DashboardWidget, by offset: Int) {
        guard let from = order.firstIndex(of: widget), order.indices.contains(from + offset) else { return }
        order.swapAt(from, from + offset)
    }

    mutating func setVisible(_ widget: DashboardWidget, _ visible: Bool) {
        if visible { hidden.remove(widget) }
        else if hidden.count < DashboardWidget.allCases.count - 1 { hidden.insert(widget) }
    }
}
