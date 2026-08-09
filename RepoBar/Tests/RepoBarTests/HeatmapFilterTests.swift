import Foundation
@testable import RepoBarCore
import Testing

struct HeatmapFilterTests {
    @Test
    func `span labels are stable`() {
        #expect(HeatmapSpan.oneMonth.label == "1 month")
        #expect(HeatmapSpan.threeMonths.label == "3 months")
        #expect(HeatmapSpan.sixMonths.label == "6 months")
        #expect(HeatmapSpan.twelveMonths.label == "12 months")
    }

    @Test
    func `filter drops older cells`() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))

        let now = try #require(calendar.date(from: DateComponents(year: 2025, month: 12, day: 15, hour: 12)))
        let recent = try #require(calendar.date(byAdding: .day, value: -10, to: now))
        let old = try #require(calendar.date(byAdding: .day, value: -80, to: now))

        let cells = [
            HeatmapCell(date: old, count: 1),
            HeatmapCell(date: recent, count: 2)
        ]

        let filtered = HeatmapFilter.filter(cells, span: .oneMonth, now: now)
        #expect(filtered.count == 1)
        #expect(filtered.first?.date == recent)
    }

    @Test
    func `aligned range starts on week boundary`() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
        calendar.firstWeekday = 2

        let now = try #require(calendar.date(from: DateComponents(year: 2025, month: 12, day: 20, hour: 12)))
        let range = HeatmapFilter.alignedRange(span: .threeMonths, now: now, calendar: calendar)
        let weekday = calendar.component(.weekday, from: range.start)
        #expect(weekday == calendar.firstWeekday)
        #expect(range.end == calendar.startOfDay(for: now))
    }
}
