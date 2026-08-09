import Foundation

public enum HeatmapSpan: Int, CaseIterable, Equatable, Codable {
    case oneMonth = 1
    case threeMonths = 3
    case sixMonths = 6
    case twelveMonths = 12

    public var label: String {
        switch self {
        case .oneMonth: "1 month"
        case .threeMonths: "3 months"
        case .sixMonths: "6 months"
        case .twelveMonths: "12 months"
        }
    }

    public var months: Int {
        self.rawValue
    }
}

public struct HeatmapRange: Equatable, Codable, Sendable {
    public let start: Date
    public let end: Date

    public init(start: Date, end: Date) {
        self.start = start
        self.end = end
    }
}

public enum HeatmapFilter {
    public static func filter(_ cells: [HeatmapCell], span: HeatmapSpan, now: Date = Date()) -> [HeatmapCell] {
        let range = range(span: span, now: now, alignToWeek: false)
        return self.filter(cells, range: range)
    }

    public static func alignedRange(
        span: HeatmapSpan,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> HeatmapRange {
        let end = calendar.startOfDay(for: now)
        let startMonth = calendar.date(byAdding: .month, value: -span.months, to: end) ?? end
        let startComponents = calendar.dateComponents([.year, .month], from: startMonth)
        let monthStart = calendar.date(from: startComponents) ?? startMonth
        let weekday = calendar.firstWeekday
        let alignedStart = calendar.nextDate(
            after: monthStart,
            matching: DateComponents(weekday: weekday),
            matchingPolicy: .nextTime,
            direction: .backward
        ) ?? monthStart
        return HeatmapRange(start: alignedStart, end: end)
    }

    public static func range(
        span: HeatmapSpan,
        now: Date = Date(),
        calendar: Calendar = .current,
        alignToWeek: Bool = true
    ) -> HeatmapRange {
        guard alignToWeek else {
            let end = calendar.startOfDay(for: now)
            let start = calendar.date(byAdding: .month, value: -span.months, to: end) ?? end
            return HeatmapRange(start: start, end: end)
        }

        return self.alignedRange(span: span, now: now, calendar: calendar)
    }

    public static func filter(_ cells: [HeatmapCell], range: HeatmapRange) -> [HeatmapCell] {
        cells.filter { $0.date >= range.start && $0.date <= range.end }
    }

    public static func filter(
        _ cells: [HeatmapCell],
        span: HeatmapSpan,
        now: Date = Date(),
        alignToWeek: Bool
    ) -> [HeatmapCell] {
        let range = range(span: span, now: now, alignToWeek: alignToWeek)
        return self.filter(cells, range: range)
    }
}
